
import Foundation
import Testing
@testable import Tokens

struct ClaudeCaretSpaceAckTests {
    // Existing draft with two single line breaks; the caret sits at its end.
    let draft = "Fix the login page\nThen check the tests\nThanks"
    var caretAtEnd: NSRange { NSRange(location: (draft as NSString).length - 2, length: 0) }

    func check(before: String? = nil, caret: NSRange? = nil, inserted: String, after: String,
               newCaret: Int?, claude: Bool = true, rich: Bool = true) -> PasteAcknowledgement.Result {
        let start = caret ?? caretAtEnd
        return PasteAcknowledgement.evaluate(before: before ?? draft, selection: start, inserted: inserted,
            after: after, caret: newCaret.map { NSRange(location: $0, length: 0) },
            richComposer: rich, caretSkipsLineBreaks: claude)
    }

    @Test func appendAfterADraftWithLineBreaksVerifies() {
        let words = " and ship it tonight"
        let caret = caretAtEnd.location + (words as NSString).length
        #expect(check(inserted: words, after: draft + words, newCaret: caret) == .verified)
        // Without the Claude flag the same readback is the old textMismatch.
        #expect(check(inserted: words, after: draft + words, newCaret: caret, claude: false) == .textMismatch)
    }

    @Test func insertionInsideTheDraftVerifiesAtTheMappedIndex() {
        // Caret after "Then check" on line two: value index 29, caret space 28 (one break before it).
        let words = " carefully"
        let after = (draft as NSString).replacingCharacters(in: NSRange(location: 29, length: 0), with: words)
        #expect(check(caret: NSRange(location: 28, length: 0), inserted: words, after: after,
                      newCaret: 28 + (words as NSString).length) == .verified)
    }

    @Test func everyOtherShapeStillFails() {
        let words = " and ship it tonight"
        let caret = caretAtEnd.location + (words as NSString).length
        // Wrong or missing text.
        #expect(check(inserted: words, after: draft + " and ship it", newCaret: caret) == .textMismatch)
        #expect(check(inserted: words, after: draft + words + "!", newCaret: caret) == .textMismatch)
        // Inserted at the very start: far before the caret, which skips only two breaks.
        #expect(check(inserted: words, after: words + draft, newCaret: caret) == .textMismatch)
        // Caret not where the paste should leave it.
        #expect(check(inserted: words, after: draft + words, newCaret: caret - 1) == .caretMismatch)
        #expect(check(inserted: words, after: draft + words, newCaret: nil) == .unreadableCaret)
        // Multi-line pastes are accepted since 2026-10-18 (lineBreakFreeClaudePaste), only exactly placed.
        #expect(check(inserted: " one\ntwo", after: draft + " one\ntwo",
                      newCaret: caretAtEnd.location + 7) == .verified)
        #expect(check(inserted: " one\ntwo", after: draft + " one\ntwo",
                      newCaret: caretAtEnd.location + 8) == .caretMismatch)
        // A selection being replaced never reaches this rule (the ordinary exact check handles it).
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: draft, caretOffset: NSRange(location: 0, length: 3),
                                                                inserted: "Mend", after: "Mend" + draft) == nil)
        // Plain (non-rich) fields never use it.
        #expect(check(inserted: words, after: draft + words, newCaret: caret, rich: false) == .textMismatch)
    }

    /// Codex QA of b2c1196: a lost, added or moved line break must fail; the shapes UX review's live
    /// Claude pastes produced (empty box, draft plus paste, placeholder line break gone) still pass.
    @Test func lineBreaksAreComparedExactlyOnlyThePlaceholderMayGo() {
        func ack(_ before: String, caret: Int, _ inserted: String, _ after: String, newCaret: Int?) -> PasteAcknowledgement.Result {
            PasteAcknowledgement.evaluate(before: before, selection: NSRange(location: caret, length: 0), inserted: inserted,
                after: after, caret: newCaret.map { NSRange(location: $0, length: 0) }, richComposer: true,
                caretSkipsLineBreaks: true)
        }
        let paste = "Hello there.\n[thinking 1.84s] more words\n— π [181 wpm, 8.63s, 40 characters]"
        let pasteCount = paste.utf16.filter { $0 != 10 }.count
        // Live shapes: empty composer (placeholder "\n"), and a draft whose placeholder goes.
        #expect(ack("\n", caret: 0, paste, paste, newCaret: pasteCount) == .verified)
        #expect(ack("Draft \n", caret: 6, paste, "Draft " + paste, newCaret: 6 + pasteCount) == .verified)
        #expect(ack("Draft \n", caret: 6, paste, "Draft " + paste + "\n", newCaret: 6 + pasteCount) == .verified)
        #expect(ack("\n", caret: 0, paste, paste, newCaret: pasteCount + 2) == .caretMismatch)
        // Codex's three counterexamples are no longer verified.
        #expect(ack("alpha\nbeta", caret: 9, "!", "alphabeta!", newCaret: 10) != .verified)
        #expect(ack("\n", caret: 0, paste, paste.replacingOccurrences(of: "\n— π", with: " — π"),
                    newCaret: pasteCount) != .verified)
        #expect(ack("// note\nlet x = 1\n", caret: 16, " ok", "// note let x = 1 ok\n", newCaret: 19) != .verified)
    }

    @Test func aDraftWithoutLineBreaksBehavesExactlyAsBefore() {
        let plain = "One line draft"
        let start = NSRange(location: (plain as NSString).length, length: 0)
        let words = " more"
        for claude in [true, false] {
            #expect(PasteAcknowledgement.evaluate(before: plain, selection: start, inserted: words, after: plain + words,
                caret: NSRange(location: start.location + 5, length: 0), richComposer: true,
                caretSkipsLineBreaks: claude) == .verified)
        }
    }

    @Test func helperMapsTheCaretDeterministically() {
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "a\nb", caretOffset: NSRange(location: 2, length: 0),
                                                                inserted: "X", after: "a\nbX") == 3)
        // A caret past the end of the text maps nowhere.
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "a\nb", caretOffset: NSRange(location: 3, length: 0),
                                                                inserted: "X", after: "a\nbX") == nil)
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "ab", caretOffset: NSRange(location: 2, length: 0),
                                                                inserted: "", after: "ab") == nil)
        // Line end and next-line start are the one ambiguity: either is accepted, never both.
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "a\nb", caretOffset: NSRange(location: 1, length: 0),
                                                                inserted: "X", after: "aX\nb") == 1)
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "a\nb", caretOffset: NSRange(location: 1, length: 0),
                                                                inserted: "X", after: "a\nXb") == 2)
    }

    @Test func codexMiddleOffsetCounterexampleIsRejected() {
        // Caret 4 in "a\nb\ncd" maps to value index 6; an insertion at 5 must not verify.
        #expect(PasteAcknowledgement.evaluate(before: "a\nb\ncd", selection: NSRange(location: 4, length: 0),
            inserted: "X", after: "a\nb\ncXd", caret: NSRange(location: 5, length: 0),
            richComposer: true, caretSkipsLineBreaks: true) != .verified)
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "a\nb\ncd", caretOffset: NSRange(location: 4, length: 0),
                                                                inserted: "X", after: "a\nb\ncXd") == nil)
        // The correct landing at the mapped index does verify.
        #expect(PasteAcknowledgement.evaluate(before: "a\nb\ncd", selection: NSRange(location: 4, length: 0),
            inserted: "X", after: "a\nb\ncdX", caret: NSRange(location: 5, length: 0),
            richComposer: true, caretSkipsLineBreaks: true) == .verified)
    }

    @Test func repeatedTextResolvesToTheMappedIndexOnly() {
        // "\naa" + "a" at caret 1 — the mapped index is 2 (after the first "a").
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "\naa", caretOffset: NSRange(location: 1, length: 0),
                                                                inserted: "a", after: "\naaa") == 2)
    }

    @Test func largeRepeatedDraftStaysLinear() {
        // Many leading line breaks and repeated patterns; must answer quickly.
        let n = 4000
        let pattern = String(repeating: "a", count: n - 1) + "b"
        let lines = String(repeating: "\n", count: n)
        let before = lines + pattern + pattern
        let start = ProcessInfo.processInfo.systemUptime
        let result = PasteAcknowledgement.lineBreakSkippingInsertion(before: before,
            caretOffset: NSRange(location: n, length: 0), inserted: pattern, after: lines + pattern + pattern + pattern)
        #expect(result == n + n)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.25)
    }

    // Leadership verifier cases (2026-10-14).
    func claude(_ before: String, _ selection: Int, _ inserted: String, _ after: String, caret: Int,
                flag: Bool = true) -> PasteAcknowledgement.Result {
        PasteAcknowledgement.evaluate(before: before, selection: NSRange(location: selection, length: 0),
            inserted: inserted, after: after, caret: NSRange(location: caret, length: 0),
            richComposer: true, caretSkipsLineBreaks: flag)
    }

    @Test func consecutiveLineBreaksSpanTheCandidateRun() {
        let before = "a\n\nb"
        for (after, index) in [("aX\n\nb", 1), ("a\nX\nb", 2), ("a\n\nXb", 3)] {
            #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: before,
                caretOffset: NSRange(location: 1, length: 0), inserted: "X", after: after) == index)
            #expect(claude(before, 1, "X", after, caret: 2) == .verified)
        }
    }

    @Test func caretBeyondTheTextIsNotMappedByTheClaudeRule() {
        // Skip-all caret space for "a\nb" ends at 2; offset 3 maps nowhere in the new rule.
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "a\nb",
            caretOffset: NSRange(location: 3, length: 0), inserted: "X", after: "a\nbX") == nil)
        // The pre-existing exact identity rule is unchanged: only its own caret (4) verifies.
        #expect(claude("a\nb", 3, "X", "a\nbX", caret: 5) != .verified)
        #expect(claude("a\nb", 3, "X", "a\nbX", caret: 4) == claude("a\nb", 3, "X", "a\nbX", caret: 4, flag: false))
    }

    @Test func crlfDraftsAreLeftToTheExactRule() {
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "ab\r\ncd",
            caretOffset: NSRange(location: 4, length: 0), inserted: "X", after: "ab\r\ncdX") == nil)
        #expect(claude("ab\r\ncd", 4, "X", "ab\r\ncdX", caret: 5) == .textMismatch)
    }

    @Test func surrogatePairsCountAsUTF16Units() {
        let inserted = "\u{1F44D}\u{1F3FD} done"
        #expect((inserted as NSString).length == 9)
        #expect(claude("a\nb", 2, inserted, "a\nb" + inserted, caret: 11) == .verified)
        #expect(claude("a\nb", 2, inserted, "a\nb" + inserted, caret: 10) == .caretMismatch)
    }

    @Test func repeatedTextVerifiesAtTheMappedIndex() {
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: "\naa",
            caretOffset: NSRange(location: 1, length: 0), inserted: "a", after: "\naaa") == 2)
        #expect(claude("\naa", 1, "a", "\naaa", caret: 2) == .verified)
    }

    @Test func emptyComposerIsUnchangedWithTheFlagOnOrOff() {
        #expect(claude("", 0, "hello", "hello", caret: 5) == .verified)
        #expect(claude("", 0, "hello", "hello", caret: 5, flag: false) == .verified)
    }

    @Test func longLineBreakPrefixWithRepeatsFindsTheRightIndex() {
        let lines = String(repeating: "\n", count: 2048)
        let pattern = String(repeating: "ab", count: 300) + "c"
        let before = lines + pattern + pattern
        let caretOffset = (pattern as NSString).length
        #expect(PasteAcknowledgement.lineBreakSkippingInsertion(before: before,
            caretOffset: NSRange(location: caretOffset, length: 0), inserted: pattern,
            after: lines + pattern + pattern + pattern) == 2048 + caretOffset)
    }
}
