


//
import Foundation
import Testing
@testable import TokensCore

@Suite struct LaunchPresentationTests {
    @Test func explicitLaunchAndReopenShowHome() {
        // Reopen uses the same explicit-launch inputs in AppDelegate.
        for publicTokens in [false, true] {
            #expect(LaunchPresentation.needsHome(publicTokens: publicTokens, firstRunPending: false,
                                                 background: false, loginItem: false))
        }
    }
    @Test func backgroundAndLoginLaunchesStayQuietAfterSetup() {
        for publicTokens in [false, true] {
            for (background, loginItem) in [(true, false), (false, true), (true, true)] {
                #expect(!LaunchPresentation.needsHome(publicTokens: publicTokens, firstRunPending: false,
                                                      background: background, loginItem: loginItem))
            }
        }
    }
    @Test func firstRunAlwaysShowsHome() {
        for publicTokens in [false, true] {
            for background in [false, true] {
                for loginItem in [false, true] {
                    #expect(LaunchPresentation.needsHome(publicTokens: publicTokens, firstRunPending: true,
                                                         background: background, loginItem: loginItem))
                }
            }
        }
    }
    @Test func bundledOrukeetPrewarmsAtEveryLaunchOnlyWhenSelected() {
        #expect(LaunchPresentation.prewarmsLocalSpeech(engine: .orukeet, orukeetBundled: true))
        #expect(!LaunchPresentation.prewarmsLocalSpeech(engine: .orukeet, orukeetBundled: false))
        #expect(!LaunchPresentation.prewarmsLocalSpeech(engine: .apple, orukeetBundled: true))
        // A fresh install's default is Orukeet in a model-bearing bundle, so first run prewarms.
        #expect(LaunchPresentation.prewarmsLocalSpeech(engine: SpeechEngineChoice.defaultChoice(orukeetBundled: true,
                                                                                                packagedDefaultModelID: nil),
                                                       orukeetBundled: true))
    }
    @Test func readyParakeetPrewarmsWithoutAnOrukeetBundle() {
        let engine = SpeechEngineChoice.defaultChoice(orukeetBundled: false,
                                                        packagedDefaultModelID: "parakeet-tdt-0.6b-v3")
        #expect(LaunchPresentation.prewarmsLocalSpeech(engine: engine, orukeetBundled: false,
                                                       localModelReady: true))
        #expect(!LaunchPresentation.prewarmsLocalSpeech(engine: engine, orukeetBundled: false,
                                                        localModelReady: false))
    }
    @Test func readinessOverridesBundlePresenceButNeverPrewarmsApple() {
        #expect(!LaunchPresentation.prewarmsLocalSpeech(engine: .orukeet, orukeetBundled: true,
                                                        localModelReady: false))
        for bundled in [false, true] {
            for ready in [false, true] {
                #expect(!LaunchPresentation.prewarmsLocalSpeech(engine: .apple, orukeetBundled: bundled,
                                                                localModelReady: ready))
            }
        }
    }
    /// Build 81: Sparkle's relaunch is quiet once; first-run setup still opens.
    @Test func updateRelaunchIsQuietOnce() {
        let suite = "update-relaunch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(!LaunchPresentation.consumeUpdateRelaunch(now: now, in: defaults))
        LaunchPresentation.markUpdateRelaunch(at: now - 30, in: defaults)
        #expect(LaunchPresentation.consumeUpdateRelaunch(now: now, in: defaults))
        #expect(!LaunchPresentation.consumeUpdateRelaunch(now: now, in: defaults))
        LaunchPresentation.markUpdateRelaunch(at: now - 3600, in: defaults)
        #expect(!LaunchPresentation.consumeUpdateRelaunch(now: now, in: defaults))
        #expect(!LaunchPresentation.needsHome(publicTokens: true, firstRunPending: false, background: false,
                                              loginItem: false, updateRelaunch: true))
        #expect(LaunchPresentation.needsHome(publicTokens: true, firstRunPending: true, background: false,
                                             loginItem: false, updateRelaunch: true))
    }
}

