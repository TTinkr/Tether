import AVFoundation
import Foundation

/// Explicit Dev proof of the real engine's start/sample/stop/restart lifecycle.
/// Uses signal-only capture: no recognizer, asset download, transcript, paste,
/// or saved audio. A missing existing grant is a skipped check, never a prompt.
@MainActor enum AudioHardwareSmokeProof {
    static func run(audio: AudioCapture, output: String) async {
        let url = URL(fileURLWithPath: output)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            print("HARDWARE_SMOKE_OUTPUT_EXISTS")
            return
        }
        var report: [String: Any] = [
            "schema_version": 1,
            "scope": "real microphone signal-only lifecycle; no recognition or destination delivery",
            "microphone": true, "speechRecognition": false, "rawAudioSaved": false,
            "transcriptSaved": false, "paste": false, "permissionPrompted": false,
            "source_commit": Bundle.main.object(forInfoDictionaryKey: "TokensSourceCommit") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        func write() {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { print("HARDWARE_SMOKE_WRITE_FAILED") }
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            report["status"] = "skipped_existing_microphone_permission_missing"
            report["passed"] = false
            write()
            return
        }
        guard !audio.demoMode else {
            report["status"] = "refused_demo_mode"
            report["passed"] = false
            write()
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        var lastTick = started
        var maximumGap = 0.0
        var ticks = 0
        func tick() async {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            maximumGap = max(maximumGap, now - lastTick)
            lastTick = now
            ticks += 1
        }
        audio.keepMicrophoneOpenWhileIdle(false)
        var cycles: [[String: Any]] = []
        for index in 0..<3 {
            let initialStarts = audio.hardwareStarts
            let began = ProcessInfo.processInfo.systemUptime
            audio.requestAccessAndStartSignal(voiceCommands: false, labMode: false)
            var sampled = false
            while ProcessInfo.processInfo.systemUptime - began < 10 {
                await tick()
                if audio.captureError != nil { break }
                if audio.isRecording && audio.hasReceivedAudio && audio.hasRecentHardwareSamples {
                    sampled = true
                    break
                }
            }
            let firstSampleMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
            if sampled { for _ in 0..<5 { await tick() } }
            let noRecognition = audio.streamingPipeline == nil && audio.speechTask == nil && audio.transcript.isEmpty
            let newStart = audio.hardwareStarts == initialStarts + 1
            let error = audio.captureError ?? ""
            audio.discardCapture()
            var confirmedStop = false
            let stopBegan = ProcessInfo.processInfo.systemUptime
            // hardwareRunning is an eager UI intent; only this callback proves
            // the owner's real detach/stop operation has returned.
            audio.hardwareOwner.stop(stopHardware: true) { confirmedStop = true }
            while !confirmedStop && ProcessInfo.processInfo.systemUptime - stopBegan < 4 { await tick() }
            // Include a synchronous last-stop stall in the main-loop gap metric.
            await tick()
            let passed = sampled && newStart && noRecognition && confirmedStop && error.isEmpty
            cycles.append([
                "cycle": index + 1, "samples_received": sampled, "new_hardware_start": newStart,
                "recognizer_absent": noRecognition, "stop_confirmed": confirmedStop,
                "first_sample_ms": firstSampleMS, "stop_ms": (ProcessInfo.processInfo.systemUptime - stopBegan) * 1000,
                "error": error, "passed": passed,
            ])
            if !passed { break }
        }
        let lifecyclePassed = cycles.count == 3 && cycles.allSatisfy { $0["passed"] as? Bool == true }
        report["cycles"] = cycles
        report["hardware_starts"] = audio.hardwareStarts
        report["main_ticks"] = ticks
        report["main_tick_max_gap_ms"] = maximumGap * 1000
        report["main_tick_within_one_second"] = maximumGap < 1
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        report["passed"] = lifecyclePassed && maximumGap < 1
        report["status"] = lifecyclePassed && maximumGap < 1 ? "passed" : "failed"
        write()
    }
}
