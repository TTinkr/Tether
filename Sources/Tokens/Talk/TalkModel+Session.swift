


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// TalkModel — Session


extension TalkModel {

    // Reset and startup deadline — back to idle; fail a microphone that never starts

    /// Back to idle, forgetting the current talk: checkpoints, the stop gate, staged state,
    /// formatters, notes, the Return reservation, the startup deadline, the target, the
    /// session id and held words. lastTranscriptForCopy is kept. Idle listening resumes on
    /// the next main-loop turn.
    func resetSession() {
        stopDestinationPreview()
        captureCheckpointWork?.cancel()
        captureCheckpointWork        = nil
        pendingCaptureCheckpointText = ""
        lastCaptureCheckpointText    = ""
        cancelFinishCountdown()
        stagedHeader    = nil
        stagedCommitted = nil
        stagedFailed    = false
        stopStream.reset()
        localFormatter.reset()
        thinkingFormatter.reset()
        previewThinkingSeconds = nil
        pauseAsides.reset()
        tinkering.cancel()
        tinkeringWorking = false
        input.finishReturnReservation()
        cancelStartupDeadline()
        activeSessionMode = nil
        target            = nil
        stopTarget.reset()
        sessionID = nil
        stopRequestedUptime = nil
        frozenRecordingDurationSeconds = nil
        phase = .idle
        displayText = ""
        displayStableWordCount = 0
        previewIsHidden = false
        retainedFailureText = ""
        retainedFailurePayload = ""
        retainedSendReturn = false
        clearHeldWords()
        DispatchQueue.main.async { [weak self] in self?.resumeInputPreview() }
    }

    /// If no audio arrives within 8 s, stop the microphone and fail the talk: hold any words,
    /// or ask the user to try again.
    func armStartupDeadline(for requestedSession: UUID?) {
        cancelStartupDeadline()
        guard let requestedSession else { return }
        let orukeet = SpeechEngineChoice.load() == .orukeet
        let deadline = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionID == requestedSession,
                  self.phase == .capturing,
                  !self.audio.hasReceivedAudio else { return }
            self.startupDeadline = nil
            let recoverableText = self.audio.transcript.isEmpty ? self.displayText : self.audio.transcript
            _ = self.audio.stop()
            Diagnostics.event("capture_start_timeout session=\(requestedSession.uuidString)")
            if recoverableText.isEmpty {
                self.showAccessFailure(orukeet
                    ? "Orukeet did not become ready. Check Speech engine in Settings, then retry."
                    : "Microphone did not start. Tap \(self.shortcutName) to retry.")
            } else {
                self.retainForRecovery(recoverableText, message: "Microphone stopped · Copy latest")
            }
        }
        startupDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + (orukeet ? 35 : 8), execute: deadline)
    }

//
// :)
//
//
    func cancelStartupDeadline() {
        startupDeadline?.cancel()
        startupDeadline = nil
    }

    // After delivery — stop timing, the delivered moment, and the notes panel

    /// Logs milliseconds since Stop for one stage of the finish; does nothing before Stop.
    func logStopTiming(stage: String, session: UUID) {
        guard let stopRequestedUptime else { return }
        let milliseconds = Int(max(0, ProcessInfo.processInfo.systemUptime - stopRequestedUptime) * 1_000)
        Diagnostics.event("stop_timing session=\(session.uuidString) stage=\(stage) milliseconds=\(milliseconds)")
    }

    /// Shows the delivered state for 0.72 s, then hides the bubble and resets, unless
    /// another talk has started by then.
    func celebrateDelivery(session: UUID) {
        phase = .delivered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
            guard let self,
                  self.phase == .delivered,
                  self.sessionID == session else { return }
            self.hideSurface()
            self.resetSession()
        }
    }

}

