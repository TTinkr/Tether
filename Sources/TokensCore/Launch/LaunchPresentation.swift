


//
import Foundation

public enum LaunchPresentation {
    public static func needsHome(publicTokens: Bool, firstRunPending: Bool,
                                 background: Bool, loginItem: Bool, updateRelaunch: Bool = false) -> Bool {
        firstRunPending || (!background && !loginItem && !updateRelaunch)
    }

    /*
    Sparkle's relaunch after an update is not an explicit launch (build 81): it used to open and
    activate Home over the app being talked into, so the next talk was held in Tokens. Updater
    stamps the moment just before relaunching; the next launch within ten minutes reads it once.
    */
    public static let updateRelaunchKey = "TokensUpdateRelaunchAt.v1"

    public static func markUpdateRelaunch(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: updateRelaunchKey)
    }

    /// True once for a launch that follows an update relaunch; clears the stamp.
    public static func consumeUpdateRelaunch(now: Date = Date(), in defaults: UserDefaults = .standard) -> Bool {
        guard let stamp = defaults.object(forKey: updateRelaunchKey) as? Double else { return false }
        defaults.removeObject(forKey: updateRelaunchKey)
        let age = now.timeIntervalSince1970 - stamp
        return age >= 0 && age < 600
    }
    /// Prewarm only a ready local model. The explicit readiness argument also covers
    /// downloaded models whose runtime ships separately from Orukeet's worker.
    public static func prewarmsLocalSpeech(engine: SpeechEngineChoice, orukeetBundled: Bool,
                                           localModelReady: Bool? = nil) -> Bool {
        engine == .orukeet && (localModelReady ?? orukeetBundled)
    }
}
