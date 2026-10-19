


//
/*


notes


*/

import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// TalkModel — Capture


extension TalkModel {

    // Begin and finish — starting one talk and stopping it

    /// A fresh capture must not silently discard an unresolved launch checkpoint.
    /// Clearing the presentation identity leaves that journal entry recoverable next launch.
    func prepareRecoveredWordsForNewTalk() {
        restoredRecoveryID = nil
    }

    /// Starts one talk. Refused while the updater restarts, and in Telescope or Tincture.
    /// Order: stop every other microphone owner (idle listeners, voice copy, the lab),
    /// clear the last talk, make a new sessionID, show the bubble, then start recording.
    /// The target app is not read here; it is captured at Stop (captureStopTarget).
    func begin() {
        guard !bubbleInteractivePreview else { return }
        // A key edge, hidden control or old setup flag cannot bypass current agreement.
        guard !Self.tokensFirstRunPending else { return }
        guard !["Telescope", "Tincture"].contains(selectedProduct) else { return }
        /*
        An update is restarting Tokens. The key used to do nothing at all, for as long as Sparkle
        waited (build 81: three silent presses in a real log). Say so, and nudge Sparkle's own
        supported retry so the restart finishes.
        */
        if updater.restarting {
            Diagnostics.event("capture_refused reason=update_restarting retry=\(updater.canRetryRestart)")
            showTalkSurface()
            showAccessFailure("Finishing an update · Tokens is restarting")
            if updater.canRetryRestart { updater.retryRestart() }
            return
        }
        // Missing selected weights wait visibly, even if Apple Speech permission exists.
        if SpeechEngineChoice.waitingForOrukeet() {
            showTalkSurface()
            // The line follows the download and clears once the model is ready (build 81).
            showOrukeetWaiting()
            Diagnostics.event("capture_waiting_for_orukeet")
            return
        }
        clearHeldWords()
        stopInputPreview()
        stopRecoveryCommandCapture()
        if labOwnsSignalCapture {
            _ = audio.stop()
            labOwnsSignalCapture = false
        }
        isLabListening = false
        if isLabOpen {
            isLabOpen = false
            onLabVisibilityChange?(false)
        }
        target = nil
        stopTarget.reset()
        // A rapid restart during the delivered celebration skips resetSession().
        // Its prefix and pending callbacks must never carry into the next talk.
        stopStream.reset()
        sessionID = UUID()
        captureCheckpointWork?.cancel()
        captureCheckpointWork = nil
        pendingCaptureCheckpointText = ""
        lastCaptureCheckpointText = ""
        previewIsHidden = false
        displayText = ""
        displayStableWordCount = 0
        retainedFailureText = ""
        retainedFailurePayload = ""
        // A new talk changes the visible words, not the outcome of the undelivered talk.
        prepareRecoveredWordsForNewTalk()
        retainedSendReturn = false
        frozenRecordingDurationSeconds = nil
        thinkingFormatter.reset()
        tinkering.cancel()
        tinkeringWorking = false
        // Refresh accounting, but launch talks use only the tiny bubble.
        // Old non-public surfaces retain their own notes lifecycle.
        if thinkingExperience && !isSyntheticRun {
            refreshDailyAllowance()
            if !publicTokens {
                showPauseAside(explicit: true)
                pauseAsides.begin(sessionID: sessionID)
            }
        }
        phase = .capturing
        syncDestinationPreview()
        Diagnostics.event(
            "capture_begin session=\(sessionID?.uuidString ?? "none") mode=\(rightOptionMode.rawValue)"
        )
        print("TTT_EVENT capture_started target=deferred_until_stop")
        showTalkSurface()
        showPauseAside(explicit: true)
        /*
        If no audio arrives within 8 s, the talk fails (armStartupDeadline).
        Personal dictionary words go to the recognizer as hints.
        */
        armStartupDeadline(for: sessionID)
        audio.requestAccessAndStart(personalVocabulary: PersonalDictionary.hints(
            for: selectedProduct, in: UserDefaults(suiteName: PersonalDictionary.suite)!))
    }

//
// :)
//
//
    /// The normal stop, in this order: capture the target (before the bubble hides; see
    /// captureStopTarget), freeze the duration, enter finalizing, note the Stop time and
    /// arm the stop gate from it, then finish the captured words before final delivery.
    func finish(explicitPayload: String? = nil, sendReturn: Bool? = nil) {
        guard phase == .capturing, let requestedSession = sessionID else { return }
        captureStopTarget()
        cancelStartupDeadline()
        frozenRecordingDurationSeconds = audio.recordingDurationSeconds
        phase = .finalizing
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        let shouldReturn = TokensPrompt.requestsReturn(product: selectedProduct, explicit: sendReturn,
                                                       autoSendAfterPasting: autoSendAfterPasting)
        beginFinishCountdown(session: requestedSession, explicitPayload: explicitPayload, sendReturn: shouldReturn)
        Diagnostics.event("capture_finish session=\(requestedSession.uuidString)")
        /*
        When the segment arrives: public Tokens never waits for a formatter. Legacy
        products retain their bounded formatter pass, then complete() hands the words to
        the gate. The guard drops results for an older talk or after delivery launched.
        */
        audio.finishAdaptively() { [weak self] segment in
            guard let self, self.sessionID == requestedSession, !self.finishLaunching,
                  !self.completedSessionIDs.contains(requestedSession) else { return }
            self.logStopTiming(stage: "ready", session: requestedSession)
            let payload = explicitPayload ?? segment.transcript
            let elapsed = ProcessInfo.processInfo.systemUptime - (self.stopRequestedUptime ?? ProcessInfo.processInfo.systemUptime)
            let remaining = self.selectedProduct == "Tokens" || self.speedOfSoundEnabled ? 0 : max(0, 1 - elapsed)
            self.localFormatter.finishWithin(remaining, raw: BrandVocabulary.apply(to: payload)) { [weak self] in
                guard let self, self.sessionID == requestedSession, self.phase == .finalizing else { return }
                self.logStopTiming(stage: "local_final_ready", session: requestedSession)
                self.complete(session: requestedSession, payload: payload, segment: segment, sendReturn: shouldReturn)
            }
        }
    }

    /// The Speed of Sound stop: preserves the same bounded final-word drain as finish().
    /// latencyStartUptime is the key edge time; complete() passes it on only when no
    /// gate is armed for the talk.
    func finishAtSpeedOfSound(sendReturn: Bool? = nil) {
        // Tokens decorations require one final insertion, not an append-only prefix.
        guard speedOfSoundEnabled,
              phase == .capturing,
              audio.isRecording,
              let requestedSession = sessionID else { return }
        let latencyStartUptime = input.fastFinishEdgeUptime
        captureStopTarget()
        cancelStartupDeadline()
        frozenRecordingDurationSeconds = audio.recordingDurationSeconds
        phase = .finalizing
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        let shouldReturn = TokensPrompt.requestsReturn(product: selectedProduct, explicit: sendReturn,
                                                       autoSendAfterPasting: autoSendAfterPasting)
        beginFinishCountdown(session: requestedSession, sendReturn: shouldReturn)
        Diagnostics.event("capture_finish session=\(requestedSession.uuidString) mode=speed_of_sound")
        audio.finishAdaptively() { [weak self] segment in
            guard let self,
                  self.sessionID == requestedSession,
                  self.phase == .finalizing else { return }
            self.logStopTiming(stage: "speed_of_sound_ready", session: requestedSession)
            self.complete(
                session: requestedSession,
                payload: segment.transcript,
                segment: segment,
                sendReturn: shouldReturn,
                latencyStartUptime: latencyStartUptime
            )
        }
    }

    /// Freezes where this talk's words go, once per talk, then hides the bubble.
    /// The target is read only while the key edge is still current: same app and window
    /// as at the key edge, under 0.5 s old (GlobalKeyMonitor.deliveryEdgeIsCurrent),
    /// checked before and after reading. Otherwise the talk has no target; words are held.
    func captureStopTarget() {
        stopDestinationPreview()
        // Capture destination BEFORE hiding a window can change foreground focus.
        if !stopTarget.captured {
            stopTarget.capture {
                guard input.deliveryEdgeIsCurrent() else {
                    Diagnostics.event("delivery_held reason=focus_changed_since_key_edge")
                    return nil
                }
                let captured = targets.capture()
                guard input.deliveryEdgeIsCurrent() else { return nil }
                return captured
            }
        }
        target          = stopTarget.value
        previewIsHidden = true
        hideSurface()
        Diagnostics.event("overlay_hidden_on_stop session=\(sessionID?.uuidString ?? "none")")
    }

}

