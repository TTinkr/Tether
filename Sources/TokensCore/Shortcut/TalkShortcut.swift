


//
import Foundation


// TalkShortcut — the one physical key that starts and stops a Talk session


/// One physical keyboard key used to talk. Left and right modifiers are different shortcuts.
public struct TalkShortcut: Codable, Equatable, Sendable {
    /// macOS virtual key code of the physical key.
    public let keyCode: UInt16
    /// Name shown in Settings and the bubble hint.
    public let displayName: String

    public init(keyCode: UInt16, displayName: String) {
        self.keyCode     = keyCode
        self.displayName = displayName
    }

    public static let rightOption = Self(keyCode: 61, displayName: "Right Option")
    public static let leftOption  = Self(keyCode: 58, displayName: "Left Option")
    public static let leftControl = Self(keyCode: 59, displayName: "Left Control")

    /// The key a fresh install uses.
    ///
    /// Tokens takes Right Option and Tokens Dev takes Left Option, so one press never starts a Talk session
    /// in both apps when they run side by side.
    public static func defaultShortcut(for channel: Channel?) -> Self {
        channel == .dev ? .leftOption : .rightOption
    }

    /// Keys the sibling app owns, mapped to the sibling's name for the key picker.
    public static func reservedKeys(for channel: Channel?) -> [UInt16: String] {
        guard let channel else { return [:] }
        return [defaultShortcut(for: channel.sibling).keyCode: channel.sibling.displayName]
    }

    /// The modifier flag bit for this key, or nil when it is an ordinary key.
    ///
    /// Trap: these are the device-dependent bits of CGEventFlags, which tell left from
    /// right. The public modifier flags do not.
    public var modifierMask: UInt64? {
        switch keyCode {
        case 55: return 0x08        // left Command
        case 54: return 0x10        // right Command
        case 56: return 0x02        // left Shift
        case 60: return 0x04        // right Shift
        case 58: return 0x20        // left Option
        case 61: return 0x40        // right Option
        case 59: return 0x01        // left Control
        case 62: return 0x2000      // right Control
        case 63: return 0x0080_0000 // Fn / Globe
        case 57: return 0x0001_0000 // Caps Lock: the flag is a toggle, so callers pass the physical state
        default: return nil
        }
    }

    /// The saved shortcut, or the channel default when nothing valid is saved.
    ///
    /// A saved key that the sibling app owns is ignored, for the same reason as the default.
    public static func load(from defaults: UserDefaults = .standard,
                            channel: Channel? = .current) -> Self {
        guard let data = defaults.data(forKey: SettingsKey.talkShortcut),
              let shortcut = try? JSONDecoder().decode(Self.self, from: data),
              shortcut.keyCode <= 255, !shortcut.displayName.isEmpty,
              reservedKeys(for: channel)[shortcut.keyCode] == nil else {
            return defaultShortcut(for: channel)
        }
        return shortcut
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SettingsKey.talkShortcut)
    }
}

