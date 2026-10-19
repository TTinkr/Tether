


//
import Foundation

/// The app a talk was delivered to, as it was at the stop. Saved locally with the entry only.
public struct PromptTargetApp: Codable, Equatable, Hashable, Sendable {
    /// e.g. "com.openai.codex". The grouping key.
    public var bundleID: String
    /// The app's localized name at the time ("Codex"); nil when the system had none.
    public var name: String?

    public init(bundleID: String, name: String?) {
        self.bundleID = bundleID
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Nil for a missing or empty bundle id, so an unknown target is never saved as "".
    public init?(bundleID: String?, name: String?) {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        self.init(bundleID: id, name: name)
    }

    /// The saved name, else the last bundle id component ("com.apple.Terminal" → "Terminal").
    public var displayName: String {
        name ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

