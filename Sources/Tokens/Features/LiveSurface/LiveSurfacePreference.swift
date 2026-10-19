
import Foundation

enum LiveSurfacePreference {
    enum Key: String {
        /// A dot per caught word under the bubble's wave (CaughtWordsStrip).
        case caughtWords = "TokensLiveSurface.caughtWords.v1"
    }
    static func load(_ key: Key, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? false
    }
    static func save(_ value: Bool, for key: Key, _ defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key.rawValue)
    }
}
