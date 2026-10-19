


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// TalkModel — IdleListening


extension TalkModel {

    /// Every idle route, including a visible level preview, requires fresh consent.
    private var idleListeningAllowed: Bool {
        ambientEnabled && backgroundConsent.isEnabled && !ambientShuttingDown
    }

    /// One status line for background listening, shown in Live notes.
    var ambientStatus: String {
        if phase == .capturing { return "Talking · on this Mac" }
        if !idleListeningAllowed { return "Background listening off" }
        if ambientOwnsCapture {
            if let error = audio.captureError { return error }
            return audio.isRecording && audio.hasReceivedAudio ? "Listening · on this Mac" : "Connecting microphone…"
        }
        // Reached only when not capturing (the first line returns in that case).
        return audio.hasRecentHardwareSamples ? "Microphone live · on this Mac" : "Background listening enabled · microphone stopped"
    }

    /// Tincture's voice box on/off. Turning it off closes the microphone.
    func toggleTinctureVoice() {
        tinctureVoiceEnabled.toggle()
        if tinctureVoiceEnabled { resumeInputPreview() }
        else { audio.keepMicrophoneOpenWhileIdle(false); stopInputPreview() }
    }

    /// Background listening on/off. Turning it off also cancels a running talk (see below)
    /// and clears what background listening had heard.
    func toggleAmbientListening() {
        if !ambientEnabled { setBackgroundListening(true); return }
        disableBackgroundListening()
        do {
            /*
            Pause is a real privacy control, including during an armed prompt.
            Cancel delivery first, retain only that explicit prompt for Copy latest.
            */
            if phase == .capturing || phase == .finalizing {
                let held = availableEarlyDelivery?.payload ?? audio.deliverySnapshot().transcript
                resetSession()
                audio.discardCapture()
                if !held.isEmpty {
                    retainForRecovery(held, message: "Listening paused · Copy latest", shouldRecordHistory: false, showOverlay: false)
                }
            }
            stopInputPreview()
            ambientReflection.discard()
            ambientTranscript = ""
        }
    }

    /// Called at quit: closes the microphone and stops every listener.
    /// ambientShuttingDown keeps resumeInputPreview from reopening it.
    func stopAmbientForQuit() {
        ambientShuttingDown = true
        disableBackgroundListening()
        audio.keepMicrophoneOpenWhileIdle(false)
        stopInputPreview()
        ambientReflection.discard()
        pauseAsides.stop()
        _ = audio.stop()
    }

    // First run and idle listening — permissions, warm-up, listening between talks

    /// Decides whether idle listening should run now, and starts or stops it. It runs when
    /// the preview is visible (not in Telescope or Tincture), in Tincture, or when
    /// background listening is allowed in the Tokens thinking experience.
    func setInputPreviewVisible(_ visible: Bool) {
        inputPreviewVisible = visible && !["Telescope", "Tincture"].contains(selectedProduct)
        if inputPreviewVisible || selectedProduct == "Tincture" || (thinkingExperience && idleListeningAllowed) { resumeInputPreview() } else { stopInputPreview() }
    }

//
// :)
//
//
    static let tokensFirstRunKey = "tinkr.tokens.firstRun.complete"

    /// No live microphone or macOS prompt until the person starts setup from an Access action
    /// (there is no Terms step in the community build). Old permission grants cannot waive it.
    static var tokensFirstRunPending: Bool {
        publicTokens && !UserDefaults.standard.bool(forKey: tokensFirstRunKey)
    }

    /*
    Build 78. tokensFirstRunKey is saved the moment setup starts, so it cannot tell a new
    install still walking through setup from someone who finished long ago. Setup counts as
    finished only when its last step's Start is pressed; a new install therefore stays "in
    setup" after its first Access action and across the Accessibility relaunch. Installs that
    began setup before build 78 are migrated as finished once, at their first 78 launch.
    */
    static let tokensSetupFinishedKey = "tinkr.tokens.setupFinished.v1"
    static let tokensSetupMigratedKey = "tinkr.tokens.setupFinishedMigrated.v1"

    static func migrateSetupFinished(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: tokensSetupMigratedKey) else { return }
        if defaults.bool(forKey: tokensFirstRunKey) { defaults.set(true, forKey: tokensSetupFinishedKey) }
        defaults.set(true, forKey: tokensSetupMigratedKey)
    }

    static func markSetupFinished(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: tokensSetupFinishedKey)
    }

    static func setupInProgress(firstRunPending: Bool, defaults: UserDefaults = .standard) -> Bool {
        firstRunPending || !defaults.bool(forKey: tokensSetupFinishedKey)
    }

    static var tokensSetupInProgress: Bool { setupInProgress(firstRunPending: tokensFirstRunPending) }

    /// Starts setup from the first Access action: the three macOS prompts, then the start-at-login choice.
    @discardableResult
    func completeTokensFirstRun(openAtLogin: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: Self.tokensFirstRunKey)
        Diagnostics.event("first_run_complete reason=access open_at_login=\(openAtLogin)")
        /*
        Attaching the key monitor may ask for Accessibility; prepareSpeech asks for the
        microphone and speech recognition.
        */
        startMonitoring()
        if !shortcutAccessGranted { startShortcutAccessPoll() }
        prepareSpeech()
        setInputPreviewVisible(true)
        // A choice already made in Settings (via the card's gear) wins over the card switch.
        if !LoginItem.choiceMade {
            if openAtLogin { LoginItem.registerIfEligible() } else { LoginItem.declineDefault() }
        }
        // Configured update checks may contact the website only after this consent boundary.
        if !isSyntheticRun { updater.startBackgroundChecks() }
        return true
    }

    /// Asks for Microphone and, only for an Apple selection, Speech access. A ready local
    /// model is prewarmed without Speech permission. Opens no microphone.
    /// The two requests run one after the other; the warm-up then runs on main.
    func prepareSpeech() {
        guard !Self.tokensFirstRunPending else { return }
        let audio = self.audio
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                guard !Self.tokensFirstRunPending else { return }
                if SpeechEngineChoice.load() == .orukeet {
                    if !SpeechEngineChoice.waitingForOrukeet() { audio.prewarmRecognition() }
                    return
                }
                // A local model's download never asks for Apple's Speech permission.
                guard SpeechEngineChoice.appleSpeechNeeded(setupPending: Self.tokensSetupInProgress) else { return }
                SFSpeechRecognizer.requestAuthorization { _ in
                    DispatchQueue.main.async {
                        guard !Self.tokensFirstRunPending else { return }
                        audio.prewarmRecognition()
                    }
                }
            }
        }
    }

    /// Starts one idle listener if every guard allows (first run done, not Telescope, not
    /// quitting, not a synthetic run, none running yet, no talk running, lab closed, not
    /// rendering preview frames):
    ///   Tincture         → Tincture's voice box, recognized on this Mac only
    ///   Tokens thinking  → background listening, if allowed (see idleListeningAllowed)
    ///   otherwise        → the input-level preview (signal only, no words), if visible
    func resumeInputPreview() {
        guard idleListeningAllowed else {
            audio.keepMicrophoneOpenWhileIdle(false)
            stopInputPreview()
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            disableBackgroundListening()
            return
        }
        guard !Self.tokensFirstRunPending else { return }
        guard selectedProduct != "Telescope", !ambientShuttingDown, !isSyntheticRun, !inputPreviewOwnsCapture,
              phase == .idle || phase == .delivered || phase == .failed,
              !isLabListening, !isLabOpen,
              !ProcessInfo.processInfo.arguments.contains("--render-preview-frames") else { return }
        if selectedProduct == "Tincture" {
            guard tinctureVoiceEnabled else { return }
            audio.keepMicrophoneOpenWhileIdle(true)
            inputPreviewOwnsCapture = true; tinctureOwnsCapture = true
            tinctureVoiceTranscript = ""; tinctureStableWords = 0
            audio.requestAccessAndStart(localOnly: true)
            /*
            Same 60 s restart as background listening below. scheduledTimer uses the current
            (main) run loop; MainActor.assumeIsolated in the block relies on that.
            */
            ambientRotation?.invalidate()
            ambientRotation = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.tinctureOwnsCapture else { return }
                    self.stopInputPreview(); self.resumeInputPreview()
                }
            }
        } else if thinkingExperience {
            guard idleListeningAllowed else { audio.keepMicrophoneOpenWhileIdle(false); return }
            audio.keepMicrophoneOpenWhileIdle(true)
            inputPreviewOwnsCapture = true
            ambientOwnsCapture      = true
            ambientTranscript       = ""
            ambientReflection.begin()
            audio.requestAccessAndStart(localOnly: true)
            ambientRotation?.invalidate()
            // Bound recognition/context lifetime; the hardware tap stays running.
            ambientRotation = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.ambientOwnsCapture else { return }
                    self.stopInputPreview()
                    self.resumeInputPreview()
                }
            }
            showPauseAside(explicit: false)
        } else if inputPreviewVisible {
            // Signal only: audio levels, no speech recognition and no voice commands.
            audio.keepMicrophoneOpenWhileIdle(false)
            inputPreviewOwnsCapture = true
            audio.requestAccessAndStartSignal(voiceCommands: false, labMode: false)
        }
    }

//
// :)
//
//
    /// Releases whichever idle listener owns the microphone and clears what it heard.
    /// discardCapture() runs only if an idle listener owned it, so a talk is never touched.
    func stopInputPreview() {
        ambientRotation?.invalidate(); ambientRotation = nil
        ambientReflection.stop()
        ambientTranscript       = ""
        let owned               = inputPreviewOwnsCapture
        inputPreviewOwnsCapture = false
        ambientOwnsCapture      = false
        tinctureOwnsCapture     = false; tinctureVoiceTranscript = ""; tinctureStableWords = 0
        if owned { audio.discardCapture() }
    }

}

