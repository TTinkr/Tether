

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

@Suite struct ClaudeMultiLinePasteTests {
    // UX review: Claude counts carets without line breaks; multi-line pastes must still verify.
    static let talk = "Oh good\n[thinking 1.91s] it shows\n— π [147 wpm, 89.14s, 18 characters]"
    static func skip(_ s: String) -> Int { s.utf16.filter { $0 != 10 }.count }
    static func check(_ before: String, at: Int, after: String, caret: Int) -> PasteAcknowledgement.Result {
        PasteAcknowledgement.evaluate(before: before, selection: NSRange(location: at, length: 0), inserted: talk,
            after: after, caret: NSRange(location: caret, length: 0), richComposer: true, caretSkipsLineBreaks: true)
    }

    @Test func emptyComposerAndTypedDraftBothVerify() {
        // Measured: empty Claude composer reads "\n"; caret after the paste skips its line breaks.
        #expect(Self.check("\n", at: 0, after: Self.talk, caret: Self.skip(Self.talk)) == .verified)
        let draft = "typed line one\nline two\n"
        let after = "typed line one\nline two\n\n" + Self.talk  // Claude adds a break at the join
        #expect(Self.check(draft, at: Self.skip(draft), after: after, caret: Self.skip(after)) == .verified)
    }

    @Test func wrongCharactersPlaceOrCaretStillFail() {
        let draft = "typed line\n"
        let at = Self.skip(draft)
        #expect(Self.check(draft, at: at, after: draft + Self.talk.replacingOccurrences(of: "good", with: "god"),
                           caret: at + Self.skip(Self.talk) - 1) != .verified)
        #expect(Self.check(draft, at: 0, after: draft + Self.talk, caret: at + Self.skip(Self.talk)) != .verified)
        #expect(Self.check(draft, at: at, after: draft + Self.talk, caret: at + Self.skip(Self.talk) - 3) == .caretMismatch)
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: NSRange(location: at, length: 0), inserted: Self.talk,
            after: draft + "\n" + Self.talk, caret: NSRange(location: at + Self.skip(Self.talk), length: 0),
            richComposer: true, caretSkipsLineBreaks: false) != .verified)
    }
}
