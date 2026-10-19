import Foundation

/// Persisted intent, independent of model availability. Capture snapshots this
/// value once per recording; changing the preference cannot replace a live engine.
public enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case orukeet

    public static let preferenceKey = "TokensSpeechEngine.v1"
    public static let orukeetBundled =
        Bundle.main.object(forInfoDictionaryKey: "TokensOrukeetEnabled") as? Bool == true

    /// The packager sets this only when it supplies the selected model's runtime.
    /// It is a default, never a replacement for a person's saved model selection.
    public static let packagedDefaultModelID =
        Bundle.main.object(forInfoDictionaryKey: "TokensDefaultSpeechModel") as? String

    public static var defaultModelID: String { defaultModelID(orukeetBundled: orukeetBundled) }
    public static func defaultModelID(orukeetBundled: Bool,
                                      packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> String {
        if let id = packagedDefaultModelID, SpeechModelCatalog.entry(id) != nil { return id }
        return orukeetBundled ? SpeechModelCatalog.orukeetID : SpeechModelCatalog.appleID
    }

    public static var defaultChoice: SpeechEngineChoice { defaultChoice(orukeetBundled: orukeetBundled) }
    public static func defaultChoice(orukeetBundled: Bool,
                                     packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> SpeechEngineChoice {
        route(defaultModelID(orukeetBundled: orukeetBundled, packagedDefaultModelID: packagedDefaultModelID))
    }

    /// Missing local weights cause a visible wait or failure. Never switch recognition to Apple.
    /// The readiness argument remains available to callers/tests that also inspect waiting state.
    public static func load(from defaults: UserDefaults = .standard,
                            orukeetBundled: Bool = SpeechEngineChoice.orukeetBundled,
                            orukeetModelReady: Bool = SpeechEngineChoice.orukeetModelReady(),
                            packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> SpeechEngineChoice {
        intended(from: defaults, orukeetBundled: orukeetBundled, packagedDefaultModelID: packagedDefaultModelID)
    }

    /// .orukeet is the existing worker route for all local models, including Parakeet.
    public static func selectedModelID(from defaults: UserDefaults = .standard,
                                       orukeetBundled: Bool = SpeechEngineChoice.orukeetBundled,
                                       packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> String {
        if let override = processModelOverride, SpeechModelCatalog.entry(override) != nil { return override }
        if let saved = defaults.string(forKey: preferenceKey), SpeechModelCatalog.entry(saved) != nil { return saved }
        return defaultModelID(orukeetBundled: orukeetBundled, packagedDefaultModelID: packagedDefaultModelID)
    }

    /// Dev fixture proofs only (--fixture-model); never changes saved settings.
    nonisolated(unsafe) public static var processModelOverride: String?

    public static func intended(from defaults: UserDefaults = .standard,
                                orukeetBundled: Bool = SpeechEngineChoice.orukeetBundled,
                                packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> SpeechEngineChoice {
        route(selectedModelID(from: defaults, orukeetBundled: orukeetBundled, packagedDefaultModelID: packagedDefaultModelID))
    }

    /// Any selected local model is waiting until its installed weights have been verified.
    public static func waitingForOrukeet(from defaults: UserDefaults = .standard,
                                         orukeetBundled: Bool = SpeechEngineChoice.orukeetBundled,
                                         orukeetModelReady: Bool = SpeechEngineChoice.orukeetModelReady(),
                                         packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> Bool {
        intended(from: defaults, orukeetBundled: orukeetBundled, packagedDefaultModelID: packagedDefaultModelID) == .orukeet
            && !orukeetModelReady
    }

    /// Apple's Speech permission is needed only when Apple is the selected engine.
    public static func appleSpeechNeeded(setupPending: Bool,
                                         from defaults: UserDefaults = .standard,
                                         orukeetBundled: Bool = SpeechEngineChoice.orukeetBundled,
                                         orukeetModelReady: Bool = SpeechEngineChoice.orukeetModelReady(),
                                         packagedDefaultModelID: String? = SpeechEngineChoice.packagedDefaultModelID) -> Bool {
        intended(from: defaults, orukeetBundled: orukeetBundled, packagedDefaultModelID: packagedDefaultModelID) == .apple
    }

    public static func orukeetModelReady() -> Bool { localModelReady(selectedModelID()) }

    /// The app supplies verified readiness at launch. This does not change selected intent.
    nonisolated(unsafe) public static var localModelReady: @Sendable (String) -> Bool = { _ in true }

    private static func route(_ id: String) -> SpeechEngineChoice {
        SpeechModelCatalog.entry(id)?.runtime == .apple ? .apple : .orukeet
    }

    public func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
