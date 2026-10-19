import Foundation
import Testing
@testable import Tokens

struct TokensAutoSendTests {
    @Test func missingSettingDefaultsOnAndExplicitChoicesPersist() throws {
        let name = "TokensAutoSendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TokensAutoSendPreference.load(from: defaults))
        #expect(defaults.object(forKey: TokensAutoSendPreference.key) == nil)
        TokensAutoSendPreference.save(false, to: defaults)
        #expect(!TokensAutoSendPreference.load(from: defaults))
        #expect(defaults.object(forKey: TokensAutoSendPreference.key) != nil)
        TokensAutoSendPreference.save(true, to: defaults)
        #expect(TokensAutoSendPreference.load(from: defaults))
    }

    @Test func preferenceControlsNormalTokensStopAndExplicitChoicesWin() {
        #expect(TokensPrompt.requestsReturn(product: "Tokens"))
        #expect(!TokensPrompt.requestsReturn(product: "Tokens", autoSendAfterPasting: false))
        #expect(TokensPrompt.requestsReturn(product: "Tokens", autoSendAfterPasting: true))
        #expect(TokensPrompt.requestsReturn(product: "Tokens", explicit: true, autoSendAfterPasting: false))
        #expect(!TokensPrompt.requestsReturn(product: "Tokens", explicit: false, autoSendAfterPasting: true))
        #expect(!TokensPrompt.requestsReturn(product: "Talk", autoSendAfterPasting: true))
        #expect(TokensPrompt.requestsReturn(product: "Talk", explicit: true, autoSendAfterPasting: false))
    }

    @Test func unconfirmedFailedAndPartialDeliveryNeverInvokeSendEvenWhenRequested() {
        var attempts = 0
        for outcome in [DeliveryOutcome.delivered, .notObserved, .failed("no_target"), .failed("partial_insert"),
                        .failed("partial_browser_continuation_refused")] {
            for requested in [false, true] {
                for reserved in [false, true] {
                    #expect(!TokensAutoSendDelivery.submitIfVerified(outcome, requested: requested,
                                                                     reservedReturn: reserved) {
                        attempts += 1
                        return true
                    })
                }
            }
        }
        #expect(attempts == 0)
    }

    @Test func verifiedSendRespectsPreferenceManualReturnAndDestinationGuardResult() {
        var attempts = 0
        #expect(!TokensAutoSendDelivery.submitIfVerified(.verified, requested: false, reservedReturn: false) {
            attempts += 1
            return true
        })
        #expect(attempts == 0)
        #expect(TokensAutoSendDelivery.submitIfVerified(.verified, requested: true, reservedReturn: false) {
            attempts += 1
            return true
        })
        #expect(TokensAutoSendDelivery.submitIfVerified(.verified, requested: false, reservedReturn: true) {
            attempts += 1
            return true
        })
        #expect(!TokensAutoSendDelivery.submitIfVerified(.verified, requested: true, reservedReturn: true) {
            attempts += 1
            return false // Current field/window/security guard rejects the send.
        })
        #expect(!TokensAutoSendDelivery.submitIfVerified(.verified, requested: false, reservedReturn: true) {
            attempts += 1
            return false // Manual Return with Auto-send OFF must also report guard rejection.
        })
        #expect(attempts == 4)
    }
}
