


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Controls


extension TalkModel {

    // Start and stop — from the talk key or the bubble's buttons

    /// A press while failed first keeps the held words under Copy latest, then starts fresh.
    func pressToTalkBegin() {
        guard phase == .idle || phase == .delivered || phase == .failed else { return }
        if phase == .failed {
            if !retainedFailurePayload.isEmpty { lastTranscriptForCopy = retainedFailurePayload }
            resetSession()
        }
        begin()
    }

    /// The normal stop. finish() calls captureStopTarget() again; StopTarget keeps the first.
    func pressToTalkEnd() {
        guard phase == .capturing else { return }
        // Tokens decorations are finalized once; never commit a prefix before final layout.
        captureStopTarget()
        finish()
    }

    /// The bubble's discard button. In the interactive bubble preview it quits the preview.
    func discardBubbleCapture() {
        if bubbleInteractivePreview { NSApp.terminate(nil); return }
        // Also valid during the stop countdown: nothing has been pasted yet.
        guard phase == .capturing || (phase == .finalizing && finishGate.isArmed && !finishLaunching) else { return }
        discardRunningCapture()
        Diagnostics.event("bubble_capture_discarded")
    }

    /*
    The talk key used as a modifier (Option+Arrow, Option+Delete, Option+letter, Option-click)
    while the press that started this talk was held: the talk was never meant. It ends with no
    paste and no history (build 81: it used to keep recording until the next Option chord,
    which pasted whatever it had heard at the caret).
    */
    func discardChordedTalk() {
        guard phase == .capturing, let sessionID, sessionID == keyBeganSession else { return }
        Diagnostics.event("capture_discarded reason=chord session=\(sessionID.uuidString)")
        discardRunningCapture()
    }

    // Home's Stop and Discard (TOK-QA-005)

    /*
    A talk whose starting key press is still down, in tap or hold mode: any click is already the
    chord discard (GlobalKeyMonitor.noteChord fires on mouse-down, before a button's action), so
    Home must not offer a Stop that promises to keep the words (review of 5e881ef: tap mode too).
    Not published: the hold ends on a key release, and the live block redraws with the level band.
    */
    var talkIsHeldByKey: Bool {
        Self.isHeldKeyTalk(phase: phase, keyBeganSession: keyBeganSession, sessionID: sessionID,
                           startingPressHeld: input.startingPressIsHeld)
    }
    static func isHeldKeyTalk(phase: TalkPhase, keyBeganSession: UUID?, sessionID: UUID?, startingPressHeld: Bool) -> Bool {
        phase == .capturing && sessionID != nil && keyBeganSession == sessionID && startingPressHeld
    }

    /// Finishing with "no target" pinned: the words go to Recent, not into an app.
    var finishKeepsWordsInApp: Bool { Self.finishKeepsWords(phase: phase, stopTarget: stopTarget) }
    static func finishKeepsWords<T>(phase: TalkPhase, stopTarget: StopTarget<T>) -> Bool {
        phase == .finalizing && stopTarget.captured && stopTarget.value == nil
    }

    /*
    Home's Stop (TOK-QA-005): ends the talk and keeps the words in Recent and Copy latest. It never
    pastes and never sends Return. A click carries no talk-key edge (deliveryEdgeIsCurrent is
    { true } outside key callbacks) and an Accessibility press can arrive while another app is in
    front, so "no target" is pinned before finish() reads one; StopTarget keeps that first answer.
    Stop waits for the first audio: before it, finishAdaptively can return without completing.
    */
    func stopTalkFromHome() {
        guard !bubbleInteractivePreview, phase == .capturing, audioIsConfirmed, let sessionID else { return }
        stopTarget.capture {
            Diagnostics.event("capture_target_unavailable reason=home_stop session=\(sessionID.uuidString)")
            return nil
        }
        // Nothing pins a target during capture today; if something ever does, Home must not paste there.
        guard stopTarget.value == nil else { return }
        finish(sendReturn: false)
    }

    /// Home's Discard (TOK-QA-005): no paste, no History row, journal entry resolved. Capturing only.
    func discardTalkFromHome() {
        guard !bubbleInteractivePreview, phase == .capturing, let sessionID else { return }
        if deferredTalkPress.isArmed {
            deferredTalkPress.cancel()
            Diagnostics.event("talk_press_deferred_cancelled reason=home_discard")
        }
        // Logged before the reset: the session id is gone afterwards.
        Diagnostics.event("capture_discarded reason=home session=\(sessionID.uuidString)")
        discardRunningCapture()
    }

    /// Ends the running talk without delivering it; shared by the bubble's ✕, a chord and Home's Discard.
    private func discardRunningCapture() {
        // Explicit discard resolves only this session.
        let discarded = sessionID
        let resolved = discarded.map { resolveTranscriptRecovery($0) } ?? true
        // Invalidate model callbacks before stopping recognition or clearing text.
        hideSurface()
        resetSession()
        previewWaveTimer?.invalidate()
        previewWaveTimer = nil
        audio.discardCapture()
        if let discarded, !resolved { keepUnresolvedDiscard(discarded) }
    }

    static let discardKeptNote = "Not discarded · words kept"

    /// The earlier-talk line a discard leaves when the journal could not record it; nil otherwise.
    static func unresolvedDiscardLine(session: UUID, resolved: Bool, journalText: String?) -> RecoveredTalk? {
        guard !resolved, let journalText, !journalText.isEmpty else { return nil }
        return RecoveredTalk(id: session, text: journalText)
    }

    /*
    when the journal cannot record a discard, the talk's saved words
    would come back after a relaunch while Home had said nothing. Say so now, on the earlier-talk
    line, with Copy and a Forget that tries again. Nothing is pasted and nothing is added to History.
    The session is remembered, so after Copy or Forget the next such discard is offered in turn.
    */
    private func keepUnresolvedDiscard(_ session: UUID) {
        Diagnostics.event("capture_discard_unresolved session=\(session.uuidString)")
        let text = try? transcriptRecovery.copyCandidate(sessionID: session)
        guard let line = Self.unresolvedDiscardLine(session: session, resolved: false, journalText: text) else { return }
        // Remembered, so a second one shown here never hides this one for good (re-check of aea32b4).
        unresolvedDiscardIDs.insert(session)
        earlierRecovery     = line
        earlierRecoveryNote = Self.discardKeptNote
    }

    /// The bubble's finish button respects the same Auto-send choice as the talk key.
    func finishBubbleCapture() {
        if bubbleInteractivePreview { NSApp.terminate(nil); return }
        guard phase == .capturing else { return }
        // Tokens decorations are finalized once; never commit a prefix before final layout.
        if speedOfSoundEnabled && audio.isRecording {
            finishAtSpeedOfSound()
        } else {
            finish()
        }
    }

    // Lab — the voice lab window, plus the menu's start/finish toggle

    /// Opens the voice lab paused: no microphone until startLabListening().
    func openLab() {
        guard phase == .idle, !isLabOpen else { return }
        isLabOpen            = true
        isLabListening       = false
        labOwnsSignalCapture = false
        onLabVisibilityChange?(true)
        print("TTT_EVENT lab_opened paused=true")
    }

    /// Signal capture with voice commands for the lab; no talk and no delivery.
    func startLabListening() {
        guard !Self.tokensFirstRunPending else { return }
        guard phase == .idle, isLabOpen, !isLabListening else { return }
        stopInputPreview()
        isLabListening       = true
        labOwnsSignalCapture = true
        audio.requestAccessAndStartSignal(voiceCommands: true, labMode: true)
        print("TTT_EVENT lab_signal_requested source=native_control")
    }

//
// :)
//
//
    /// Stops lab listening; the microphone stops only if the lab owned it.
    func pauseLab(source: String = "native_control") {
        guard isLabListening || labOwnsSignalCapture else { return }
        let shouldStopSignal = labOwnsSignalCapture
        isLabListening       = false
        labOwnsSignalCapture = false
        labPreviewCandidate  = nil
        if shouldStopSignal { _ = audio.stop() }
        print("TTT_EVENT lab_paused source=\(source) stopped_signal=\(shouldStopSignal)")
    }

    func toggleLabListening() {
        if isLabListening {
            pauseLab()
        } else {
            startLabListening()
        }
    }

    /// --demo: opens the lab already listening.
    func runLabPreview() {
        // --demo is generated signal only: AudioCapture returns before permission/hardware access.
        guard audio.demoMode || !Self.tokensFirstRunPending else { return }
        guard ProcessInfo.processInfo.arguments.contains("--demo") else { return }
        isLabOpen            = true
        isLabListening       = true
        labOwnsSignalCapture = true
        audio.requestAccessAndStartSignal(voiceCommands: true, labMode: true)
        print("TTT_EVENT lab_demo_started")
    }

    func closeLab() {
        pauseLab(source: "lab_closed")
        isLabOpen = false
        onLabVisibilityChange?(false)
        print("TTT_EVENT lab_closed")
    }

    func beginDictationFromLab() {
        guard phase == .idle else { return }
        begin()
    }

    /// The menu command "Start / Finish Dictation" (Control-Option-Space): starts or
    /// finishes a talk; ignored while finalizing.
    func toggle() {
        guard !bubbleInteractivePreview else { return }
        guard selectedProduct != "Telescope" else { return }
        print("TTT_EVENT chord phase=\(phase)")
        switch phase {
        case .capturing:
            pressToTalkEnd()
        case .idle, .delivered, .failed:
            pressToTalkBegin()
        case .finalizing:
            break
        }
    }

    // Lab sound preview — briefly shows a candidate sound name

    func previewLabSoundFromControl(_ candidate: Candidate) {
        guard phase == .idle, isLabOpen else { return }
        setLabSoundPreview(candidate, source: "control")
    }

    /// Shows a candidate for 1.1 s; a newer preview replaces it.
    func setLabSoundPreview(_ candidate: Candidate, source: String) {
        labPreviewCandidate = candidate
        labPreviewRevision &+= 1
        let revision = labPreviewRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.labPreviewRevision == revision else { return }
            self.labPreviewCandidate = nil
        }
        print("TTT_EVENT lab_sound_preview source=\(source) candidate=\(candidate.displayName) revision=\(revision)")
    }

}

