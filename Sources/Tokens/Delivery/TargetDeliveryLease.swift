


//
import AppKit
import ApplicationServices
import Darwin


extension TargetDelivery {


    // Return and activation — submit after delivery; bring a pointer target's app forward


    /*
    Sends one Return to the target app, only while that app, window and field are still
    in front. Posted straight to the app's process and tagged 0x54545452 ("TTTR") so
    GlobalKeyMonitor lets it through instead of holding it back as the user's Return.
    */
    static func sendReturn(to target: CapturedTarget) -> Bool {
        /*
        Every check before Return shares one step budget: an app that stops answering here gets
        no Return, after at most one second of waiting in all (build 81).
        */
        AXWaitBudget.within(AXWaitBudget.forStep()) { budget in
            let sent = sendReturnChecked(to: target)
            if !sent, budget.stopped { Diagnostics.event("return_target_busy \(budget.summary)") }
            return sent
        }
    }

    private static func sendReturnChecked(to target: CapturedTarget) -> Bool {
        if stagedSubmissionPID == target.pid {
            guard let final = stagedSubmissionTarget else { return false }
            stagedSubmissionTarget = nil // one attempt, including a focus/caret failure
            guard exactWindow(final), exactFocus(final), exactSelection(final), exactValue(final),
                  !isSecure(final.element) else { return false }
        }
        /*
        Match the narrowly scoped opaque Codex lease used by insertion.
        Never activate or recapture another destination to submit.
        */
        let opaqueCodex = target.application.bundleIdentifier == "com.openai.codex"
            && target.element == nil && target.window != nil
            && target.pointerPosition == nil && (target.windowCount ?? 0) > 0
            && windowCount(in: applicationElement(target.pid)) == target.windowCount
        guard accessibilityTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              !isSecure(target.element), exactWindow(target), (exactFocus(target) || opaqueCodex),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else { return false }
        down.flags = []
        up.flags   = []
        down.setIntegerValueField(.eventSourceUserData, value: 0x54545452)
        up.setIntegerValueField(.eventSourceUserData, value: 0x54545452)
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return true
    }

    /*
    Unhides and activates the app, then waits up to 0.35 s, turning the run loop in 10 ms
    steps, for it to become the front app. Returns whether it did.
    */
    static func activate(_ target: CapturedTarget) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { return true }
        target.application.unhide()
        _            = target.application.activate(options: [])
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid,
              ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }


    // Lease checks — is the same app, window, field, caret and text still there?


    /*
    The checks build on each other: selection needs focus, focus needs window, window needs
    the target app in front. exactValue only compares the text. If no window was captured,
    the front app alone passes the window check; with no field captured, focus fails.
    Terminals always pass the selection and value checks.
    */
    static func exactWindow(_ target: CapturedTarget) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        guard let expected = target.window else { return true }
        let app = applicationElement(target.pid)
        guard let current = focusedWindow(in: app) else { return false }
        return CFEqual(current, expected)
    }

//
// :)
//
//
    static func exactFocus(_ target: CapturedTarget) -> Bool {
        guard exactWindow(target), let expected = target.element else { return false }
        let app = applicationElement(target.pid)
        guard let current = focusedElement(in: app) else { return false }
        return CFEqual(current, expected)
    }

    static func isTerminal(_ target: CapturedTarget) -> Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
            .contains(target.application.bundleIdentifier ?? "")
    }

    static func exactSelection(_ target: CapturedTarget) -> Bool {
        guard exactFocus(target), let element = target.element else { return false }
        // Terminal AX ranges describe scrollback selection, not the shell's input cursor.
        if isTerminal(target) { return true }
        /*
        Terminal emulators expose a focused input surface but often no AX range.
        Keep the captured window and focus checks, and never send Return.
        */
        if target.selection == nil {
            /*
            Some native/web editors identify their focused text control but
            do not expose a selection range. Missing evidence is not a change.
            Keep exact application/window/element and available value checks.
            */
            let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? ""
            return ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || caretTrusted(role: role)
        }
        guard let expected = target.selection, let current = selectedRange(in: element) else { return false }
        return current.location == expected.location && current.length == expected.length
    }

    /*
    Caret trust (build 85; UX review: "it should always paste where the cursor is ... I don't want
    it to be pasting in random places"). A browser page or group still reported as focused after
    the caret search (TargetDelivery.caretTextBox) names no box Tokens can read, but Command-V
    goes to the macOS keyboard focus, which is the blinking cursor. With the same app, window
    and element as at Stop (every other check unchanged, secure fields still refused), it is
    pasted once. Such a paste can never be confirmed, so it never sends Return and the words
    stay ready to Copy.
    */
    static func caretTrusted(role: String) -> Bool {
        DestinationFocus.containerRoles.contains(role)
    }

    static func exactValue(_ target: CapturedTarget) -> Bool {
        // New process output must not invalidate a paste to the same terminal input.
        if isTerminal(target) { return true }
        guard let before = target.valueBefore else { return true }
        guard let element = target.element, let current = value(in: element) else { return false }
        return before == current
    }


}

