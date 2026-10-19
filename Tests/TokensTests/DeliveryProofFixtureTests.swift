


//
import Foundation
import Testing
@testable import Tokens

struct DeliveryProofFixtureTests {
    @Test @MainActor func receiptKeepsTheOwnedDocumentWithoutClaimingSuccess() throws {
        let receipt = TargetDelivery.scratchProofReceipt(documentID: "tp-tokens-fixture42",
            trusted: false, isDev: true, testpadFrontmost: false)
        let data = try JSONSerialization.data(withJSONObject: receipt)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["document"] as? String == "tp-tokens-fixture42")
        #expect(decoded["physical_input"] as? Bool == false)
        #expect(decoded["status"] as? String == "failed")
    }

    @Test @MainActor func stagedFixtureReassemblesExactTypedText() throws {
        let payload = TargetDelivery.scratchProofPayload
        let plan = try #require(ThreeStepPaste.plan(payload))
        #expect(plan.steps.joined() == payload)
        #expect(payload.hasSuffix("## Typed\n\n" + TargetDelivery.scratchProofTypedText))
        #expect(TargetDelivery.scratchProofTypedText.hasPrefix("  "))
        #expect(TargetDelivery.scratchProofTypedText.hasSuffix("  "))
        #expect(TargetDelivery.scratchProofTypedText.contains("\n"))
    }

    @Test func guidanceDistinguishesTypedAuthorshipFromSpeechAndGeneration() {
        #expect(RecommendedSkill.text.contains("`## Typed`"))
        #expect(RecommendedSkill.text.contains("user-authored, not spoken or model-generated"))
        #expect(RecommendedSkill.text.contains("Preserve its exact characters and line breaks"))
    }
}

