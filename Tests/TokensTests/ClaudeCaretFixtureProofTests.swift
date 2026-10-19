import Foundation
import Testing
@testable import Tokens

@Suite struct ClaudeCaretFixtureProofTests {
    @Test func guardRequiresExactKnownFixtureAndCollapsedValidCaret() throws {
        let text = try #require(ClaudeCaretFixtureProof.fixture("two-lines"))
        #expect(ClaudeCaretFixtureProof.permits(id: "two-lines", value: text, range: CFRange(location: 3, length: 0)))
        #expect(!ClaudeCaretFixtureProof.permits(id: "unknown", value: text, range: CFRange(location: 0, length: 0)))
        #expect(!ClaudeCaretFixtureProof.permits(id: "two-lines", value: text + "private", range: CFRange(location: 0, length: 0)))
        for range in [CFRange(location: -1, length: 0), CFRange(location: 0, length: 1), CFRange(location: text.utf16.count + 1, length: 0)] {
            #expect(!ClaudeCaretFixtureProof.permits(id: "two-lines", value: text, range: range))
        }
        let emoji = try #require(ClaudeCaretFixtureProof.fixture("blank-line-emoji"))
        #expect(!ClaudeCaretFixtureProof.permits(id: "blank-line-emoji", value: emoji, range: CFRange(location: 11, length: 0)))
    }
    @Test func coordinateModelsRemainDistinctAndNeverExposeText() {
        let result = ClaudeCaretFixtureProof.comparisons(before: "a\n\nb", location: 1,
            after: "a\n\n" + ClaudeCaretFixtureProof.payload + "b", caret: CFRange(location: 8, length: 0))
        #expect(result["identity_value"] as? Bool == false)
        #expect(result["skip_lf_right_biased_diagnostic_value"] as? Bool == true)
        #expect(result["append_value"] as? Bool == false)
        #expect(result.values.allSatisfy { !($0 is String) })
    }
    @Test func canonicalEquivalenceIsNotExactUTF16Evidence() {
        #expect("é" == "e\u{301}")
        #expect(!ClaudeCaretFixtureProof.exact("é", "e\u{301}"))
        let result = ClaudeCaretFixtureProof.comparisons(before: "é", location: 1,
            after: "e\u{301}" + ClaudeCaretFixtureProof.payload, caret: nil)
        #expect(result["identity_value"] as? Bool == false)
        #expect(result["append_value"] as? Bool == false)
        let ambiguous = ClaudeCaretFixtureProof.comparisons(before: "a\n\nb", location: 1, after: "", caret: nil)
        #expect(ambiguous["skip_lf_inverse_boundary_count"] as? Int == 3)
        #expect(ambiguous["skip_lf_mapping_ambiguous"] as? Bool == true)
    }
    @Test func freshOutputGuardPreservesExistingFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("sentinel".utf8)
        try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        #expect(LocalSpeechFixtureProof.reserveReceipt(input: "/__tokens_claude_fixture_no_input__", output: file.path) == nil)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(LocalSpeechFixtureProof.reserveReceipt(input: "/unused", output: "relative.json") == nil)
    }
}
