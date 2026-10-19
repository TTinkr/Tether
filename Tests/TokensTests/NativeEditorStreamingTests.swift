import Foundation
import Testing
@testable import Tokens

struct NativeEditorStreamingTests {
    @Test func preparedSeparatorRemainsInFirstStageAndAllBytesSurvive() throws {
        let payload = " # π\nThe blue notebook is beside the lamp and ready.\n\n---\n\n# Metadata\n"
        let plan = try #require(ThreeStepPaste.plan(payload))
        #expect(plan.steps.count == 3)
        #expect(plan.steps.first?.hasPrefix(" # π\n") == true)
        #expect(plan.steps.dropLast().joined().hasSuffix("The blue notebook is beside the "))
        #expect(plan.steps.joined() == payload)
        #expect(ThreeStepPaste.plan(" " + payload) == nil)
    }
    @Test func nativeFixtureCannotTargetUnownedTextOrWrongCaret() {
        let id = "native-fixture-example"
        let sentinel = NativeEditorFixtureProof.sentinel(id)
        let end = NSRange(location: sentinel.utf16.count, length: 0)
        for bundle in ["com.apple.TextEdit", "com.apple.Notes", "com.tinkr.testpad"] {
            #expect(NativeEditorFixtureProof.owned(bundle: bundle, id: id, value: sentinel, range: end))
            #expect(!NativeEditorFixtureProof.owned(bundle: bundle, id: id, value: sentinel + "existing words", range: end))
            #expect(!NativeEditorFixtureProof.owned(bundle: bundle, id: id, value: sentinel, range: NSRange(location: 0, length: 0)))
        }
        #expect(!NativeEditorFixtureProof.owned(bundle: "com.openai.codex", id: id, value: sentinel, range: end))
    }
}
