


//
import AppKit
import ApplicationServices
import Darwin


// ShortcutMonitorStartResult — whether the key listener started, or why not


enum ShortcutMonitorStartResult: Equatable {
    case started
    case accessibilityDenied
    case tapUnavailable
}


// GlobalKeyMonitor — the system-wide key listener; reports talk key edges to the app


/// Historical name retained for source compatibility; monitors a configurable physical key.
final class GlobalKeyMonitor {


    // Wiring and state — callbacks the app sets, and what the tap remembers between events


    /*
    onPress / onRelease fire on the main thread for each talk key edge.
    onFastFinish fires when Return is pressed while the talk key is held ("speed of sound").
    */
    var onToggle: () -> Void     = {}
    var onPress: () -> Void      = {}
    var onRelease: () -> Void    = {}
    var onFastFinish: () -> Void = {}
    /*
    Another key, modifier or click while the press that started a talk is still held: the talk
    key was used as a modifier (Option+Arrow, Option+Delete, Option+letter, Option-click), so
    the app throws that talk away without pasting (build 81).
    */
    var onChord: () -> Void      = {}
    /*
    Return-to-finish works only when the setting is on (Enabled) and the app says a talk
    is recording right now (Ready). Both are asked inside the tap, at the Return key edge.
    */
    var speedOfSoundEnabled: () -> Bool = { SpeedOfSoundPreference.isEnabled() }
    var speedOfSoundReady: () -> Bool   = { false }
    /*
    The app answers "would this edge finish the talk?". When yes, Return is held back from
    this moment, before the main thread has even started finishing.
    */
    var isStopEdge: (Bool) -> Bool = { _ in false }
    /*
    Holds back Return/Enter between the stop edge and verified delivery, so a Return typed
    right after stopping cannot submit or edit the target before the words land.
    hasReservedReturn is true when such a Return was swallowed; the app then sends one
    Return itself after delivery, and calls finishReturnReservation when it is done.
    */
    private var returnGate = DeliveryReturnGate()
    var hasReservedReturn: Bool { returnGate.requested }
    /// Return is being held back right now (between a stop edge and the end of delivery).
    var hasPendingReturnReservation: Bool { returnGate.pending }
    func finishReturnReservation() { returnGate.finish() }
    // System uptime of the key edge that finished the talk; the start of the paste latency.
    private(set) var fastFinishEdgeUptime: TimeInterval?
    var onUnavailable: (String) -> Void = { _ in }
    /// Set only while held words are on screen: ⌘C (8) copies, Escape (53) dismisses.
    /// Any other key press or click releases it, so ⌘C in other work is never taken.
    var onHeldWordsKey: ((Int64) -> Bool)?
    /// The key the held words consumed; its repeats and release are swallowed too.
    private var heldWordsSwallowKey: Int64?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var held            = false
    private var fastFinishChord = FastFinishChord()
    /// The held press began a talk (rather than stopping one); a chord now discards it.
    private var pressStartedTalk = false
    private var chordReported    = false
    /// A press made with another modifier already down (Cmd+Option+Esc): no talk, release ignored.
    private var suppressedPress  = false
    /*
    Bumped by every other key, modifier or click the tap lets through, by Return-to-finish,
    and when the talk key changes. A press/release edge's delivery check compares against
    it, so any other input after the edge means the edge no longer says where words go.
    */
    private var inputGeneration: UInt64 = 0
    /*
    Set only while onPress / onRelease / onFastFinish run on main, then reset to always-true.
    Inside those callbacks it answers: is it under 0.5 s since the key edge, with the same
    front app and window, and (for press/release) no other input since? Code that reads it
    later, after the callback has returned, always gets true.
    */
    var deliveryEdgeIsCurrent: () -> Bool = { true }

//
// :)
//
//
    private var shortcutState             = ShortcutHold()
    private(set) var shortcut             = TalkShortcut.load()
    /*
    While choosing a new talk key: the callback that receives it. recordedRelease is the key
    just pressed, whose repeats and release are swallowed so it neither types into the front
    app nor starts a talk on its release.
    */
    private var shortcutRecording: ((TalkShortcut) -> Void)?
    private var recordedRelease: UInt16?
    var isRecordingShortcut: Bool { shortcutRecording != nil }


    // Choosing the talk key — record the next key pressed, or set one directly


    /// Returns false when a held dictation key or delivery is still active.
    @discardableResult
    func beginShortcutRecording(onRecorded: @escaping (TalkShortcut) -> Void) -> Bool {
        guard !held, !returnGate.pending else { return false }
        /*
        Recording needs the tap running (start may show the Accessibility prompt).
        Edge state is cleared so a half-seen press of the old key cannot fire later.
        */
        start()
        guard eventTap != nil else { return false }
        shortcutState.reset()
        fastFinishChord = FastFinishChord()
        inputGeneration &+= 1
        shortcutRecording = onRecorded
        return true
    }

    func cancelShortcutRecording() { shortcutRecording = nil }

    /*
    Refused while the talk key is down, while delivery is holding Return, for a key code
    above 255, or for a key the sibling app owns. On success the choice is saved.
    */
    @discardableResult
    func setShortcut(_ newShortcut: TalkShortcut) -> Bool {
        guard !held, !returnGate.pending, newShortcut.keyCode <= 255,
              TalkShortcut.siblingReservedKeys()[newShortcut.keyCode] == nil else { return false }
        cancelShortcutRecording()
        shortcut = newShortcut
        shortcut.save()
        shortcutState.reset()
        fastFinishChord = FastFinishChord()
        inputGeneration &+= 1
        return true
    }

    @discardableResult
    func resetShortcut() -> Bool { setShortcut(TalkShortcut.productDefault()) }


    // Life cycle — sleep and wake, and starting and stopping the event tap


    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                /*
                A lost physical key-up must not leave Hold latched after sleep.
                Audio owns cancellation; synthesizing release here could paste.
                */
                self.held            = false
                self.fastFinishChord = FastFinishChord()
                self.returnGate      = DeliveryReturnGate()
                self.pressStartedTalk = false
                self.suppressedPress  = false
                self.shortcutState.reset()
                self.cancelShortcutRecording()
                self.recordedRelease = nil
                // On wake, switch the tap back on in case it was turned off while asleep.
                if name == NSWorkspace.didWakeNotification, let tap = self.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            })
        }
    }

    /*
    The tap holds an unretained pointer to this monitor (see start), so the tap is
    invalidated here, before the monitor goes away.
    */
    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }

//
// :)
//
//
    /*
    Safe to call again: a tap that exists and is on is kept. A tap that is off or invalid
    is torn down and built fresh. Accessibility permission is required; Input Monitoring
    (listen_event) is only logged. promptForAccessibility shows the system dialog.
    */
    @discardableResult
    func start(
        promptForAccessibility: Bool = true,
        reportFailure: Bool = true
    ) -> ShortcutMonitorStartResult {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if CFMachPortIsValid(eventTap), CGEvent.tapIsEnabled(tap: eventTap) {
                return .started
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(eventTap)
            self.runLoopSource = nil
            self.eventTap      = nil
        }
        let accessibility = TargetDelivery.accessibilityTrusted(prompt: promptForAccessibility)
        let listenEvent   = CGPreflightListenEventAccess()
        Diagnostics.event("shortcut_access accessibility=\(accessibility) listen_event=\(listenEvent)")
        guard accessibility else {
            if reportFailure {
                onUnavailable("\(shortcut.displayName) is blocked. Enable \(ProductIdentity.displayName) in Privacy & Security > Accessibility.")
            }
            return .accessibilityDenied
        }
        /*
        A plain C callback cannot capture self, so the monitor travels as userInfo.
        The tap is a session-level, head-of-queue "default" tap: unlike a listen-only tap
        it can swallow an event (return nil) so the front app never sees it. Mouse downs
        are watched so a click drops the held-words keys and counts as other input.
        */
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) },
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            if reportFailure {
                onUnavailable("\(shortcut.displayName) is still blocked. Relaunch \(ProductIdentity.displayName), then remove and re-add it in Accessibility if needed.")
            }
            Diagnostics.event("shortcut_tap_create_failed accessibility=true listen_event=\(listenEvent)")
            return .tapUnavailable
        }
        /*
        The tap runs on the main run loop in common modes, so handle(type:event:) is on the
        main thread and keeps running while a menu or drag holds the run loop in tracking mode.
        */
        eventTap      = tap
        let source    = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            runLoopSource = nil
            eventTap      = nil
            if reportFailure {
                onUnavailable("\(shortcut.displayName) is still blocked. Relaunch \(ProductIdentity.displayName), then remove and re-add it in Accessibility if needed.")
            }
            Diagnostics.event("shortcut_tap_enable_failed accessibility=true listen_event=\(listenEvent)")
            return .tapUnavailable
        }
        Diagnostics.event("shortcut_monitor_started listen_event=\(listenEvent)")
        return .started
    }

//
// :)
//
//
    /*
    Stopping while the talk key is down reports one release right away, because the tap
    can no longer see the real key-up. Nothing stays held back afterwards.
    */
    func stop() {
        onHeldWordsKey      = nil
        heldWordsSwallowKey = nil
        returnGate          = DeliveryReturnGate()
        if held { held = false; onRelease() }
        fastFinishChord = FastFinishChord()
        shortcutState.reset()
        cancelShortcutRecording()
        recordedRelease = nil
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap      = nil
    }


    // Event handling — every key, modifier and click on the Mac passes through here


    /*
    Called by the tap on the main thread for every watched event. Returning the event lets
    it through; returning nil swallows it. The steps run in a fixed order and each may end
    the event: our own Return, choosing a new key, held-words keys, Return held back for
    delivery, a tap that macOS switched off, Return-to-finish, and finally the talk key.
    Keep it fast: macOS switches off a tap whose callback is slow (tapDisabledByTimeout).
    The app's callbacks are sent to main with async, so this returns before they run.
    */
    /// Internal (not private) so tests can feed it synthetic events; only the tap calls it in the app.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        /*
        0x54545452 is "TTTR" in ASCII: the tag TargetDelivery.sendReturn puts on the Return
        it posts itself. Let it through untouched so it is never held back or mistaken
        for the user's key.
        */
        if event.getIntegerValueField(.eventSourceUserData) == 0x54545452 {
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged || type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // The key just chosen as the talk key: swallow it until it is released.
            if let recordedRelease, keyCode == Int64(recordedRelease) {
                if type == .keyUp || (type == .flagsChanged && !Self.modifierDown(keyCode: recordedRelease, event: event)) {
                    self.recordedRelease = nil
                }
                return nil
            }
            /*
            Choosing a new talk key: the first clean press (a key-down that is not a repeat,
            or a modifier going down) becomes the key. Every key event is swallowed while
            choosing, so nothing types into the front app. The callback runs later on main.
            */
            if let callback = shortcutRecording {
                let validDown = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                    || type == .flagsChanged && keyCode >= 0 && keyCode <= 255 && Self.modifierDown(keyCode: UInt16(keyCode), event: event)
                if validDown, keyCode >= 0, keyCode <= 255,
                   TalkShortcut.siblingReservedKeys()[UInt16(keyCode)] != nil {
                    // Keep recording: the sibling app owns this key, so wait for another.
                    recordedRelease = UInt16(keyCode)
                    Diagnostics.event("dictation_shortcut_sibling_key_rejected keycode=\(keyCode)")
                    return nil
                }
                if validDown, keyCode >= 0, keyCode <= 255 {
                    let selected = TalkShortcut(keyCode: UInt16(keyCode), displayName: Self.keyName(keyCode: UInt16(keyCode), event: event))
                    shortcutRecording = nil
                    if setShortcut(selected) {
                        recordedRelease = selected.keyCode
                        Diagnostics.event("dictation_shortcut_recorded keycode=\(keyCode)")
                        DispatchQueue.main.async { callback(selected) }
                    }
                }
                return nil
            }
        }
        // A held-words key (⌘C or Escape) was already used: swallow its repeats and its release.
        if let swallowed = heldWordsSwallowKey, type == .keyDown || type == .keyUp,
           event.getIntegerValueField(.keyboardEventKeycode) == swallowed {
            if type == .keyUp { heldWordsSwallowKey = nil }
            return nil
        }
        /*
        Held words on screen: a clean ⌘C or plain Escape (not a repeat, not the talk key)
        goes to the app, and is swallowed if the app used it. Any other key-down or any
        click clears the handler, so ⌘C in other work is never taken.
        */
        if let onHeldWordsKey {
            if type == .keyDown {
                let keyCode   = event.getIntegerValueField(.keyboardEventKeycode)
                let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                // Match ⌘C by character so non-QWERTY layouts copy with their own C.
                let isCopy = modifiers == .maskCommand
                    && NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() == "c"
                let isEscape = keyCode == 53 && modifiers.isEmpty
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if (isCopy || isEscape), !isRepeat, keyCode != Int64(shortcut.keyCode) {
                    if onHeldWordsKey(keyCode) {
                        heldWordsSwallowKey = keyCode
                        return nil
                    }
                } else {
                    self.onHeldWordsKey = nil
                }
            } else if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                self.onHeldWordsKey = nil
            }
        }
        /*
        Between a stop edge and verified delivery, Return/Enter presses are swallowed here
        (and their key-ups, so the app never sees a lone release). See DeliveryReturnGate.
        */
        if type == .keyDown || type == .keyUp {
            if returnGate.handle(keyCode: event.getIntegerValueField(.keyboardEventKeycode), down: type == .keyDown) {
                Diagnostics.event("delivery_return_reserved down=\(type == .keyDown)")
                return nil
            }
        }
        /*
        macOS switched the tap off (callback too slow, or disabled by user input).
        Key edges may have been missed while it was off, so every per-key state is cleared,
        a held talk key is reported as released, and the tap is switched straight back on.
        */
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            returnGate = DeliveryReturnGate()
            // A key-up missed while disabled must not leave that key swallowed afterwards.
            heldWordsSwallowKey = nil
            shortcutState.reset()
            cancelShortcutRecording()
            recordedRelease = nil
            fastFinishChord = FastFinishChord()
            if held { held = false; DispatchQueue.main.async { [weak self] in self?.onRelease() } }
            Diagnostics.event("input_tap_reenabled")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Return-to-finish: Return (36) or keypad Enter (76) while the talk key is held.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) != Int64(shortcut.keyCode) {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 36 || keyCode == 76 {
                switch fastFinishChord.keyDown(
                    keyCode: keyCode,
                    rightOptionHeld: held,
                    enabled: speedOfSoundEnabled() && speedOfSoundReady()
                ) {
                case .finish:
                    returnGate.begin()
                    _ = returnGate.handle(keyCode: keyCode, down: true)
                    /*
                    Reserve Enter until insertion has been verified.
                    Refresh the destination lease at this key edge, not at the
                    earlier Option press, and dispatch one finish on main.
                    This Return itself is swallowed and marked as requested, so the
                    app can send one Return to the target after the words land.
                    The lease here checks time and front window, not other input.
                    */
                    inputGeneration &+= 1
                    let capturedAt       = ProcessInfo.processInfo.systemUptime
                    let destination      = InputDestinationStamp.current()
                    fastFinishEdgeUptime = capturedAt
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.deliveryEdgeIsCurrent = {
                            ProcessInfo.processInfo.systemUptime - capturedAt < 0.5
                                && destination.pid != nil && destination.window != nil
                                && destination == InputDestinationStamp.current()
                        }
                        defer { self.deliveryEdgeIsCurrent = { true } }
                        Diagnostics.event("speed_of_sound_enter keycode=\(keyCode)")
                        self.onFastFinish()
                    }
                    return nil
                case .consume:
                    return nil
                case .passThrough:
                    break
                }
            }
        }
        /*
        Anything that is not the talk key goes through to the front app, and counts as
        other input for the delivery check.
        */
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard (type == .flagsChanged || type == .keyDown || type == .keyUp), keyCode == Int64(shortcut.keyCode) else {
            inputGeneration &+= 1
            noteChord(type: type, event: event, keyCode: keyCode)
            return Unmanaged.passUnretained(event)
        }
        /*
        The talk key. Every event for it is swallowed, edge or not, so the front app never
        sees it. Only a real press or release (per ShortcutHold) goes on to the app.
        */
        let edgeEvent: ShortcutHold.Event = type == .flagsChanged ? .flagsChanged : (type == .keyDown ? .keyDown : .keyUp)
        guard let down = shortcutState.update(shortcut: shortcut, keyCode: keyCode, event: edgeEvent,
            flags: event.flags.rawValue, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            physicalModifierDown: shortcut.keyCode == 57 ? Self.modifierDown(keyCode: 57, event: event) : nil) else { return nil }
        // Part of a shortcut made with another modifier already down: not a talk, before or after.
        if down, Self.otherModifiersDown(event.flags, talkKey: shortcut.keyCode) {
            suppressedPress = true
            Diagnostics.event("dictation_shortcut_ignored reason=with_modifiers keycode=\(keyCode)")
            return nil
        }
        if !down, suppressedPress { suppressedPress = false; return nil }
        talkEdge(down: down, keyCode: keyCode, source: nil)
        return nil
    }

    /// Cmd, Control, Shift or Option held besides the talk key itself (device-independent flags).
    static func otherModifiersDown(_ flags: CGEventFlags, talkKey: UInt16) -> Bool {
        let own: CGEventFlags = switch talkKey {
        case 58, 61: .maskAlternate
        case 54, 55: .maskCommand
        case 56, 60: .maskShift
        case 59, 62: .maskControl
        case 63:     .maskSecondaryFn
        default:     []
        }
        return !flags.intersection(CGEventFlags([.maskCommand, .maskControl, .maskShift, .maskAlternate]).subtracting(own)).isEmpty
    }

    /*
    The talk-key press that began the running talk is still down, so the next click is a chord
    that discards it (noteChord). Read-only; Home hides its Stop and Discard while it is true, in
    tap mode as well as hold (TOK-QA-005 review). Main run loop, like every edge.
    */
    var startingPressIsHeld: Bool { held && pressStartedTalk && !chordReported }

    private func noteChord(type: CGEventType, event: CGEvent, keyCode: Int64) {
        guard held, pressStartedTalk, !chordReported else { return }
        let pressed: Bool = switch type {
        case .keyDown: event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: true
        // Another modifier going down while the talk key is held (Option then Command).
        case .flagsChanged: Self.otherModifiersDown(event.flags, talkKey: shortcut.keyCode)
        default: false
        }
        guard pressed else { return }
        chordReported = true
        Diagnostics.event("dictation_shortcut_chord type=\(type.rawValue)")
        DispatchQueue.main.async { [weak self] in self?.onChord() }
    }

    /*
    Dev-only live QA (QATalkTrigger): one talk-key edge with no hardware event behind it. It
    takes the same path as a physical edge from here on (Return gate, front app/window stamp,
    input generation, onPress/onRelease); only ShortcutHold is skipped. Refused when the key
    is already in that state, so it never doubles or cuts a physical press.
    */
    @discardableResult
    func injectQAEdge(down: Bool) -> Bool {
        guard held != down else { return false }
        talkEdge(down: down, keyCode: Int64(shortcut.keyCode), source: "qa")
        return true
    }

    /// A talk-key edge after ShortcutHold (or QA) decided it is one; runs on the main run loop.
    private func talkEdge(down: Bool, keyCode: Int64, source: String?) {
        held = down
        let stops = isStopEdge(down)
        pressStartedTalk = down && !stops
        chordReported = false
        /*
        If this edge will finish the talk, start holding back Return now, in the tap,
        before the main thread begins finishing.
        */
        if stops {
            returnGate.begin()
            fastFinishEdgeUptime = ProcessInfo.processInfo.systemUptime
        }
        if !down { fastFinishChord.optionReleased() }
        /*
        Stamp the front app and window at the key edge (cheap; no Accessibility calls).
        On main, the app's press/release callback can ask deliveryEdgeIsCurrent whether
        that is still where the words should go.
        */
        let destination = InputDestinationStamp.current()
        let generation  = inputGeneration
        let capturedAt  = ProcessInfo.processInfo.systemUptime
        Diagnostics.event("dictation_shortcut_edge keycode=\(keyCode) pressed=\(down)" + (source.map { " source=\($0)" } ?? ""))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryEdgeIsCurrent = { [weak self] in
                self?.inputGeneration == generation
                    && ProcessInfo.processInfo.systemUptime - capturedAt < 0.5
                    && destination.pid != nil && destination.window != nil
                    && destination == InputDestinationStamp.current()
            }
            defer { self.deliveryEdgeIsCurrent = { true } }
            if down { self.onPress() } else { self.onRelease() }
        }
    }

//
// :)
//
//
    // Key helpers — is a modifier down, and what to call a key in the settings


    /*
    Caps Lock (57) is read from the physical key state, because its event flag shows
    whether the lock is on, not whether the key is held. Other modifiers use their flag bit.
    */
    private static func modifierDown(keyCode: UInt16, event: CGEvent) -> Bool {
        if keyCode == 57 { return CGEventSource.keyState(.hidSystemState, key: keyCode) }
        let candidate = TalkShortcut(keyCode: keyCode, displayName: "")
        guard let mask = candidate.modifierMask else { return false }
        return event.flags.rawValue & mask != 0
    }

    /*
    Fixed names for modifiers and special keys; otherwise the character the current
    keyboard layout gives (uppercased), or "Key <code>" when there is none.
    */
    private static func keyName(keyCode: UInt16, event: CGEvent) -> String {
        let names: [UInt16: String] = [54:"Right Command", 55:"Left Command", 56:"Left Shift", 60:"Right Shift", 58:"Left Option", 61:"Right Option", 59:"Left Control", 62:"Right Control", 63:"Fn / Globe", 57:"Caps Lock", 36:"Return", 76:"Enter", 49:"Space", 48:"Tab", 51:"Delete", 117:"Forward Delete", 53:"Escape", 123:"Left Arrow", 124:"Right Arrow", 125:"Down Arrow", 126:"Up Arrow", 115:"Home", 119:"End", 116:"Page Up", 121:"Page Down", 122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        if let name = names[keyCode] { return name }
        if let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            return characters.uppercased()
        }
        return "Key \(keyCode)"
    }


}

