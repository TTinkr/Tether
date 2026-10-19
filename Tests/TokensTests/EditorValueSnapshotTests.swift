import Foundation
import Testing
@testable import Tokens

struct EditorValueSnapshotTests {
    private var empty: EditorValueSnapshot {
        .init(raw: "Describe your task", placeholder: "Describe your task", characterCount: 0,
              selection: NSRange(location: 0, length: 0), role: "AXTextArea")
    }
    @Test func onlyValidNumericCountsAreAccepted() {
        #expect(EditorValueSnapshot.declaredCharacterCount(NSNumber(value: 0)) == 0)
        #expect(EditorValueSnapshot.declaredCharacterCount(NSNumber(value: 18)) == 18)
        for value: Any in [NSNumber(value: false), NSNumber(value: -1), NSNumber(value: 0.5),
                           NSNumber(value: Double.infinity), "0", NSNull()] {
            #expect(EditorValueSnapshot.declaredCharacterCount(value) == nil)
        }
    }
    @Test func onlyExplicitEmptyPlaceholderBecomesEmpty() {
        #expect(empty.text == "")
        var literal = empty
        literal.characterCount = literal.raw.utf16.count
        #expect(literal.text == literal.raw)
        literal.characterCount = nil
        #expect(literal.text == literal.raw)
    }
    @Test func unknownOrInconsistentEvidencePreservesDraft() {
        var cases: [EditorValueSnapshot] = []
        var item = empty; item.placeholder = nil; cases.append(item)
        item = empty; item.placeholder = "different"; cases.append(item)
        item = empty; item.placeholder = "Describe your task "; cases.append(item)
        item = empty; item.characterCount = -1; cases.append(item)
        item = empty; item.selection = nil; cases.append(item)
        item = empty; item.selection = NSRange(location: 1, length: 0); cases.append(item)
        item = empty; item.selection = NSRange(location: 0, length: 1); cases.append(item)
        item = empty; item.role = "AXGroup"; cases.append(item)
        item = empty; item.role = nil; cases.append(item)
        for item in cases { #expect(item.text == item.raw) }
    }
    @Test func placeholderAwareBaselineStillRequiresExactFullInsertionAndCaret() {
        let baseline = empty.text
        #expect(PasteAcknowledgement.evaluate(before: baseline, selection: NSRange(location: 0, length: 0),
            inserted: "Hello 👋", after: "Hello 👋", caret: NSRange(location: 8, length: 0)) == .verified)
        #expect(PasteAcknowledgement.evaluate(before: baseline, selection: NSRange(location: 0, length: 0),
            inserted: "Hello 👋", after: "Hello", caret: NSRange(location: 5, length: 0)) == .textMismatch)
    }
}
