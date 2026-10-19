


//
import AppKit
import CoreText
import SwiftUI


// TokensWritingBox — A ruled box to write in


/// A ruled box to write in. The text inside is a real text view, one line of writing per grid row.
struct TokensWritingBox: View {
    @Binding var text: String
    var editable = true
    var bordered = true
    let label: String
    var startsAtFirstRule = false

    // The text view measures its first glyph baseline. Its origin is aligned to the same
    // paper coordinate space as surrounding controls; no guessed top inset is necessary.
    var body: some View {
        TokensPencilEditor(text: $text, editable: editable, label: label, startsAtFirstRule: startsAtFirstRule)
            // Hide only descenders from the preceding, scrolled-out line at the viewport edge.
            .mask { Rectangle().padding(.top, 8) }
            .padding(.bottom, 8)
            .background {
                if bordered {
                    Rectangle().stroke(TokensUI.rule, lineWidth: 1)
                }
            }
            .tokensPaperAligned()
    }

}


// TokensPencilEditor — multi-line pencil text view ruled to the grid, one line per row


/// Multi-line pencil writing in a real text view, ruled to the grid: one line of text per grid row.
struct TokensPencilEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    let label: String
    var startsAtFirstRule = false

    // The coordinator carries the text view's edits back out through the binding.
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        /*
        Real AppKit text view in a scroll view: transparent so the paper shows through, a vertical
        scroller that hides itself, no horizontal scrolling, and line-scroll steps of one square.
        Editing is plain text only, with undo on; smart quotes, smart dashes, text replacement and
        spelling auto-correction are switched off so the stored text is exactly what was typed.
        */
        let scroll                   = NSTextView.scrollableTextView()
        scroll.drawsBackground       = false
        scroll.borderType            = .noBorder
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers    = true
        scroll.verticalLineScroll    = TokensUI.paperCell
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        // TextKit also scrolls automatically after edits and window/zoom changes. A ruled
        // clip view constrains those paths as well as wheel scrolling to whole paper rows.
        scroll.documentView = nil
        let ruledClip = TokensPaperClipView()
        ruledClip.drawsBackground = false
        scroll.contentView = ruledClip
        scroll.documentView = view
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.insertionPointColor = TokensInk.primary.nsColor
        view.selectedTextAttributes = [.backgroundColor: TokensInk.secondary.nsColor.withAlphaComponent(0.2)]
        /*
        Paragraph height follows the printed 56-point paper cell. The first baseline inset
        is measured with TextKit using the identical font and paragraph attributes.
        */
        view.textContainerInset = NSSize(width: 0, height: Self.firstBaselineInset)
        view.textContainer?.lineFragmentPadding = TokensUI.module / 2
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.usesFontLeading = false
        view.defaultParagraphStyle = Self.paragraph
        view.typingAttributes      = Self.attributes
        /*
        Hook-up: the Coordinator becomes the delegate (so it hears every edit), the caption passed
        in becomes the accessibility label, and the starting text goes in and gets the pencil style
        from `rule`. The observer registered after that calls Coordinator.settle when a scroll ends.
        */
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label)
        view.string = text
        Self.rule(view)
        if startsAtFirstRule {
            // Keep trailing caret clearance while showing the first line without an empty row.
            DispatchQueue.main.async { [weak scroll, weak view] in
                guard let scroll, let view, let container = view.textContainer else { return }
                view.layoutManager?.ensureLayout(for: container)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: TokensUI.paperCell))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.settle(_:)),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        return scroll
    }

//
// :)
//
//
    /*
    SwiftUI to AppKit: the text view is only written to when its text really differs from the
    binding, so an edit that just came from the view is not pushed back into it.
    */
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        Self.rule(view)
    }

    // Every line is forced to exactly one square tall (minimum and maximum line height are equal).
    private static let paragraph: NSParagraphStyle = {
        let style               = NSMutableParagraphStyle()
        style.minimumLineHeight = TokensUI.paperCell
        style.maximumLineHeight = TokensUI.paperCell
        return style
    }()

    /// TextKit supplies the real first baseline for the same font and paragraph style used
    /// by the editor. The inset puts it on the first printed rule, including empty editors.
    static var firstBaselineInset: CGFloat {
        let storage = NSTextStorage(string: "Ag", attributes: attributes)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.usesFontLeading = false
        layout.ensureLayout(for: container)
        let baseline = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
            + layout.location(forGlyphAt: 0).y
        // One extra top/bottom row leaves caret and descender clearance at the document end.
        return TokensUI.paperCell + max(0, TokensUI.paperCell - baseline)
    }

    private static var attributes: [NSAttributedString.Key: Any] {
        var attributes              = TokensTypesetter.attributes(size: 15, ink: .primary)
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    /*
    Re-applies the pencil font, ink and fixed line height to ALL the text and to what is typed
    next, so pasted or replaced text cannot bring in another look.
    */
    fileprivate static func rule(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        view.typingAttributes = attributes
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        /*
        Called after every edit. The pencil style is re-applied unless an input-method composition is
        in progress (marked text), then the new text is copied out to the binding if it differs.
        */
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if !view.hasMarkedText() { TokensPencilEditor.rule(view) }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
        }

        /// When scrolling stops, rest on a whole square so the writing is back on the lines.
        @objc func settle(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView else { return }
            let clip  = scroll.contentView
            let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            let y     = min((clip.bounds.origin.y / TokensUI.paperCell).rounded() * TokensUI.paperCell, limit)
            guard abs(y - clip.bounds.origin.y) > 0.01 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}


/// Programmatic caret scrolling and scrollbar drags use this same constraint. Always choose
/// a valid whole-row offset; trailing editor inset keeps the final line above the clipped edge.
final class TokensPaperClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        let limit = max(0, (documentView?.frame.height ?? 0) - bounds.height)
        let lastRule = floor(limit / TokensUI.paperCell) * TokensUI.paperCell
        rect.origin.y = min(lastRule, max(0, (rect.origin.y / TokensUI.paperCell).rounded() * TokensUI.paperCell))
        return rect
    }
}

// TokensHistoryText — pulls a saved talk's own words and word count out of its text


/// What a saved dictation says, without the receipt wrapper around it.
enum TokensHistoryText {
    /*
    New entries carry authorship explicitly. Do not feed the combined Markdown
    back into the legacy parser: literal headings can be spoken or typed text.
    */
    static func preview(_ entry: PromptHistoryEntry) -> String {
        guard let authored = entry.authored else { return preview(entry.text) }
        return authored.spokenText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

//
// :)
//
//
    static func words(_ entry: PromptHistoryEntry) -> Int {
        entry.authored?.spokenWordCount ?? words(entry.text)
    }

    /*
    Matches the "· 8 words ·" part of the receipt's counts line, for example
    "42 characters · 8 words · 3.1s · 155 wpm".
    */
    private static let wordCount = try! NSRegularExpression(pattern: "· (\\d+) words? ·")

    /*
    Keeps only the spoken words: everything after "## Your words" and before the first "---" line,
    with blank lines, "*Thinking" lines (the measured thinking pauses), "# " title lines and "> "
    lines removed, joined into one line separated by spaces.
    */
    static func preview(_ text: String) -> String {
        var body = text
        if body.hasPrefix("# π\n") { body = String(body.dropFirst("# π\n".count)) }
        else if let start = body.range(of: "## Transcript") ?? body.range(of: "## Your words") { body = String(body[start.upperBound...]) }
        if let end = body.range(of: "\n---") { body = String(body[..<end.lowerBound]) }
        return ThinkingComposer.removingAnnotations(body).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") && !$0.hasPrefix(">") && !$0.hasPrefix("— π (") }
            .joined(separator: " ")
    }

    /*
    Reads the word count straight from the receipt. The receipt sits in the closing "# Metadata"
    block (the last 400 characters) and, in entries saved before 2026-10-03, under the title
    (the first 400). If there is none, it counts the words of preview() instead.
    */
    static func words(_ text: String) -> Int {
        for edge in [String(text.suffix(400)), String(text.prefix(400))] {
            if let match = wordCount.firstMatch(in: edge, range: NSRange(edge.startIndex..., in: edge)),
               let range = Range(match.range(at: 1), in: edge), let count = Int(edge[range]) {
                return count
            }
        }
        return preview(text).split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}

