import AVFoundation
import Foundation
import TokensCore

/// Orukeet-only rolling offline recognition. The current window's hypothesis is
/// replaceable; closed windows are never decoded again, so they publish as settled. This is not the unsupported
/// native StreamingRecognize API, and contains no Apple recognizer or fallback.
/// A live talk starts before the model is ready: converted 16 kHz audio is held
/// as a bounded pre-roll while the worker loads, then replayed, so no speech is lost.
final class OrukeetSpeechPipeline: StreamingSpeechPipeline, @unchecked Sendable {
    let engineIdentity = "orukeet"
    let requiresExplicitFinalization = true
    /// Pre-roll bound and load deadline: above the worker's 25 s start limit plus
    /// asset verification. About 2.2 MB of 16 kHz mono floats.
    static let loadAllowance: TimeInterval = 35
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var loaded = false // lock
    private var bufferedSamples = 0 // lock; undecoded 16 kHz samples held by windows
    /// Finish's bound: the final decode scaled to the audio still undecoded, plus
    /// whatever remains of a pending model load. A hung decode fails in seconds, not 30.
    var finalizationTimeout: TimeInterval {
        let (isLoaded, samples, queued) = locked { (loaded, bufferedSamples, queuedInputSeconds) }
        let pendingLoad = isLoaded ? 0 : max(0, createdAt + Self.loadAllowance - ProcessInfo.processInfo.systemUptime)
        return pendingLoad + Self.finalDecodeBudget(seconds: Double(samples) / 16000 + queued)
    }
    /// About 3 s plus 0.2 s per undecoded second (a normal final decode is well under
    /// 1 s), capped at 8 s per 30 s window. The base also covers one in-flight prefix.
    static func finalDecodeBudget(seconds: Double) -> TimeInterval {
        let windows = max(1, (seconds / 30).rounded(.up))
        return min(3 + 0.2 * max(0, seconds), 8 * windows)
    }
    var isLoading: Bool { locked { !loaded } }
    private enum Phase { case accepting, finishing, finished, failed, canceled }
    private let lock = NSLock()
    private var phase: Phase = .accepting
    private var generation = UUID()
    private var snapshot = TranscriptSnapshot(finalizedText: "", volatileText: "")
    private var failure: String?
    private var queuedInputSeconds: Double = 0
    private let queue = DispatchQueue(label: "tokens.orukeet.audio", qos: .userInitiated)
    private let naturalFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let onUpdate: (TranscriptSnapshot) -> Void
    private let onFailure: (String) -> Void
    private let onLoaded: () -> Void
    // The following fields belong exclusively to queue, never the tap/main thread.
    // decoder is nil while the model loads; audio then only accumulates (pre-roll).
    private var decoder: OrukeetDecoding?
    private var releaseDecoder: ((Bool) -> Void)?
    private var windows = OrukeetAudioWindows()
    private var segments: [OrukeetDecodedAudio] = []
    private var segmentWords: [TimedWord] = []
    private var volatile: OrukeetDecodedAudio?
    private var volatileOrigin: Double = 0
    private var volatileDuration: Double = 0
    private var inFlight = false
    // A canceled/failed talk whose decode is still in flight returns the lease
    // only after the worker answers, so the next talk never sees a busy worker.
    private var releaseAfterInFlight = false
    private var lastPrefixCount = 0
    private let tuning = OrukeetLiveTuning.current
    // Measurement only: when audio first arrived and whether words have appeared yet.
    private var firstAudioUptime: TimeInterval?
    private var hasShownWords = false
    private var inputEnded = false
    private var released = false
    private var completion: ((TranscriptSnapshot) -> Void)?

    static func prewarm() async throws { try await OrukeetWorkerPool.shared.prewarm() }
    static func unloadIfIdle() async { await OrukeetWorkerPool.shared.unloadIfIdle() }
    static func make(naturalFormat: AVAudioFormat,
                     onFailure: @escaping (String) -> Void = { _ in },
                     onUpdate: @escaping (TranscriptSnapshot) -> Void) async throws -> OrukeetSpeechPipeline {
        let worker = try await OrukeetWorkerPool.shared.acquire()
        do {
            return try OrukeetSpeechPipeline(naturalFormat: naturalFormat, decoder: worker,
                release: { reusable in Task { await OrukeetWorkerPool.shared.release(worker, reusable: reusable) } },
                onFailure: onFailure, onUpdate: onUpdate)
        } catch { await OrukeetWorkerPool.shared.release(worker, reusable: true); throw error } // Unused, still warm.
    }
    /// Live capture: returns at once so the microphone tap attaches immediately.
    /// The lease is acquired in the background (a cold load takes seconds) and
    /// attached when ready; the task retains the pipeline until then, so a talk
    /// canceled during the load still hands the loaded model back warm.
    static func start(naturalFormat: AVAudioFormat,
                      onFailure: @escaping (String) -> Void = { _ in },
                      onUpdate: @escaping (TranscriptSnapshot) -> Void,
                      onLoaded: @escaping () -> Void = {}) throws -> OrukeetSpeechPipeline {
        let pipeline = try OrukeetSpeechPipeline(naturalFormat: naturalFormat, decoder: nil,
                                                 onFailure: onFailure, onUpdate: onUpdate, onLoaded: onLoaded)
        Task.detached(priority: .userInitiated) {
            do {
                let worker = try await OrukeetWorkerPool.shared.acquire()
                pipeline.attach(worker, release: { reusable in
                    Task { await OrukeetWorkerPool.shared.release(worker, reusable: reusable) }
                })
            } catch { pipeline.loadFailed(error) }
        }
        return pipeline
    }
    static func startFailureMessage(_ error: Error) -> String {
        let reason = (error as? OrukeetFailure)?.localizedDescription ?? OrukeetFailure.workerExited.localizedDescription
        return "\(LocalSpeechModelName.current) could not start. \(reason) Choose Apple in Settings to switch engines."
    }
    /// Injected decoders permit lifecycle/window tests without models or microphone.
    /// A nil decoder starts in the loading state; attach(_:release:) supplies it.
    init(naturalFormat: AVAudioFormat, decoder: OrukeetDecoding?,
         release: ((Bool) -> Void)? = nil, onFailure: @escaping (String) -> Void = { _ in },
         onUpdate: @escaping (TranscriptSnapshot) -> Void = { _ in },
         onLoaded: @escaping () -> Void = {}) throws {
        guard naturalFormat.sampleRate.isFinite, (8000...192000).contains(naturalFormat.sampleRate),
              naturalFormat.channelCount > 0, naturalFormat.channelCount <= 8,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false) else { throw OrukeetFailure.invalidAudio }
        self.naturalFormat = naturalFormat; self.targetFormat = target; self.decoder = decoder
        self.releaseDecoder = decoder.map { decoder in release ?? { _ in decoder.shutdown() } }
        self.onUpdate = onUpdate; self.onFailure = onFailure; self.onLoaded = onLoaded
        self.loaded = decoder != nil
        if naturalFormat == target { converter = nil }
        else {
            guard let conversion = AVAudioConverter(from: naturalFormat, to: target) else { throw OrukeetFailure.conversion }
            // Normal priming synthesizes the resampler's trailing silence at EOF.
            // .none is latency mode: it can omit the delayed final samples even
            // after endOfStream, shortening the captured clock and final word.
            conversion.primeMethod = .normal
            // Mix every channel to mono: a mic on input 2 of an interface was silent here (build 81).
            conversion.downmix = true
            converter = conversion
        }
        if decoder == nil {
            queue.asyncAfter(deadline: .now() + Self.loadAllowance) { [weak self] in
                guard let self, self.decoder == nil else { return }
                self.fail(OrukeetFailure.startupTimeout, workerFault: false, startup: true)
            }
        }
    }
    /// Supplies the leased worker and replays the pre-roll. A talk that ended while
    /// loading (canceled or failed pipeline-side) returns the unused worker warm.
    func attach(_ decoder: OrukeetDecoding, release: @escaping (Bool) -> Void) {
        queue.async {
            self.decoder = decoder; self.releaseDecoder = release
            let token: UUID? = self.locked {
                self.loaded = true
                return self.phase == .accepting || self.phase == .finishing ? self.generation : nil
            }
            guard let token else { self.release(reusable: true); return }
            DispatchQueue.main.async { guard self.active(token) else { return }; self.onLoaded() }
            self.pump(token)
        }
    }
    func loadFailed(_ error: Error) {
        queue.async { self.fail(error, workerFault: false, startup: true) }
    }
    private func locked<T>(_ action: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return action() }
    var currentSnapshot: TranscriptSnapshot { locked { snapshot } }
    var currentResult: (snapshot: TranscriptSnapshot, failure: String?) { locked { (snapshot, failure) } }
    private func active(_ token: UUID) -> Bool {
        locked { generation == token && (phase == .accepting || phase == .finishing) }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        // Tap work is a bounded borrowed-buffer copy and queue admission only.
        lock.lock()
        guard phase == .accepting, buffer.frameLength > 0 else { lock.unlock(); return }
        let duration = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
        guard buffer.format == naturalFormat, duration.isFinite, duration <= 1,
              queuedInputSeconds + duration <= 2 else {
            lock.unlock(); fail(OrukeetFailure.overload, workerFault: false); return
        }
        guard let copy = ModernAudioBuffer.copy(buffer) else { lock.unlock(); fail(OrukeetFailure.conversion, workerFault: false); return }
        let token = generation
        queuedInputSeconds += duration
        // Queue insertion occurs under the lifecycle lock, so finish is ordered after
        // every accepted buffer. Conversion and IPC never run on the tap callback.
        queue.async { [weak self] in
            guard let self else { return }
            self.locked { self.queuedInputSeconds = max(0, self.queuedInputSeconds - duration) }
            guard self.active(token) else { return }
            do { try self.convert(copy); self.pump(token) }
            catch { self.fail(error, workerFault: false, startup: (error as? OrukeetFailure) == .startupTimeout) }
        }
        lock.unlock()
    }
    private func accept(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        guard let samples = buffer.floatChannelData?[0] else { throw OrukeetFailure.conversion }
        if decoder == nil, Double(windows.samples.count + Int(buffer.frameLength)) > Self.loadAllowance * 16000 {
            throw OrukeetFailure.startupTimeout // Pre-roll full: the model never became ready.
        }
        try windows.append(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
        if firstAudioUptime == nil { firstAudioUptime = ProcessInfo.processInfo.systemUptime }
        noteBuffered()
    }
    private func noteBuffered() { let count = windows.samples.count; locked { bufferedSamples = count } }
    private func convert(_ buffer: AVAudioPCMBuffer) throws {
        guard let converter else { try accept(buffer); return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / naturalFormat.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { throw OrukeetFailure.conversion }
        var supplied = false
        var error: NSError?
        let outcome = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, outcome != .error else { throw OrukeetFailure.conversion }
        try accept(output)
    }
    private func flushConverter() throws {
        guard let converter else { return }
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { throw OrukeetFailure.conversion }
            var error: NSError?
            let outcome = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            guard error == nil, outcome != .error else { throw OrukeetFailure.conversion }
            try accept(output)
            if outcome == .endOfStream { return }
            if output.frameLength == 0 && outcome == .inputRanDry { return }
        }
        throw OrukeetFailure.conversion // Never silently discard an undrained converter tail.
    }
    func finish(completion: @escaping (TranscriptSnapshot) -> Void) {
        let budget = finalizationTimeout
        lock.lock()
        guard phase == .accepting else { lock.unlock(); return }
        phase = .finishing
        let token = generation
        queue.async { [weak self] in
            guard let self, self.active(token) else { return }
            self.completion = completion
            do { try self.flushConverter(); self.inputEnded = true; self.pump(token) }
            catch { self.fail(error, workerFault: false) }
        }
        queue.asyncAfter(deadline: .now() + budget) { [weak self] in
            guard let self, self.active(token) else { return }
            self.fail(OrukeetFailure.requestTimeout)
        }
        lock.unlock()
    }
    private func pump(_ token: UUID) {
        guard active(token), !inFlight, let decoder else { return } // Loading: keep the pre-roll.
        if inputEnded && windows.samples.isEmpty { complete(token); return }
        let closesWindow = windows.boundary != nil || inputEnded
        let count = windows.boundary ?? min(windows.samples.count, windows.maximumWindow)
        let step = hasShownWords ? tuning.stepSamples : tuning.firstStepSamples
        guard count > 0, closesWindow || count - lastPrefixCount >= step else { return }
        // Nothing but quiet so far: no decode, so no invented words (build 81, isQuiet).
        if windows.isQuiet(count) {
            guard closesWindow else { return }
            Diagnostics.event("orukeet_quiet_window_skipped seconds=\(String(format: "%.2f", Double(count) / 16000)) final=\(inputEnded)")
            windows.commit(count); lastPrefixCount = 0; volatile = nil
            noteBuffered()
            publish(token)
            pump(token)
            return
        }
        if inputEnded { Diagnostics.event("orukeet_final_window seconds=\(String(format: "%.2f", Double(count) / 16000))") }
        let samples = Array(windows.samples.prefix(count))
        let origin = Double(windows.originSamples) / 16000
        inFlight = true
        if !closesWindow { lastPrefixCount = count }
        // Strong capture: the lease must outlive a canceled talk until the worker answers.
        decoder.decode(samples) { result in
            self.queue.async {
                self.inFlight = false
                guard self.active(token) else {
                    // The answer is discarded. A normal answer means the worker is idle and
                    // healthy; a failed one already stopped the worker (OrukeetWorker.decode).
                    if self.releaseAfterInFlight {
                        if case .success = result { self.release(reusable: true) } else { self.release(reusable: false) }
                    }
                    return
                }
                switch result {
                case .failure(let error): self.fail(error)
                case .success(let decoded):
                    if closesWindow {
                        self.segments.append(decoded)
                        self.segmentWords += Self.timedWords(decoded, origin: origin, duration: Double(count) / 16000, final: true)
                        // The whole closed window has succeeded before any of its PCM
                        // is removed; remaining samples retain their exact next origin.
                        self.windows.commit(count); self.lastPrefixCount = 0; self.volatile = nil
                        self.noteBuffered()
                    } else {
                        self.volatile = decoded; self.volatileOrigin = origin; self.volatileDuration = Double(count) / 16000
                    }
                    if !self.hasShownWords, !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.hasShownWords = true
                        let since = self.firstAudioUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                        Diagnostics.event("orukeet_first_words ms=\(Int(since * 1000))")
                    }
                    self.publish(token)
                    self.pump(token)
                }
            }
        }
    }
    private static func joined(_ parts: [String]) -> String {
        parts.reduce("") { previous, next in
            guard !next.isEmpty else { return previous }
            guard !previous.isEmpty else { return next }
            let separator = previous.last?.isWhitespace == true || next.first?.isWhitespace == true ? "" : " "
            return previous + separator + next
        }
    }
    static func timedWords(_ result: OrukeetDecodedAudio, origin: Double, duration: Double, final: Bool) -> [TimedWord] {
        // Invalid/unavailable native offsets remain absent; never estimate or clip.
        guard result.words.allSatisfy({ $0.startMS.isFinite && $0.endMS.isFinite && $0.startMS >= 0
            && $0.endMS >= $0.startMS && $0.endMS <= duration * 1000 + 1 }) else { return [] }
        let words = result.words.map { TimedWord(text: $0.text, start: origin + $0.startMS / 1000,
                                                 end: origin + $0.endMS / 1000, isFinal: final) }
        return alignedWords(words, text: result.text)
    }
    static func alignedWords(_ words: [TimedWord], text: String) -> [TimedWord] {
        // Native display text may restore punctuation/case, but timestamps must
        // still account for every whitespace-delimited lexical word, in order.
        func lexical(_ value: String) -> [String] {
            value.split(whereSeparator: \.isWhitespace).map {
                $0.lowercased().filter { $0.isLetter || $0.isNumber }
            }.filter { !$0.isEmpty }
        }
        let expected = lexical(text)
        let actual = words.map { lexical($0.text) }
        guard actual.allSatisfy({ $0.count == 1 }), expected == actual.flatMap({ $0 }) else { return [] }
        return words
    }
    private func proposed(final: Bool) -> TranscriptSnapshot {
        // Closed windows are settled during recording too; only the open window is volatile.
        let settled = Self.joined(segments.map(\.text))
        let open = volatile?.text ?? ""
        let text = Self.joined([settled, open])
        var words = segmentWords
        if let volatile { words += Self.timedWords(volatile, origin: volatileOrigin, duration: volatileDuration, final: false) }
        // A closed window with missing timing cannot leave a partially timed
        // whole transcript when later windows have valid offsets (or vice versa).
        words = Self.alignedWords(words, text: text)
        if final { words = words.map { var word = $0; word.isFinal = true; return word } }
        return TranscriptSnapshot(finalizedText: final ? text : settled, volatileText: final ? "" : open, timedWords: words)
    }
    private func publish(_ token: UUID) {
        let value = proposed(final: false)
        let accepted = locked { () -> Bool in
            guard generation == token, phase == .accepting || phase == .finishing else { return false }
            snapshot = value; return true
        }
        guard accepted else { return }
        DispatchQueue.main.async { [weak self] in guard let self, self.active(token) else { return }; self.onUpdate(value) }
    }
    private func complete(_ token: UUID) {
        let value = proposed(final: true)
        let accepted = locked { () -> Bool in
            guard generation == token, phase == .finishing else { return false }
            phase = .finished; snapshot = value; return true
        }
        guard accepted else { return }
        let callback = completion; completion = nil
        release(reusable: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.locked({ self.generation == token && self.phase == .finished }) else { return }
            self.onUpdate(value); callback?(value)
        }
    }
    /// Before attach there is nothing to release yet; attach sees the ended phase.
    private func release(reusable: Bool) {
        guard !released, let releaseDecoder else { return }
        released = true; releaseDecoder(reusable)
    }
    /// workerFault=false is pipeline-side (overload, conversion): the worker stays warm.
    private func fail(_ error: Error, workerFault: Bool = true, startup: Bool = false) {
        let message = startup ? Self.startFailureMessage(error)
            : (error as? OrukeetFailure)?.localizedDescription ?? OrukeetFailure.workerExited.localizedDescription
        let token: UUID? = locked {
            guard phase == .accepting || phase == .finishing else { return nil }
            phase = .failed; failure = message; return generation
        }
        guard let token else { return }
        queue.async { self.releaseWorker(killing: workerFault) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.locked({ self.generation == token && self.phase == .failed }) else { return }
            self.onFailure(message)
        }
    }
    /*
    AudioCapture's own finish deadline gave up on this talk (build 81). Its timer and the one in
    finish(completion:) fire at almost the same moment; when AudioCapture's ran first, its cleanup
    cancel() kept the hung worker leased until the worker's own 25 s limit, and every talk in
    between failed with "still finishing another recording". Failing here as a worker fault shuts
    the worker down and returns the lease at once, so the next talk reloads the model instead.
    A finished, failed or canceled pipeline is left as it is; a model still loading returns warm.
    */
    func abandonFinish() { fail(OrukeetFailure.requestTimeout) }
    func cancel() {
        let shouldRelease = locked { () -> Bool in
            let active = phase == .accepting || phase == .finishing
            phase = .canceled; generation = UUID(); return active
        }
        // Strong capture: a dropped pipeline must still return its lease warm.
        if shouldRelease { queue.async { self.releaseWorker(killing: false) } }
    }
    /// Queue only. Cancellation and pipeline-side failures keep the model warm; an
    /// in-flight decode is awaited and discarded first. Worker faults quarantine it.
    private func releaseWorker(killing: Bool) {
        if killing || !inFlight { release(reusable: !killing) } else { releaseAfterInFlight = true }
    }
    // Every decode strongly retains self, so deinit never races an in-flight request.
    deinit { if !released { releaseDecoder?(true) } }
}

/// A pipeline whose late final decode AudioCapture can abandon as a worker fault (build 81).
protocol AbandonableFinish: AnyObject { func abandonFinish() }
extension OrukeetSpeechPipeline: AbandonableFinish {}

/*
The name of the local model a talk is using, for status lines and messages (build 81): build 79's
Whisper, Parakeet, Canary, Qwen3 and Moonshine all run through this pipeline, and every line said
"Orukeet". An Apple choice never reaches the local pipeline, so it reads Orukeet there.
*/
enum LocalSpeechModelName {
    static var current: String {
        guard let entry = SpeechModelCatalog.entry(SpeechEngineChoice.selectedModelID()),
              entry.runtime != .apple else { return "Orukeet" }
        return entry.name
    }
}
