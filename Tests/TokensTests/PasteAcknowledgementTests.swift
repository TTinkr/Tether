

import Foundation
import Testing
@testable import Tokens

struct PasteAcknowledgementTests {
    @Test func mismatchShapeNamesPunctuationButNeverWords() {
        let shape = PasteAcknowledgement.mismatchShape(before: "\n", selection: NSRange(location: 0, length: 0),
            inserted: "Hello there\n\n---\n\nMore 42", after: "Hello there\n\n\n\nMore 42\n")
        #expect(shape.contains("diff_line=2"))
        #expect(shape.contains("removed=[---]"))
        #expect(!shape.contains("Hello") && !shape.contains("More") && !shape.contains("42"))
        let words = PasteAcknowledgement.mismatchShape(before: "", selection: NSRange(location: 0, length: 0),
            inserted: "Secret 7", after: "")
        #expect(words.contains("removed=[aaaaaas9]"))
        #expect(!words.contains("Secret"))
    }

    @Test func exactReplacementAndUTF16Caret() {
        #expect(PasteAcknowledgement.evaluate(before: "hello old!", selection: NSRange(location: 6, length: 3),
            inserted: "🌱", after: "hello 🌱!", caret: NSRange(location: 8, length: 0)) == .verified)
        #expect(PasteAcknowledgement.evaluate(before: "", selection: NSRange(location: 0, length: 0),
            inserted: "🌱", after: "🌱", caret: NSRange(location: 1, length: 0)) == .caretMismatch)
    }
    @Test func partialAndNormalizedWhitespaceNeverVerify() {
        let body = "First thought.\n\n<thinking duration=\"1.5531s\"/>\n\nNext thought."
        for actual in ["First thought.", body + body, body.replacingOccurrences(of: "\n\n", with: "\n")] {
            #expect(PasteAcknowledgement.evaluate(before: "", selection: NSRange(location: 0, length: 0),
                inserted: body, after: actual, caret: NSRange(location: (actual as NSString).length, length: 0)) == .textMismatch)
        }
        #expect(PasteAcknowledgement.evaluate(before: "", selection: NSRange(location: 0, length: 0),
            inserted: body, after: body, caret: NSRange(location: (body as NSString).length, length: 0)) == .verified)
    }
    @Test func missingAndMovedCaretAreDistinct() {
        for (caret, expected) in [(nil, PasteAcknowledgement.Result.unreadableCaret),
                                  (NSRange(location: 2, length: 0), .caretMismatch),
                                  (NSRange(location: 3, length: 1), .caretMismatch)] {
            #expect(PasteAcknowledgement.evaluate(before: "", selection: NSRange(location: 0, length: 0),
                inserted: "abc", after: "abc", caret: caret) == expected)
        }
        #expect(PasteAcknowledgement.evaluate(before: "", selection: NSRange(location: 0, length: 0),
            inserted: "abc", after: nil, caret: nil) == .unreadableValue)
    }
    @Test func invalidSelectionFailsWithoutOverflowOrException() {
        for range in [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
                      NSRange(location: Int.max, length: Int.max), NSRange(location: 1, length: Int.max)] {
            #expect(PasteAcknowledgement.evaluate(before: "abc", selection: range, inserted: "x",
                after: "x", caret: nil) == .invalidSelection)
        }
    }
}
