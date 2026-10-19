


//
import Foundation


// Channel — which of the two apps this is: Tokens or Tokens Dev


/// The two apps built from this one source tree.
///
/// Both can be installed and running at once. Tokens is what people use; Tokens Dev is where a
/// change is tried first, then promoted. Each has its own identity, shortcut key, and data.
public enum Channel: String, CaseIterable, Sendable {
    case production
    case dev

    /// Theorem: these strings never change. macOS ties microphone and Accessibility
    /// permission to the bundle identifier, so a rename would silently revoke both.
    public var bundleIdentifier: String {
        switch self {
        case .production: return "com.tinkr.tokens.community.macos"
        case .dev:        return "com.tinkr.tokens.community.dev.macos"
        }
    }

    /// The name shown to people, including in the other app's key picker.
    public var displayName: String {
        switch self {
        // The launch name is Tokens.
        case .production: return "Tokens"
        case .dev:        return "Tokens Dev"
        }
    }

    /// The other app that may be running beside this one.
    public var sibling: Channel {
        switch self {
        case .production: return .dev
        case .dev:        return .production
        }
    }

    /// The channel for a bundle identifier, or nil for anything else (tests, ad-hoc copies).
    public init?(bundleIdentifier: String?) {
        guard let match = Channel.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        self = match
    }

    /// The channel of the running process.
    public static var current: Channel? {
        Channel(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

