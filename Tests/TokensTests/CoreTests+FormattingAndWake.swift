


//
/*
CoreTests+FormattingAndWake.swift
Tokens · Tests

Owns: formatting, wake timing and frozen delivery targets
Never: changes the assertion order or weakens checks.
See: CoreTests.swift (ordered suite entry point).
*/


import Foundation
import Testing
@testable import Tokens


extension CoreTests {
    static func formattingAndWake(automaticCharacters: CharacterTalkRendering) throws {
        let longFirst = Array(repeating: "um I I meant seven not six", count: 10).joined(separator: " ") + "."
        let longSecond = "Also " + Array(repeating: "Claude Code keeps my exact words", count: 8).joined(separator: " ") + "."
        let longPrompt = longFirst + " " + longSecond
        let paragraphs = ParagraphFormatter.format(longPrompt)
        precondition(paragraphs == longFirst + "\n\n" + longSecond)
        precondition(ParagraphFormatter.format(paragraphs) == paragraphs)
        precondition(paragraphs.filter { !$0.isWhitespace } == longPrompt.filter { !$0.isWhitespace })
        let shortPrompt = "Um, I meant six. No, actually seven. Claude Code."
        precondition(ParagraphFormatter.format(shortPrompt) == shortPrompt)
        let fourSentences = "First I think aloud. Second I add a detail. Third I make a correction. Fourth I continue the thought."
        let fourSentenceParagraphs = "First I think aloud. Second I add a detail. Third I make a correction.\n\nFourth I continue the thought."
        precondition(ParagraphFormatter.format(fourSentences) == fourSentenceParagraphs)
        let sixSentences = "One is here. Two is here. Three is here. Four is here. Five is here. Six is here."
        let sixSentenceParagraphs = "One is here. Two is here. Three is here.\n\nFour is here. Five is here. Six is here."
        precondition(ParagraphFormatter.format(sixSentences) == sixSentenceParagraphs)
        precondition(ParagraphFormatter.format(sixSentenceParagraphs) == sixSentenceParagraphs)
        precondition(ParagraphFormatter.format("First thought.\nSecond thought.")
            == "First thought.\n\nSecond thought.")
        precondition(ParagraphFormatter.format("First thought.\n\nSecond thought.")
            == "First thought.\n\nSecond thought.")
        precondition(fourSentenceParagraphs.filter { !$0.isWhitespace } == fourSentences.filter { !$0.isWhitespace })
        let markdownDefaults = UserDefaults(suiteName: "TTTMarkdownTests-\(UUID().uuidString)")!
        precondition(TranscriptRenderMode.current(in: markdownDefaults) == .plain)
        markdownDefaults.set(TranscriptRenderMode.markdown.rawValue, forKey: TranscriptRenderMode.preferenceKey)
        precondition(TranscriptRenderMode.current(in: markdownDefaults) == .markdown)
        let markdownRaw = "um I think seven not six. No wait actually seven. Also Claude Code keeps my exact words 🧠."
        let markdown = MarkdownFormatter.format(markdownRaw, durationSeconds: 23, metadataEnabled: true)
        let markdownMetrics = TranscriptMetadata.line(for: markdownRaw, durationSeconds: 23)!
        precondition(markdown.hasPrefix("# Talked with Tinkr\n\n> \(markdownMetrics)\n\n"))
        precondition(TranscriptMetadata.line(for: "Hi 🧠.", durationSeconds: 10)
            == "5 characters · 1 word · 10s · 6 wpm")
        precondition(TranscriptMetadata.line(for: " \n", durationSeconds: 10) == nil)
        precondition(TranscriptMetadata.line(for: "Hi.", durationSeconds: .infinity) == nil)
        let markdownBody = markdown
            .components(separatedBy: "\n\n")
            .dropFirst(2)
            .joined(separator: "\n\n")
        precondition(LexicalFidelity.words(in: markdownRaw) == LexicalFidelity.words(in: markdownBody))
        precondition(markdownBody.contains("um I think seven not six."))
        precondition(markdownBody.contains("No wait actually seven."))
        precondition(MarkdownFormatter.format("", durationSeconds: 23, metadataEnabled: true).isEmpty)
        precondition(MarkdownFormatter.format(markdownRaw, durationSeconds: 23, metadataEnabled: false)
            == "# Talked with Tinkr\n\num I think seven not six. No wait actually seven.\n\nAlso Claude Code keeps my exact words 🧠.")
        let taggedMarkdown = MarkdownFormatter.format(
            automaticCharacters.markdownText,
            durationSeconds: 10,
            metadataEnabled: true,
            metadataTranscript: automaticCharacters.deliveryText
        )
        precondition(taggedMarkdown.contains("<char>RILEY</char>"))
        precondition(taggedMarkdown.contains("> 17 characters · 4 words · 10s · 24 wpm"))
        precondition(ParagraphFormatter.format(markdownRaw) == markdownRaw)
        print("PASS: Markdown is opt-in, reports characters/words/time/WPM, and preserves fillers, corrections, emoji and word order")
        let abbreviation = Array(repeating: "word", count: 110).joined(separator: " ") + " Dr. Smith keeps talking"
        precondition(ParagraphFormatter.format(abbreviation) == abbreviation)
        print("PASS: three-sentence paragraph cadence preserves words, corrections and abbreviations")
        var stopTarget = StopTarget<String>()
        func timed(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
            TimedWord(text: text, start: start, end: end, isFinal: true)
        }
        var wake = WakeRouter()
        let volatile = [TimedWord(text: "earlier", start: 0, end: 0.4, isFinal: false),
                        TimedWord(text: "off", start: 1, end: 1.4, isFinal: false)]
        let finalizedEarlier = TimedWordRevision.replacing(volatile, with: [timed("Earlier", 0, 0.4)], start: 0, end: 0.5, isFinal: true)
        precondition(finalizedEarlier.map(\.text) == ["Earlier", "off"])
        let revisedTail = TimedWordRevision.replacing(volatile, with: [TimedWord(text: "office", start: 1, end: 1.3, isFinal: false)], start: 0.8, end: 1.3, isFinal: false)
        precondition(revisedTail.map(\.text) == ["earlier", "office"])
        let wakePrefix = [timed("On,", 0, 0.2), timed("I", 0.25, 0.35), timed("want", 0.4, 0.6)]
        let opened     = wake.observe(wakePrefix, audioTime: 0.7)
        precondition(opened.first?.kind == .began && opened.last?.text == "I want")
        let span     = opened.first?.spanID
        let ordinary = wakePrefix + [timed("it", 0.7, 0.8), timed("off.", 0.85, 1.0)]
        precondition(!wake.observe(ordinary, audioTime: 2).contains { $0.kind == .finished })
        let ended = ordinary + [timed("Off.", 2.0, 2.2), timed("off", 2.3, 2.45)]
        precondition(!wake.observe(ended, audioTime: 2.5).contains { $0.kind == .finished })
        let stopEvents = wake.observe(ended, audioTime: 3)
        precondition(stopEvents.filter { $0.kind == .finished }.count == 1)
        precondition(stopEvents.last?.spanID == span && stopEvents.last?.text == "I want it off.")
        precondition(wake.observe(ended, audioTime: 4).isEmpty)
        var quotedWake = WakeRouter()
        precondition(quotedWake.observe([timed("\"On\"", 0, 0.2)], audioTime: 1).isEmpty)
        var revisedWake = WakeRouter()
        _               = revisedWake.observe(wakePrefix, audioTime: 0.7)
        _               = revisedWake.observe(wakePrefix + [timed("off", 1.5, 1.7)], audioTime: 1.8)
        precondition(!revisedWake.observe(wakePrefix + [timed("office", 1.5, 1.9)], audioTime: 2.6).contains { $0.kind == .finished })
        precondition(revisedWake.requestStop(at: 2) != nil)
        precondition(revisedWake.requestStop(at: 2) == nil)
        _ = revisedWake.observe(wakePrefix + [timed("office.", 1.5, 1.9), timed("ignored", 2.1, 2.3)], audioTime: 2.8)
        precondition(revisedWake.finish()?.text == "I want office.")
        precondition(revisedWake.finish() == nil)
        var immediateWake = WakeRouter()
        _                 = immediateWake.observe(wakePrefix, audioTime: 0.7)
        precondition(immediateWake.requestStop(at: 0.75)?.text == "I want")
        precondition(immediateWake.finish()?.text == "I want")
        precondition(immediateWake.finish() == nil)
        let lateRevision = [timed("On", 0, 0.2), timed("I", 0.25, 0.35), timed("wanted", 0.4, 0.8)]
        precondition(immediateWake.observe(lateRevision, audioTime: 1).isEmpty,
                     "Late recognition must not redeliver or rewrite a stopped span")
        print("PASS: immediate wake snapshot freezes once; late revisions cannot redeliver")
        var acousticWake = WakeRouter()
        let coarseWords  = [timed("On", 0, 1), timed("hello", 1, 3.6), timed("Off", 3.84, 4.74)]
        let silence      = [SilenceInterval(start: 3.25, end: 4.05), SilenceInterval(start: 4.55, end: 5.55)]
        precondition(acousticWake.observe(coarseWords, audioTime: 5.55, silences: silence).last?.text == "hello")
        precondition(acousticWake.spanID == nil)
        // Fast interim timestamps can extend the Off word into already measured silence.
        var fastWake  = WakeRouter()
        let fastWords = [timed("On,", 0, 1.14), timed("hello", 1.14, 3.90), timed("Off.", 4.02, 4.92)]
        precondition(fastWake.observe(fastWords, audioTime: 5.55, silences: [SilenceInterval(start: 3.34, end: 4.087), SilenceInterval(start: 4.458, end: 5.55)]).last?.text == "hello")
        precondition(fastWake.spanID == nil)
        var noisyWake = WakeRouter()
        precondition(!noisyWake.observe(coarseWords, audioTime: 5.55, silences: []).contains { $0.kind == .finished })
        var silenceTracker = SilenceTracker()
        silenceTracker.observe(rmsDB: -80, start: 0, end: 0.3)
        silenceTracker.observe(rmsDB: -80, start: 0.3, end: 0.6)
        precondition(silenceTracker.snapshot().last?.duration == 0.6)
        silenceTracker.observe(rmsDB: -80, start: 1.0, end: 1.1) // Dropped frames are not evidence of silence.
        precondition((silenceTracker.snapshot().last?.duration ?? 0) < 0.2)
        print("PASS: wake same-chunk prefix, isolated Off, repeated Off once, quoted literals, revisions and timestamp cutoff")
        var focusedApp = "editor A"
        focusedApp     = "editor B" // Switch while dictating.
        stopTarget.capture { focusedApp }
        focusedApp = "editor C" // Switch during final recognition drain.
        stopTarget.capture { focusedApp }
        precondition(stopTarget.value == "editor B")
        stopTarget.reset()
        stopTarget.capture { nil }
        stopTarget.capture { "late unrelated editor" }
        precondition(stopTarget.captured && stopTarget.value == nil)
        print("PASS: stop-target frozen across drain; missing target never retargets late")
        var option = RightOptionHold()
        precondition(option.update(keyCode: 58, flags: 0x20) == nil)
        precondition(option.update(keyCode: 61, flags: 0x40) == true)
        precondition(option.update(keyCode: 61, flags: 0x40) == nil)
        precondition(option.update(keyCode: 58, flags: 0x60) == nil)
        precondition(option.update(keyCode: 61, flags: 0x20) == false)
        precondition(option.update(keyCode: 61, flags: 0) == nil)
        option = RightOptionHold() // Event-tap re-enable clears stale pressed state.
        precondition(option.update(keyCode: 61, flags: 0x40) == true)
        option = RightOptionHold()
        precondition(option.update(keyCode: 61, flags: 0x40) == true)
        precondition(option.update(keyCode: 61, flags: 0) == false)
        print("PASS: Right Option only; duplicate edges ignored; left Option coexistence")
        print("PASS: TTT transcript, capture lifecycle, classifier, JSONL, arrow chord, and capture-command core")
    }
}

