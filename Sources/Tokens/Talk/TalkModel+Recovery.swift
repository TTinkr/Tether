


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// TalkModel — Recovery


/// A temporary shortcut error remembers the status it covered. It never stores or edits words.
/// Repeated failures retain the first snapshot; a newer status invalidates the model's owner.
struct ShortcutAccessFailure {
    let message: String
    let previousMessage: String
    let previousPhase: TalkPhase

    init(message: String, currentMessage: String, currentPhase: TalkPhase,
         replacing previous: ShortcutAccessFailure?) {
        self.message = message
        if let previous, previous.message == currentMessage {
            previousMessage = previous.previousMessage
            previousPhase = previous.previousPhase
        } else {
            previousMessage = currentMessage
            previousPhase = currentPhase
        }
    }

    func restoredStatus(currentMessage: String, currentPhase: TalkPhase) -> (message: String, phase: TalkPhase)? {
        guard currentMessage == message else { return nil }
        // A key repair must not resurrect an interrupted capture or overwrite a newer phase.
        let restoredPhase: TalkPhase
        if currentPhase == .failed {
            switch previousPhase {
            case .idle, .delivered, .failed: restoredPhase = previousPhase
            case .capturing, .finalizing: restoredPhase = .failed
            }
        } else {
            restoredPhase = currentPhase
        }
        return (previousMessage, restoredPhase)
    }
}

extension TalkModel {

    // Saving — recovery journal, and holding words for Copy latest

    /*
    Normal talk persistence uses prompt history (recordPromptHistory) and the recovery
    journal below. Explicit speech-proof routes also write local transcript-bearing reports
    to their requested output paths; see SpeechProofs.swift.
    No data collection. The old per-talk dataset.jsonl row is gone.
    */

    /// Writes the words to the recovery journal with a state (capturing, stopped,
    /// finalTextReady, held, deliveryUncertain). On failure the words stay in memory for
    /// Copy latest and a storage message is shown. The talk's History row id goes with them:
    /// the journal trims an old unconfirmed paste only while that row is confirmed saved (build 81).
    func checkpointTranscript(_ text: String, session: UUID, state: TranscriptRecoveryState) {
        guard !isSyntheticRun else { return }
        do {
            try transcriptRecovery.checkpoint(sessionID: session, text: text, state: state,
                                              historyEntryID: historyRowIDs[session])
        } catch {
            retainedFailurePayload = text
            historyStorageError    = "Recovery could not be saved; keep this app open and use Copy latest."
            Diagnostics.event("recognized_text_checkpoint_failed session=\(session)")
        }
    }

    /*
    The live 0.75 s snapshot goes to the journal's own queue, off the main thread (build 81).
    A failure is reported back on main only while this talk is still recording: once Stop has
    run, its own synchronous checkpoint has the newer words and reports any failure itself.
    */
    func checkpointCaptureTranscript(_ text: String, session: UUID) {
        guard !isSyntheticRun else { return }
        transcriptRecovery.checkpointInBackground(sessionID: session, text: text) { [weak self] in
            DispatchQueue.main.async {
                Diagnostics.event("recognized_text_checkpoint_failed session=\(session)")
                guard let self, self.sessionID == session, self.phase == .capturing else { return }
                self.retainedFailurePayload = text
                self.historyStorageError    = "Recovery could not be saved; keep this app open and use Copy latest."
            }
        }
    }

    /// Persist the latest raw recognizer text at a bounded cadence while capture
    /// is active. Continued partial revisions update the pending value but cannot
    /// postpone the write indefinitely. Recovery only offers Copy after relaunch.
    /// At most one write per 0.75 s; the newest text wins.
    func scheduleCaptureCheckpoint(_ text: String) {
        guard !isSyntheticRun, phase == .capturing, let requestedSession = sessionID,
              !text.isEmpty, text != lastCaptureCheckpointText else { return }
        pendingCaptureCheckpointText = text
        guard captureCheckpointWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.captureCheckpointWork = nil
            guard self.phase == .capturing, self.sessionID == requestedSession else { return }
            let latest = self.pendingCaptureCheckpointText
            guard !latest.isEmpty, latest != self.lastCaptureCheckpointText else { return }
            self.checkpointCaptureTranscript(latest, session: requestedSession)
            self.lastCaptureCheckpointText = latest
            Diagnostics.event("capture_checkpoint session=\(requestedSession.uuidString) characters=\(latest.utf16.count)")
        }
        captureCheckpointWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    /// Marks the talk's journal entry done, so it is not offered again at launch.
    /// False when the journal could not be written (the words stay in it).
    @discardableResult
    func resolveTranscriptRecovery(_ session: UUID) -> Bool {
        guard !isSyntheticRun else { return true }
        do { try transcriptRecovery.resolve(sessionID: session); return true }
        catch { Diagnostics.event("recognized_text_resolution_failed session=\(session)"); return false }
    }

    /*
    The next earlier talk to offer on Home (build 81): the newest
    unresolved journal entry older than the newest History talk, other than the held words under
    Copy latest and the talk running now. After one is copied or forgotten, the next one shows
    at once instead of waiting for a relaunch.
    */
    func refreshEarlierRecovery() {
        guard !isSyntheticRun, let entries = try? transcriptRecovery.recover() else { return }
        let newestHistory = promptHistory.map(\.createdAt).max()
        // A discard the journal could not record stays offered even though it is newer than History.
        unresolvedDiscardIDs.formIntersection(entries.map(\.id))
        let next = entries.filter { entry in
            entry.id != restoredRecoveryID && entry.id != sessionID
                && (unresolvedDiscardIDs.contains(entry.id) || !Self.offersAtLaunch(entry.updatedAt, newestHistory: newestHistory))
        }.max { $0.updatedAt < $1.updatedAt }
        earlierRecovery = next.map { RecoveredTalk(id: $0.id, text: $0.text) }
        earlierRecoveryNote = next.map { unresolvedDiscardIDs.contains($0.id) } == true ? Self.discardKeptNote : nil
    }

    /// The one "hold the words" path: set the failure message, keep the words for Copy
    /// latest, optionally record history, enter failed, and (unless showOverlay is false)
    /// show the bubble again on the target's screen, with the held words when asked.
    func retainForRecovery(
        _ text: String,
        authored: AuthoredPrompt? = nil,
        // A talk that stopped early, kept for Copy; talk wording, not "Transcript held" (build 81).
        message: String = "Talk stopped early · Copy latest",
        sendReturn: Bool = false,
        shouldRecordHistory: Bool = true,
        showOverlay: Bool = true,
        holdWords: Bool = false,
        showRecoveryWindow: Bool = true
    ) {
        /*
        A held payload may include literal typed text or generated presentation.
        Keep its exact bytes; only structured faithful fields belong in History.
        */
        retainedFailureText    = message
        retainedFailurePayload = text
        if !text.isEmpty {
            // Callers checkpoint raw recognized words with their actual recovery state.
            // Presentation text belongs to this window and Copy latest, not that journal.
            /*
            On the destination's screen, or else the screen the bubble was on for this talk: the
            places the user was looking (build 81: it could open on the other display).
            */
            if showOverlay && showRecoveryWindow {
                recoveryWindows.present(id: sessionID ?? UUID(), text: text, message: message,
                                        screenFrame: target?.screenFrame ?? compactWindow()?.frame)
            }
        }
        lastTranscriptForCopy  = text
        if shouldRecordHistory {
            if let authored { recordPromptHistory(authored, session: sessionID) }
            else { recordPromptHistory(text, session: sessionID) }
        }
        retainedSendReturn = sendReturn
        phase              = .failed
        Diagnostics.event("recovery_retained session=\(sessionID?.uuidString ?? "none")")
        if showOverlay {
            if showRecoveryWindow && !text.isEmpty {
                // The pop-up holds the words; the tiny bubble leaves instead of lingering (build 79).
                clearHeldWords()
                hideSurface()
                return
            }
            previewIsHidden = false
            if holdWords, !text.isEmpty { presentHeldWords() }
            showSurface(on: target?.screenFrame)
        }
    }

//
// :)
//
//
    // Recovery copy — copying held words, and failure messages

    /// Copies the held words and sets the status line to "copied".
    func copyRetainedTranscript() {
        guard !retainedFailurePayload.isEmpty else { return }
        stopRecoveryCommandCapture()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(retainedFailurePayload, forType: .string)
        retainedFailureText = "copied"
        print("TTT_EVENT recovery_copy characters=\(retainedFailurePayload.utf16.count)")
    }

    /// Nothing in this class calls it.
    private func startRecoveryCommandCapture() {
        /*
        Recovery command capture is disabled. Manual talks and separately consented
        background listening own their microphone lifetimes.
        */
        recoveryOwnsCommandCapture = false
    }

    func stopRecoveryCommandCapture() {
        guard recoveryOwnsCommandCapture else { return }
        recoveryOwnsCommandCapture = false
        _ = audio.stop()
    }

    /// Reached only from observeCompletedSegment's "copy" command (see the note there).
    func copyRetainedByVoice() {
        guard phase == .failed, !retainedFailurePayload.isEmpty else { return }
        let payload = retainedFailurePayload
        stopRecoveryCommandCapture()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        print("TTT_EVENT recovery_voice_copy characters=\(payload.utf16.count)")
        hideSurface()
        resetSession()
    }

    /// Show a temporary key-access error without losing the recovery status it covers.
    func showShortcutAccessFailure(_ message: String) {
        let failure = ShortcutAccessFailure(message: message, currentMessage: retainedFailureText,
                                            currentPhase: phase, replacing: shortcutAccessFailure)
        showAccessFailure(message)
        // Assign after showAccessFailure, whose status assignment invalidates older ownership.
        shortcutAccessFailure = failure
    }

    /// Successful reattachment removes only the key error still owned by this recovery flow.
    func resolveShortcutAccessFailure() {
        guard let failure = shortcutAccessFailure else { return }
        shortcutAccessFailure = nil
        guard let restored = failure.restoredStatus(currentMessage: retainedFailureText, currentPhase: phase) else { return }
        retainedFailureText = restored.message
        if phase != restored.phase { phase = restored.phase }
    }

    /// A failure message with no new words to hold: key access, microphone start, capture errors.
    func showAccessFailure(_ message: String) {
        retainedFailureText = message
        phase               = .failed
        Diagnostics.event("access_failure session=\(sessionID?.uuidString ?? "none")")
        scheduleFailureStatusHide()
    }

    /*
    A failure that holds no words (the microphone did not start, the voice model is still
    downloading, an update is restarting, speech failed before any words) used to float over every
    app and Space until the next talk, with no way to close it (build 81). The bubble now leaves
    after a few seconds. Only the bubble goes: the line stays on Home, and the next press starts
    fresh as before. Held words and key-access errors keep their own lifecycles.
    */
    static let failureStatusSeconds: TimeInterval = 5

    static func failureStatusMayLeave(phase: TalkPhase, heldPayload: String, heldWordsVisible: Bool,
                                      keyAccessFailure: Bool) -> Bool {
        phase == .failed && heldPayload.isEmpty && !heldWordsVisible && !keyAccessFailure
    }

    private func scheduleFailureStatusHide() {
        failureStatusHide?.cancel()
        let session = sessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            failureStatusHide = nil
            guard self.sessionID == session,
                  Self.failureStatusMayLeave(phase: self.phase, heldPayload: self.retainedFailurePayload,
                                             heldWordsVisible: self.heldWordsVisible,
                                             keyAccessFailure: self.shortcutAccessFailure != nil) else { return }
            Diagnostics.event("failure_status_hidden session=\(session?.uuidString ?? "none")")
            self.hideSurface()
        }
        failureStatusHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.failureStatusSeconds, execute: work)
    }

    /*
    A press while the voice model is still downloading. The line used to be a snapshot ("37%"
    for good, even after the download finished). It now follows the download while it is still
    the status shown, and once the model is ready the status clears so the next press just talks
    (build 81).
    */
    func showOrukeetWaiting() {
        let store = MainActor.assumeIsolated { SpeechModelStore.shared }
        var shown = MainActor.assumeIsolated { store.waitingLine() }
        showAccessFailure(shown)
        // After the change lands: @Published sends before the new state is stored.
        orukeetWaitingFollower = MainActor.assumeIsolated { store.$states }
            .dropFirst()
            .map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .failed, self.retainedFailureText == shown,
                          self.retainedFailurePayload.isEmpty, self.shortcutAccessFailure == nil else {
                        orukeetWaitingFollower = nil
                        return
                    }
                    if !SpeechEngineChoice.waitingForOrukeet() {
                        orukeetWaitingFollower = nil
                        Diagnostics.event("capture_waiting_for_orukeet_ready")
                        self.hideSurface()
                        self.resetSession()
                        return
                    }
                    shown = store.waitingLine()
                    self.retainedFailureText = shown
                }
            }
    }

}

/// The pending hide of a words-free failure status, and the download line's follower (build 81).
private var failureStatusHide: DispatchWorkItem?
private var orukeetWaitingFollower: AnyCancellable?

