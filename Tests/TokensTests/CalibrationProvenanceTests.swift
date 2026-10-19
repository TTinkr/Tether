


//
import Foundation
import Testing
import TokensCore
@testable import Tokens


@Suite struct CalibrationProvenanceTests {
    @Test func structuralCalibrationKeepsLiteralSpokenHeadingsAndExcludesOtherText() {
        let spoken = "say this\n## Typed\nand continue speaking"
        let authored = AuthoredPrompt(transcript: "## Transcript\n\n" + spoken,
                                      spokenText: spoken, typed: "TYPED_SENTINEL should never enter")
        let rendered = authored.presented(over: "> *AI question:* GENERATED_SENTINEL\n\n" + authored.transcript)
        let entry = PromptHistoryEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: 1000),
                                       text: rendered, authored: authored)
        let input = TinkeringPrompts.calibrationInput(entries: [entry])
        #expect(input.count == 1)
        #expect(input.text.hasSuffix("say this ## Typed and continue speaking"))
        #expect(!input.text.contains("TYPED_SENTINEL"))
        #expect(!input.text.contains("GENERATED_SENTINEL"))
    }

    @Test func legacyEntriesKeepExistingTupleInputBehavior() {
        let date            = Date(timeIntervalSince1970: 1000)
        let text            = "# π Legacy\n\n> *2s · 4 words · 120 wpm*\n\nlegacy spoken words here"
        let entry           = PromptHistoryEntry(id: UUID(), createdAt: date, text: text)
        let legacy          = TinkeringPrompts.calibrationInput(history: [(date: date, text: text)])
        let structuralRoute = TinkeringPrompts.calibrationInput(entries: [entry])
        #expect(structuralRoute.text == legacy.text)
        #expect(structuralRoute.count == legacy.count)
        #expect(structuralRoute.text.hasSuffix("legacy spoken words here"))
    }

    @Test func structuralCalibrationStillBoundsAndSortsItsInput() {
        let entries = (0..<80).map { index in
            PromptHistoryEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: Double(index)),
                authored: AuthoredPrompt(transcript: "unused", spokenText: "saved spoken entry \(index)"))
        }
        let input = TinkeringPrompts.calibrationInput(entries: entries)
        #expect(input.count == TinkeringPrompts.maximumEntries)
        #expect(input.text.split(separator: "\n").first?.hasSuffix("saved spoken entry 79") == true)
        #expect(input.text.split(separator: "\n").last?.hasSuffix("saved spoken entry 40") == true)
        let emptySpeech = PromptHistoryEntry(id: UUID(), createdAt: Date(),
            authored: AuthoredPrompt(transcript: "", spokenText: "", typed: "three typed words"))
        #expect(TinkeringPrompts.calibrationInput(entries: [emptySpeech]).count == 0)
    }

    @Test @MainActor func accumulatedQuestionsRetainNewestSixtyAndRespectRollback() {
        let state   = ThinkingPanelState()
        state.notes = " user text \n"
        for generation in 1...70 {
            state.receive(.init(text: "Question \(generation)?", state: .done,
                                model: "fixture", generation: generation))
        }
        let lines = state.question.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 60)
        #expect(lines.first == "Question 11?" && lines.last == "Question 70?")
        #expect(state.batches.count == 60)
        state.receive(.init(text: "Question 69?", state: .kept, model: "fixture", generation: 69))
        #expect(!state.question.contains("Question 70?"))
        #expect(state.question.hasSuffix("Question 69?"))
        #expect(state.notes == " user text \n")
        state.beginSession()
        #expect(state.batches.isEmpty && state.notes == " user text \n")
    }

    @Test @MainActor func oneLargeQuestionBatchCannotBypassTheLineBound() {
        let state = ThinkingPanelState()
        let lines = (1...90).map { "Question \($0)?" }
        state.receive(.init(text: lines.joined(separator: "\n"), state: .streaming,
                            model: "fixture", generation: 1))
        #expect(state.batches.count == 1)
        #expect(state.question.components(separatedBy: "\n").count == 60)
        #expect(state.question.hasPrefix("Question 31?\n"))
        #expect(state.question.hasSuffix("Question 90?"))
    }
}

