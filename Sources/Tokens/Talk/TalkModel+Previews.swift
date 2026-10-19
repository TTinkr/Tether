


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Previews


extension TalkModel {

    // Bubble previews — scripted runs with no real talk (launch arguments)

    /// Local stage or native-panel preview: a fixed fake wave. With --temple-live-proof it also runs
    /// 40 s of scripted speech and thinking pauses for the bubble's π counter.
    func runInteractiveBubblePreview() {
        precondition((bubbleInteractivePreview || ProofRoutes.nativeBubblePreview) && isSyntheticRun)
        phase                  = .capturing
        displayText            = ""
        previewIsHidden        = false
        previewAudioConfirmed  = true
        previewThinkingSeconds = nil
        // Stable fictional signal: no microphone, transcription, dispatch, or ambient animation.
        previewWaveform = (0..<96).map { index -> Double in
            let fast = abs(sin(Double(index) * 0.37))
            let slow = abs(sin(Double(index) * 0.11))
            return 0.12 + 0.44 * fast * slow
        }
        // Speech at 0–2 s and 22–25 s, thinking pauses in between; ends at 40 s.
        if ProcessInfo.processInfo.arguments.contains("--temple-live-proof") {
            let began = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let elapsed                 = ProcessInfo.processInfo.systemUptime - began
                let speaking                = elapsed < 2 || (elapsed >= 22 && elapsed < 25)
                self.previewThinkingSeconds = speaking ? nil : max(0, elapsed - (elapsed < 22 ? 2 : 25))
                if elapsed >= 40 {
                    timer.invalidate()
                    Diagnostics.event("temple_live_proof_completed synthetic_capture=true")
                }
            }
            previewWaveTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Scripted bubble run: a 30 fps wave with quiet stretches at 1.8–2.25 s and from 3.65 s,
    /// timed word updates, then finalizing → delivered → hidden.
    func runGlassPreview() {
        if ProofRoutes.isAllowed, isSyntheticRun,
           ProcessInfo.processInfo.arguments.contains("--pause-response-preview") {
            runPauseResponsePreview()
            return
        }
        phase                  = .capturing
        displayText            = ""
        displayStableWordCount = 0
        previewIsHidden        = false
        previewPauseRevision   = 0
        previewAudioConfirmed  = true
        previewInputLevel      = 0
        previewWaveform        = Array(repeating: 0, count: 96)
        previewWaveTimer?.invalidate()
        var waveTick = 0
        let waveTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self, self.phase == .capturing, var samples = self.previewWaveform else {
                timer.invalidate()
                return
            }
            waveTick += 1
            let time = Double(waveTick) / 30.0
            let phrase = 0.34 + 0.26 * sin(time * 2.15) + 0.12 * sin(time * 5.1)
            let isQuietInterval = (1.8...2.25).contains(time) || time >= 3.65
            let energy = isQuietInterval ? 0 : min(0.82, max(0.08, phrase))
            let quietStart = time >= 3.65 ? 3.65 : 1.8
            self.previewThinkingSeconds = isQuietInterval && time - quietStart >= ThinkingPauseTracker.minimumDisplayedPause
                ? time - quietStart : nil
            samples.removeFirst()
            samples.append(energy)
            self.previewWaveform   = samples
            self.previewInputLevel = energy
        }
        previewWaveTimer = waveTimer
        RunLoop.main.add(waveTimer, forMode: .common)
        // The 0.55 s line has a misspelling that the 0.88 s line corrects (a live revision).
        let updates: [(at: TimeInterval, text: String)] = [
            (0.25, "Talk"),
            (0.55, "\(appName) follows your whole sentnce"),
            (0.88, "\(appName) follows your whole sentence"),
            (1.28, "\(appName) follows your whole sentence through one soft moving wave."),
            (2.48, "\(appName) follows your whole sentence through one soft moving wave. The next thought starts cleanly"),
            (3.18, "\(appName) follows your whole sentence through one soft moving wave. The next thought starts cleanly after the pause.")
        ]
        for update in updates {
            DispatchQueue.main.asyncAfter(deadline: .now() + update.at) { [weak self] in
                guard self?.phase == .capturing else { return }
                self?.displayText = update.text
                self?.displayStableWordCount = max(0, update.text.split(whereSeparator: { $0.isWhitespace }).count - 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.10) { [weak self] in
            guard let self, self.phase == .capturing else { return }
            self.previewPauseRevision = (self.previewPauseRevision ?? 0) + 1
        }
        let streamEnd = thinkingExperience ? 6.0 : 4.05
        DispatchQueue.main.asyncAfter(deadline: .now() + streamEnd) { [weak self] in
            guard self?.phase == .capturing else { return }
            self?.previewWaveTimer?.invalidate()
            self?.previewWaveTimer = nil
            self?.displayStableWordCount = self?.displayText.split(whereSeparator: { $0.isWhitespace }).count ?? 0
            self?.phase = .finalizing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + streamEnd + 0.35) { [weak self] in
            guard let self, self.phase == .finalizing else { return }
            self.phase = .delivered
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + streamEnd + 0.95) { [weak self] in
            guard let self, self.phase == .delivered else { return }
            self.previewIsHidden = true
        }
    }

//
// :)
//
//
    // Controls and stream previews — scripted Home and live-word runs

    /// --controls-preview: fixed history, a copy mark, the history list opening, level bars.
    func runControlsPreview() {
        guard ProcessInfo.processInfo.arguments.contains("--controls-preview") else { return }
        promptHistory = [
            PromptHistoryEntry(
                id: UUID(),
                createdAt: Date().addingTimeInterval(-72),
                text: "Keep every recognized word, including the correction I just made."
            ),
            PromptHistoryEntry(
                id: UUID(),
                createdAt: Date().addingTimeInterval(-236),
                text: "Make the tiny recording capsule feel immediate and calm."
            ),
            PromptHistoryEntry(
                id: UUID(),
                createdAt: Date().addingTimeInterval(-581),
                text: "Show all previous prompts without deleting older entries."
            )
        ]
        if ProcessInfo.processInfo.arguments.contains("--long-history-preview") {
            promptHistory.insert(PromptHistoryEntry(id: UUID(), createdAt: Date(),
                text: (1...32).map { "Line \($0): A fictional notebook keeps every word, café, 한국어 and 🧠 intact." }.joined(separator: "\n\n") + "\n  "), at: 0)
        }
        lastTranscriptForCopy = promptHistory.first?.text ?? ""
        displayText = "Keep every original word while the live display follows the newest measured lines. Unicode stays intact: café, 한국어, and emoji 🧠. This unusuallylongunbrokenendingtokenremainsvisiblewithoutellipsis."
        previewInputDeviceName = "Studio Display Microphone · preview"
        previewAudioConfirmed = false
        previewInputLevel = 0
        previewWaveform = Array(repeating: 0, count: 96)
        metadataEnabled = false
        historyExpanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.copyFeedbackRevision = UUID()
            self?.copyFeedbackKey = "latest"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            self?.copyFeedbackKey = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.setPromptHistoryExpanded(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            self?.previewAudioConfirmed = true
            self?.appendPreviewLevel(0.12)
            // The default Settings fixture matches shipping defaults: metadata opt-in, character tags on.
            self?.metadataEnabled = ProcessInfo.processInfo.arguments.contains("--transcript-extras-preview")
            self?.characterTagsEnabled = true
            self?.numberTagsEnabled = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            self?.appendPreviewLevel(0.38)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) { [weak self] in
            self?.appendPreviewLevel(0.78)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            self?.appendPreviewLevel(0)
        }
    }

    /// --main-stream-preview: words arriving every 0.1 s with one misspelling corrected,
    /// then finalizing → idle.
    func runMainStreamPreview() {
        guard ProcessInfo.processInfo.arguments.contains("--main-stream-preview") else { return }
        phase                  = .capturing
        displayText            = ""
        displayStableWordCount = 0
        previewAudioConfirmed  = true
        previewInputLevel      = 0.28
        previewWaveform        = Array(repeating: 0.18, count: 96)
        previewInputDeviceName = "Studio Display Microphone · preview"
        metadataEnabled        = false
        historyExpanded        = false

        let updates: [(at: TimeInterval, text: String)] = [
            (0.06, "We keep"),
            (0.16, "We keep every recognized"),
            (0.26, "We keep every recognized word exactly"),
            (0.36, "We keep every recognized word exactly while phrases"),
            (0.46, "We keep every recognized word exactly while phrases arrive smothly"),
            (0.56, "We keep every recognized word exactly while phrases arrive smoothly"),
            (0.66, "We keep every recognized word exactly while phrases arrive smoothly a few"),
            (0.76, "We keep every recognized word exactly while phrases arrive smoothly a few words at"),
            (0.86, "We keep every recognized word exactly while phrases arrive smoothly a few words at a time"),
            (0.96, "We keep every recognized word exactly while phrases arrive smoothly a few words at a time with café"),
            (1.06, "We keep every recognized word exactly while phrases arrive smoothly a few words at a time with café 한국어"),
            (1.16, "We keep every recognized word exactly while phrases arrive smoothly a few words at a time with café 한국어 and 🧠 intact, spelling A L E X.")
        ]
        for update in updates {
            DispatchQueue.main.asyncAfter(deadline: .now() + update.at) { [weak self] in
                guard let self, self.phase == .capturing else { return }
                self.displayText = update.text
                self.displayStableWordCount = max(
                    0,
                    update.text.split(whereSeparator: { $0.isWhitespace }).count - 1
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.36) { [weak self] in
            guard let self, self.phase == .capturing else { return }
            self.displayStableWordCount = self.displayText.split(whereSeparator: { $0.isWhitespace }).count
            self.phase                  = .finalizing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.66) { [weak self] in
            guard let self, self.phase == .finalizing else { return }
            self.phase = .idle
        }
    }

//
// :)
//
//
    /// Shifts a 12-sample bump, scaled by level, into the preview wave.
    private func appendPreviewLevel(_ level: Double) {
        previewInputLevel = level
        guard var history = previewWaveform, history.count >= 12 else { return }
        let shape = [0.58, 0.72, 0.91, 1.0, 0.84, 0.63, 0.47, 0.69, 0.88, 0.74, 0.51, 0.36]
        history.removeFirst(shape.count)
        history.append(contentsOf: shape.map { $0 * level })
        previewWaveform = history
    }

}


extension TalkModel {
    /// Fictional PCM through the real pause scanner and live bubble accessor. Never
    /// acquires audio hardware or calls a recognizer, clipboard, history, or delivery.
    private func runPauseResponsePreview() {
        guard ProofRoutes.isAllowed, isSyntheticRun else { return }
        phase = .capturing
        previewAudioConfirmed = true
        previewWaveform = nil
        previewThinkingSeconds = nil
        audio.isRecording = true
        audio.hasReceivedAudio = true
        audio.thinking.reset()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var tick = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            tick += 1
            let end = Double(tick) * 0.05
            let speech = end <= 0.5 || (end > 2.0 && end <= 2.6) || (end > 4.0 && end <= 4.6)
            let noisyGap = end > 0.5 && end <= 2.0
            let db: Double = speech ? -24 : noisyGap ? -40 : -70
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
            buffer.frameLength = 800
            let samples = buffer.floatChannelData![0]
            for index in 0..<800 { samples[index] = Float(pow(10, db / 20)) * (index.isMultiple(of: 2) ? 1 : -1) }
            self.audio.thinking.observe(buffer: buffer, end: end, host: ProcessInfo.processInfo.systemUptime)
            // Deliberately stale display RMS reproduces the former extra UI gate.
            self.audio.features.rmsDBFS = speech ? -24 : -40
            self.audio.waveform = Array(repeating: speech ? 0.5 : 0.06, count: 96)
            if speech && !(end > 2.0 && end <= 2.2) {
                self.audio.timedWords = [TimedWord(text: "notebook", start: max(0, end - 0.2), end: end, isFinal: true)]
                self.audio.transcriptChangedAt = Date()
            }
            if end >= 6.7 {
                timer.invalidate()
                self.audio.isRecording = false
                self.phase = .idle
            }
        }
        previewWaveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
