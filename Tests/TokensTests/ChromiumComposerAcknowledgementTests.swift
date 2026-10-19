
import Foundation
import Testing
@testable import Tokens

struct ChromiumComposerAcknowledgementTests {
    static let placeholder = "Ask Codex anything"
    static let prompt = "# π Blue notebook\n\n## Transcript\n\nThe fictional notebook stays by the lamp."
    static func caret(_ n: Int) -> NSRange { NSRange(location: n, length: 0) }
    static func len(_ s: String) -> Int { (s as NSString).length }

    // Measured shape A: before_utf16 = placeholder + "\n", caret 0/0, after == inserted.
    @Test func emptyComposerPlaceholderPlusBreakIsEmpty() {
        let raw = Self.placeholder + "\n"
        let snapshot = EditorValueSnapshot(raw: raw, placeholder: Self.placeholder,
                                           characterCount: Self.len(raw), selection: Self.caret(0), role: "AXTextArea",
                                           richComposer: true)
        #expect(snapshot.text == "")
        #expect(PasteAcknowledgement.evaluate(before: snapshot.text, selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt))) == .verified)
    }

    @Test func placeholderLookalikesStayDraftText() {
        let raw = Self.placeholder + "\n"
        var cases: [EditorValueSnapshot] = []
        cases.append(.init(raw: raw, placeholder: Self.placeholder, characterCount: 3, selection: Self.caret(0), role: "AXTextArea", richComposer: true))
        cases.append(.init(raw: raw, placeholder: Self.placeholder, characterCount: Self.len(raw), selection: Self.caret(1), role: "AXTextArea", richComposer: true))
        cases.append(.init(raw: raw + "\n", placeholder: Self.placeholder, characterCount: Self.len(raw) + 1, selection: Self.caret(0), role: "AXTextArea"))
        cases.append(.init(raw: raw, placeholder: nil, characterCount: Self.len(raw), selection: Self.caret(0), role: "AXTextArea"))
        cases.append(.init(raw: raw, placeholder: Self.placeholder, characterCount: Self.len(raw), selection: Self.caret(0), role: "AXGroup"))
        // The same shape in a native or plain web text field stays draft text.
        cases.append(.init(raw: raw, placeholder: Self.placeholder, characterCount: Self.len(raw), selection: Self.caret(0), role: "AXTextArea"))
        for item in cases { #expect(item.text == item.raw) }
    }

    // Measured shape C: before 300 / caret 299 (just before a final "\n"), after = before - 1 + inserted.
    @Test func pasteFillingTheEmptyLastLineVerifies() {
        let draft = "Earlier draft line.\n"
        let n = Self.len(draft)
        let after = "Earlier draft line." + Self.prompt
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 1), inserted: Self.prompt,
            after: after, caret: Self.caret(n - 1 + Self.len(Self.prompt)), richComposer: true) == .verified)
        // Measured empty composer without placeholder: before "\n", caret 0.
        #expect(PasteAcknowledgement.evaluate(before: "\n", selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .verified)
    }

    // a native or code editor that really loses a trailing line feed must not verify.
    @Test func nativeTrailingLineFeedLossStaysRejected() {
        let draft = "let x = 1\n"
        let n = Self.len(draft)
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 1), inserted: "// note",
            after: "let x = 1// note", caret: Self.caret(n - 1 + 7)) == .textMismatch)
        #expect(PasteAcknowledgement.evaluate(before: "\n", selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt))) == .textMismatch)
        // Exact native behaviour is unchanged: the line feed stays after the insertion.
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 1), inserted: "// note",
            after: "let x = 1// note\n", caret: Self.caret(n - 1 + 7)) == .verified)
    }

    @Test func anythingElseLostOrAddedNeverVerifies() {
        let draft = "Earlier draft line.\n"
        let n = Self.len(draft)
        let filled = "Earlier draft line." + Self.prompt
        // Caret not just before the final line break.
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 2), inserted: Self.prompt,
            after: filled, caret: Self.caret(Self.len(filled)), richComposer: true) == .textMismatch)
        // One more character lost (measured shape B: 478 inserted, 474 read back).
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 1), inserted: Self.prompt,
            after: String(filled.dropLast()), caret: Self.caret(Self.len(filled) - 1), richComposer: true) == .textMismatch)
        // Draft text gone.
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 1), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .textMismatch)
        // Doubled paste.
        #expect(PasteAcknowledgement.evaluate(before: "\n", selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt + Self.prompt, caret: Self.caret(2 * Self.len(Self.prompt)), richComposer: true) == .textMismatch)
        // Right text, caret elsewhere.
        #expect(PasteAcknowledgement.evaluate(before: "\n", selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(0), richComposer: true) == .caretMismatch)
    }

    // a real draft that literally equals the placeholder plus a line break is
    // misread as empty, but a paste can never delete it, so the readback can never verify.
    @Test func placeholderLookalikeDraftCanNeverFalselyVerify() {
        let raw = Self.placeholder + "\n"
        let snapshot = EditorValueSnapshot(raw: raw, placeholder: Self.placeholder, characterCount: Self.len(raw),
                                           selection: Self.caret(0), role: "AXTextArea", richComposer: true)
        let realAfter = Self.prompt + raw
        #expect(PasteAcknowledgement.evaluate(before: snapshot.text, selection: Self.caret(0), inserted: Self.prompt,
            after: realAfter, caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .textMismatch)
    }

    // A rich editor that keeps its trailing line feed verifies by the unchanged exact rule.
    @Test func richEditorKeepingTrailingLineFeedVerifiesExactly() {
        let draft = "Earlier draft line.\n"
        let n = Self.len(draft)
        let kept = "Earlier draft line." + Self.prompt + "\n"
        #expect(PasteAcknowledgement.evaluate(before: draft, selection: Self.caret(n - 1), inserted: Self.prompt,
            after: kept, caret: Self.caret(n - 1 + Self.len(Self.prompt)), richComposer: true) == .verified)
    }

    @Test func shapeFlagsCarryNoText() {
        let flags = PasteAcknowledgement.shapeFlags(before: "secret draft\n", selection: Self.caret(12),
                                                    inserted: Self.prompt, after: "secret draft" + Self.prompt)
        #expect(!flags.contains("secret") && !flags.contains("notebook"))
        #expect(flags.contains("after_eq_prefix_plus_inserted=true") && flags.contains("caret_before_final_lf=true"))
    }

    // Measured live 2026-10-12 (build 33): empty Codex composer, 18-character empty-state line
    // ending in a line feed, caret 0/0; after the paste the field reads exactly the pasted text.
    @Test func emptyStateLineReplacedByThePasteVerifies() {
        let emptyState = "Ask for follow-up\n"
        #expect(Self.len(emptyState) == 18)
        #expect(PasteAcknowledgement.evaluate(before: emptyState, selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .verified)
        // Not in a native field, not with the caret elsewhere, not if anything else remains.
        #expect(PasteAcknowledgement.evaluate(before: emptyState, selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt))) == .textMismatch)
        #expect(PasteAcknowledgement.evaluate(before: emptyState, selection: Self.caret(3), inserted: Self.prompt,
            after: Self.prompt, caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .textMismatch)
        #expect(PasteAcknowledgement.evaluate(before: emptyState, selection: Self.caret(0), inserted: Self.prompt,
            after: Self.prompt + "\n", caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .textMismatch)
        #expect(PasteAcknowledgement.evaluate(before: "real draft without break", selection: Self.caret(0),
            inserted: Self.prompt, after: Self.prompt, caret: Self.caret(Self.len(Self.prompt)), richComposer: true) == .textMismatch)
    }
}
