


//
import AVFoundation
import Foundation
import Speech


// StreamingSpeechPipeline — what AudioCapture needs from a live recognizer


/*
append: one microphone buffer (called on the audio thread).
finish: no more audio; completion gets the final transcript on main.
cancel: stop now; no completion. currentSnapshot: the transcript so far, read on demand.
*/
protocol StreamingSpeechPipeline: AnyObject {
    var engineIdentity: String { get }
    var requiresExplicitFinalization: Bool { get }
    var finalizationTimeout: TimeInterval { get }
    var currentSnapshot: TranscriptSnapshot { get }
    var currentResult: (snapshot: TranscriptSnapshot, failure: String?) { get }
    func append(_ buffer: AVAudioPCMBuffer)
    func finish(completion: @escaping (TranscriptSnapshot) -> Void)
    func cancel()
}


extension StreamingSpeechPipeline {
    var engineIdentity: String { "apple" }
    var requiresExplicitFinalization: Bool { false }
    var finalizationTimeout: TimeInterval { 3 }
    var currentResult: (snapshot: TranscriptSnapshot, failure: String?) { (currentSnapshot, nil) }
}

// StreamingSpeechError — why the fast recognizer could not be set up


enum StreamingSpeechError: Error {
    case unavailable
    case unsupportedLocale
    case missingAudioFormat
    case conversionUnavailable
    case assetsNotInstalled
}


// ModernSpeechPipeline — Apple's on-device SpeechAnalyzer for one talk, start to finish


@available(macOS 26.0, *)
/*
Transcript/lifecycle state is protected by stateLock; converter/input access
is serialized by inputLock. Lifecycle entry points are called on main.
*/
final class ModernSpeechPipeline: StreamingSpeechPipeline, @unchecked Sendable {


    // State — the recognizer parts, the transcript so far, and where the talk is in its life


    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter?
    private let onUpdate: (TranscriptSnapshot) -> Void
    private let onFailure: (String) -> Void
    private var resultTask: Task<Void, Never>?
    private var transcript = TranscriptAccumulator()
    /*
    accepting -> finishing -> finished. Only accepting takes audio. Once finished, no more
    updates are delivered; finish()'s completion is the last thing sent. cancel() jumps
    straight to finished.
    */
    private enum State { case accepting, finishing, finished }
    private var state: State = .accepting
    private let stateLock    = NSLock()
    private let inputLock    = NSLock()
    private var finishTask: Task<Void, Never>?
    /*
    Runs the analyzer over the input stream. Its value is the end time analyzeSequence
    returns (nil if it gave none or threw); finish() finalizes through that time.
    */
    private var analysisTask: Task<CMTime?, Never>?


    // Setup — speech model download, audio format, analyzer and context words


    /*
    Prewarm: make sure the en_US speech model is installed, downloading it once if not,
    so the first talk does not wait for it. Builds no pipeline.
    */
    static func prepareAssets() async throws {
        guard SpeechTranscriber.isAvailable else { throw StreamingSpeechError.unavailable }
        let requestedLocale = Locale(identifier: "en_US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw StreamingSpeechError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        try await ensureAssets(for: transcriber, locale: locale)
    }

//
// :)
//
//
    /*
    Builds a ready pipeline for one talk. naturalFormat is the microphone's format;
    contextualStrings are words the recognizer should expect (names, vocabulary).
    volatileResults + fastResults ask for quick, revisable partial text while talking.
    onUpdate and onFailure are called on main.
    */
    static func make(
        naturalFormat: AVAudioFormat,
        contextualStrings: [String] = [],
        ambientBufferLimit: Int? = nil,
        allowAssetDownload: Bool = true,
        onFailure: @escaping (String) -> Void = { _ in },
        onUpdate: @escaping (TranscriptSnapshot) -> Void
    ) async throws -> ModernSpeechPipeline {
        guard SpeechTranscriber.isAvailable else { throw StreamingSpeechError.unavailable }
        let requestedLocale = Locale(identifier: "en_US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw StreamingSpeechError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            // Word timing places measured-silence notes; it never edits text.
            attributeOptions: [.audioTimeRange]
        )
        print("TTT_SPEECH setup=assets")
        try await ensureAssets(for: transcriber, locale: locale, allowDownload: allowAssetDownload)
        print("TTT_SPEECH setup=format")
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) else { throw StreamingSpeechError.missingAudioFormat }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )
        if !contextualStrings.isEmpty {
            print("TTT_SPEECH setup=context")
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        print("TTT_SPEECH setup=prepare")
        /*
        analyzeSequence prepares from its input; do not await the autonomous
        start route before PCM is available.
        With ambientBufferLimit set, the input stream keeps only the newest that many
        buffers if the analyzer falls behind; otherwise it keeps every buffer.
        */
        let policy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy = ambientBufferLimit.map { .bufferingNewest(max(1, $0)) } ?? .unbounded
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: policy)
        let pipeline = try ModernSpeechPipeline(
            transcriber: transcriber,
            analyzer: analyzer,
            naturalFormat: naturalFormat,
            analyzerFormat: analyzerFormat,
            inputBuilder: builder,
            onFailure: onFailure,
            onUpdate: onUpdate
        )
        pipeline.startReadingResults()
        /*
        One structured lifecycle for finite dictation. It returns control so
        microphone PCM can arrive, and finish awaits the consumed input end.
        */
        pipeline.analysisTask = Task { [weak pipeline] in
            do { return try await analyzer.analyzeSequence(stream) }
            catch {
                DispatchQueue.main.async {
                    guard let pipeline, pipeline.withStateLock({ pipeline.state == .accepting }) else { return }
                    pipeline.onFailure(error.localizedDescription)
                }
                return nil
            }
        }
        return pipeline
    }

    /*
    A converter is made only when the microphone format differs from the analyzer's;
    if one cannot be made, the pipeline is not built.
    */
    private init(
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        naturalFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        onFailure: @escaping (String) -> Void,
        onUpdate: @escaping (TranscriptSnapshot) -> Void
    ) throws {
        self.transcriber    = transcriber
        self.analyzer       = analyzer
        self.analyzerFormat = analyzerFormat
        self.inputBuilder   = inputBuilder
        self.onUpdate       = onUpdate
        self.onFailure      = onFailure
        if naturalFormat == analyzerFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: naturalFormat, to: analyzerFormat) else {
                throw StreamingSpeechError.conversionUnavailable
            }
            // Mix every channel to mono: a mic on input 2 of an interface was silent here (build 81).
            converter.downmix = true
            self.converter = converter
        }
    }

//
// :)
//
//
    private static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale,
                                     allowDownload: Bool = true) async throws {
        let installed = (await SpeechTranscriber.installedLocales).contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        try await SpeechAssetPolicy.ensure(installed: installed, allowDownload: allowDownload) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
    }


    // Results — reading the recognizer's text and word times as they arrive


    /*
    Each result is folded into the transcript under the state lock, then the new snapshot
    is sent to main. After the pipeline is finished, results are dropped. A recognizer
    error while still accepting audio is reported through onFailure.
    */
    private func startReadingResults() {
        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let update: TranscriptSnapshot? = self.withStateLock {
                        guard self.state != .finished else { return nil }
                        self.transcript.apply(String(result.text.characters), isFinal: result.isFinal,
                                              words: Self.timedWords(in: result.text, isFinal: result.isFinal))
                        return self.transcript.snapshot
                    }
                    guard let update else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.withStateLock({ self.state != .finished }) else { return }
                        self.onUpdate(update)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.withStateLock({ self.state == .accepting }) else { return }
                    self.onFailure(message)
                }
            }
        }
    }

    var currentSnapshot: TranscriptSnapshot {
        withStateLock { transcript.snapshot }
    }

    /// Words with the recognizer's own audio ranges. Times are seconds on the
    /// analyzer input clock (capture start = 0). Punctuation without a range
    /// rides with its word; a word with no ranged character stays an untimed
    /// placeholder rather than discarding every other word's time.
    private static func timedWords(in text: AttributedString, isFinal: Bool) -> [TimedWord] {
        var words: [TimedWord] = []
        var current: TimedWord?
        for run in text.runs {
            let range = run.audioTimeRange.flatMap { $0.start.isNumeric && $0.end.isNumeric ? $0 : nil }
            for character in text[run.range].characters {
                if character.isWhitespace {
                    if let word = current { words.append(word); current = nil }
                    continue
                }
                var word = current ?? TimedWord(text: "", start: -1, end: -1, isFinal: isFinal)
                word.text.append(character)
                if let range {
                    word.start = word.hasTiming ? min(word.start, range.start.seconds) : range.start.seconds
                    word.end   = max(word.end, range.end.seconds)
                }
                current = word
            }
        }
        if let word = current { words.append(word) }
        return words.contains(where: \.hasTiming) ? words : []
    }

//
// :)
//
//
    // Input and lifecycle — feed audio in, then finish or cancel


    /*
    Called on the audio thread for every microphone buffer. inputLock keeps the converter
    to one buffer at a time and stops finish() from closing the stream mid-append. The
    converter's input block hands over this one buffer, then says "no more data for now".
    Without a converter the buffer is copied, because tap buffers are only borrowed.
    */
    func append(_ buffer: AVAudioPCMBuffer) {
        inputLock.lock()
        defer { inputLock.unlock() }
        guard withStateLock({ state == .accepting }) else { return }
        if let converter {
            let ratio    = analyzerFormat.sampleRate / max(1, buffer.format.sampleRate)
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied            = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard conversionError == nil,
                  status == .haveData || status == .inputRanDry,
                  converted.frameLength > 0 else { return }
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        } else if let copy = ModernAudioBuffer.copy(buffer) {
            inputBuilder.yield(AnalyzerInput(buffer: copy))
        }
    }

    /*
    Closes the input (under inputLock, so no append can slip in after), waits for the
    analyzer to finalize everything it was given (or stops it if analysis gave no end
    time), then waits for the last results to be read.
    The completion gets the full text with nothing left volatile, on main. Calling it a
    second time, or after cancel(), does nothing; a cancel during the wait means no call.
    */
    func finish(completion: @escaping (TranscriptSnapshot) -> Void) {
        inputLock.lock()
        let shouldFinish = withStateLock {
            guard state == .accepting else { return false }
            state = .finishing
            return true
        }
        if shouldFinish { inputBuilder.finish() }
        inputLock.unlock()
        guard shouldFinish else { return }
        finishTask = Task { [weak self] in
            guard let self else { return }
            if let analysis = self.analysisTask {
                if let end = await analysis.value {
                    try? await self.analyzer.finalizeAndFinish(through: end)
                } else { await self.analyzer.cancelAndFinishNow() }
            } else {
                try? await self.analyzer.finalizeAndFinishThroughEndOfInput()
            }
            _ = await self.resultTask?.value
            let final: TranscriptSnapshot? = self.withStateLock {
                guard self.state == .finishing else { return nil }
                self.state = .finished
                let last   = self.transcript.snapshot
                let final  = TranscriptSnapshot(finalizedText: last.text, volatileText: "", timedWords: last.timedWords)
                return final
            }
            if let final { DispatchQueue.main.async { completion(final) } }
        }
    }

//
// :)
//
//
    /*
    Safe to call more than once. Closes the input, stops every task, and tells the
    analyzer to stop at once without finalizing.
    */
    func cancel() {
        inputLock.lock()
        let shouldCancel = withStateLock {
            guard state != .finished else { return false }
            state = .finished
            return true
        }
        if shouldCancel { inputBuilder.finish() }
        inputLock.unlock()
        guard shouldCancel else { return }
        finishTask?.cancel()
        analysisTask?.cancel()
        resultTask?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }


}


// ModernAudioBuffer — copies a microphone buffer so it can outlive the tap callback


/// Tap buffers are borrowed by AVAudioEngine. Copy before crossing a queue or
/// handing a buffer to an asynchronous analyzer.
enum ModernAudioBuffer {
    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        target.frameLength = source.frameLength
        let sourceList     = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetList     = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        for index in 0..<min(sourceList.count, targetList.count) {
            guard let from = sourceList[index].mData, let to = targetList[index].mData else { continue }
            memcpy(to, from, Int(sourceList[index].mDataByteSize))
            targetList[index].mDataByteSize = sourceList[index].mDataByteSize
        }
        return target
    }
}


/// Policy is checked before even asking the framework for an installation request.
enum SpeechAssetPolicy {
    static func ensure(installed: Bool, allowDownload: Bool,
                       install: () async throws -> Void) async throws {
        guard !installed else { return }
        guard allowDownload else { throw StreamingSpeechError.assetsNotInstalled }
        try await install()
    }
}
