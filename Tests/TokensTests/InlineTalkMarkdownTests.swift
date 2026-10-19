


//
import Foundation
import Testing
@testable import Tokens

@Suite struct InlineTalkMarkdownTests {
    @Test func historicalShortPrecisionPauseRemainsReadable() {
        #expect(InlineTalkMarkdown.render("First\n*Thinking · 1.25 s*\nNext") == "First\n*[pause 1.2500]* Next")
    }

    @Test func pauseSampleAndFourDecimalRounding() {
        let body = ThinkingComposer.body([
            ThinkingSegment(text: "First thought", pausesAfter: [1.57649]),
            ThinkingSegment(text: "Next thought.", pausesAfter: [])
        ]) { $0 }
        #expect(InlineTalkMarkdown.render(body) == "First thought\n*[pause 1.5765]* Next thought.")
    }

    @Test func newNotationIsItalicAndStableOnRerender() {
        let rendered = CharacterTalk.render("Spell R I L E Y then count one two three.")
        #expect(rendered.markdownText == "Spell *<char>RILEY</char>* then count *<num>1 2 3</num>*.")
        #expect(rendered.deliveryText == "Spell RILEY then count 1 2 3.")
        #expect(CharacterTalk.render(rendered.markdownText).markdownText == rendered.markdownText)
        for literal in ["<num>one two three</num>", "*<num>1 2 3</num>*", "<TN>1 2 3</TN>", "`*[pause 1.5000]*`", "<num>unfinished one two three"] {
            #expect(CharacterTalk.render(literal).markdownText == literal)
            #expect(InlineTalkMarkdown.render(literal) == literal)
        }
    }

    @Test func placedPausesBecomeItalicLinePrefixes() {
        let body = ThinkingComposer.body([
            ThinkingSegment(text: "Keep  every\nword", pausesAfter: [1.25, 2]),
            ThinkingSegment(text: "then finish.", pausesAfter: [3])
        ]) { $0 }
        let rendered = InlineTalkMarkdown.render(body)
        #expect(rendered == "Keep every word\n*[pause 1.2500]*\n*[pause 2.0000]* then finish.\n*[pause 3.0000]*")
        #expect(!rendered.contains("\n\n\n"))
        #expect(InlineTalkMarkdown.render(rendered) == rendered)
        #expect(LexicalFidelity.preservesWords(raw: "Keep every word then finish.",
                    formatted: ThinkingComposer.removingAnnotations(rendered)))
    }

    @Test func unplacedPausesStayExplicitRatherThanInventingLocations() {
        let body = ThinkingComposer.body([ThinkingSegment(text: "hello world", pausesAfter: [])], unplaced: [2.3]) { $0 }
        let rendered = InlineTalkMarkdown.render(body)
        #expect(rendered == "hello world")
        #expect(InlineTalkMarkdown.render("hello world\n\n<thinking duration=\"2.3000s\" placement=\"unplaced\" count=\"1\"/>") == "hello world")
        #expect(ThinkingComposer.removingAnnotations(rendered).trimmingCharacters(in: .whitespaces) == "hello world")
    }

    @Test func unplacedTimingRemainsInCaptureAndMetadata() {
        let placement = ThinkingComposer.placement(raw: "hello world", words: [],
            pauses: [ThinkingPause(start: 1, end: 3.3)])
        #expect(placement.unplaced.count == 1)
        #expect(abs(placement.unplaced[0] - 2.3) < 0.0001)
        let body = ThinkingComposer.body(placement.segments, unplaced: placement.unplaced) { $0 }
        let envelope = ThinkingPrompt.format(title: "Timing", body: body, durationSeconds: 5,
                                             countTranscript: "hello world", pauses: placement.unplaced)
        let presented = InlineTalkMarkdown.authoredPrompt(envelope, spokenText: "hello world").text
        #expect(presented.hasPrefix("# π\nhello world"))
        #expect(presented.contains("1x thinking (2.3000s)"))
        #expect(presented.contains("\n\n---\n\n# Metadata\n\n"))
        #expect(!presented.contains("placement=\"unplaced\""))
        #expect(!presented.contains("unplaced ×"))
    }

    @Test func pauseBlocksBesideProtectedLiteralsRemainSeparate() {
        let code = "```\nTHINK (unplaced ×1 · 2.3000s · measured silence, position not aligned to words)\n```"
        let spelling = "<char>RILEY\nTHINK (1.2500s)</char>"
        let input = code + "\n\nTHINK (1.2500s)\n\n" + spelling
        #expect(InlineTalkMarkdown.render(input) == code + "\n*[pause 1.2500]* " + spelling)
        for literal in ["`<thinking duration=\"2.3000s\" placement=\"unplaced\" count=\"1\"/>`", code, spelling] {
            #expect(InlineTalkMarkdown.render(literal) == literal)
        }
    }

    @Test func historicalMarkersAndOrdinaryThinkMentionsRemainReadable() {
        #expect(ThinkingComposer.removingAnnotations("first\n\nTHINK (1.2500s)\n\nlast") == "first\n\n\nlast")
        let prose = "I THINK about TK-1.2500s and (TK-1.2500s)."
        #expect(ThinkingComposer.removingAnnotations(prose) == prose)
        #expect(InlineTalkMarkdown.render(prose) == prose)
        #expect(TokensHistoryText.preview("## Transcript\n\nTHINK (about the word TK) before speaking.") == "THINK (about the word TK) before speaking.")
        #expect(InlineTalkMarkdown.render("THINK (1.2500s)\n\nhello") == "*[pause 1.2500]* hello")
    }

    @Test func protectedCodeIsNotFlattenedOrTreatedAsAPause() {
        let code = "```swift\nTHINK (1.2500s)\nlet x = 2\n```"
        #expect(InlineTalkMarkdown.render("before\n\n" + code + "\n\nafter") == "before " + code + " after")
        #expect(ThinkingComposer.removingAnnotations(code) == code)
        let literal = "`<thinking duration=\"1.2500s\"/>`"
        #expect(ThinkingComposer.removingAnnotations(literal) == literal)
    }

    @Test func characterSpansAndLegacyPausesKeepTheirMeaning() {
        let literal = "<char>RILEY\nTHINK (1.2500s)</char>"
        #expect(InlineTalkMarkdown.render(literal) == literal)
        #expect(InlineTalkMarkdown.removingMarkers(literal) == literal)
        #expect(InlineTalkMarkdown.removingMarkers("before — (TK-1.2500s) — after") == "before after")
    }

    @Test func newPublicCaptureHasNoTypedOrGeneratedDecoration() {
        let envelope = ThinkingPrompt.format(title: "Title", body: "Hello WORLD", durationSeconds: 2,
                                             countTranscript: "Hello WORLD", pauses: [])
        let authored = InlineTalkMarkdown.authoredPrompt(envelope, spokenText: "Hello WORLD")
        #expect(authored.typed.isEmpty)
        #expect(authored.spokenText == "Hello WORLD")
        #expect(authored.text.hasPrefix("# π\nHello WORLD"))
        #expect(!authored.text.contains("## Typed"))
        #expect(!authored.text.contains("AI summary"))
    }

}

