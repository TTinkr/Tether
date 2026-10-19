


//
import Foundation
import Testing
import TokensCore
@testable import Tokens


// MarkdownSampleTests — what one talk must look like


@Suite struct MarkdownSampleTests {

    /// The reference rendering of one fictional talk (the format sample, not microphone proof).
    static func sample() throws -> String {
        #"""
        # π
        Let's build Token Maxxing with clear code and keep every word I say
        *[pause 1.2500]* Then test the microphone and paste.

        ---

        # Metadata

        > *12.0000s · 19 words · 95 wpm · 1x thinking (1.2500s)*
        > *Talked, not typed. Transcription may contain errors; use context to interpret unclear words.*
        > *Thinking tags record measured microphone silence only, not a claim about thought.*
        """#
    }

    static let spoken = "Let's build Token Maxxing with clear code and keep every word I say Then test the microphone and paste."
    static let body   = "Let's build Token Maxxing with clear code and keep every word I say\n\nTHINK (1.2500s)\n\nThen test the microphone and paste."
    static let typed  = "Keep the graph paper simple.\nReturn makes a new line."

    static func rendered(typed: String) -> String {
        // The same three steps TalkModel.deliver takes: measured envelope, presentation, typed notes.
        let envelope  = ThinkingPrompt.format(title: "Title", body: body, durationSeconds: 12,
                                              countTranscript: spoken, pauses: [1.25])
        let launch = InlineTalkMarkdown.authoredPrompt(envelope, spokenText: spoken)
        // Typed content here is an old-history compatibility fixture, not a new launch input.
        return AuthoredPrompt(transcript: launch.transcript, spokenText: spoken, typed: typed).text
    }

    @Test func theAppProducesExactlyTheReferenceSample() throws {
        #expect(Self.rendered(typed: "") == (try Self.sample()))
    }

    @Test func withNothingTypedTheMetadataFollowsTranscript() {
        let text = Self.rendered(typed: "")
        #expect(text.hasPrefix("# π\nLet's build"))
        #expect(!text.contains("## Transcript"))
        #expect(!text.contains("\n\n\n"))
        #expect(!text.contains("## Typed"))
    }

    @Test func aiNotesJoinTheMetadataAndNeverTheTranscript() {
        let envelope  = ThinkingPrompt.format(title: "T", body: Self.body, durationSeconds: 12, countTranscript: Self.spoken, pauses: [1.25])
        let presented = TokensDecoration.decoratePrompt(envelope, decorated: false, headerNotes: ["> *AI summary · local · may be inaccurate: plan the build*"])
        let transcript = presented.components(separatedBy: "# π\n")[1].components(separatedBy: "\n\n---\n\n")[0]
        #expect(!transcript.contains("AI summary"))
        #expect(presented.hasSuffix("not a claim about thought.*\n> *AI summary · local · may be inaccurate: plan the build*"))
    }

    @Test func threeStepPasteStartsWithOnlyPiAndWords() throws {
        let plan = try #require(ThreeStepPaste.plan(Self.rendered(typed: Self.typed)))
        #expect(plan.header.hasPrefix("# π\n"))
        #expect(plan.header == "# π\n")
        #expect(plan.steps.joined() == Self.rendered(typed: Self.typed))
    }

    @Test func heldWordsAndHistoryPreviewShowOnlyTheSpokenWords() {
        let text = Self.rendered(typed: Self.typed)
        #expect(TalkModel.heldWordsDisplay(text) == Self.spoken)
        #expect(TokensHistoryText.preview(text) == Self.spoken)
        #expect(TokensHistoryText.words(text) == 19)
    }
}

