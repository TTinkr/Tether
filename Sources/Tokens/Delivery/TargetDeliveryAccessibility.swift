


//
import AppKit
import ApplicationServices
import Darwin


extension TargetDelivery {


    // Low-level helpers — Accessibility lookups, the Command-V keystroke, and leading space


    /*
    How long one Accessibility request to the destination may wait for an answer. Delivery runs
    on the main thread, next to the global key tap, and macOS otherwise waits about 6 s for an app
    that does not answer, several times per stop: Tokens froze and everyone's typing stalled
    while a stuck app caught up. A healthy app answers in milliseconds, a big composer in tens;
    one second leaves plenty of room. The stop-key capture is thrown away after 0.5 s anyway
    (GlobalKeyMonitor.deliveryEdgeIsCurrent), so a slower answer could never be used. Inside a
    capture or delivery the wait is also cut to what is left of its AXWaitBudget (build 81).
    */
    static let messagingTimeout: Float = 1.0

    /// The destination app's Accessibility element, with the bounded wait above.
    static func applicationElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    /*
    True only when a request failed because the app did not answer in time: the error macOS
    gives for a timeout, after waiting (nearly) the whole wait it was given. A quick "cannot
    complete" from an app that simply lacks the attribute is not a stuck app.
    */
    static func requestTimedOut(_ error: AXError, elapsed: TimeInterval,
                                bound: TimeInterval = Double(messagingTimeout)) -> Bool {
        error == .cannotComplete && elapsed >= bound * 0.9
    }

    /*
    Every Accessibility question delivery asks another app goes through here. Inside a capture
    or delivery (AXWaitBudget.current) it waits at most the smaller of one second and what is
    left of that budget, and once the budget has stopped it is not asked at all: it fails as if
    the app had not answered, which every caller already treats as "not the same target". The
    reference goes back to the one-second bound afterwards. Outside a budget (the destination
    preview, the screen sampler) the reference's own wait applies, as before (build 81).
    Never pass the system-wide reference here: its timeout is Tokens' process-wide default.
    */
    static func ask(_ owner: AXUIElement, _ request: () -> AXError) -> AXError {
        guard let budget = AXWaitBudget.current else { return request() }
        return budget.ask { wait in
            AXUIElementSetMessagingTimeout(owner, wait)
            defer { AXUIElementSetMessagingTimeout(owner, messagingTimeout) }
            return request()
        }
    }

    /*
    The two system-wide questions, through a fresh system-wide reference. Its wait cannot be set
    on its own: the system-wide reference carries Tokens' process-wide default, so that default
    is set (again, harmlessly) to AXWaitBudget.systemWideWait first, and inside a budget the
    question is asked only while that whole wait still fits. This changes how long Tokens itself
    waits on any reference without a wait of its own; it never changes another app (build 81).
    */
    static func askSystemWide(_ request: (AXUIElement) -> AXError) -> AXError {
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, Float(AXWaitBudget.systemWideWait)) == .success else {
            return .cannotComplete
        }
        guard let budget = AXWaitBudget.current else { return request(system) }
        return budget.askWhole(AXWaitBudget.systemWideWait) { request(system) }
    }

    /*
    Three tries: the app's focused element, then its focused window's focused element,
    then the system-wide focused element, kept only if it belongs to this same app.
    */
    static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        focusedElementRead(in: app).element
    }

    /*
    The same three tries, plus whether the app stopped answering. All three share one budget
    (the capture's or delivery's, or one of their own), so a timeout on any of them, not only
    the first, ends the lookup, and the system-wide try never runs on a stuck app (build 81).
    */
    static func focusedElementRead(in app: AXUIElement) -> (element: AXUIElement?, unresponsive: Bool) {
        AXWaitBudget.within(AXWaitBudget.forStep()) { budget in
            focusedElementLookup(budget: budget,
                appFocus: { copyElement(kAXFocusedUIElementAttribute as String, from: app) },
                focusedWindow: { focusedWindow(in: app) },
                windowFocus: { copyElement(kAXFocusedUIElementAttribute as String, from: $0) },
                systemFocus: {
                    var raw: CFTypeRef?
                    guard askSystemWide({ AXUIElementCopyAttributeValue($0, kAXFocusedUIElementAttribute as CFString, &raw) })
                            == .success else { return nil }
                    return boundedElement(raw)
                },
                sameApplication: { element in
                    var expected: pid_t = 0
                    var actual: pid_t   = 0
                    return AXUIElementGetPid(app, &expected) == .success
                        && AXUIElementGetPid(element, &actual) == .success && expected == actual
                },
                inner: { caretTextBox(inside: $0) })
        }
    }

    /*
    The order of the three tries, with every request already charged to `budget` by its caller
    (production goes through ask/askSystemWide; tests stand in for an app). After each try a
    stopped budget ends the lookup: "unresponsive" then means the app ran out of time or the
    budget ran out, and nothing more is asked of it (build 81).
    */
    static func focusedElementLookup<Element>(
        budget: AXWaitBudget,
        appFocus: () -> Element?,
        focusedWindow: () -> Element?,
        windowFocus: (Element) -> Element?,
        systemFocus: () -> Element?,
        sameApplication: (Element) -> Bool,
        inner: (Element) -> Element? = { _ in nil }
    ) -> (element: Element?, unresponsive: Bool) {
        /*
        A page or group reported as focused gives way to the text box that holds its caret
        (build 84: on a Sonoma Mac, Chrome reported YouTube's page, not its focused search box,
        until a click; the paste was refused and the words held). The same answer serves the
        capture and every later "same field?" check, so they always agree.
        */
        func settled(_ element: Element) -> (element: Element?, unresponsive: Bool) {
            guard !budget.stopped else { return (element, true) }
            return (inner(element) ?? element, budget.stopped)
        }
        if let element = appFocus() { return settled(element) }
        guard !budget.stopped else { return (nil, true) }
        if let window = focusedWindow() {
            guard !budget.stopped else { return (nil, true) }
            if let element = windowFocus(window) { return settled(element) }
        }
        guard !budget.stopped else { return (nil, true) }
        guard let element = systemFocus(), sameApplication(element) else { return (nil, budget.stopped) }
        return settled(element)
    }

    /*
    The text box holding the caret inside a focused web page or group, or nil when the element
    is not such a container or none is found. First the browser's own answer (the element at the
    start of AXSelectedTextMarkerRange, walked up to its text box: exact, a few reads); then a
    bounded breadth-first search for a focused text box. Only roles and focus flags are read.
    */
    static func caretTextBox(inside container: AXUIElement) -> AXUIElement? {
        guard DestinationFocus.containerRoles.contains(stringAttribute(kAXRoleAttribute as String, from: container) ?? "") else {
            return nil
        }
        /*
        One paste asks "same field?" several times. A box found in the last second is reused only
        while it still reports focus itself (Codex review of 85: a memo keyed by the page alone
        could answer A after focus moved to B). "None found" is never remembered, so a box that
        appears later is seen at once.
        */
        let now = ProcessInfo.processInfo.systemUptime
        if let memo = caretMemo, CFEqual(memo.container, container), now - memo.at < 1.0,
           DeliveryFocusNode(memo.box).focused { return memo.box }
        let box = textBoxAtSelectionMarker(in: container)
            ?? DestinationFocus.resolve(DeliveryFocusNode(container), limit: DeliveryFocusNode.searchLimit)?.element
        caretMemo = nil
        if let box, AXWaitBudget.current?.stopped != true { caretMemo = (container, box, now) }
        return box
    }

    nonisolated(unsafe) private static var caretMemo: (container: AXUIElement, box: AXUIElement, at: TimeInterval)?

    private static func textBoxAtSelectionMarker(in container: AXUIElement) -> AXUIElement? {
        var range: CFTypeRef?
        guard ask(container, { AXUIElementCopyAttributeValue(container, "AXSelectedTextMarkerRange" as CFString, &range) }) == .success,
              let range else { return nil }
        var start: CFTypeRef?
        guard ask(container, { AXUIElementCopyParameterizedAttributeValue(container,
                  "AXStartTextMarkerForTextMarkerRange" as CFString, range, &start) }) == .success,
              let start else { return nil }
        var found: CFTypeRef?
        guard ask(container, { AXUIElementCopyParameterizedAttributeValue(container,
                  "AXUIElementForTextMarker" as CFString, start, &found) }) == .success,
              var node = boundedElement(found) else { return nil }
        // Up from the caret's text run to the box that owns it (a few levels at most).
        for _ in 0..<12 {
            let role = stringAttribute(kAXRoleAttribute as String, from: node)
            if DestinationFocus.textRoles.contains(role ?? "") { return node }
            if CFEqual(node, container) { return nil }
            guard let parent = copyElement(kAXParentAttribute as String, from: node) else { return nil }
            node = parent
        }
        return nil
    }

    static func windowCount(in app: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard ask(app, { AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) }) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.count
    }

    static func focusedWindow(in app: AXUIElement) -> AXUIElement? {
        copyElement(kAXFocusedWindowAttribute as String, from: app)
    }

    /*
    Accessibility gives window positions measured down from the top of the main screen;
    AppKit screens measure up from the bottom. The window's centre is flipped into AppKit
    terms, and the visible frame of whichever screen contains it is returned.
    */
    static func screenFrame(for window: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard ask(window, { AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) }) == .success,
              ask(window, { AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) }) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size     = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              let main = NSScreen.screens.first else { return nil }
        let cocoaCenter = NSPoint(
            x: position.x + size.width / 2,
            y: main.frame.maxY - position.y - size.height / 2
        )
        return NSScreen.screens.first(where: { NSMouseInRect(cocoaCenter, $0.frame, false) })?.visibleFrame
    }

    static func copyElement(_ attribute: String, from owner: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard ask(owner, { AXUIElementCopyAttributeValue(owner, attribute as CFString, &value) }) == .success else { return nil }
        return boundedElement(value)
    }

    /*
    Every element read here is a fresh reference, and a fresh reference waits Tokens' default,
    not its app's bound. Bound it before anyone asks it anything: the window, the field and its
    text are read again and again while the words are pasted (build 81).
    */
    static func boundedElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func selectedRange(in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard ask(element, {
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        }) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

//
// :)
//
//
    static func value(in element: AXUIElement) -> String? {
        editorValueSnapshot(in: element)?.text
    }

    /// Read related attributes in one AX request to reduce inconsistencies between
    /// separate reads. AX does not promise an atomic snapshot; unknown attributes stay unknown.
    static func editorValueSnapshot(in element: AXUIElement) -> EditorValueSnapshot? {
        let attributes = [kAXValueAttribute, kAXPlaceholderValueAttribute,
                          kAXNumberOfCharactersAttribute, kAXSelectedTextRangeAttribute,
                          kAXRoleAttribute] as CFArray
        var result: CFArray?
        guard ask(element, { AXUIElementCopyMultipleAttributeValues(element, attributes, [], &result) }) == .success,
              let values = result as? [Any], values.count == 5 else {
            // The single-value fallback shares the budget: after a timed-out snapshot it is never asked (build 81).
            var raw: CFTypeRef?
            guard ask(element, { AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) }) == .success,
                  let text = raw as? String else { return nil }
            return EditorValueSnapshot(raw: text)
        }
        guard let raw = values[0] as? String else { return nil }
        let count = EditorValueSnapshot.declaredCharacterCount(values[2])
        var selection: NSRange?
        let rangeValue = values[3] as CFTypeRef
        if CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range),
               range.location >= 0, range.length >= 0 {
                selection = NSRange(location: range.location, length: range.length)
            }
        }
        let role = values[4] as? String
        return EditorValueSnapshot(raw: raw, placeholder: values[1] as? String,
                                   characterCount: count, selection: selection, role: role,
                                   richComposer: isRichComposer(element, role: role))
    }

    /*
    A web rich-text editor (contenteditable), identified by the element itself: a text area that
    is web content (it carries a DOM class list, even an empty one) and has child nodes for its
    paragraphs. Native text views and plain web <textarea>/<input> fields have no children.
    Measured 2026-10-11 in Chrome: ProseMirror and plain contenteditable have children; textarea
    and input have none.
    */
    static func isRichComposer(_ element: AXUIElement, role: String?) -> Bool {
        guard role == "AXTextArea" else { return false }
        var names: CFArray?
        guard ask(element, { AXUIElementCopyAttributeNames(element, &names) }) == .success,
              let list = names as? [String], list.contains("AXDOMClassList") else { return false }
        var count: CFIndex = 0
        return ask(element, { AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) }) == .success
            && count > 0
    }

    /*
    Key code 0x09 is the V key; with the Command flag this is Command-V, posted straight
    to the target process rather than to whatever app is in front.
    */
    static func postCommandV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        /*
        Diagnostics: a second paste into a browser rich editor can fire
        beforeinput with the full text yet insert nothing, while a manual Command-V works. The line
        records whether the target was frontmost and which route posted; a Dev-only setting posts
        through the HID tap (the keyboard's own path) instead, for an A/B. The public download always
        posts to the process, as before.
        */
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let viaHID = PasteRoute.devPostsThroughHID
        // The HID route types into whatever is in front: never post it when that is not the target.
        if !PasteRoute.mayPost(viaHID: viaHID, frontPID: front, targetPID: pid) {
            Diagnostics.event("paste_command_refused route=hid target_front=false")
            return false
        }
        Diagnostics.event("paste_command_posted route=\(viaHID ? "hid" : "pid") target_front=\(front == pid)")
        if viaHID {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return true
    }

    /*
    Trims the words, then adds one leading space when the caret sits right after a
    non-space character that is not an opening bracket, unless the words start with
    punctuation such as "." or ")". Needs the field's text and caret to decide.
    */
    static func preparedText(_ raw: String, for target: CapturedTarget, preservingTrailingWhitespace: Bool = false,
                             preservingWhitespace: Bool = false) -> String {
        preparedText(raw, valueBefore: target.valueBefore, selection: target.selection,
                     caretSkipsLineBreaks: caretSkipsLineBreaks(target),
                     preservingTrailingWhitespace: preservingTrailingWhitespace,
                     preservingWhitespace: preservingWhitespace)
    }

    /*
    Claude desktop's composer counts its caret without line breaks, the same rule its paste
    readback uses (PasteAcknowledgement.lineBreakSkippingInsertion). Only its rich composer:
    a plain text box in the same app counts the ordinary way.
    */
    static func caretSkipsLineBreaks(_ target: CapturedTarget) -> Bool {
        target.richComposer && target.application.bundleIdentifier == "com.anthropic.claudefordesktop"
    }

    /*
    The exact UTF-16 index in the field's text of a Claude desktop caret, or nil when there is no
    single such index. Claude reports offset c meaning "right after the c-th UTF-16 unit that is
    not a line break" (the same model as PasteAcknowledgement.lineBreakSkippingInsertion). When
    that unit is followed by one or more line breaks, the end of the line and the start of every
    following line all report the same c: "Hi|\n\nthere", "Hi\n|\nthere" and "Hi\n\n|there" all
    read 2. No other evidence tells them apart, so that caret has no exact index. Nor does a
    caret past the text, or a draft holding "\r", which the measured model does not cover.
    Guessing "fresh line" for a blank line below joined
    words when the caret was really at the end of "Hi".

    At such a caret this returns nil; claudeSpacingIndex then decides the leading space from what
    follows the line breaks.
    */
    static func lineBreakSkippingCaretIndex(before: String, caret: Int) -> Int? {
        let units = Array(before.utf16)
        guard caret >= 0, !units.contains(13) else { return nil }
        var index = 0, counted = 0
        while counted < caret {
            guard index < units.count else { return nil }
            if units[index] != 10 { counted += 1 }
            index += 1
        }
        // Followed by a line break: this line's end or a later line's start, indistinguishable.
        // No exact index; claudeSpacingIndex decides from what follows (build 81).
        if index < units.count, units[index] == 10 { return nil }
        return index
    }

    /*
    Where the leading-space check looks, as an exact UTF-16 index into the field's text, or nil
    when unsure. Ordinary editors report that index directly. Claude's rich composer reports a
    line-break-skipping caret (lineBreakSkippingCaretIndex); its selections are outside that
    measured model, so a Claude selection is unsure too (build 81).
    */
    static func spacingIndex(before: String, selection: CFRange, caretSkipsLineBreaks: Bool) -> Int? {
        guard caretSkipsLineBreaks else { return selection.location }
        guard selection.length == 0 else { return nil }
        return claudeSpacingIndex(before: before, caret: selection.location)
    }

    /*
    Claude's caret for the leading-space rule: exact when it
    has one place (lineBreakSkippingCaretIndex). Where it stands before line breaks the place is
    ambiguous, and the two outcomes are chosen by what follows:
    - only line breaks follow (the end of the draft, usually a fresh line after Shift-Return):
      no index, so no space ("Hi\n" + talk → "Hi\nwords");
    - more text follows (a caret inside a multi-line draft): the end of the line, the reading
      builds 78-80 used, so the words never join that line ("Hi|\nthere" → "Hi words\nthere").
      If the caret was really at the start of a later line this adds the space there, as 78 did.
    */
    static func claudeSpacingIndex(before: String, caret: Int) -> Int? {
        if let exact = lineBreakSkippingCaretIndex(before: before, caret: caret) { return exact }
        let units = Array(before.utf16)
        guard caret > 0, !units.contains(13) else { return nil }
        var index = 0, counted = 0
        while counted < caret {
            guard index < units.count else { return nil }
            if units[index] != 10 { counted += 1 }
            index += 1
        }
        // Here index sits on the first of the line breaks after the reported caret.
        return units[index...].contains(where: { $0 != 10 }) ? index : nil
    }

    static func preparedText(_ raw: String, valueBefore: String?, selection: CFRange?, caretSkipsLineBreaks: Bool,
                             preservingTrailingWhitespace: Bool = false, preservingWhitespace: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // An early prefix is an append-only fragment: its newline belongs to the
        // final prompt and must survive both clipboard preparation and readback.
        let trailing = preservingTrailingWhitespace
            ? String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed()) : ""
        // A finalized reveal owns an exact frozen body, including boundary whitespace.
        let clean = preservingWhitespace ? raw : trimmed + trailing
        guard !clean.isEmpty,
              let before = valueBefore,
              let selection,
              selection.location > 0,
              let first = clean.first,
              !first.isWhitespace,
              !".,?!;:%)]}".contains(first) else { return clean }
        let source = before as NSString
        /*
        One UTF-16 index, or no space. Ordinary editors give it directly; Claude's caret goes
        through claudeSpacingIndex, which never joins words to a line inside the draft and never
        puts a space on the fresh line at a draft's end (build 81). An index that splits a
        surrogate pair is not a real caret position.
        */
        guard let location = spacingIndex(before: before, selection: selection,
                                          caretSkipsLineBreaks: caretSkipsLineBreaks),
              location <= source.length,
              location == 0 || !(0xD800...0xDBFF).contains(source.character(at: location - 1)) else { return clean }
        let prefix = source.substring(to: location)
        guard let previous = prefix.last,
              !previous.isWhitespace,
              !"([{".contains(previous) else { return clean }
        return " " + clean
    }


}


/// Dev-only A/B for the Command-V route. Never read in the public download.
enum PasteRoute {
    static let devHIDKey = "TokensDevPasteViaHID.v1"
    static var devPostsThroughHID: Bool {
        DevChannel.isActive && ProofRoutes.isAllowed && UserDefaults.standard.bool(forKey: devHIDKey)
    }
    /*
    Dev-only, off unless QA opts in: the paste-target state line. Its
    reads sit between Command-V and the readback, so they run only on a deliberate diagnostic
    trial; the public download and an ordinary Dev paste never ask them and never wait on them.
    */
    static let devTargetStateKey = "TokensDevPasteTargetState.v1"
    static var devLogsTargetState: Bool {
        logsTargetState(dev: DevChannel.isActive, proofRoutes: ProofRoutes.isAllowed,
                        optedIn: UserDefaults.standard.bool(forKey: devTargetStateKey))
    }
    static func logsTargetState(dev: Bool, proofRoutes: Bool, optedIn: Bool) -> Bool { dev && proofRoutes && optedIn }
    /// Whether a Command-V may be posted: the HID route only to the app in front.
    static func mayPost(viaHID: Bool, frontPID: pid_t?, targetPID: pid_t) -> Bool {
        !viaHID || frontPID == targetPID
    }
}


/// A live AX node for the delivery-side focus search; every read goes through the current
/// AXWaitBudget (TargetDelivery.ask), so a slow page ends the search instead of the talk.
final class DeliveryFocusNode: DestinationFocusNode {
    /// Wider than the marker's 160: a big page (YouTube) keeps its search box past that.
    static let searchLimit = 400
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }

    var role: String? { TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: element) }
    var editable: Bool { flag("AXEditable") }
    var focused: Bool { flag(kAXFocusedAttribute as String) }
    var children: [DeliveryFocusNode] {
        guard AXWaitBudget.current?.stopped != true else { return [] }
        var raw: CFTypeRef?
        guard TargetDelivery.ask(element, { AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) }) == .success,
              let list = raw as? [AXUIElement] else { return [] }
        return list.map(DeliveryFocusNode.init)
    }

    private func flag(_ name: String) -> Bool {
        var raw: CFTypeRef?
        guard TargetDelivery.ask(element, { AXUIElementCopyAttributeValue(element, name as CFString, &raw) }) == .success else { return false }
        return (raw as? NSNumber)?.boolValue ?? false
    }
}
