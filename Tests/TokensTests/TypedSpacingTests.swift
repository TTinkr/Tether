


//
import AppKit
import SwiftUI
import Testing
@testable import Tokens

@MainActor private final class SpacingTestView: NSTextView {
    let undo = UndoManager()
    override var undoManager: UndoManager? { undo }
}

@MainActor private final class SpacingProvider: TokensThinkingProvider {
    var output                  = "yo whats up"
    var installed: Set<String>? = ["qwen3.5:0.8b"]
    var calls                   = 0
    func installedModels() async -> Set<String>? { installed }
    func warm(model: String) async {}
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]],
                maxTokens: Int, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        calls += 1
        onDelta(output)
    }
}

@Suite(.serialized) @MainActor struct TypedSpacingTests {
    private func editor(_ text: String) -> SpacingTestView {
        let view        = SpacingTestView(frame: .zero)
        view.isEditable = true; view.allowsUndo = true
        view.string     = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return view
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }

    @Test func nativeDelegateSchedulesRepairAndPublishesVisibleText() async throws {
        var notes = ""
        let parent = ThinkingPanelGridEditor(text: Binding(get: { notes }, set: { notes = $0 }),
            editable: true, label: "Test notes", spacing: { _ in "yo whats up" })
        let coordinator           = parent.makeCoordinator()
        coordinator.spacing.delay = 1
        let scroll                = ThinkingGridPaper.make(editable: true)
        let view                  = try #require(scroll.documentView as? NSTextView)
        coordinator.attach(view)
        view.insertText("yowhatsup", replacementRange: NSRange(location: 0, length: 0))
        let deadline = Date().addingTimeInterval(2)
        while view.string != "yo whats up" && Date() < deadline { await settle() }
        #expect(view.string == "yo whats up")
        #expect(notes == view.string)
    }

    @Test func onlySpacesMayChangeIncludingUnicodeAndLineBreaks() {
        #expect(TypedSpacing.accepts(raw: "yowhatsup", proposal: "yo whats up"))
        #expect(TypedSpacing.accepts(raw: "h i h i", proposal: "hi hi"))
        #expect(!TypedSpacing.accepts(raw: "yowhatsup", proposal: "yo what is up"))
        #expect(!TypedSpacing.accepts(raw: "whatsup", proposal: "what's up"))
        #expect(!TypedSpacing.accepts(raw: "Hi", proposal: "hi"))
        #expect(!TypedSpacing.accepts(raw: "a\nb", proposal: "a b"))
        #expect(!TypedSpacing.accepts(raw: "a\tb", proposal: "a b"))
        #expect(!TypedSpacing.accepts(raw: "e\u{301}", proposal: "é"))
        #expect(TypedSpacing.accepts(raw: "👩🏽‍💻hi\nthere", proposal: "👩🏽‍💻 hi\nthere"))
    }

    @Test func automaticEditPublishesAndCanBeUndone() async {
        let view      = editor("yowhatsup"), repair = ThinkingPadSpacing()
        repair.delay  = 1
        var published = ""
        repair.changed(view, repair: { _ in "yo whats up" }) { published = $0 }
        await settle()
        #expect(view.string == "yo whats up")
        #expect(published == view.string)
        #expect(view.selectedRange().location == view.string.utf16.count)
        #expect(view.undo.canUndo)
        view.undo.undo()
        #expect(view.string == "yowhatsup")
    }

//
// :)
//
//
    @Test func newerTypingMovedSelectionAndCancellationWin() async {
        for mode in 0..<3 {
            let view     = editor("yowhatsup"), repair = ThinkingPadSpacing()
            repair.delay = 1
            var repairRequested = false
            repair.changed(view, repair: { _ in
                // Inject the newer interaction while the proposal is in flight.
                // Wall-clock sleeps cannot guarantee this ordering on a busy runner.
                if mode == 0 { view.string = "new words" }
                if mode == 1 { view.setSelectedRange(NSRange(location: 0, length: 0)) }
                if mode == 2 { repair.cancel() }
                repairRequested = true
                return "yo whats up"
            }) { _ in }
            let deadline = Date().addingTimeInterval(2)
            while !repairRequested && Date() < deadline { await settle() }
            #expect(repairRequested, "The mock repair must run before checking stale-result rejection")
            #expect(view.string == (mode == 0 ? "new words" : "yowhatsup"))
        }
    }

    @Test func compositionNeverGetsReplaced() async {
        let view     = editor("yowhatsup"), repair = ThinkingPadSpacing()
        repair.delay = 1
        repair.changed(view, repair: { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return "yo whats up"
        }) { _ in }
        try? await Task.sleep(nanoseconds: 5_000_000)
        view.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let marked = view.string
        await settle()
        #expect(view.hasMarkedText())
        #expect(view.string == marked)
    }

    @Test func longNotebookSendsOnlyCurrentLineAndKeepsEarlierText() async {
        let prefix    = String(repeating: "earlier note ", count: 100) + "\n"
        let view      = editor(prefix + "yowhatsup"), repair = ThinkingPadSpacing()
        repair.delay  = 1
        var requested = ""
        repair.changed(view, repair: { text in requested = text; return "yo whats up" }) { _ in }
        let deadline = Date().addingTimeInterval(2)
        while view.string == prefix + "yowhatsup" && Date() < deadline { await settle() }
        #expect(requested == "yowhatsup")
        #expect(view.string == prefix + "yo whats up")
    }

    @Test func localProposalMustPassInvariantAndUnavailableModelsDoNothing() async {
        let provider = SpacingProvider()
        let model    = "qwen3.5:0.8b"
        #expect(await TypedSpacing.repair("yowhatsup", provider: provider, model: model) == "yo whats up")
        provider.output = "yo what is up"
        #expect(await TypedSpacing.repair("yowhatsup", provider: provider, model: model) == nil)
        provider.installed = []
        #expect(await TypedSpacing.repair("yowhatsup", provider: provider, model: model) == nil)
        #expect(provider.calls == 2)
        provider.installed = [model + ":cloud"]
        #expect(await TypedSpacing.repair("yowhatsup", provider: provider, model: model + ":cloud") == nil)
        #expect(provider.calls == 2)
    }

    @Test func sessionAndDeliveryInvalidateSpacingAndRetainVisibleNotes() {
        let state   = ThinkingPanelState()
        state.notes = "yo whats up"
        let epoch   = state.spacingEpoch
        state.beginSession()
        #expect(state.spacingEpoch != epoch)
        let next = state.spacingEpoch
        #expect(state.consumeNotesForDelivery() == "yo whats up")
        #expect(state.spacingEpoch != next)
        #expect(state.notes.isEmpty)
    }

    @Test func multipleGapChangesKeepSelectionOnCharacters() {
        let old = "hihi whats up", new = "hi hi whatsup"
        #expect(TypedSpacing.selection(NSRange(location: 5, length: 8), from: old, to: new)
                == NSRange(location: 6, length: 7))
    }
}

