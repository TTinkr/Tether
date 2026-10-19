


//
import Foundation


// TalkShortcut — the one physical key that starts a talk, and where that choice is saved


/// One physical keyboard key. Left/right modifiers are distinct shortcuts.
struct TalkShortcut: Codable, Equatable, Sendable {
    /*
    keyCode is the macOS virtual key code of the physical key (61 = Right Option,
    58 = Left Option, 59 = Left Control). It names a key position, not a character.
    */
    let keyCode: UInt16
    let displayName: String
    static let rightOption               = Self(keyCode: 61, displayName: "Right Option")
    static let leftOption                = Self(keyCode: 58, displayName: "Left Option")
    static let preferenceKey             = "TTTDictationShortcut.v2"
    static let leftControl               = Self(keyCode: 59, displayName: "Left Control")
    static let tokensBundleIdentifier    = "com.tinkr.tokens.community.macos"
    static let tokensDevBundleIdentifier = "com.tinkr.tokens.community.dev.macos"
    static let rightCommand              = Self(keyCode: 54, displayName: "Right Command")
    static let globe                     = Self(keyCode: 63, displayName: "Fn")

    /// Tokens owns Right Option and Tokens Dev owns Left Option, so both can run without one key
    /// dictating twice. Choices saved under an older key are dropped.
    /// prod_tokens takes Fn so it can run beside both without double dictation.
    /// Some keyboards have no Right Control, and Caps Lock + Space is a common launcher shortcut.
    /// Not Control: every Ctrl shortcut would start or stop a talk, because the talk key's presses
    /// are taken by Tokens. Trap: a Mac may remap Caps Lock to Right Command and the Command keys
    /// to Fn, so Right Command would fire on every launcher shortcut and Fn would be a physical
    /// Command key. Fn alone has no other use on a default setup.
    static func productDefault(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Self {
        if bundleIdentifier == FreshStart.bundleIdentifier { return .globe }
        return bundleIdentifier == tokensDevBundleIdentifier ? .leftOption : .rightOption
    }

    /// Keys sibling apps already own, with the owner's name; choosing one would make both apps dictate at once.
    static func siblingReservedKeys(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> [UInt16: String] {
        switch bundleIdentifier {
        case tokensBundleIdentifier: return [leftOption.keyCode: "Tokens Dev"]
        case tokensDevBundleIdentifier: return [rightOption.keyCode: "Tokens"]
        case FreshStart.bundleIdentifier: return [rightOption.keyCode: "Tokens", leftOption.keyCode: "Tokens Dev"]
        default: return [:]
        }
    }

    /*
    What macOS itself does with a key, when that would fight the talk. Seen on a friend's Mac
    (2026-10-06 recording, 06:50 and 07:50): Fn chosen as the talk key opened Emoji & Symbols on
    every press. Known AppleFnUsageType values map to their named action. Missing or unfamiliar
    settings produce a conditional reminder, not a claim about this Mac's actual key behavior.
    Some Macs remap Command to Fn, so this warns; it never blocks.
    */
    static func systemConflict(keyCode: UInt16,
                               defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.HIToolbox")) -> String? {
        systemConflict(keyCode: keyCode, usage: defaults?.object(forKey: "AppleFnUsageType") as? Int)
    }

    /// Pure mapping for unknown configuration as well as explicitly observed settings.
    static func systemConflict(keyCode: UInt16, usage: Int?) -> String? {
        guard keyCode == globe.keyCode else { return nil }
        let change = " Set “Press 🌐 key to” to “Do Nothing” in System Settings › Keyboard."
        switch usage {
        case 0: return nil
        case 1: return "Pressing Fn also changes the input source." + change
        case 2: return "Pressing Fn also opens Emoji & Symbols." + change
        case 3: return "Pressing Fn also starts Apple Dictation." + change
        default: return "Fn may also trigger a macOS shortcut. Check “Press 🌐 key to” in System Settings › Keyboard."
        }
    }

    /*
    Modifier keys never send key-down or key-up, only "flags changed" events. This is the
    bit in those event flags that is set while this exact key is down; the per-side bits
    are what tell Left Option from Right Option. nil means an ordinary (non-modifier) key.
    */
    var modifierMask: UInt64? {
        switch keyCode {
        case 55: return 0x08       // left Command
        case 54: return 0x10       // right Command
        case 56: return 0x02       // left Shift
        case 60: return 0x04       // right Shift
        case 58: return 0x20       // left Option
        case 61: return 0x40       // right Option
        case 59: return 0x01       // left Control
        case 62: return 0x2000     // right Control
        case 63: return 0x00800000 // Fn / Globe
        case 57: return 0x00010000 // Caps Lock requires physical state override
        default: return nil
        }
    }

    /*
    A saved key is used only when it decodes, is a real key code, has a name, and is not
    a key the sibling app owns. Anything else falls back to this app's default key.
    */
    static func load(in defaults: UserDefaults = .standard,
                     bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let shortcut = try? JSONDecoder().decode(Self.self, from: data),
              shortcut.keyCode <= 255, !shortcut.displayName.isEmpty,
              siblingReservedKeys(bundleIdentifier: bundleIdentifier)[shortcut.keyCode] == nil else {
            return productDefault(bundleIdentifier: bundleIdentifier)
        }
        return shortcut
    }

//
// :)
//
//
    func save(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}


// ShortcutHold — turns raw events for the talk key into one press and one release


/// Deterministic edge filtering shared by the event tap and headless tests.
struct ShortcutHold {
    enum Event: Equatable { case keyDown, keyUp, flagsChanged }
    private(set) var held = false
    mutating func reset() { held = false }

    /*
    Returns true on the press edge, false on the release edge, and nil for everything else
    (another key, an auto-repeat, or no change from what we already think is held).
    Modifier keys are read only from flagsChanged; ordinary keys only from keyDown/keyUp.
    physicalModifierDown, when given, replaces the flag bit (used for Caps Lock, whose
    flag shows the lock state rather than whether the key is being held).
    */
    mutating func update(shortcut: TalkShortcut, keyCode: Int64, event: Event,
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
        guard down != held else { return nil }
        held = down
        return down
    }
}

