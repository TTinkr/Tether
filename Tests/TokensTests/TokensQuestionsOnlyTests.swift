


//
import Combine
import Foundation
import Testing
@testable import Tokens

@MainActor private final class QuestionsOnlyProbe: TokensThinkingProvider {
    var warmed: [String] = []
    var calls: [(TokensThinkingLane, String)] = []
    var pauseBeforeReply = false

    func installedModels() async -> Set<String>? { ["qwen3.5:0.8b", "qwen3.5:4b"] }
    func warm(model: String) async { warmed.append(model) }
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]],
                maxTokens: Int, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        let source = TokensThinkingStream.transcript(inUserMessage: messages.last?["content"] ?? "")
        calls.append((lane, source))
        if pauseBeforeReply { try await Task.sleep(nanoseconds: 300_000_000) }
        onDelta("Who builds the landing page?\nWhat does pricing include?\nWhen does the free tier end?\n")
    }
}

@Suite(.serialized) struct TokensQuestionsOnlyTests {
    @MainActor private static func waitUntil(_ done: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return done()
    }

    @Test @MainActor func promptAndValidation() {
        let prompt = TokensThinkingStream.questionsSystem
        #expect(prompt.contains("three short, distinct questions"))
        #expect(prompt.contains("Never predict"))
        #expect(!TokensThinkingStream.questionsExample.1.contains("→"))
        let source = "build the landing page and decide pricing for the free tier"
        let raw = "→ what comes next…\nWho builds the landing page?\nWhat does pricing include?\nWhen does the free tier end?\n"
        let parsed = TokensThinkingStream.display(.questions, raw: raw, source: source, final: true)
        #expect(parsed.text == "Who builds the landing page?\nWhat does pricing include?\nWhen does the free tier end?")
        let partial = TokensThinkingStream.display(.questions, raw: "→ landing page…\nWho builds the landing", source: source, final: false)
        #expect(partial.text.isEmpty)
        let previous = (1...12).map { "Earlier question \($0)?" }
        let messages = TokensThinkingStream.messages(.questions, transcript: source, previousQuestions: previous)
        let context  = messages[messages.count - 2]["content"] ?? ""
        #expect(context.contains("Earlier question 12?"))
        #expect(!context.contains("Earlier question 1?"))
        #expect(TokensThinkingStream.transcript(inUserMessage: messages.last?["content"] ?? "") == source)
    }

    @Test @MainActor func defaultUsesOnlyQuestionsAndRestartsAfterNewWords() async {
        let probe  = QuestionsOnlyProbe()
        let stream = TokensThinkingStream(provider: probe)
        stream.begin()
        #expect(await Self.waitUntil { stream.availability == .ready && !probe.warmed.isEmpty })
        #expect(probe.warmed == ["qwen3.5:0.8b"])
        let first = "build the landing page and decide pricing for the free tier"
        stream.pauseBegan(transcript: first)
        #expect(await Self.waitUntil { stream.questions.state == .done })
        #expect(probe.calls.count == 1 && probe.calls[0].0 == .questions)
        #expect(stream.questions.generation == 1)
        #expect(stream.questions.sourceWords == TokensThinkingStream.wordCount(first))
        #expect(stream.recentQuestions.count == 3)
        #expect(stream.reflection.state == .idle)
        #expect(!stream.holdsReflectionModel)
        stream.speechResumed()
        stream.pauseBegan(transcript: first)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(probe.calls.count == 1)
        let second = first + " after the microphone testing tomorrow"
        stream.speechResumed()
        stream.pauseBegan(transcript: second)
        #expect(await Self.waitUntil { stream.questions.generation == 2 && stream.questions.state == .done })
        #expect(probe.calls.count == 2 && probe.calls[1].1 == second)
        #expect(stream.questions.sourceWords == TokensThinkingStream.wordCount(second))
        #expect(probe.calls.allSatisfy { $0.0 == .questions })
        stream.end()
        stream.begin()
        #expect(stream.recentQuestions.isEmpty)
        stream.end()
    }

//
// :)
//
//
    @Test @MainActor func speechCancelsAnAudiblePauseImmediately() async {
        let probe              = QuestionsOnlyProbe()
        probe.pauseBeforeReply = true
        let stream             = TokensThinkingStream(provider: probe)
        stream.begin()
        #expect(await Self.waitUntil { stream.availability == .ready })
        stream.pauseBegan(transcript: "build the landing page and decide pricing for the free tier")
        #expect(await Self.waitUntil { probe.calls.count == 1 })
        stream.observe(pauseSeconds: nil, estimated: false, rmsDB: -20,
                       transcript: "build the landing page and decide pricing for the free tier", host: 10)
        #expect(stream.questions.state == .kept)
        #expect(stream.reflection.state == .idle)
        try? await Task.sleep(nanoseconds: 350_000_000)
        #expect(stream.questions.text.isEmpty)
        stream.end()
    }
}

