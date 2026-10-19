import AVFoundation
import Foundation
import Speech
import TokensCore

/// Source-fixture-only proof of the real legacy speech engine on this host.
/// The caller supplies fictional AIFF audio. No microphone, UI, permission request,
/// history, clipboard or paste. A newer host OS is not proof of macOS 15.6 behavior.
@MainActor
enum LegacyTalkFileProof {
    private enum ProofError: String, Error {
        case proofRouteDisabled, speechPermissionNotAuthorized, onDeviceSpeechUnavailable
        case unsupportedFixture, unsupportedAudioFormat, emptyOrOversizedFixture
    }

    @MainActor private final class RunState {
        var accumulator = TokensCore.LegacyTranscriptAccumulator()
        var tracker = ThinkingPauseTracker()
        var clock = 0.0
        var callbacks: [[String: Any]] = []
        var errors: [String] = []
        var finalReceived = false
        var active = true
        private var previousCallbackText = ""

        func receive(text: String?, words: [TokensCore.TimedWord], isFinal: Bool, error: String?) {
            guard active else { return }
            let before = accumulator.snapshot.text
            if let text {
                let pauseRevision = tracker.pausesIncludingCurrent.count
                accumulator.apply(text, isFinal: isFinal, words: words, pauseRevision: pauseRevision)
                let timed = words.filter { $0.hasTiming && $0.end > $0.start }
                callbacks.append([
                    "audio_submitted_s": clock,
                    "incoming_words": text.split(whereSeparator: { $0.isWhitespace }).count,
                    "prior_words": before.split(whereSeparator: { $0.isWhitespace }).count,
                    "retained_words": accumulator.snapshot.text.split(whereSeparator: { $0.isWhitespace }).count,
                    "timed_words": timed.count,
                    "first_word_start": timed.first?.start ?? -1,
                    "last_word_end": timed.map(\.end).max() ?? -1,
                    "final": isFinal,
                    "pause_revision": pauseRevision,
                    "same_as_previous_callback": text == previousCallbackText,
                    "cumulative_against_previous_callback": !previousCallbackText.isEmpty
                        && (text == previousCallbackText || text.hasPrefix(previousCallbackText + " ")),
                    "cumulative_against_retained": !before.isEmpty
                        && (text == before || text.hasPrefix(before + " ")),
                    "recovery": accumulator.failure != nil
                ])
                previousCallbackText = text
            }
            if let error { errors.append(error) }
            if isFinal { finalReceived = true }
        }
    }

    static func run(input: String, output: String) async {
        let began = ProcessInfo.processInfo.systemUptime
        let state = RunState()
        var report: [String: Any] = [
            "route": "legacy-real-time-fictional-file-only",
            "source_fixture_only": true,
            "expected_text_compared": false,
            "microphone": false, "paste": false, "history": false,
            "permission_requested": false,
            "host_os": ProcessInfo.processInfo.operatingSystemVersionString,
            "macos_15_6_proof": false,
            "authorization": SFSpeechRecognizer.authorizationStatus().rawValue,
            "status": "failed"
        ]
        do {
            guard ProofRoutes.isAllowed else { throw ProofError.proofRouteDisabled }
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                throw ProofError.speechPermissionNotAuthorized
            }
            let url = URL(fileURLWithPath: input)
            guard ["aif", "aiff"].contains(url.pathExtension.lowercased()) else {
                throw ProofError.unsupportedFixture
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
                  recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                throw ProofError.onDeviceSpeechUnavailable
            }
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw ProofError.unsupportedAudioFormat
            }
            let duration = Double(file.length) / format.sampleRate
            guard duration > 0, duration <= 600 else { throw ProofError.emptyOrOversizedFixture }
            report["fixture_name"] = url.lastPathComponent
            report["fixture_duration_s"] = duration
            report["sample_rate"] = format.sampleRate
            report["channels"] = format.channelCount
            report["on_device_required"] = true
            report["adds_punctuation"] = true
            report["task_hint"] = "dictation"

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            request.requiresOnDeviceRecognition = true
            // Keep the fixture independent of the user's personal dictionary.
            request.contextualStrings = TalkVocabulary.hints
            let task = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let words = (result?.bestTranscription.segments ?? []).map {
                    TokensCore.TimedWord(text: $0.substring, start: $0.timestamp,
                                        end: $0.timestamp + $0.duration, isFinal: isFinal)
                }
                let errorText = error?.localizedDescription
                DispatchQueue.main.async {
                    state.receive(text: text, words: words, isFinal: isFinal, error: errorText)
                }
            }
            defer {
                state.active = false
                request.endAudio()
                task.cancel()
            }
            let playbackBegan = ProcessInfo.processInfo.systemUptime
            while file.framePosition < file.length, !state.finalReceived,
                  state.errors.isEmpty, state.accumulator.failure == nil {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: 4096)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    throw ProofError.unsupportedAudioFormat
                }
                let count = Int(buffer.frameLength)
                let level = ThinkingLevelScan.scan(
                    channels: (0..<Int(format.channelCount)).map {
                        UnsafeBufferPointer(start: channels[$0], count: count)
                    }, window: ThinkingLevelScan.windowFrames(sampleRate: format.sampleRate))
                let start = state.clock
                state.clock += Double(count) / format.sampleRate
                state.tracker.observe(rmsDB: level.rmsDB, start: start, end: state.clock,
                    soundStart: level.soundStart.map { start + Double($0) / format.sampleRate },
                    soundEnd: level.soundEnd.map { start + Double($0) / format.sampleRate })
                request.append(buffer)
                let remaining = playbackBegan + state.clock - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            let allAudioSubmitted = file.framePosition == file.length
            report["all_audio_submitted"] = allAudioSubmitted
            report["premature_final"] = state.finalReceived && !allAudioSubmitted
            request.endAudio()
            task.finish()
            let drainBegan = ProcessInfo.processInfo.systemUptime
            let deadline = drainBegan + 5
            while !state.finalReceived, state.errors.isEmpty, state.accumulator.failure == nil,
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let timedOut = !state.finalReceived && state.errors.isEmpty && state.accumulator.failure == nil
            report["drain_ms"] = (ProcessInfo.processInfo.systemUptime - drainBegan) * 1000
            report["timed_out"] = timedOut
            report["final_received"] = state.finalReceived
            report["status"] = allAudioSubmitted && state.finalReceived && !timedOut
                && state.errors.isEmpty && state.accumulator.failure == nil
                && !state.accumulator.snapshot.text.isEmpty ? "passed" : "failed"
        } catch {
            if let error = error as? ProofError { report["error"] = error.rawValue }
            else { report["error"] = error.localizedDescription }
        }
        state.active = false
        let snapshot = state.accumulator.snapshot
        report["audio_submitted_s"] = state.clock
        report["elapsed_s"] = ProcessInfo.processInfo.systemUptime - began
        report["callbacks"] = state.callbacks
        report["errors"] = state.errors
        report["ambiguous_reset"] = state.accumulator.hasAmbiguousReset
        report["recovery"] = state.accumulator.failure != nil
        report["recovery_reason"] = state.accumulator.failure ?? ""
        report["transcript"] = snapshot.text
        report["word_count"] = snapshot.text.split(whereSeparator: { $0.isWhitespace }).count
        report["thinking_pauses_s"] = state.tracker.pausesIncludingCurrent.map(\.duration)
        report["word_times"] = snapshot.timedWords.map {
            ["text": $0.text, "start": $0.start, "end": $0.end, "final": $0.isFinal] as [String: Any]
        }
        do {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { print("LEGACY_FILE_PROOF_WRITE_FAILED") }
    }
}
