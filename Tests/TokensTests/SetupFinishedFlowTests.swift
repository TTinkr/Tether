import Foundation
import Testing
import TokensCore
@testable import Tokens

/// Accepting Terms and finishing setup remain separate, including across a relaunch.
/// A selected local model waits for its download without asking for Apple's permission.
struct SetupFinishedFlowTests {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "SetupFinishedFlowTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func asksForApple(_ defaults: UserDefaults, firstRunPending: Bool) -> Bool {
        SpeechEngineChoice.appleSpeechNeeded(
            setupPending: TalkModel.setupInProgress(firstRunPending: firstRunPending, defaults: defaults),
            from: defaults, orukeetBundled: false, orukeetModelReady: false,
            packagedDefaultModelID: "parakeet-tdt-0.6b-v3")
    }

    @Test func newInstallRetainsSetupProgressAcrossRelaunchWithoutAnAppleBridge() throws {
        let (d, suite) = try defaults()
        defer { d.removePersistentDomain(forName: suite) }
        TalkModel.migrateSetupFinished(d)
        #expect(TalkModel.setupInProgress(firstRunPending: true, defaults: d))
        #expect(!asksForApple(d, firstRunPending: true))

        d.set(true, forKey: TalkModel.tokensFirstRunKey)
        #expect(TalkModel.setupInProgress(firstRunPending: false, defaults: d))
        #expect(!asksForApple(d, firstRunPending: false))

        TalkModel.migrateSetupFinished(d) // A relaunch must not mistake accepted Terms for finished setup.
        #expect(TalkModel.setupInProgress(firstRunPending: false, defaults: d))
        #expect(!asksForApple(d, firstRunPending: false))

        TalkModel.markSetupFinished(d)
        #expect(!TalkModel.setupInProgress(firstRunPending: false, defaults: d))
        #expect(!asksForApple(d, firstRunPending: false))
        #expect(d.object(forKey: SpeechEngineChoice.preferenceKey) == nil)
    }

    @Test func installFromBeforeBuild78CountsAsFinishedWithoutApplePermission() throws {
        let (d, suite) = try defaults()
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: TalkModel.tokensFirstRunKey)
        TalkModel.migrateSetupFinished(d)
        #expect(!TalkModel.setupInProgress(firstRunPending: false, defaults: d))
        #expect(!asksForApple(d, firstRunPending: false))

        // A Terms update may reopen setup, but it does not select Apple's recognizer.
        #expect(TalkModel.setupInProgress(firstRunPending: true, defaults: d))
        #expect(!asksForApple(d, firstRunPending: true))
    }

    @Test func anExplicitAppleChoiceStillNeedsPermissionBeforeAndAfterSetup() throws {
        let (d, suite) = try defaults()
        defer { d.removePersistentDomain(forName: suite) }
        SpeechEngineChoice.apple.persist(to: d)
        TalkModel.migrateSetupFinished(d)
        #expect(asksForApple(d, firstRunPending: true))
        d.set(true, forKey: TalkModel.tokensFirstRunKey)
        #expect(asksForApple(d, firstRunPending: false))
        TalkModel.markSetupFinished(d)
        #expect(asksForApple(d, firstRunPending: false))
        #expect(d.string(forKey: SpeechEngineChoice.preferenceKey) == "apple")
    }
}
