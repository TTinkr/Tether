import AVFoundation
import Foundation
import Darwin
import Speech
import TokensCore

/// Monotonic file replay schedule. Each buffer becomes available at its end-frame
/// time, as it would from a capture tap. A stalled host fails instead of replaying
/// seconds of queued audio in a burst and mislabeling the result as real-time.
struct LocalSpeechFixturePacing {
    let startedAt: TimeInterval
    let sampleRate: Double
    static let maximumLag: TimeInterval = 0.75
    func targetTime(afterFrames frames: Int) -> TimeInterval {
        startedAt + Double(frames) / sampleRate
    }
    func delay(afterFrames frames: Int, now: TimeInterval) -> TimeInterval {
        max(0, targetTime(afterFrames: frames) - now)
    }
    func lag(afterFrames frames: Int, now: TimeInterval) -> TimeInterval {
        max(0, now - targetTime(afterFrames: frames))
    }
    func admits(afterFrames frames: Int, now: TimeInterval) -> Bool {
        startedAt.isFinite && sampleRate.isFinite && sampleRate > 0 && frames >= 0 && now.isFinite
            && lag(afterFrames: frames, now: now) <= Self.maximumLag
    }
}

/// Internal proof only: root-selected fictional local audio; never opens a microphone.
enum LocalSpeechFixtureProof {
    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var permitted: Bool { lock.lock(); defer { lock.unlock() }; return active }
        func close() { lock.lock(); active = false; lock.unlock() }
    }

    private final class FeedProgress: @unchecked Sendable {
        struct Snapshot {
            var frames = 0
            var startedAt: TimeInterval?
            var finishedAt: TimeInterval?
            var finalizationBudget: TimeInterval?
            var maximumLag: TimeInterval = 0
            var failure: String?
        }
        private let lock = NSLock()
        private var state = Snapshot()
        var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return state }
        func start(at time: TimeInterval) { lock.lock(); state.startedAt = time; lock.unlock() }
        func append(frames: Int, lag: TimeInterval) {
            lock.lock(); state.frames += frames; state.maximumLag = max(state.maximumLag, lag); lock.unlock()
        }
        func finish(at time: TimeInterval, budget: TimeInterval) {
            lock.lock(); state.finishedAt = time; state.finalizationBudget = budget; lock.unlock()
        }
        func fail(_ reason: String) { lock.lock(); state.failure = reason; lock.unlock() }
    }

    @MainActor static func run(input: String, output: String, engine: SpeechEngineChoice = .apple) async {
        guard let receiptURL = reserveReceipt(input: input, output: output) else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let receiptID = UUID().uuidString
        var result: [String: Any] = ["run_id": receiptID, "passed": false,
            "scope": "local fictional fixture; packaged speech pipeline; no microphone, download, delivery or history",
            "engine_selected": engine.rawValue,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
            "finish_callback": false]
        func write() {
            result["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - began
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: receiptURL, options: .atomic)
            }
        }
        result["status"] = "starting"; write()
        // SpeechAnalyzer transcriber modules are local and do not use the legacy
        // SFSpeechRecognizer server-authorization gate. This file-only route never
        // requests permission or opens a microphone, and cannot select that legacy API.
        guard input.hasPrefix("/"), input != output else {
            result["status"] = "invalid_local_path"; write(); return
        }
        // This bounded synthetic replay is active work even without a foreground
        // window. Prevent App Nap / utility-timer coalescing from pacing the file.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Local fictional speech fixture")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let queue = DispatchQueue(label: "Tokens.local-speech-fixture", qos: .userInitiated)
        let admission = Admission()
        var loaded = false
        var buffers: [AVAudioPCMBuffer] = []
        var naturalFormat: AVAudioFormat?
        var failure: String?
        queue.async {
            do {
                let url = URL(fileURLWithPath: input)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0,
                      (values.fileSize ?? Int.max) <= 20_000_000 else { throw FixtureError.invalidFile }
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                guard format.sampleRate > 0, format.channelCount > 0, format.channelCount <= 2,
                      file.length > 0, Double(file.length) / format.sampleRate <= (engine == .orukeet ? 330 : 30),
                      Double(file.length) * Double(format.channelCount) * 4 <= 24_000_000 else {
                    throw FixtureError.invalidFile
                }
                var chunks: [AVAudioPCMBuffer] = []
                while file.framePosition < file.length && admission.permitted {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else {
                        throw FixtureError.invalidFile
                    }
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    chunks.append(buffer)
                }
                DispatchQueue.main.async {
                    guard admission.permitted else { return }
                    naturalFormat = format; buffers = chunks; loaded = true
                }
            } catch {
                DispatchQueue.main.async { if admission.permitted { failure = "fixture_read_failed"; loaded = true } }
            }
        }
        var deadline = began + 15
        while !loaded && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard loaded, failure == nil, let format = naturalFormat else {
            admission.close(); result["status"] = failure ?? "fixture_read_deadline"; write(); return
        }
        result["input_frames"] = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let audioSeconds = Double(buffers.reduce(0) { $0 + Int($1.frameLength) }) / format.sampleRate
        result["audio_seconds"] = audioSeconds
        let overallDeadline = began + audioSeconds + 90
        deadline = began + 45
        result["setup_deadline_seconds"] = deadline - began
        var pipeline: StreamingSpeechPipeline?
        var setupDone = false
        var updateCount = 0
        var firstTextSeconds: Double?
        var modelReadySeconds: Double?
        var finishCallbackSeconds: Double?
        var updates: [[String: Any]] = []
        let setup = Task { @MainActor in
            do {
                let onUpdate: (TranscriptSnapshot) -> Void = { snapshot in
                        updateCount += 1
                        updates.append(["seconds": ProcessInfo.processInfo.systemUptime - began,
                                        "text": snapshot.text, "stable_words": snapshot.stableWordCount])
                        if firstTextSeconds == nil, !snapshot.text.isEmpty {
                            firstTextSeconds = ProcessInfo.processInfo.systemUptime - began
                        }
                    }
                let created: StreamingSpeechPipeline
                if engine == .orukeet {
                    let assets = try OrukeetAssets.resolveSelected()
                    let modelID = SpeechEngineChoice.selectedModelID()
                    result["model_id"] = modelID
                    if let pinned = SpeechModelCatalog.entry(modelID)?.download, modelID != SpeechModelCatalog.orukeetID {
                        result["model_sha256"] = pinned.sha256   // verified by resolveSelected
                    } else {
                        let manifestData = try Data(contentsOf: assets.resourceRoot.appendingPathComponent("asset-manifest.json"))
                        if let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
                            result["model_sha256"] = manifest["model_sha256"]
                        }
                    }
                    // Exercise the app's actual loading/pre-roll path: file audio
                    // begins before the model is ready, without opening a mic.
                    created = try OrukeetSpeechPipeline.start(naturalFormat: format,
                        onFailure: { message in failure = message }, onUpdate: onUpdate,
                        onLoaded: { modelReadySeconds = ProcessInfo.processInfo.systemUptime - began })
                    result["pipeline_start_mode"] = "immediate_with_preroll"
                } else if #available(macOS 26.0, *) {
                    created = try await ModernSpeechPipeline.make(naturalFormat: format,
                        allowAssetDownload: false, onFailure: { _ in failure = "analyzer_failed" }, onUpdate: onUpdate)
                } else { throw FixtureError.unsupportedOS }
                guard admission.permitted else { queue.async { created.cancel() }; return }
                pipeline = created
            } catch { failure = "\(engine.rawValue)_unavailable: \(error.localizedDescription)" }
            setupDone = true
        }
        while !setupDone && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard setupDone, failure == nil, let activePipeline = pipeline else {
            admission.close(); setup.cancel()
            if let pipeline { queue.async { pipeline.cancel() } }
            result["status"] = failure ?? "setup_deadline"; write(); return
        }
        result["setup_seconds"] = ProcessInfo.processInfo.systemUptime - began
        result["engine_actual"] = activePipeline.engineIdentity
        var finished = false
        var finalText = ""
        let chunks = buffers
        let feed = FeedProgress()
        let feedStarted = ProcessInfo.processInfo.systemUptime
        let schedule = LocalSpeechFixturePacing(startedAt: feedStarted, sampleRate: format.sampleRate)
        let feedDeadline = min(overallDeadline - 35, feedStarted + audioSeconds + 5)
        result["feed_deadline_seconds"] = feedDeadline - began
        queue.async {
            feed.start(at: feedStarted)
            var frames = 0
            for buffer in chunks {
                let nextFrames = frames + Int(buffer.frameLength)
                // Recompute against the same origin after each wakeup. Scheduling
                // overhead is never added to the next chunk's target time.
                while true {
                    guard admission.permitted else { activePipeline.cancel(); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now < feedDeadline else { feed.fail("feed_deadline"); return }
                    guard schedule.admits(afterFrames: nextFrames, now: now) else {
                        feed.fail("feed_pacing_stall"); return
                    }
                    let delay = schedule.delay(afterFrames: nextFrames, now: now)
                    if delay > 0 { Thread.sleep(forTimeInterval: min(delay, 0.05)); continue }
                    activePipeline.append(buffer)
                    feed.append(frames: Int(buffer.frameLength), lag: schedule.lag(afterFrames: nextFrames, now: now))
                    frames = nextFrames
                    break
                }
            }
            guard admission.permitted else { activePipeline.cancel(); return }
            feed.finish(at: ProcessInfo.processInfo.systemUptime, budget: activePipeline.finalizationTimeout)
            activePipeline.finish { snapshot in
                guard admission.permitted else { return }
                finishCallbackSeconds = ProcessInfo.processInfo.systemUptime - began
                if let message = activePipeline.currentResult.failure { failure = message }
                finalText = snapshot.text; finished = true
            }
        }
        var deadlineStatus = "feed_deadline"
        while !finished && failure == nil {
            let progress = feed.snapshot
            if let error = progress.failure { failure = error; break }
            let phaseDeadline: TimeInterval
            if let finish = progress.finishedAt {
                phaseDeadline = min(overallDeadline, finish + (progress.finalizationBudget ?? 30) + 5)
                deadlineStatus = "finalization_deadline"
            } else { phaseDeadline = feedDeadline; deadlineStatus = "feed_deadline" }
            if ProcessInfo.processInfo.systemUptime >= phaseDeadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        admission.close()
        queue.async { activePipeline.cancel() }
        result["finish_callback"] = finished
        // A silent fixture may correctly finish with no words. The external
        // verifier compares this transcript with its independently held reference.
        result["passed"] = finished && failure == nil
        result["has_speech"] = !finalText.isEmpty
        let progress = feed.snapshot
        let finishRequestedSeconds = progress.finishedAt.map { $0 - began }
        let feedElapsed = (progress.finishedAt ?? ProcessInfo.processInfo.systemUptime) - (progress.startedAt ?? feedStarted)
        result["fed_frames"] = progress.frames
        result["feed_started_seconds"] = progress.startedAt.map { $0 - began }
        result["model_ready_seconds"] = modelReadySeconds
        result["fed_audio_seconds"] = Double(progress.frames) / format.sampleRate
        result["feed_elapsed_seconds"] = feedElapsed
        result["feed_rate"] = feedElapsed > 0 ? Double(progress.frames) / format.sampleRate / feedElapsed : 0
        result["max_feed_lag_seconds"] = progress.maximumLag
        result["feed_completed"] = progress.finishedAt != nil && progress.frames == (result["input_frames"] as? Int ?? -1)
        if finished && failure == nil { result["failed_phase"] = NSNull() }
        else { result["failed_phase"] = progress.finishedAt == nil ? "feeding" : "finalization" }
        if let finish = progress.finishedAt {
            result["finalization_deadline_seconds"] = min(overallDeadline, finish + (progress.finalizationBudget ?? 30) + 5) - began
        }
        result["status"] = failure ?? (finished ? "finished" : deadlineStatus)
        result["transcript"] = finalText
        result["update_count"] = updateCount
        result["first_text_seconds"] = firstTextSeconds
        result["finish_requested_seconds"] = finishRequestedSeconds
        result["finish_callback_seconds"] = finishCallbackSeconds
        if let stop = finishRequestedSeconds, let end = finishCallbackSeconds {
            result["recognition_finalization_seconds"] = end - stop
        }
        result["updates"] = updates
        result["timed_words"] = activePipeline.currentSnapshot.timedWords.map {
            ["text": $0.text, "start": $0.start, "end": $0.end, "final": $0.isFinal] as [String: Any]
        }
        result["text_before_finish"] = firstTextSeconds.map { first in
            finishRequestedSeconds.map { first < $0 } ?? false
        } ?? false
        // Completion proves the pipeline finish callback; analyzer internals may use
        // their existing cancellation fallback if analyzeSequence supplies no end time.
        result["proof_boundary"] = engine == .orukeet
            ? "real bundled Orukeet immediate-start/pre-roll pipeline over paced fictional audio; no live microphone, capture-admission or destination proof"
            : "pipeline finish callback, not independent analyzer finalization telemetry"
        write()
    }
    /// Reserve a new receipt before any write; never replace an existing file or
    /// follow an output symlink. O_EXCL closes the existence-check creation race.
    static func reserveReceipt(input: String, output: String) -> URL? {
        guard input.hasPrefix("/"), output.hasPrefix("/") else { return nil }
        let source = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: output).standardizedFileURL
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonical = parent.appendingPathComponent(destination.lastPathComponent)
        guard source != canonical.resolvingSymlinksInPath() else { return nil }
        let descriptor = canonical.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { return nil }
        Darwin.close(descriptor)
        return canonical
    }

    private enum FixtureError: Error { case invalidFile, unsupportedOS }
}
