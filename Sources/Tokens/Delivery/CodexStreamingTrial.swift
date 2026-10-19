import Foundation

/// A local diagnostic lease for streaming into Codex. Ordinary verified pastes never
/// arm it, and early speculative prefixes remain disabled for Codex. It holds a small
/// count of attempts bound to one running app process, so a restarted app never
/// inherits it. There is no clock: an expiry made two physical trials miss their
/// window (and a float-rounded epoch rejected a third). Consume before posting so a
/// transport failure cannot re-arm it.
///
/// Arm from a shell for the running app:
///   defaults write com.tinkr.tokens.community.macos TokensCodexBoundaryTrial.v1 -int 3
///   defaults write com.tinkr.tokens.community.macos TokensCodexBoundaryTrial.v1.pid -int <PID>
enum CodexStreamingTrial {
    static let preferenceKey = "TokensCodexBoundaryTrial.v1"
    static let processKey = preferenceKey + ".pid"
    /// Retired: a former expiry. Removed when the lease is consumed or cleared.
    static let expiryKey = preferenceKey + ".expires"
    /// Upper bound on attempts one arming can grant.
    static let maximumAttempts = 10

    /// Remaining attempts for this process; zero when unarmed or armed for another process.
    static func remaining(in defaults: UserDefaults = .standard,
                          processID: Int = Int(ProcessInfo.processInfo.processIdentifier)) -> Int {
        guard defaults.integer(forKey: processKey) == processID else { return 0 }
        return min(max(defaults.integer(forKey: preferenceKey), 0), maximumAttempts)
    }

    /// A short, text-free state for the staging_gate diagnostic.
    static func status(in defaults: UserDefaults = .standard,
                       processID: Int = Int(ProcessInfo.processInfo.processIdentifier)) -> String {
        guard defaults.integer(forKey: preferenceKey) > 0 else { return "off" }
        guard defaults.integer(forKey: processKey) == processID else { return "other_process" }
        return "armed_\(remaining(in: defaults, processID: processID))"
    }

    static func consume(bundle: String?, richComposer: Bool, exactPlan: Bool,
                        in defaults: UserDefaults = .standard,
                        processID: Int = Int(ProcessInfo.processInfo.processIdentifier)) -> Bool {
        let left = remaining(in: defaults, processID: processID)
        guard bundle == "com.openai.codex", richComposer, exactPlan, left > 0 else { return false }
        if left > 1 {
            defaults.set(left - 1, forKey: preferenceKey)
        } else {
            defaults.removeObject(forKey: preferenceKey)
        }
        defaults.removeObject(forKey: expiryKey)
        return true
    }
}
