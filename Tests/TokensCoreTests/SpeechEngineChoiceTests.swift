import Foundation
import Testing
@testable import TokensCore

struct SpeechEngineChoiceTests {
    private let parakeet = "parakeet-tdt-0.6b-v3"

    private func isolatedDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let suite = "SpeechEngineChoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    @Test func absentOrInvalidPackagedMetadataPreservesLegacyDefaults() {
        for packagedID in [nil, "", "Apple", "future-engine", " parakeet-tdt-0.6b-v3 "] as [String?] {
            #expect(SpeechEngineChoice.defaultModelID(orukeetBundled: true,
                                                       packagedDefaultModelID: packagedID) == "orukeet")
            #expect(SpeechEngineChoice.defaultModelID(orukeetBundled: false,
                                                       packagedDefaultModelID: packagedID) == "apple")
            #expect(SpeechEngineChoice.defaultChoice(orukeetBundled: true,
                                                      packagedDefaultModelID: packagedID) == .orukeet)
            #expect(SpeechEngineChoice.defaultChoice(orukeetBundled: false,
                                                      packagedDefaultModelID: packagedID) == .apple)
        }
    }

    @Test func packagedModelMetadataOverridesTheLegacyBundleFlag() {
        for bundled in [false, true] {
            for id in ["apple", "orukeet", parakeet, "whisper-base.en"] {
                #expect(SpeechEngineChoice.defaultModelID(orukeetBundled: bundled,
                                                           packagedDefaultModelID: id) == id)
                let expected: SpeechEngineChoice = id == "apple" ? .apple : .orukeet
                #expect(SpeechEngineChoice.defaultChoice(orukeetBundled: bundled,
                                                          packagedDefaultModelID: id) == expected)
            }
        }
    }

    @Test func freshAndUnknownPreferencesUseLegacyDefaultsWithoutWriting() {
        isolatedDefaults { defaults in
            for bundled in [false, true] {
                defaults.removeObject(forKey: SpeechEngineChoice.preferenceKey)
                let expected: SpeechEngineChoice = bundled ? .orukeet : .apple
                #expect(SpeechEngineChoice.load(from: defaults, orukeetBundled: bundled,
                                                  orukeetModelReady: false, packagedDefaultModelID: nil) == expected)
                #expect(defaults.object(forKey: SpeechEngineChoice.preferenceKey) == nil)
                for invalid in ["", "Apple", "future-engine"] {
                    defaults.set(invalid, forKey: SpeechEngineChoice.preferenceKey)
                    #expect(SpeechEngineChoice.load(from: defaults, orukeetBundled: bundled,
                                                      orukeetModelReady: false, packagedDefaultModelID: nil) == expected)
                    #expect(defaults.string(forKey: SpeechEngineChoice.preferenceKey) == invalid)
                }
            }
        }
    }

    @Test func freshParakeetDefaultNeverSwitchesToAppleWhileDownloading() {
        isolatedDefaults { defaults in
            for bundled in [false, true] {
                #expect(SpeechEngineChoice.selectedModelID(from: defaults, orukeetBundled: bundled,
                                                            packagedDefaultModelID: parakeet) == parakeet)
                #expect(SpeechEngineChoice.intended(from: defaults, orukeetBundled: bundled,
                                                     packagedDefaultModelID: parakeet) == .orukeet)
                for ready in [false, true] {
                    #expect(SpeechEngineChoice.load(from: defaults, orukeetBundled: bundled,
                                                      orukeetModelReady: ready, packagedDefaultModelID: parakeet) == .orukeet)
                    #expect(SpeechEngineChoice.waitingForOrukeet(from: defaults, orukeetBundled: bundled,
                                                                  orukeetModelReady: ready,
                                                                  packagedDefaultModelID: parakeet) == !ready)
                    for setupPending in [false, true] {
                        #expect(!SpeechEngineChoice.appleSpeechNeeded(setupPending: setupPending, from: defaults,
                                                                        orukeetBundled: bundled,
                                                                        orukeetModelReady: ready,
                                                                        packagedDefaultModelID: parakeet))
                    }
                }
                #expect(defaults.object(forKey: SpeechEngineChoice.preferenceKey) == nil)
            }
        }
    }

    @Test func invalidSavedPreferenceUsesParakeetWithoutRewritingIt() {
        isolatedDefaults { defaults in
            for invalid in ["", "Apple", "future-engine"] {
                defaults.set(invalid, forKey: SpeechEngineChoice.preferenceKey)
                #expect(SpeechEngineChoice.selectedModelID(from: defaults, orukeetBundled: false,
                                                            packagedDefaultModelID: parakeet) == parakeet)
                #expect(SpeechEngineChoice.load(from: defaults, orukeetBundled: false,
                                                  orukeetModelReady: false, packagedDefaultModelID: parakeet) == .orukeet)
                #expect(defaults.string(forKey: SpeechEngineChoice.preferenceKey) == invalid)
            }
        }
    }

    @Test func explicitAppleAndOtherModelsSurviveTheNewPackagedDefault() {
        isolatedDefaults { defaults in
            for saved in ["apple", "orukeet", "parakeet-tdt-0.6b-v2", "whisper-base.en"] {
                defaults.set(saved, forKey: SpeechEngineChoice.preferenceKey)
                let expected: SpeechEngineChoice = saved == "apple" ? .apple : .orukeet
                for bundled in [false, true] {
                    #expect(SpeechEngineChoice.selectedModelID(from: defaults, orukeetBundled: bundled,
                                                                packagedDefaultModelID: parakeet) == saved)
                    for ready in [false, true] {
                        #expect(SpeechEngineChoice.load(from: defaults, orukeetBundled: bundled,
                                                          orukeetModelReady: ready,
                                                          packagedDefaultModelID: parakeet) == expected)
                        #expect(SpeechEngineChoice.waitingForOrukeet(from: defaults, orukeetBundled: bundled,
                                                                      orukeetModelReady: ready,
                                                                      packagedDefaultModelID: parakeet)
                                == (expected == .orukeet && !ready))
                    }
                }
                #expect(defaults.string(forKey: SpeechEngineChoice.preferenceKey) == saved)
            }
        }
    }

    @Test func explicitAppleNeedsPermissionRegardlessOfSetupOrLocalReadiness() {
        isolatedDefaults { defaults in
            SpeechEngineChoice.apple.persist(to: defaults)
            for setupPending in [false, true] {
                for ready in [false, true] {
                    #expect(SpeechEngineChoice.appleSpeechNeeded(setupPending: setupPending, from: defaults,
                                                                  orukeetBundled: false,
                                                                  orukeetModelReady: ready,
                                                                  packagedDefaultModelID: parakeet))
                }
            }
        }
    }

    @Test func explicitAppleAndOrukeetChoicesRoundTrip() {
        isolatedDefaults { defaults in
            for choice in SpeechEngineChoice.allCases {
                choice.persist(to: defaults)
                #expect(defaults.string(forKey: SpeechEngineChoice.preferenceKey) == choice.rawValue)
                #expect(SpeechEngineChoice.load(from: defaults, orukeetModelReady: false,
                                                  packagedDefaultModelID: parakeet) == choice)
            }
        }
    }

    @Test func capturedChoiceDoesNotChangeWhenPreferenceChanges() {
        isolatedDefaults { defaults in
            SpeechEngineChoice.apple.persist(to: defaults)
            let captured = SpeechEngineChoice.load(from: defaults, packagedDefaultModelID: parakeet)
            SpeechEngineChoice.orukeet.persist(to: defaults)
            #expect(captured == .apple)
            #expect(SpeechEngineChoice.load(from: defaults, orukeetModelReady: false,
                                              packagedDefaultModelID: parakeet) == .orukeet)
        }
    }
}
