


//
import AVFoundation
import AppKit
import SwiftUI


extension TalkModel {
    /// Both Settings surfaces use this setter instead of writing presentation state.
    var backgroundListeningBinding: Binding<Bool> {
        Binding(get: { self.ambientEnabled }, set: { self.setBackgroundListening($0) })
    }

    func configureListeningPrivacy() {
        backgroundLifecycle = BackgroundListeningLifecycle { [weak self] reason, suspended in
            guard let self else { return }
            if suspended {
                self.backgroundConsent.suspend(reason)
                self.disableBackgroundListening()
                /*
                A tap remembered while the last talk finishes would start a new talk once it
                lands, and delivery can land after the lock (build 81 review). Forget it in
                every phase, sleep included; the next talk needs a fresh press after unlocking.
                */
                if self.deferredTalkPress.isArmed {
                    self.deferredTalkPress.cancel()
                    let name = reason == .sleep ? "sleep" : reason == .screenLock ? "screen_lock" : "inactive_session"
                    Diagnostics.event("talk_press_deferred_cancelled reason=\(name)")
                }
                /*
                A talk never records through a locked screen or a switched-out session (build 81:
                a tap-mode talk recorded the room while the Mac was locked). It ends without
                pasting; its words wait under Copy latest, as on sleep (AudioCapture handles sleep).
                */
                if reason != .sleep, self.phase == .capturing {
                    Diagnostics.event("capture_interrupted reason=\(reason == .screenLock ? "screen_lock" : "inactive_session")")
                    self.audio.interruptCapture(message: reason == .screenLock
                        ? "Mac locked. Copy latest, then tap to talk again."
                        : "Switched user. Copy latest, then tap to talk again.")
                }
            } else {
                self.backgroundConsent.resume(reason)
            }
        }
    }

    /// Continue is the consent edge. A historic preference or an open Settings page is not.
    func setBackgroundListening(_ enabled: Bool) {
        guard enabled else { disableBackgroundListening(); return }
        guard !Self.tokensFirstRunPending else { return }
        guard !ambientShuttingDown, !isSyntheticRun,
              let request = backgroundConsent.beginRequest() else { return }
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "Keep listening between talks?"
        warning.informativeText = "Tokens will keep the microphone on and transcribe nearby speech on this Mac, including other people nearby. Local models may turn those words into temporary notes. This switch does not enable saved memory or uploads.\n\nListening turns off when you turn it off, lock or sleep your Mac, or quit Tokens. You must enable it again after unlocking or relaunching."
        warning.addButton(withTitle: "Continue")
        warning.addButton(withTitle: "Cancel")
        guard warning.runModal() == .alertFirstButtonReturn else {
            disableBackgroundListening()
            return
        }
        // Lock/Off can arrive while the modal is running; they invalidate its request.
        guard backgroundConsent.pendingRequest == request, !Self.tokensFirstRunPending else { return }
        let complete: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.ambientShuttingDown, !Self.tokensFirstRunPending else { return }
                guard self.backgroundConsent.complete(request, warningAccepted: true, microphoneGranted: granted) else { return }
                self.ambientEnabled    = true
                self.showLiveTinkering = true
                self.audio.keepMicrophoneOpenWhileIdle(true)
                self.resumeInputPreview()
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    complete(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: complete)
        default:             complete(false)
        }
    }

    /// Idle-only Off. AudioCapture stops the hardware immediately when it has no active
    /// session; otherwise it closes when the current manual talk finishes. The manual
    /// session and its delivery gate stay intact.
    func disableBackgroundListening() {
        backgroundConsent.revoke()
        ambientEnabled    = false
        showLiveTinkering = false
        audio.keepMicrophoneOpenWhileIdle(false)
        stopInputPreview()
        ambientReflection.discard()
        ambientTranscript = ""
    }
}

