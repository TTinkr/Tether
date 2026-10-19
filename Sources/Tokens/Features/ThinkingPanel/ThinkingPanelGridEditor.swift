


//
import AppKit
import SwiftUI

struct ThinkingPanelGridEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let label: String
    var spacing: ThinkingPadSpacing.Repair? = nil
    var spacingEpoch = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll    = ThinkingGridPaper.make(editable: editable)
        let view      = scroll.documentView as! NSTextView
        context.coordinator.attach(view)
        view.setAccessibilityLabel(label)
        view.string = text
        ThinkingGridPaper.rule(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if context.coordinator.parent.spacingEpoch != spacingEpoch {
            context.coordinator.spacing.cancel()
        }
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { context.coordinator.spacing.cancel() }
        ThinkingGridPaper.update(view, in: scroll, text: text, editable: editable)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.spacing.cancel()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ThinkingPanelGridEditor
        let spacing = ThinkingPadSpacing()
        private var suppressCompletedEdit = false
        func attach(_ view: NSTextView) {
            view.delegate = self
            (view as? ThinkingGridTextView)?.onComposition = { [weak self] in self?.spacing.cancel() }
            (view as? ThinkingGridTextView)?.onEditCompleted = { [weak self, weak view] in
                guard let self, let view else { return }
                self.schedule(view)
            }
        }
        private func schedule(_ view: NSTextView) {
            if suppressCompletedEdit { suppressCompletedEdit = false; return }
            spacing.changed(view, repair: parent.spacing) { [weak self] text in self?.parent.text = text }
        }
        init(_ parent: ThinkingPanelGridEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard parent.editable, let view = notification.object as? NSTextView,
                  !view.hasMarkedText() else { return }
            /*
            Composition stays in TextKit until committed; the binding never sees a partial candidate.
            A user commit wins over an external update that arrived while composition was active.
            */
            if parent.text != view.string { parent.text = view.string }
            if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
                suppressCompletedEdit = (view as? ThinkingGridTextView)?.isPerformingEdit == true
                spacing.cancel()
                return
            }
            /*
            TextKit may publish a selection change after textDidChange. Schedule only
            after the enclosing native edit ends so that change cannot cancel this edit.
            */
            if (view as? ThinkingGridTextView)?.isPerformingEdit != true { schedule(view) }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if !spacing.applying { spacing.cancel() }
        }
        func textDidEndEditing(_ notification: Notification) {
            spacing.cancel()
        }
    }
}

//
// :)
//
//
// ThinkingGridPaper — shared cell metrics, attributes and native update rules


/// TextKit keeps editing, selection, undo and IME; one grapheme advances one paper cell.
enum ThinkingGridPaper {
    /*
    Updates never replace marked text. Normal binding updates retry after composition commits;
    no delayed external value is allowed to silently overwrite a newly committed user edit.
    */
    static func update(_ view: NSTextView, in scroll: NSScrollView, text: String, editable: Bool) {
        guard !view.hasMarkedText(), view.string != text else { return }
        let selection = view.selectedRange()
        let previous  = view.string
        let visible   = scroll.contentView.bounds
        let followEnd = view.string.isEmpty || visible.maxY >= view.bounds.maxY - ThinkingGridPaper.side
        view.string   = text
        ThinkingGridPaper.rule(view)
        let length           = (text as NSString).length
        let updatedSelection = editable ? ThinkingGridPaper.selection(selection, from: previous, to: text)
            : NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
        view.setSelectedRange(updatedSelection)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        if !editable && followEnd { view.scrollRangeToVisible(NSRange(location: length, length: 0)) }
    }
    static let side: CGFloat = 24
    static let font          = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static var attributes: [NSAttributedString.Key: Any] {
        let p                = NSMutableParagraphStyle()
        p.minimumLineHeight  = side; p.maximumLineHeight = side
        p.lineBreakMode      = .byCharWrapping
        p.defaultTabInterval = side * 4
        return [.font: font, .foregroundColor: NSColor.labelColor,
                .ligature: 0, .paragraphStyle: p]
    }

    /// External text changes keep an end caret at the end and suffix selections attached to their text.
    /// This maps UTF-16 selection offsets only; it never repairs or changes the supplied characters.
    static func selection(_ selection: NSRange, from old: String, to new: String) -> NSRange {
        let before = Array(old.utf16), after = Array(new.utf16)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        func anchor(_ offset: Int, followsInsertion: Bool) -> Int {
            /*
            At a pure insertion the prefix end and suffix start are the same offset. Selection
            starts belong to the suffix, ends to the prefix; a caret follows the inserted text.
            Checking the prefix first would accidentally select the newly inserted characters.
            */
            if offset == prefix, prefix == before.count - suffix {
                return followsInsertion ? offset + after.count - before.count : offset
            }
            if offset >= before.count { return after.count }
            if offset <= prefix { return offset }
            if offset >= before.count - suffix { return offset + after.count - before.count }
            return min(offset, after.count - suffix)
        }
        let start = anchor(min(selection.location, before.count), followsInsertion: true)
        let end   = anchor(min(NSMaxRange(selection), before.count), followsInsertion: selection.length == 0)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func rule(_ view: NSTextView) {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return }
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        let text  = storage.string as NSString
        var index = 0
        while index < text.length {
            let range = text.rangeOfComposedCharacterSequence(at: index)
            let char  = text.substring(with: range)
            if char != "\n" && char != "\r" && char != "\r\n" && char != "\t" {
                let width = (char as NSString).size(withAttributes: attributes).width
                storage.addAttribute(.kern, value: side - width, range: range)
            }
            index = NSMaxRange(range)
        }
        storage.endEditing()
        var typing            = attributes
        typing[.kern]         = side - ("M" as NSString).size(withAttributes: attributes).width
        view.typingAttributes = typing
        view.needsDisplay     = true
    }

//
// :)
//
//
    static func make(editable: Bool) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = ThinkingGridLayout()
        let container = NSTextContainer(containerSize: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let text = ThinkingGridTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 200), textContainer: container)
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.drawsBackground = false; text.allowsUndo = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = .zero
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.smartInsertDeleteEnabled = false
        layout.usesFontLeading = false
        text.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        text.typingAttributes = attributes
        text.setFrameSize(text.frame.size)
        rule(text)
        let scroll                 = NSScrollView(frame: text.frame)
        scroll.documentView        = text; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers  = true; scroll.scrollerStyle = .overlay
        scroll.verticalLineScroll  = side
        return scroll
    }
}

