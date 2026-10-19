


//
import AppKit
import ApplicationServices
import Darwin


// TargetDelivery — capture the target, check it, paste the words, and send Return


enum TargetDelivery {


    // Capture — read the target app's window, text field, caret and text


    // A staged submission is allowed once, against the exact acknowledged final editor state.
    static var stagedSubmissionPID: pid_t?
    static var stagedSubmissionTarget: CapturedTarget?

    /*
    Accessibility permission is what lets Tokens read and change other apps' text fields.
    prompt: true asks macOS to show its permission dialog when it is missing.
    */
    static func accessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /*
    No target for this app itself, a quit app, or a password field. Everything else is
    recorded as found, with nil for whatever the app does not expose. Every read shares one
    capture budget (AXWaitBudget.forCapture): an app that stops answering partway through, not
    only at the first read, ends the capture at once and the words are held (build 81).
    */
    static func capture(application: NSRunningApplication) -> CapturedTarget? {
        guard accessibilityTrusted(),
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else { return nil }
        let pid = application.processIdentifier
        let appElement = applicationElement(pid)
        return AXWaitBudget.within(AXWaitBudget.forCapture()) { budget in
            let reads = CaptureReads<AXUIElement>(
                focused: { focusedElementRead(in: appElement) },
                focusedWindow: { focusedWindow(in: appElement) },
                evidence: { element in
                    FocusedEditorWarmup.Evidence(
                        role: stringAttribute(kAXRoleAttribute as String, from: element),
                        subrole: stringAttribute(kAXSubroleAttribute as String, from: element),
                        hasSelection: selectedRange(in: element) != nil)
                },
                enable: { enableManualAccessibility(appElement) },
                frontmost: {
                    !application.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                },
                same: { CFEqual($0, $1) },
                secure: { isSecure($0) },
                editor: { editorValueSnapshot(in: $0) },
                screenFrame: { screenFrame(for: $0) },
                selection: { selectedRange(in: $0) },
                windowCount: { windowCount(in: appElement) },
                wait: { usleep(25_000) })
            guard let reading = readCapture(budget: budget, bundle: application.bundleIdentifier ?? "unknown", reads) else {
                return nil
            }
            return CapturedTarget(
                id: UUID(),
                application: application,
                pid: pid,
                element: reading.element,
                window: reading.window,
                screenFrame: reading.screenFrame,
                selection: reading.selection,
                valueBefore: reading.editor?.text,
                windowCount: reading.windowCount,
                richComposer: reading.editor?.richComposer ?? false
            )
        }
    }

    /*
    The Accessibility reads one capture makes, as closures. Production passes real reads that
    all charge the capture's AXWaitBudget; tests stand in for an app that answers and then
    stalls, without a real app.
    */
    struct CaptureReads<Element> {
        var focused: () -> (element: Element?, unresponsive: Bool)
        var focusedWindow: () -> Element?
        var evidence: (Element) -> FocusedEditorWarmup.Evidence
        var enable: () -> Bool
        var frontmost: () -> Bool
        var same: (Element, Element) -> Bool
        var secure: (Element) -> Bool
        var editor: (Element) -> EditorValueSnapshot?
        var screenFrame: (Element) -> NSRect?
        var selection: (Element) -> CFRange?
        var windowCount: () -> Int?
        var wait: () -> Void
    }

    struct CaptureReading<Element> {
        var element: Element?
        var window: Element?
        var screenFrame: NSRect?
        var selection: CFRange?
        var editor: EditorValueSnapshot?
        var windowCount: Int?
    }

    /*
    The capture, in order, stopping as soon as the budget stops: after the first focus read,
    the first window read, the warmup (whose "still current" check also stops), the secure
    check, the text snapshot and the closing reads. A capture that ran out of time is held
    rather than half-read, and a capture this slow is past the stop key's 0.5 s anyway.
    */
    static func readCapture<Element>(budget: AXWaitBudget, bundle: String,
                                     _ reads: CaptureReads<Element>) -> CaptureReading<Element>? {
        func held() -> CaptureReading<Element>? {
            Diagnostics.event("capture_target_busy bundle=\(bundle) \(budget.summary)")
            return nil
        }
        let initialRead = reads.focused()
        guard !initialRead.unresponsive, !budget.stopped else { return held() }
        let initialWindow = reads.focusedWindow()
        guard !budget.stopped else { return held() }
        /*
        Electron and Chromium apps (Cursor, VS Code, Slack, Claude) keep their accessibility tree
        off until an assistive client asks for it, so focus may be nil or a page container and the
        paste would be refused as "original_editor_changed". Asking once, then re-reading over a
        few short turns, is the documented way to switch the tree on. Native apps ignore the ask.
        */
        let resolution = FocusedEditorWarmup.resolve(initial: initialRead.element, evidence: reads.evidence,
                                                      enable: reads.enable, stillCurrent: {
            guard !budget.stopped, reads.frontmost() else { return false }
            guard let initialWindow else { return true }
            guard let current = reads.focusedWindow() else { return false }
            return reads.same(initialWindow, current)
        }, read: { reads.focused().element }, wait: reads.wait)
        if resolution.enabled {
            Diagnostics.event("capture_target_manual_accessibility bundle=\(bundle) element=\(resolution.element != nil) attempts=\(resolution.attempts) valid=\(resolution.valid)")
        }
        guard !budget.stopped else { return held() }
        guard resolution.valid else { return nil }
        let element = resolution.element
        let secure = element.map(reads.secure) ?? false
        guard !budget.stopped else { return held() }
        guard !secure else { return nil }
        let editor = element.flatMap(reads.editor)
        guard !budget.stopped else { return held() }
        if let editor {
            Diagnostics.event("capture_editor_shape raw_utf16=\(editor.raw.utf16.count) declared_characters=\(editor.characterCount ?? -1) placeholder_matches=\(editor.raw == editor.placeholder) placeholder_plus_lf=\(editor.placeholder.map { editor.raw == $0 + "\n" } ?? false) rich=\(editor.richComposer) empty_placeholder=\(editor.isEmptyPlaceholder)")
        }
        let window = reads.focusedWindow()
        let screenFrame = window.flatMap(reads.screenFrame)
        let selection = element.flatMap(reads.selection)
        let windowCount = reads.windowCount()
        guard !budget.stopped else { return held() }
        return CaptureReading(element: element, window: window, screenFrame: screenFrame,
                              selection: selection, editor: editor, windowCount: windowCount)
    }

    /// Asks an Electron/Chromium app to build its accessibility tree. True when the app accepted the ask.
    static func enableManualAccessibility(_ app: AXUIElement) -> Bool {
        ask(app, { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }) == .success
    }

    /*
    A field counts as secure when it says so, and also when it could not be asked because the
    capture's or delivery's budget has stopped: an unanswered question is never proof of an
    ordinary field, and every caller refuses a secure one (build 81).
    */
    static func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return stringAttribute(kAXSubroleAttribute as String, from: element) == "AXSecureTextField"
            || stringAttribute(kAXRoleAttribute as String, from: element) == "AXSecureTextField"
            || AXWaitBudget.current?.stopped == true
    }

    /// Read-only target resolution in Quartz global screen coordinates. The
    /// selection/click is deferred until delivery and revalidated against this hit.
    /// The hit test and every read after it share one capture budget (build 81).
    static func captureAtPointer() -> CapturedTarget? {
        guard accessibilityTrusted(), let point = CGEvent(source: nil)?.location else { return nil }
        return AXWaitBudget.within(AXWaitBudget.forCapture()) { budget in
            guard let element = editableElement(at: point) else { return nil }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: pid),
                  !application.isTerminated,
                  let before = value(in: element),
                  let window = copyElement(kAXWindowAttribute as String, from: element) else { return nil }
            let caretRange = range(at: point, in: element).map { CFRange(location: $0.location, length: 0) }
            let target = CapturedTarget(
                id: UUID(), application: application, pid: pid, element: element,
                window: window, screenFrame: screenFrame(for: window),
                selection: selectedRange(in: element), valueBefore: before,
                pointerPosition: point, pointerRange: caretRange
            )
            guard !budget.stopped else {
                Diagnostics.event("capture_pointer_busy bundle=\(application.bundleIdentifier ?? "unknown") \(budget.summary)")
                return nil
            }
            return target
        }
    }

//
// :)
//
//
    // Pointer targets — the text field under the mouse, and placing the caret there


    /*
    The editable text field at a screen point, or nil. Buttons and links end the search,
    and so does reaching the window or the app; the search climbs at most 12 parents.
    */
    private static func editableElement(at point: CGPoint) -> AXUIElement? {
        /*
        The hit test goes through the system-wide reference (askSystemWide), and the element it
        hits is a fresh reference: it is bounded before its first read, like every climbed parent
       .
        */
        var hit: AXUIElement?
        guard askSystemWide({ AXUIElementCopyElementAtPosition($0, Float(point.x), Float(point.y), &hit) }) == .success,
              var candidate = boundedElement(hit) else { return nil }
        /*
        Accessibility hit tests may return an inline text child. Climb only
        to its text control, never fall back to the app's unrelated focus.
        */
        for _ in 0..<12 {
            // A stopped budget answers nothing; stop climbing rather than read twelve unanswered parents.
            if AXWaitBudget.current?.stopped == true { return nil }
            let role = stringAttribute(kAXRoleAttribute as String, from: candidate) ?? ""
            if role == kAXButtonRole as String || role == "AXLink" { return nil }
            if PointerTargetPolicy.allows(
                role: role,
                subrole: stringAttribute(kAXSubroleAttribute as String, from: candidate),
                enabled: boolAttribute(kAXEnabledAttribute as String, from: candidate) ?? true,
                selectionAvailable: selectedRange(in: candidate) != nil,
                valueSettable: isSettable(kAXValueAttribute as String, on: candidate),
                selectedTextSettable: isSettable(kAXSelectedTextAttribute as String, on: candidate),
                explicitlyEditable: boolAttribute("AXEditable", from: candidate)
            ) { return candidate }
            if role == kAXWindowRole as String || role == kAXApplicationRole as String { return nil }
            guard let parent = copyElement(kAXParentAttribute as String, from: candidate),
                  !CFEqual(parent, candidate) else { return nil }
            candidate = parent
        }
        return nil
    }

    // The character position under a screen point, asked of the field through Accessibility.
    private static func range(at point: CGPoint, in element: AXUIElement) -> CFRange? {
        var position = point
        guard let parameter = AXValueCreate(.cgPoint, &position) else { return nil }
        var raw: CFTypeRef?
        guard ask(element, { AXUIElementCopyParameterizedAttributeValue(
            element, kAXRangeForPositionParameterizedAttribute as CFString, parameter, &raw
        ) }) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        /*
        TextEdit can report range zero for blank space below the document.
        Trust a positional range only when its glyph/caret bounds are near
        the pointer; otherwise let the editor place its caret with a click.
        */
        var candidate = range
        guard let rangeParameter = AXValueCreate(.cfRange, &candidate) else { return nil }
        var rawBounds: CFTypeRef?
        guard ask(element, { AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeParameter, &rawBounds
        ) }) == .success, let rawBounds, CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(rawBounds, to: AXValue.self), .cgRect, &bounds),
              !bounds.isNull, !bounds.isInfinite, bounds.height > 0,
              bounds.insetBy(dx: -3, dy: -2).contains(point) else { return nil }
        return range
    }

    private static func activatePointerTarget(_ target: CapturedTarget) -> Bool {
        // Raise the pointed window, not every window of its application.
        if let window = target.window {
            _ = ask(window, { AXUIElementPerformAction(window, kAXRaiseAction as CFString) })
        }
        return activate(target)
    }

//
// :)
//
//
    /*
    Before delivery, the same field must still be under the pointer, with the same text,
    both before and after its app is brought to the front (raising a window can change
    what is under the pointer). Returns the target with its caret set, or nil.
    */
    static func preparePointerTarget(_ captured: CapturedTarget) -> CapturedTarget? {
        guard let point = captured.pointerPosition, let expected = captured.element,
              let hit = editableElement(at: point), CFEqual(hit, expected),
              exactValue(captured), activatePointerTarget(captured),
              let activeHit = editableElement(at: point), CFEqual(activeHit, expected) else { return nil }
        /*
        Prefer an AX caret assignment: no synthetic click is needed when the
        editor provides a character range for this exact screen position.
        */
        if var selection = captured.pointerRange,
           isSettable(kAXSelectedTextRangeAttribute as String, on: expected),
           let selectionValue = AXValueCreate(.cfRange, &selection) {
            _ = ask(expected, { AXUIElementSetAttributeValue(expected, kAXFocusedAttribute as CFString, kCFBooleanTrue) })
            if exactFocus(captured),
               ask(expected, {
                   AXUIElementSetAttributeValue(expected, kAXSelectedTextRangeAttribute as CFString, selectionValue)
               }) == .success {
                var target       = captured
                target.selection = selection
                guard exactSelection(target), exactValue(target) else { return nil }
                return target
            }
        }
        /*
        Some editors omit RangeForPosition. Click only a revalidated editable
        text hit, then require the same element/window and a readable caret.
        */
        guard let finalHit = editableElement(at: point), CFEqual(finalHit, expected),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        /*
        Delivery is already session-claimed by the model. Never retry a paste.
        The short wait lets the external editor process the single caret click.
        */
        usleep(80_000)
        guard exactFocus(captured), exactValue(captured),
              let selection = selectedRange(in: expected), selection.length == 0 else { return nil }
        var target       = captured
        target.selection = selection
        return target
    }


    // Attribute helpers and direct insertion — Accessibility text writes (TextEdit only)


    private static func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return ask(element, { AXUIElementIsAttributeSettable(element, name as CFString, &settable) }) == .success
            && settable.boolValue
    }

    static func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard ask(element, { AXUIElementCopyAttributeValue(element, name as CFString, &raw) }) == .success else { return nil }
        return raw as? String
    }

    /// The whole wait the paste-target diagnostic may use: its own, never the delivery's.
    static let pasteTargetStateBudget: TimeInterval = 0.15

    /*
    Diagnostics only (never decides anything): the keyboard state of the paste target, no text.
    Its questions run under a small budget of their own, so a slow answer can neither spend nor
    stop the delivery's shared budget (a stopped budget would leave the readback unable to
    confirm a good paste). The system-wide focus fallback needs more than this budget, so it is
    skipped and an unanswered field reads "-".
    */
    static func pasteTargetState(_ target: CapturedTarget) -> String {
        func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "-" }
        let active = NSRunningApplication(processIdentifier: target.pid)?.isActive
        let own = AXWaitBudget(total: pasteTargetStateBudget, perRequest: 0.05)
        return AXWaitBudget.$current.withValue(own) {
            let window = target.window
            let main = window.flatMap { boolAttribute(kAXMainAttribute as String, from: $0) }
            let windowFocused = window.flatMap { boolAttribute(kAXFocusedAttribute as String, from: $0) }
            let fieldFocused = target.element.flatMap { boolAttribute(kAXFocusedAttribute as String, from: $0) }
            // exactFocus is also false when it could not ask: a stopped budget means unknown, not moved.
            let focusSame: Bool? = exactFocus(target) ? true : (own.stopped ? nil : false)
            return "app_active=\(flag(active)) window_main=\(flag(main)) window_focused=\(flag(windowFocused)) field_focused=\(flag(fieldFocused)) focus_same=\(flag(focusSame)) \(own.summary)"
        }
    }

    private static func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard ask(element, { AXUIElementCopyAttributeValue(element, name as CFString, &raw) }) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    // Test builds only: a hook that runs between writing the clipboard and posting Command-V.
    #if TTT_DELIVERY_TESTING

//
// :)
//
//
    static var beforePasteTestBarrier: (() -> Void)?
    #endif

    /// Streaming is restricted to fully observable, writable native text controls.
    /// Opaque web composers and terminals retain the existing single-paste path.
    static func supportsStagedInsertion(_ target: CapturedTarget) -> Bool {
        // One step budget for these checks, unless a delivery's budget is already in force (build 81).
        AXWaitBudget.within(AXWaitBudget.forStep()) { _ in
            guard StagedPrompt.allowsDirectInsertion(bundleIdentifier: target.application.bundleIdentifier),
                  target.pointerPosition == nil, !isTerminal(target),
                  let element = target.element, target.valueBefore != nil,
                  let range = target.selection, range.location >= 0, range.length >= 0,
                  !isSecure(element),
                  isSettable(kAXSelectedTextAttribute as String, on: element) else { return false }
            return accessibilityTrusted() && exactWindow(target) && exactFocus(target)
                && exactSelection(target) && exactValue(target)
        }
    }

    /*
    Writes text at the caret by setting the field's selected text, then reads the field
    back: it must equal the old text with this piece spliced in, and the caret must sit
    right after it. On success returns the target updated to that new text and caret.
    */
    /// A failure may follow a write: callers must retain, never retry or submit.
    static func appendVerified(_ text: String, to target: CapturedTarget) -> CapturedTarget? {
        // The checks, the write and the readback share one step budget (build 81).
        AXWaitBudget.within(AXWaitBudget.forStep()) { _ in
            guard supportsStagedInsertion(target), let element = target.element,
                  let before = target.valueBefore, let range = target.selection,
                  range.location + range.length <= (before as NSString).length else { return nil }
            let expected = (before as NSString).replacingCharacters(
                in: NSRange(location: range.location, length: range.length), with: text)
            guard ask(element, {
                      AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                  }) == .success,
                  exactWindow(target), exactFocus(target), value(in: element) == expected,
                  let caret = selectedRange(in: element), caret.length == 0,
                  caret.location == range.location + (text as NSString).length else { return nil }
            var next         = target
            next.valueBefore = expected
            next.selection   = caret
            return next
        }
    }


}

