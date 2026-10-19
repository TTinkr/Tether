


//
import AppKit
import SwiftUI
import Testing
@testable import Tokens

@Suite(.serialized) @MainActor struct ThinkingGridEditorTests {
    private func editor(editable: Bool = true) throws -> (NSScrollView, ThinkingGridTextView) {
        let scroll = ThinkingGridPaper.make(editable: editable)
        let view   = try #require(scroll.documentView as? ThinkingGridTextView)
        return (scroll, view)
    }

    @Test func nativeEntryKeepsRepeatedSpacesReturnAndPunctuationLiteral() throws {
        let (_, view) = try editor()
        view.insertText("hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        /*
        Feed only the direct override, not the system event queue. This exercises c426f0a's fix without
        focus, a window or the system input context's double-space substitution preferences.
        */
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49))
        view.keyDown(with: space)
        view.keyDown(with: space)
        view.insertText("there", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertNewline(nil)
        view.insertText("\"quote\" -- e\u{301} 👩🏽‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "hi  there\n\"quote\" -- e\u{301} 👩🏽‍💻")
        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.smartInsertDeleteEnabled)
    }

    @Test func committedNativeChangesReachBindingWithoutNormalization() throws {
        var stored      = ""
        let binding     = Binding<String>(get: { stored }, set: { stored = $0 })
        let bridge      = ThinkingPanelGridEditor(text: binding, editable: true, label: "Test notes")
        let coordinator = bridge.makeCoordinator()
        let (_, view)   = try editor()
        view.delegate   = coordinator
        view.insertText("  exact\n\nwords  ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(stored == "  exact\n\nwords  ")
    }

    @Test func externalUpdatesPreserveSuffixSelectionAndEndCaret() throws {
        let (scroll, view) = try editor()
        let original       = "👩🏽‍💻 hello end"
        view.string        = original
        ThinkingGridPaper.rule(view)
        let selected = (original as NSString).range(of: "end")
        view.setSelectedRange(selected)
        let replacement = "👩🏽‍💻 hello new end"
        ThinkingGridPaper.update(view, in: scroll, text: replacement, editable: true)
        #expect(view.string == replacement)
        #expect(view.selectedRange() == (replacement as NSString).range(of: "end"))
        view.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        ThinkingGridPaper.update(view, in: scroll, text: replacement + "!", editable: true)
        #expect(view.selectedRange() == NSRange(location: (replacement as NSString).length + 1, length: 0))
        ThinkingGridPaper.update(view, in: scroll, text: "", editable: true)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func modelUpdatesLeaveReadOnlyQuestionSelectionStable() throws {
        let (scroll, view) = try editor(editable: false)
        ThinkingGridPaper.update(view, in: scroll, text: "first question", editable: false)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        ThinkingGridPaper.update(view, in: scroll, text: "first question\n\nnext question", editable: false)
        #expect(view.selectedRange() == NSRange(location: 0, length: 5))
        #expect(!view.isEditable && view.isSelectable)
        #expect(view.string == "first question\n\nnext question")
    }

    @Test func insertionBoundaryKeepsSelectedPrefixAndSuffixSeparate() {
        let before = "first last"
        let after  = "first new last"
        #expect(ThinkingGridPaper.selection(NSRange(location: 0, length: 6), from: before, to: after)
                == NSRange(location: 0, length: 6))
        #expect(ThinkingGridPaper.selection(NSRange(location: 6, length: 4), from: before, to: after)
                == NSRange(location: 10, length: 4))
        #expect(ThinkingGridPaper.selection(NSRange(location: 6, length: 0), from: before, to: after)
                == NSRange(location: 10, length: 0))
    }

//
// :)
//
//
    @Test func markedCompositionSurvivesExternalUpdateAndPublishesOnlyOnCommit() throws {
        var stored = ""
        let bridge = ThinkingPanelGridEditor(text: Binding(get: { stored }, set: { stored = $0 }),
                                            editable: true, label: "Composition")
        let coordinator    = bridge.makeCoordinator()
        let (scroll, view) = try editor()
        view.delegate      = coordinator
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        let candidate = view.string
        ThinkingGridPaper.update(view, in: scroll, text: "external replacement", editable: true)
        #expect(view.string == candidate)
        #expect(view.hasMarkedText())
        #expect(stored.isEmpty)
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(view.string == "日本")
        #expect(stored == "日本")
    }

    @Test func spacesOccupyCellsAndResizeWrapsWithoutChangingText() throws {
        let (_, view) = try editor()
        view.string   = "a  b\ncdef"
        ThinkingGridPaper.rule(view)
        view.setFrameSize(NSSize(width: 4 * ThinkingGridPaper.side + 11, height: 240))
        let container = try #require(view.textContainer)
        let layout    = try #require(view.layoutManager)
        layout.ensureLayout(for: container)
        #expect(container.containerSize.width == 4 * ThinkingGridPaper.side)
        #expect(!container.widthTracksTextView)
        let a           = position(character: 0, layout: layout)
        let firstSpace  = position(character: 1, layout: layout)
        let secondSpace = position(character: 2, layout: layout)
        #expect(abs(firstSpace.x - a.x - ThinkingGridPaper.side) < 0.1)
        #expect(abs(secondSpace.x - firstSpace.x - ThinkingGridPaper.side) < 0.1)
        #expect(abs(position(character: 5, layout: layout).y - a.y - ThinkingGridPaper.side) < 0.1)
        let original  = view.string
        let selection = NSRange(location: 3, length: 0)
        view.setSelectedRange(selection)
        view.setFrameSize(NSSize(width: 2 * ThinkingGridPaper.side + 9, height: 240))
        layout.ensureLayout(for: container)
        #expect(container.containerSize.width == 2 * ThinkingGridPaper.side)
        #expect(position(character: 3, layout: layout).y > a.y)
        #expect(view.string == original)
        #expect(view.selectedRange() == selection)
    }

    @Test func gridAttributesPreserveComposedCharactersAndTabs() throws {
        let (_, view) = try editor()
        let original  = "e\u{301}👩🏽‍💻\t日本\r\n  "
        view.string   = original
        ThinkingGridPaper.rule(view)
        #expect(view.string == original)
        let style = try #require(view.defaultParagraphStyle)
        #expect(style.minimumLineHeight == ThinkingGridPaper.side)
        #expect(style.maximumLineHeight == ThinkingGridPaper.side)
        #expect(style.defaultTabInterval == ThinkingGridPaper.side * 4)
        let storage      = try #require(view.textStorage)
        let firstCluster = (original as NSString).rangeOfComposedCharacterSequence(at: 0)
        #expect(firstCluster.length == 2)
        #expect(storage.attribute(.kern, at: 0, effectiveRange: nil) != nil)
    }

    @Test func composedCharacterInkAdvancesOneCell() throws {
        let (_, view) = try editor()
        view.string   = "e\u{301}👩🏽‍💻日"
        ThinkingGridPaper.rule(view)
        view.setFrameSize(NSSize(width: 240, height: 240))
        let layout    = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let source    = view.string as NSString
        let first     = source.rangeOfComposedCharacterSequence(at: 0)
        let second    = source.rangeOfComposedCharacterSequence(at: NSMaxRange(first))
        let starts    = [first.location, second.location, NSMaxRange(second)]
        let positions = starts.map { position(character: $0, layout: layout) }
        #expect(abs(positions[1].x - positions[0].x - ThinkingGridPaper.side) < 0.1)
        #expect(abs(positions[2].x - positions[1].x - ThinkingGridPaper.side) < 0.1)
        #expect(positions.allSatisfy { abs($0.y - positions[0].y) < 0.1 })
    }

//
// :)
//
//
    private func position(character: Int, layout: NSLayoutManager) -> NSPoint {
        let glyph    = layout.glyphIndexForCharacter(at: character)
        let line     = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layout.location(forGlyphAt: glyph)
        return NSPoint(x: line.minX + location.x, y: line.minY + location.y)
    }
}

