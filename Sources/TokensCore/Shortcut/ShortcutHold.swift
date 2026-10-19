


//
/// Tracks whether the Talk key is held, and reports only the moments it changes.
public struct ShortcutHold: Sendable {
    public enum Event: Equatable, Sendable { case keyDown, keyUp, flagsChanged }

    public private(set) var isHeld = false

    public init() {}

    public mutating func reset() { isHeld = false }

    /// Feeds one key event.
    ///
    /// - Returns: `true` when the shortcut was just pressed, `false` when just released, and nil
    ///   when the event is for another key, a key repeat, or no change.
    /// - Parameter physicalModifierDown: the real key state when the flag cannot be trusted
    ///   (Caps Lock reports a toggle, not a press).
    public mutating func update(shortcut: TalkShortcut, keyCode: Int64, event: Event,
                                flags: UInt64 = 0, isRepeat: Bool = false,
                                physicalModifierDown: Bool? = nil) -> Bool? {
        guard keyCode == Int64(shortcut.keyCode) else { return nil }
        let down: Bool
        if let mask = shortcut.modifierMask {
            guard event == .flagsChanged else { return nil }
            down = physicalModifierDown ?? (flags & mask != 0)
        } else {
            guard event != .flagsChanged else { return nil }
            if event == .keyDown && isRepeat { return nil }
            down = event == .keyDown
        }
        guard down != isHeld else { return nil }
        isHeld = down
        return down
    }
}

