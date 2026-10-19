
import Foundation
import Testing
@testable import Tokens

struct RequiresReviewAutoSendTests {
    @Test func reviewNeverRequestsReturnEvenWithAutoSendOrAReturnPressedAfterStop() {
        for autoSend in [false, true] {
            for reserved in [false, true] {
                #expect(!TokensAutoSendDelivery.returnRequested(autoSend: autoSend, reservedReturn: reserved,
                                                                requiresReview: true))
                #expect(TokensAutoSendDelivery.returnRequested(autoSend: autoSend, reservedReturn: reserved,
                                                               requiresReview: false) == (autoSend || reserved))
            }
        }
    }

    @Test func aReviewTalkNeverReachesSendEvenWhenVerified() {
        var attempts = 0
        let requested = TokensAutoSendDelivery.returnRequested(autoSend: true, reservedReturn: true, requiresReview: true)
        let sent = TokensAutoSendDelivery.submitIfVerified(.verified, requested: requested, reservedReturn: false) {
            attempts += 1; return true
        }
        #expect(!sent && attempts == 0)
    }

    @Test func segmentsDefaultToNoReviewAndCarryTheFlagThroughTheStopGate() {
        let plain = CompletedSegment(id: UUID(), features: .silence, transcript: "fictional words")
        #expect(!plain.requiresReview)
        var held = plain
        held.requiresReview = true
        let pending = TalkModel.PendingDelivery(payload: held.transcript, segment: held, sendReturn: true)
        #expect(pending.segment.requiresReview)
    }
}
