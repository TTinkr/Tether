


//
/*
Owns: regressions found in the pinned legacy-to-rebuild semantic audit.
Never: open a microphone, contact a model, show UI or change saved user settings.
See: TalkModel+Transcript.swift; ThinkingStream+Execution.swift; ThinkingComposer.swift.
*/

import Foundation
import Testing
@testable import Tokens


// A controlled stream intentionally ignores cancellation to exercise stale callbacks.


@MainActor private final class ParityQuestionProvider: TokensThinkingProvider {
    struct Call {
        let emit: @MainActor (String) -> Void
        let finish: CheckedContinuation<Void, Never>
    }
    var calls: [Call] = []
    func installedModels() async -> Set<String>? { [] }
    func warm(model: String) async {}
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]],
                maxTokens: Int, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        await withCheckedContinuation { continuation in
            calls.append(Call(emit: onDelta, finish: continuation))
        }
    }
}

@Suite(.serialized) struct LegacyParityRegressionTests {
    @MainActor private static func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @MainActor private static func ready(_ provider: ParityQuestionProvider) -> TokensThinkingStream {
        let stream = TokensThinkingStream(provider: provider)
        // Avoid even a model availability probe: these tests own the in-memory session.
        stream.availability = .ready
        stream.installed    = [stream.tuning.questionsModel]
        stream.sessionOpen  = true
        return stream
    }

    @Test func brandCorrectionDoesNotUnplaceMeasuredSilence() {
        let raw   = "i am using the tinker bubble and then i stopped"
        let words = timed(raw, starts: [0, 0.2, 0.4, 0.6, 0.8, 1.0, 3.9, 4.1, 4.3, 4.5])
        let placement = ThinkingComposer.placement(raw: raw, words: words,
            pauses: [ThinkingPause(start: 1.5, end: 3.8)])
        #expect(placement.unplaced.isEmpty && placement.segments.count == 2)
        let reference = CharacterTalk.render(BrandVocabulary.apply(to: raw)).markdownText
        #expect(reference != raw)
        // Use the exact app segment renderer, not a copied correction in this test.
        let body = ThinkingComposer.body(placement.segments, unplaced: placement.unplaced,
                                         paragraphs: TalkModel.thinkingSegmentText)
        #expect(body.contains("\n\nTHINK (2.3000s)\n\n"))
        #expect(LexicalFidelity.preservesWords(raw: reference,
            formatted: ThinkingComposer.removingAnnotations(body)))
        #expect(TalkModel.thinkingSegmentText("talk characters R I L E Y end talk characters")
            .contains("<char>RILEY</char>"))
    }

    @Test func savedPauseGrammarsStayProtectedAndOutOfSpokenReaders() {
        let annotations = ["THINK (2.3500s)",
            "THINK (unplaced ×1 · 2.3500s · measured silence, position not aligned to words)",
            "THINK unplaced ×1 (2.3500s) · measured silence, position not aligned to words",
            "*Thinking · 2.350 s*",
            "*Thinking · unplaced ×1 · 2.350 s · measured silence, position not aligned to words*"]
        for line in annotations {
            #expect(ThinkingComposer.isAnnotation(line))
            #expect(ThinkingComposer.removingAnnotations("before\n" + line + "\nafter") == "before\nafter")
            #expect(TokensDecoration.render(body: line) == line)
        }
        let spoken = "I said THINK (2.3500s) out loud\nTHINK about the launch\nTHINK (2.35s)"
        #expect(ThinkingComposer.removingAnnotations(spoken) == spoken)
    }

//
// :)
//
//
    @Test @MainActor func completedQuestionsNeedFiveNewWords() async {
        let provider = ParityQuestionProvider()
        let subject  = Self.ready(provider)
        let source   = "build the landing page and decide pricing for the free tier"
        subject.pauseBegan(transcript: source)
        #expect(await Self.settled { provider.calls.count == 1 })
        guard provider.calls.count == 1 else { return }
        provider.calls[0].emit("Who builds the landing page?\n")
        provider.calls[0].finish.resume()
        #expect(await Self.settled { subject.runtime[.questions]?.job == nil })
        #expect(subject.runtime[.questions]?.askedWords == TokensThinkingStream.wordCount(source))
        subject.speechResumed()
        subject.pauseBegan(transcript: source + " after the microphone test")
        #expect(subject.runtime[.questions]?.job == nil)
        subject.pauseBegan(transcript: source + " after the microphone test tomorrow")
        #expect(await Self.settled { provider.calls.count == 2 })
        guard provider.calls.count == 2 else { return }
        provider.calls[1].emit("When does the free tier end?\n")
        provider.calls[1].finish.resume()
        #expect(await Self.settled { subject.runtime[.questions]?.job == nil })
        subject.end()
    }

    @Test @MainActor func interruptedSetRetainsCompleteQuestionsAndRetriesSameWords() async {
        let provider = ParityQuestionProvider()
        let stream   = Self.ready(provider)
        let source   = "build the landing page and decide pricing for the free tier"
        stream.pauseBegan(transcript: source)
        #expect(await Self.settled { provider.calls.count == 1 })
        guard provider.calls.count == 1 else { return }
        provider.calls[0].emit("Who builds the landing page?\nWhat does pricing")
        stream.speechResumed()
        #expect(stream.questions.text == "Who builds the landing page?")
        #expect(stream.recentQuestions == ["Who builds the landing page?"])
        #expect(stream.runtime[.questions]?.askedWords == 0)
        stream.pauseBegan(transcript: source)
        #expect(await Self.settled { provider.calls.count == 2 })
        guard provider.calls.count == 2 else { provider.calls[0].finish.resume(); return }
        provider.calls[0].emit(" include?\nWhen does the free tier end?\n")
        provider.calls[0].finish.resume()
        provider.calls[1].emit("Who builds the landing page?\nWhat does pricing include?\n")
        provider.calls[1].finish.resume()
        #expect(await Self.settled { stream.runtime[.questions]?.job == nil })
        #expect(stream.recentQuestions == ["Who builds the landing page?", "What does pricing include?"])
        #expect(!stream.questions.text.contains("free tier"))
        #expect(stream.runtime[.questions]?.askedWords == TokensThinkingStream.wordCount(source))
        stream.end()
    }

    @Test @MainActor func unusableCompletionDoesNotLoopButNewWordsCanRetry() async {
        let provider = ParityQuestionProvider()
        let stream   = Self.ready(provider)
        let source   = "build the landing page and decide pricing for the free tier"
        stream.pauseBegan(transcript: source)
        #expect(await Self.settled { provider.calls.count == 1 })
        guard provider.calls.count == 1 else { return }
        provider.calls[0].emit("An unrelated statement, not a grounded question.\n")
        provider.calls[0].finish.resume()
        #expect(await Self.settled { stream.runtime[.questions]?.job == nil })
        #expect(stream.runtime[.questions]?.askedWords == 0)
        #expect(stream.runtime[.questions]?.failures == 1)
        #expect(stream.recentQuestions.isEmpty)
        // A clean unusable answer must not spin on repeated pauses of identical text.
        stream.speechResumed()
        stream.pauseBegan(transcript: source)
        #expect(stream.runtime[.questions]?.job == nil)
        #expect(provider.calls.count == 1)
        // The five-word cadence applies after a usable set, not an empty result.
        stream.pauseBegan(transcript: source + " tomorrow")
        #expect(await Self.settled { provider.calls.count == 2 })
        guard provider.calls.count == 2 else { return }
        provider.calls[1].emit("Who builds the landing page?\n")
        provider.calls[1].finish.resume()
        #expect(await Self.settled { stream.runtime[.questions]?.job == nil })
        #expect(stream.runtime[.questions]?.failures == 0)
        #expect(stream.runtime[.questions]?.askedWords == TokensThinkingStream.wordCount(source) + 1)
        stream.end()
    }

//
// :)
//
//
    @Test @MainActor func repeatedQuestionsKeepOnlyNineContextLines() async {
        let provider = ParityQuestionProvider()
        let stream = Self.ready(provider)
        let names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "omega"]
        var source = "the launch includes " + names.joined(separator: " ")
        for (index, name) in names.enumerated() {
            source += " and the launch continues tomorrow"
            stream.pauseBegan(transcript: source)
            #expect(await Self.settled { provider.calls.count == index + 1 })
            guard provider.calls.count == index + 1 else { return }
            provider.calls[index].emit("When is the \(name) launch?\n")
            provider.calls[index].finish.resume()
            #expect(await Self.settled { stream.runtime[.questions]?.job == nil })
            stream.speechResumed()
        }
        #expect(stream.recentQuestions.count == 9)
        #expect(stream.recentQuestions.first == "When is the delta launch?")
        #expect(stream.recentQuestions.last == "When is the omega launch?")
        stream.end()
    }
}


// Generated notation is distinct from literal user text and from stored history.
struct CharacterTagTests {
    @Test func generatedSpellingUsesCharTags() {
        let rendered = CharacterTalk.render("My name is talk characters R I L E Y end talk characters.")
        #expect(rendered.markdownText == "My name is *<char>RILEY</char>*.")
        #expect(rendered.deliveryText == "My name is RILEY.")
        #expect(TokensDecoration.render(body: rendered.markdownText).contains("<char>RILEY</char>"))
        #expect(CharacterTalk.render("A L E X").markdownText == "*<char>ALEX</char>*")
        #expect(CharacterTalk.render("talk characters R I L E Y").markdownText == "*<char>RILEY</char>*")
    }
    @Test func literalTagsAndCodeRemainExact() {
        for literal in ["<char>R I L E Y</char>", "<TC> RILEY </TC>", "`<TC> RILEY </TC>`", "```\nR I L E Y\n```", "<char>R I L E Y"] {
            let rendered = CharacterTalk.render(literal)
            #expect(rendered.markdownText == literal)
            #expect(rendered.deliveryText == literal)
        }
    }
    @Test func newTagsSurvivePausePresentationAndHistoryReading() {
        let body = CharacterTalk.render("R I L E Y").markdownText + "\n\nTHINK (1.2500s)\n\ncontinues"
        let presented = InlineTalkMarkdown.render(body)
        #expect(presented == "*<char>RILEY</char>*\n*[pause 1.2500]* continues")
        #expect(InlineTalkMarkdown.removingMarkers(presented).split(whereSeparator: \.isWhitespace).joined(separator: " ") == "*<char>RILEY</char>* continues")
        #expect(InlineTalkMarkdown.removingMarkers("<TC> RILEY </TC> — (TK-1.2500s) — continues") == "<TC> RILEY </TC> continues")
    }
}
