import Foundation
import Testing
import TokensCore
@testable import Tokens

struct TokensRevealComponentsTests {
    @Test func generatedMetadataStaysSeparateFromLiteralSpokenHeadings() {
        let body = "Here is a literal heading `# Metadata` and 👩🏽‍💻 e\u{301} text.\n<char>A B</char>"
        let envelope = TokensPrompt.format(body, durationSeconds: 2, countTranscript: body)
        let parts = TokensDecoration.parts(envelope, decorated: false)
        let authored = InlineTalkMarkdown.authoredPrompt(envelope, spokenText: body)
        let plan = parts.revealPlan(spokenWordCount: authored.spokenWordCount)
        #expect(plan.completeText == authored.text)
        #expect(plan.marker == "# π\n")
        #expect(plan.body.contains("`# Metadata`"))
        #expect(plan.metadata.hasPrefix("\n\n---\n\n# Metadata\n\n> *"))
        #expect(plan.removingMarker().completeText == String(authored.text.dropFirst(plan.marker.count)))
        #expect(plan.prependingMarker("\n").completeText == "\n" + authored.text)
        #expect(plan.prependingMarker(" ").duration == plan.duration)
        #expect(plan.removingMarker().openingCharacters == plan.openingCharacters)
    }

    @Test func emptyAndLegacyFallbackKeepFormatterBehavior() {
        #expect(TokensDecoration.parts(" \n ").text.isEmpty)
        let body = "One two three"
        let parts = TokensDecoration.parts(body, decorated: false)
        #expect(parts.text == "# π\nOne two three")
        #expect(parts.metadata.isEmpty)
    }
}
