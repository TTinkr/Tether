


//
/*
ThinkingQuestionPagesTests.swift
Owns: accumulated question/cancellation and typed-note delivery boundaries.
Never: use a microphone, show a window, or write to another app.
*/


import AppKit
import SwiftUI
import Testing
import TokensCore
@testable import Tokens

@Suite(.serialized) struct ThinkingQuestionPagesTests {
    @Test @MainActor func growingQuestionsKeepEarlierPauses() {
        let state = ThinkingPanelState()
        state.receive(.init(text: "Who finishes the landing page?\nWhat does pricing include?\nWhen does the launch begin?",
                            state: .done, model: "fixture", generation: 1, sourceWords: 22))
        let first = state.question
        state.receive(.init(text: first, state: .waiting, model: "fixture", generation: 1, sourceWords: 22))
        #expect(state.batches.count == 1)
        state.receive(.init(text: "Who finishes the landing page?\nWhich launch", state: .streaming,
                            model: "fixture", generation: 2, sourceWords: 35))
        #expect(state.question.hasPrefix(first))
        #expect(state.batches.count == 2)
        state.receive(.init(text: "Who finishes the landing page?\nWhich launch needs the pricing page?\nWhen does pricing change?",
                            state: .done, model: "fixture", generation: 2, sourceWords: 35))
        #expect(state.batches.count == 2)
        #expect(state.question.components(separatedBy: "Who finishes the landing page?").count == 2)
        #expect(state.question.hasSuffix("When does pricing change?"))
    }

    @Test @MainActor func cancellationRemovesUnfinishedBatchAndSessionPreservesNotes() {
        let state = ThinkingPanelState()
        let complete = TokensThinkingLaneOutput(text: "When is the launch?", state: .done, model: "fixture", generation: 1)
        state.receive(complete)
        state.receive(.init(text: "Which launch", state: .streaming, model: "fixture", generation: 2))
        var rollback   = complete
        rollback.state = .kept
        state.receive(rollback)
        #expect(state.batches.count == 1)
        #expect(state.question == complete.text)
        state.notes = "Keep the free tier."
        state.beginSession()
        #expect(state.batches.isEmpty)
        #expect(state.notes == "Keep the free tier.")
    }

    @Test func notesStaySeparateAndPreserveText() {
        let words = "# π Launch\n\n> *12.0000s · 9 words*\n\n## Transcript\n\num, launch launch no next week after the review."
        let notes = "Keep the free tier.\n\n- check pricing\n"
        #expect(ThinkingNotes.appending(notes, to: words) == words + "\n\n## Typed\n\n" + notes)
        #expect(ThinkingNotes.appending(" \n", to: words) == words + "\n\n## Typed\n\n \n")
        #expect(ThinkingNotes.appending("", to: words) == words)
        let plan = ThreeStepPaste.plan(ThinkingNotes.appending(notes, to: words))
        #expect(plan != nil)
        #expect(plan?.steps.joined() == ThinkingNotes.appending(notes, to: words))
        let legacyWords = words.replacingOccurrences(of: "## Transcript", with: "## Your words")
        #expect(ThreeStepPaste.plan(ThinkingNotes.appending(notes, to: legacyWords))?.steps.joined() == ThinkingNotes.appending(notes, to: legacyWords))
    }

    @Test func historyPreviewAndCountUseSpokenProvenance() {
        let spoken = "say this\n## Typed\nand continue"
        let authored = AuthoredPrompt(transcript: "## Transcript\n\n" + spoken,
                                      spokenText: spoken, typed: "Tinker  stays typed \n\n")
        let entry = PromptHistoryEntry(id: UUID(), createdAt: Date(), authored: authored)
        #expect(TokensHistoryText.preview(entry) == "say this ## Typed and continue")
        #expect(TokensHistoryText.words(entry) == 6)
        #expect(entry.text.hasSuffix("Tinker  stays typed \n\n"))
        let typedOnly = PromptHistoryEntry(id: UUID(), createdAt: Date(),
            authored: AuthoredPrompt(transcript: "", spokenText: "", typed: "not spoken"))
        #expect(TokensHistoryText.preview(typedOnly).isEmpty)
        #expect(TokensHistoryText.words(typedOnly) == 0)
    }

    @Test func gripResizingKeepsTopLeftAndBounds() {
        let initial = NSRect(x: 200, y: 200, width: 560, height: 364)
        let screen  = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let minimum = NSSize(width: 72, height: 52)
        let maximum = NSSize(width: 1000, height: 650)
        let larger = ThinkingResizeGeometry.frame(original: initial, delta: NSSize(width: 100, height: -100),
            minimum: minimum, maximum: maximum, visible: screen)
        #expect(larger.size == NSSize(width: 660, height: 464))
        #expect(larger.minX == initial.minX && larger.maxY == initial.maxY)
        let tiny = ThinkingResizeGeometry.frame(original: initial, delta: NSSize(width: -9999, height: 9999),
            minimum: minimum, maximum: maximum, visible: screen)
        #expect(tiny.size == minimum && tiny.maxY == initial.maxY)
        let limited = ThinkingResizeGeometry.frame(original: initial, delta: NSSize(width: 9999, height: -9999),
            minimum: minimum, maximum: maximum, visible: screen)
        #expect(limited.maxX <= screen.maxX && limited.minY >= screen.minY)
    }

//
// :)
//
//
    @Test func defaultPanelMatchesDisplayProportions() {
        let display = CGSize(width: 1512, height: 982)
        let size    = ThinkingPanelGeometry.expandedSize(screen: display)
        #expect(abs(size.width / size.height - display.width / display.height) < 0.001)
        #expect(size.width < display.width && size.height < display.height)
        let fallback = ThinkingPanelGeometry.expandedSize(screen: .zero)
        #expect(fallback.width.isFinite && fallback.height > 0)
    }
}

