


//
import AVFoundation
import Foundation
import Speech


// TalkFileProof — runs a sound file through the real recognizer and pause tracker


/// File-only regression route. Never opens a microphone, pastes or writes history.
@MainActor
enum TalkFileProof {
    /*
    Feeds the file in 4096-frame chunks and sleeps for each chunk's length, so the
    recognizer receives audio at real speed as it would from the microphone. Then it
    finishes, waiting at most 5 s, and reports words, word times and thinking pauses.
    Needs macOS 26 (the fast on-device recognizer); older systems report failed.
    */
    static func run(input: String, output: String) async {
        var report: [String: Any] = ["route": "finite-file-only", "microphone": false, "paste": false]
        do {
            guard #available(macOS 26.0, *) else { throw StreamingSpeechError.unavailable }
            let file               = try AVAudioFile(forReading: URL(fileURLWithPath: input))
            var failures: [String] = []
            let pipeline = try await ModernSpeechPipeline.make(naturalFormat: file.processingFormat,
                contextualStrings: TalkVocabulary.hints,
                onFailure: { failures.append($0) }, onUpdate: { _ in })
            defer { pipeline.cancel() }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                throw StreamingSpeechError.missingAudioFormat
            }
            // Measured silence from the same samples, so the proof also shows where thinking notes land.
            var tracker = ThinkingPauseTracker()
            var clock   = 0.0
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: 4096)
                guard buffer.frameLength > 0 else { break }
                if let channels = buffer.floatChannelData {
                    let count = Int(buffer.frameLength), rate = file.processingFormat.sampleRate
                    let level = ThinkingLevelScan.scan(
                        channels: (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: channels[$0], count: count) },
                        window: ThinkingLevelScan.windowFrames(sampleRate: rate))
                    let start = clock
                    clock += Double(count) / rate
                    tracker.observe(rmsDB: level.rmsDB, start: start, end: clock,
                                    soundStart: level.soundStart.map { start + Double($0) / rate },
                                    soundEnd: level.soundEnd.map { start + Double($0) / rate })
                }
                pipeline.append(buffer)
                let seconds = Double(buffer.frameLength) / file.processingFormat.sampleRate
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            /*
            Whichever comes first resumes: the finished transcript, or the 5 s deadline with
            the latest snapshot. `resolved` makes sure the continuation resumes only once.
            */
            let start = ProcessInfo.processInfo.systemUptime
            let final: (TranscriptSnapshot, Bool) = await withCheckedContinuation { continuation in
                var resolved = false
                pipeline.finish { snapshot in
                    guard !resolved else { return }; resolved = true
                    continuation.resume(returning: (snapshot, false))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard !resolved else { return }; resolved = true
                    continuation.resume(returning: (pipeline.currentSnapshot, true))
                }
            }
            report["finalize_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            report["transcript"] = final.0.text
            let pauses = tracker.pausesIncludingCurrent
            let placement = ThinkingComposer.placement(raw: final.0.text, words: final.0.timedWords, pauses: pauses)
            report["thinking_pauses_s"] = pauses.map(\.duration)
            report["timed_words"] = final.0.timedWords.filter(\.hasTiming).count
            report["word_times"] = final.0.timedWords.map { "\($0.text)@\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end))" }
            report["pause_spans"] = pauses.map { "\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end))" }
            report["placed_by_word_times"] = placement.placedByWordTimes
            report["unplaced"] = placement.unplaced.count
            report["your_words"] = ThinkingComposer.body(placement.segments, unplaced: placement.unplaced) { $0 }
            report["timed_out"] = final.1
            report["errors"] = failures
            report["status"] = !final.1 && failures.isEmpty && !final.0.text.isEmpty ? "passed" : "failed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}

//
// :)
//
//
// MicrophonePauseProof — 20 s on the real microphone, sampling the live pause counter


/// Explicit hardware regression route: real microphone and production capture
/// engine, no paste/Return/history/allowance changes, no microphone audio saved.
@MainActor enum MicrophonePauseProof {
    /*
    Samples the live counter every 200 ms for 100 samples (20 s), then finishes with a
    1.5 s drain and a 3 s cap; on the cap it stops and uses the snapshot taken first.
    The report includes the transcript; it is written with owner-only permissions
    (folder 0700, file 0600).
    */
    static func run(output: String) async {
        let audio = AudioCapture()
        audio.requestAccessAndStart()
        var samples: [[String: Any]] = []
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            samples.append(["clock": audio.recordingDurationSeconds,
                            "estimated": audio.thinkingOpenPauseIsEstimated,
                            "counter": audio.thinkingOpenPauseSeconds ?? -1,
                            "words": audio.timedWords.count,
                            "last_word_end": audio.timedWords.last?.end ?? -1])
        }
        let snapshot = audio.deliverySnapshot()
        let final: CompletedSegment = await withCheckedContinuation { continuation in
            var completed = false
            audio.finish(after: 1.5) { segment in
                guard !completed else { return }; completed = true
                continuation.resume(returning: segment)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !completed else { return }; completed = true
                _ = audio.stop(); continuation.resume(returning: snapshot)
            }
        }
        let placement = ThinkingComposer.placement(raw: final.transcript, words: final.timedWords,
            pauses: final.thinkingPauses, anchors: final.thinkingAnchors)
        let body = ThinkingComposer.body(placement.segments, unplaced: placement.unplaced) { $0 }
        let rendered = ThinkingPrompt.format(title: "Microphone pause test", body: body,
            durationSeconds: 20, countTranscript: final.transcript,
            pauses: final.thinkingPauses.map(\.duration), speechGapEstimate: final.thinkingPausesAreSpeechEstimates)
        let report: [String: Any] = ["route": "real-microphone-production-capture-no-send", "microphone": true,
            "paste": false, "rawAudioSaved": false, "transcript": final.transcript,
            "timedWords": final.timedWords.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String:Any] },
            "pauses": final.thinkingPauses.map { ["start":$0.start,"end":$0.end,"duration":$0.duration] },
            "estimated": final.thinkingPausesAreSpeechEstimates, "live": samples, "formatted": rendered,
            "error": audio.captureError ?? ""]
        do {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            try data.write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch { print("PAUSE_PROOF_WRITE_FAILED") }
    }
}

