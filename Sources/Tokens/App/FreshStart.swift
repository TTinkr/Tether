


//
import Foundation


// FreshStart — every launch of prod_tokens is a first launch


/// A separate build (prod_tokens) that resets all memory every time it opens, so each launch behaves like
/// the first run.
enum FreshStart {
    static let bundleIdentifier = "com.tinkr.tokens.community.fresh.macos"
    static let displayName      = "prod_tokens"

    /// True only inside prod_tokens.
    static var isFreshApp: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }

    /*
    Theorem: runs once per process, before TalkModel exists (AppDelegate's first property),
             so nothing has read the old settings or history yet.
    What is wiped: this app's settings domain (keys, first-run and terms flags, window frames,
    bubble position), its personal dictionary suite, and its Application Support folder
    (history, recovery journal, delivery counts). Kept: the event log, which holds no words
    and helps explain what a first run did.
    */
    @discardableResult
    static func resetIfFreshApp() -> Bool {
        guard isFreshApp else { return false }
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.removePersistentDomain(forName: bundleIdentifier + ".preferences")
        defaults.synchronize()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        // Trap: only ever this exact folder. A wrong path here would delete someone's data.
        if support.lastPathComponent == bundleIdentifier {
            try? FileManager.default.removeItem(at: support)
        }
        Diagnostics.event("fresh_start_reset")
        return true
    }
}

