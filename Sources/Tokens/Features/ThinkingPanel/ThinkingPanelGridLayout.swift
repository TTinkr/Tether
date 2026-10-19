


//
import AppKit

/// Glyph positions remain TextKit positions; only the visible ink is centered in each cell.
final class ThinkingGridLayout: NSLayoutManager, NSLayoutManagerDelegate {
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange range: NSRange) -> Int {
        var fixed = Array(UnsafeBufferPointer(start: properties, count: range.length))
        /*
        Ordinary text layout hangs/truncates trailing spaces. A paper cell must instead
        occupy its full width and wrap, without replacing U+0020 in the real string.
        */
        for index in fixed.indices { fixed[index].remove(.elastic) }
        setGlyphs(glyphs, properties: fixed, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let source     = storage.string as NSString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var index      = characters.location
        while index < NSMaxRange(characters), index < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: index)
            let char  = source.substring(with: range)
            let glyph = glyphIndexForCharacter(at: range.location)
            if NSLocationInRange(glyph, glyphsToShow), !char.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                var attrs = storage.attributes(at: range.location, effectiveRange: nil)
                attrs.removeValue(forKey: .kern)
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let x    = location(forGlyphAt: glyph).x
                var ink  = NSAttributedString(string: char, attributes: attrs)
                var size = ink.size()
                if size.width > ThinkingGridPaper.side - 2 || size.height > ThinkingGridPaper.side - 2 {
                    let scale = min((ThinkingGridPaper.side - 2) / size.width, (ThinkingGridPaper.side - 2) / size.height)
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: ThinkingGridPaper.font.pointSize * scale, weight: .regular)
                    ink = NSAttributedString(string: char, attributes: attrs); size = ink.size()
                }
                ink.draw(at: NSPoint(x: origin.x + line.minX + x + (ThinkingGridPaper.side - size.width) / 2,
                                     y: origin.y + line.minY + (ThinkingGridPaper.side - size.height) / 2))
            }
            index = NSMaxRange(range)
        }
    }
}


// ThinkingGridTextView — literal-space input, scrolling paper and full-cell wrapping


final class ThinkingGridTextView: NSTextView {
    var onComposition: (() -> Void)?
    var onEditCompleted: (() -> Void)?
    private var editDepth = 0
    var isPerformingEdit: Bool { editDepth > 0 }
    private func finishEdit() {
        editDepth -= 1
        if editDepth == 0 { onEditCompleted?() }
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        editDepth += 1
        defer { finishEdit() }
        super.insertText(string, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        onComposition?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func keyDown(with event: NSEvent) {
        editDepth += 1
        defer { finishEdit() }
        /*
        A graph-paper space is a literal cell. The macOS input context can turn
        two spaces into a period even with text replacement disabled.
        Keep composed text and keyboard shortcuts on the normal input path.
        */
        if isEditable, !hasMarkedText(), event.characters == " ",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        super.keyDown(with: event)
    }

//
// :)
//
//
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let path   = NSBezierPath(); path.lineWidth = 0.5
        let firstX = floor(rect.minX / ThinkingGridPaper.side) * ThinkingGridPaper.side
        let firstY = floor(rect.minY / ThinkingGridPaper.side) * ThinkingGridPaper.side
        var x      = firstX
        while x <= rect.maxX { path.move(to: NSPoint(x: x, y: rect.minY)); path.line(to: NSPoint(x: x, y: rect.maxY)); x += ThinkingGridPaper.side }
        var y = firstY
        while y <= rect.maxY { path.move(to: NSPoint(x: rect.minX, y: y)); path.line(to: NSPoint(x: rect.maxX, y: y)); y += ThinkingGridPaper.side }
        NSColor.labelColor.withAlphaComponent(0.14).setStroke(); path.stroke()
    }
    override func didChangeText() {
        super.didChangeText()
        ThinkingGridPaper.rule(self)
    }
    override func unmarkText() {
        super.unmarkText()
        ThinkingGridPaper.rule(self)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Full cells only. Wrapping changes column count, never cell dimensions or source text.
        textContainer?.containerSize.width = max(ThinkingGridPaper.side, floor(newSize.width / ThinkingGridPaper.side) * ThinkingGridPaper.side)
    }
}

