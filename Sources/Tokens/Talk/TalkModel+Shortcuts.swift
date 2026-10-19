


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Shortcuts


extension TalkModel {

    /// Records the next key pressed as the new talk key. Refused mid-talk.
    func changeShortcut() {
        guard phase != .capturing && phase != .finalizing else { return }
        recordingShortcut = input.beginShortcutRecording { [weak self] shortcut in
            self?.shortcutName = shortcut.displayName
            self?.shortcutKeyCode = shortcut.keyCode
            self?.recordingShortcut = false
        }
    }

    func cancelShortcutChange() {
        input.cancelShortcutRecording()
        recordingShortcut = false
    }

    /// Back to this product's default talk key. Refused mid-talk.
    func resetShortcut() {
        guard phase != .capturing && phase != .finalizing else { return }
        cancelShortcutChange()
        input.resetShortcut()
        shortcutName    = input.shortcut.displayName
        shortcutKeyCode = input.shortcut.keyCode
    }

    /// Picks a talk key from a list. Returns false mid-talk or when the key monitor
    /// refuses the key (see GlobalKeyMonitor.setShortcut).
    @discardableResult
    func selectShortcut(_ shortcut: TalkShortcut) -> Bool {
        guard phase != .capturing && phase != .finalizing else { return false }
        cancelShortcutChange()
        guard input.setShortcut(shortcut) else {
            Diagnostics.event("dictation_shortcut_select_refused keycode=\(shortcut.keyCode)")
            return false
        }
        shortcutName    = shortcut.displayName
        shortcutKeyCode = shortcut.keyCode
        Diagnostics.event("dictation_shortcut_selected keycode=\(shortcut.keyCode)")
        return true
    }

    // Key access — Accessibility permission for the talk key

    /// Attaches the global key monitor for the talk key (Telescope has none). Success clears
    /// its owned key-access error while preserving held words and earlier status. accessibilityDenied: the
    /// permission is off. tapUnavailable: the app needs a relaunch before the key works.
    func startMonitoring(
        promptForAccessibility: Bool = false,
        reportFailure: Bool = true
    ) {
        guard !Self.tokensFirstRunPending else {
            input.stop()
            shortcutAccessGranted = false
            shortcutAccessPollTimer?.invalidate()
            shortcutAccessPollTimer = nil
            return
        }
        guard selectedProduct != "Telescope" else {
            input.stop()
            shortcutAccessGranted = false
            return
        }
        let result = input.start(
            promptForAccessibility: promptForAccessibility,
            reportFailure: reportFailure
        )
        switch result {
        case .started:
            shortcutAccessGranted       = true
            shortcutAccessNeedsRelaunch = false
            shortcutAccessPollTimer?.invalidate()
            shortcutAccessPollTimer    = nil
            shortcutAccessPollAttempts = 0
            resolveShortcutAccessFailure()
        case .accessibilityDenied:
            shortcutAccessGranted       = false
            shortcutAccessNeedsRelaunch = false
        case .tapUnavailable:
            shortcutAccessGranted       = false
            shortcutAccessNeedsRelaunch = true
        }
        // Whatever the result, re-check idle listening on the next main-loop turn.
        DispatchQueue.main.async { [weak self] in self?.resumeInputPreview() }
    }

//
// :)
//
//
    /// Opens System Settings at Privacy & Security → Accessibility, then polls for the grant.
    func openShortcutAccessibilitySettings() {
        guard !Self.tokensFirstRunPending else { return }
        startMonitoring(promptForAccessibility: true, reportFailure: true)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        startShortcutAccessPoll()
        Diagnostics.event("shortcut_access_settings_opened")
    }

    /// Re-attaches the key within 90 s of Accessibility being granted in System Settings.
    /// Tries every 0.75 s, 120 times; on timeout it says what to do next.
    func startShortcutAccessPoll() {
        guard !Self.tokensFirstRunPending else { return }
        shortcutAccessPollTimer?.invalidate()
        shortcutAccessPollAttempts = 0
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.shortcutAccessPollAttempts += 1
            self.startMonitoring(promptForAccessibility: false, reportFailure: false)
            if self.shortcutAccessGranted || self.shortcutAccessPollAttempts >= 120 {
                timer.invalidate()
                self.shortcutAccessPollTimer = nil
                if !self.shortcutAccessGranted {
                    self.showShortcutAccessFailure(
                        self.shortcutAccessNeedsRelaunch
                            ? "Accessibility changed, but \(self.shortcutName) still needs a \(appName) relaunch."
                            : "\(self.shortcutName) is blocked. Enable \(appName) in Privacy & Security > Accessibility, then Try Again."
                    )
                }
            }
        }
        // .common mode: the poll also fires while a menu or control is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        shortcutAccessPollTimer = timer
    }

    /// "Try Again": re-attach without prompting.
    func retryShortcutAccess() {
        startMonitoring(promptForAccessibility: false, reportFailure: true)
    }

    /// Starts a shell that waits 1 s and opens this app as a new instance, then quits, so
    /// the new process can attach the key monitor. Refused mid-talk.
    func relaunchForShortcutAccess() {
        guard !reconnectDisabled else { return }
        let process           = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; exec /usr/bin/open -n \"$1\"",
            "TokensRelaunch",
            Bundle.main.bundlePath
        ]
        do {
            try process.run()
            Diagnostics.event("shortcut_access_relaunch_requested")
            NSApp.terminate(nil)
        } catch {
            showShortcutAccessFailure("\(appName) could not relaunch automatically. Quit and reopen it, then Try Again.")
        }
    }

    // Key edges — a press or release of the talk key becomes begin or finish

    /// Every talk key press and release arrives here, on main. RightOptionMode.action turns
    /// it into begin, finish or ignore; during a talk, the mode it began with is used.
    /// With Speed of Sound on, a finish while recording skips the local formatter wait.
    func routeRightOption(pressed: Bool) {
        // Home hides Stop/Discard while this talk's starting press is down; redraw it on release (TOK-QA-005).
        if !pressed, phase == .capturing, sessionID != nil, keyBeganSession == sessionID { objectWillChange.send() }
        let sessionMode = (phase == .capturing || phase == .finalizing)
            ? (activeSessionMode ?? rightOptionMode)
            : rightOptionMode
        switch sessionMode.action(
            pressed: pressed,
            capturing: phase == .capturing,
            finalizing: phase == .finalizing
        ) {
        case .begin:
            pressToTalkBegin()
            // Remember the mode only if a talk actually started, and that this press started it.
            if phase == .capturing { activeSessionMode = sessionMode; keyBeganSession = sessionID }
        case .finish:
            if speedOfSoundEnabled && audio.isRecording { finishAtSpeedOfSound() }
            else { pressToTalkEnd() }
        case .ignore:
            // The last talk is still finishing: remember the press instead of dropping it (build 81).
            if phase == .finalizing { deferTalkKeyEdge(pressed: pressed) }
        }
    }

    // Presses while the last talk finishes — remembered, then acted on once it lands (build 81)

    /// Remembers, or takes back, a talk-key edge that arrived while the last talk was finishing.
    func deferTalkKeyEdge(pressed: Bool) {
        let mode = rightOptionMode
        // Locked, asleep or switched out: nothing is remembered to start later (build 81 review).
        guard backgroundConsent.suspensions.isEmpty else {
            if pressed { Diagnostics.event("talk_press_dropped reason=locked") }
            return
        }
        guard deferredTalkPress.note(pressed: pressed, mode: mode, at: DeferredTalkPress.now()) else { return }
        Diagnostics.event(deferredTalkPress.isArmed
            ? "talk_press_deferred reason=finalizing mode=\(mode.rawValue)"
            : "talk_press_deferred_cancelled reason=\(pressed ? "second_tap" : "released")")
    }

    /// The talk key used as a modifier (Option+Arrow): a remembered press was never a talk either.
    func handleTalkKeyChord() {
        if deferredTalkPress.isArmed {
            deferredTalkPress.cancel()
            Diagnostics.event("talk_press_deferred_cancelled reason=chord")
        }
        discardChordedTalk()
    }

    /*
    phase's didSet calls this when the last talk leaves finalizing. It waits one main-loop turn
    so the delivery code that changed the phase finishes first (that code still releases the
    Return gate for its own talk), then starts the remembered talk through pressToTalkBegin,
    the same path a fresh press takes.
    */
    func lastTalkLeftFinalizing() {
        guard deferredTalkPress.isArmed else { return }
        DispatchQueue.main.async { [weak self] in self?.resumeDeferredTalkPress() }
    }

    func resumeDeferredTalkPress() {
        /*
        Delivery can still land after the Mac locks, sleeps or switches user: its target was
        captured at Stop. The remembered press must not start a talk then (build 81 review);
        it would record the room behind the lock screen with nothing to end it.
        */
        let landing = DeferredTalkPress.landing(
            phase: phase,
            keptInApp: retainedFailureText == Self.keptInAppMessage,
            suspended: !backgroundConsent.suspensions.isEmpty)
        let mode    = deferredTalkPress.mode ?? rightOptionMode
        // The hardware state: the talk key's own events are swallowed by the tap.
        let keyDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcutKeyCode))
        switch deferredTalkPress.take(now: DeferredTalkPress.now(), landing: landing, keyDown: keyDown) {
        case .none:
            return
        case .dropped(let reason):
            Diagnostics.event("talk_press_dropped reason=\(reason)")
        case .begin:
            pressToTalkBegin()
            // As in routeRightOption: this press began the talk, in this mode.
            if phase == .capturing { activeSessionMode = mode; keyBeganSession = sessionID }
            Diagnostics.event("talk_press_resumed mode=\(mode.rawValue) session=\(sessionID?.uuidString ?? "none")")
        }
    }

}

