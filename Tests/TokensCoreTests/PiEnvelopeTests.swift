


//
import Foundation
import Testing
@testable import TokensCore

/*
Fixtures follow the writer shapes: TokensDecoration.parts (current), TokensPrompt.format and
ThinkingPrompt.header (legacy header-first), and AuthoredPrompt.appendingTyped for typed text.
Writer-built parity (calling the real app writers) lives in Tests/TokensTests/EnvelopeCheckProofTests.
*/
struct PiEnvelopeTests {
    static let talked = "> *Talked, not typed. Transcription may contain errors; use context to interpret unclear words.*"
    static let measured = "> *Thinking tags record measured microphone silence only, not a claim about thought.*"

    /// The current layout exactly as TokensDecoration.parts joins it: marker + body + metadata.
    static func current(_ body: String, stats: String) -> String {
        "# π\n" + body + "\n\n---\n\n" + AuthoredPrompt.metadataHeading + "\n\n" + stats + "\n" + talked + "\n" + measured
    }

    // Nine lexical words; 9 * 60 / 12.3456 = 43.74 → "44" with the writers' "%.0f".
    static let body = "Fix the build.\n*[pause 2.3500]* then maybe rename the data model"
    static let stats = "> *12.3456s · 9 words · 44 wpm · 1x thinking (2.3500s)*"
    static let envelope = current(body, stats: stats)

    @Test func roundTripCurrentLayout() throws {
        let parsed = try #require(PiEnvelope.parse(Self.envelope))
        #expect(parsed.layout == .current)
        #expect(parsed.title == nil)
        #expect(parsed.body == Self.body)
        #expect(parsed.spokenText == "Fix the build. then maybe rename the data model")
        #expect(parsed.pauses == [PiPause(seconds: 2.35, wordIndex: 3)])
        #expect(parsed.stats == PiStats(seconds: 12.3456, words: 9, wpm: 44, pauseCount: 1, pauseTotal: 2.35))
        #expect(parsed.notes == [Self.talked, Self.measured])
        #expect(parsed.typed == nil)
        #expect(PiEnvelopeVerifier.verify(parsed) == [])
    }

    @Test func editedWordIsReportedAsMismatch() throws {
        let edited = Self.current(Self.body.replacingOccurrences(of: "Fix", with: "Fix the"), stats: Self.stats)
        let mismatches = PiEnvelopeVerifier.verify(try #require(PiEnvelope.parse(edited)))
        #expect(mismatches.contains(.words(stated: 9, counted: 10)))
        #expect(mismatches.contains(.wpm(stated: 44, computed: 49)))
    }

    @Test func deletedPauseMarkerIsReported() throws {
        let edited = Self.current(Self.body.replacingOccurrences(of: "*[pause 2.3500]* ", with: ""), stats: Self.stats)
        let mismatches = PiEnvelopeVerifier.verify(try #require(PiEnvelope.parse(edited)))
        #expect(mismatches.contains(.pauseCount(stated: 1, counted: 0)))
        #expect(mismatches.contains(.pauseTotal(stated: 2.35, counted: 0)))
        #expect(!mismatches.contains { if case .words = $0 { true } else { false } })
    }

    @Test func legacyHeaderFirst() throws {
        let text = "# π Talked to tinkr\n\n> *56.6s · 3 words · 3 wpm*\n" + Self.talked + "\n\nhello there friend"
        let parsed = try #require(PiEnvelope.parse(text))
        #expect(parsed.layout == .legacyHeaderFirst)
        #expect(parsed.title == "Talked to tinkr")
        #expect(parsed.body == "hello there friend")
        #expect(parsed.stats?.seconds == 56.6)
        #expect(parsed.stats?.pauseCount == nil)
        #expect(parsed.notes == [Self.talked])
        #expect(PiEnvelopeVerifier.verify(parsed) == [])
    }

    @Test func legacyRoundedSecondsAcceptsWriterRate() throws {
        // Writer saw 56.64 s: 261 * 60 / 56.64 = 276.48 → 276, printed as "56.6s".
        let words = Array(repeating: "word", count: 261).joined(separator: " ")
        let text = "# π Talked to tinkr\n\n> *56.6s · 261 words · 276 wpm*\n" + Self.talked + "\n\n" + words
        #expect(PiEnvelopeVerifier.verify(try #require(PiEnvelope.parse(text))) == [])
    }

    @Test func oldestTranscriptHeadingLayout() throws {
        let text = "# π Old title\n\n# Metadata\n\n> *2.0000s · 2 words · 60 wpm · 0x thinking (0.0000s)*\n"
            + Self.talked + "\n\n## Transcript\n\nold words"
        let parsed = try #require(PiEnvelope.parse(text))
        #expect(parsed.layout == .legacyTranscriptHeading)
        #expect(parsed.title == "Old title")
        #expect(parsed.body == "old words")
        #expect(PiEnvelopeVerifier.verify(parsed) == [])
        // AuthoredPrompt's legacy branch puts a rule before the typed section.
        let typed = try #require(PiEnvelope.parse(AuthoredPrompt.appendingTyped("typed note", to: text)))
        #expect(typed.body == "old words")
        #expect(typed.typed == "typed note")
    }

    @Test func plainWordsAndBareMarkerAreNotEnvelopes() {
        #expect(PiEnvelope.parse("just words") == nil)
        #expect(PiEnvelope.parse("# π\njust words") == nil)
        #expect(PiEnvelope.parse("# π\njust words\n\n---\n\n# Metadata\n\nnot a quote") == nil)
    }

    @Test func spokenMetadataHeadingStaysInBody() throws {
        let body = "first part\n\n# Metadata\n\nmore words after it"
        let text = Self.current(body, stats: "> *6.0000s · 7 words · 70 wpm · 0x thinking (0.0000s)*")
        let parsed = try #require(PiEnvelope.parse(text))
        #expect(parsed.body == body)
        #expect(parsed.stats?.words == 7)
        #expect(PiEnvelopeVerifier.verify(parsed) == [])
    }

    @Test func typedSectionIsSeparated() throws {
        let typed = "  exact\ttyped\n\nbytes ## not a heading "
        let text = AuthoredPrompt.appendingTyped(typed, to: Self.envelope)
        let parsed = try #require(PiEnvelope.parse(text))
        #expect(parsed.typed == typed)
        #expect(parsed.body == Self.body)
        #expect(!parsed.spokenText.contains("typed"))
        #expect(PiEnvelopeVerifier.verify(parsed) == [])
        // Legacy header-first takes the general "## Typed" branch.
        let legacy = "# π Talked to tinkr\n\n> *56.6s · 3 words · 3 wpm*\n" + Self.talked + "\n\nhello there friend"
        let legacyParsed = try #require(PiEnvelope.parse(AuthoredPrompt.appendingTyped("t", to: legacy)))
        #expect(legacyParsed.body == "hello there friend")
        #expect(legacyParsed.typed == "t")
    }

    @Test func idIgnoresPresentationButNotWordsOrTime() {
        let id = PiEnvelopeID.id(spokenText: "Fix the build. Then rename", seconds: 12.3456)
        #expect(id.count == 8)
        #expect(id.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(PiEnvelopeID.id(spokenText: "fix  THE build then, rename!", seconds: 12.3451) == id)
        #expect(PiEnvelopeID.id(spokenText: "Fix the build. Then rebuild", seconds: 12.3456) != id)
        #expect(PiEnvelopeID.id(spokenText: "Fix the build. Then rename", seconds: 12.3556) != id)
        #expect(PiEnvelopeID.id(spokenText: "Fix the build. Then rename", seconds: nil) != id)
        #expect(PiEnvelopeID.token(id) == "π-id " + id)
    }

    @Test func protectedSpansAndHistoricalMarkers() throws {
        let body = "say `*[pause 1.0000]*` literally\nTHINK (0.5000s)\nthen <thinking duration=\"0.2500s\"/> more"
        let parsed = PiEnvelope.spokenText(of: body)
        #expect(parsed == "say `*[pause 1.0000]*` literally then more")
        let text = Self.current(body, stats: "> *6.0000s · 7 words · 70 wpm · 2x thinking (0.7500s)*")
        let envelope = try #require(PiEnvelope.parse(text))
        #expect(envelope.pauses == [PiPause(seconds: 0.5, wordIndex: 5), PiPause(seconds: 0.25, wordIndex: 6)])
        #expect(PiEnvelopeVerifier.verify(envelope) == [])
    }

    @Test func historicalUnplacedPausesAndTagsCountLikeTheWriter() throws {
        // 3 placed + 2 unplaced = 5 pauses; each marker rounds alone, the writer rounded the sum once.
        let body = "THINK (1.0000s)\nspell <TC>ALEX</TC> now\nTHINK (2.0000s)\nthen *<num>4 5</num>* more\nTHINK (0.5001s)\nend"
            + "\nTHINK unplaced ×2 (3.0000s) · measured silence, position not aligned to words"
        let stats = "> *60.0000s · 8 words · 8 wpm · 5x thinking (6.5002s)*"
        let envelope = try #require(PiEnvelope.parse(Self.current(body, stats: stats)))
        #expect(envelope.pauses.count == 3)
        #expect(envelope.unplacedPauseCount == 2)
        #expect(envelope.unplacedPauseTotal == 3)
        #expect(PiEnvelopeVerifier.verify(envelope) == [])
        #expect(PiEnvelopeID.id(spokenText: envelope.spokenText, seconds: 60)
                == PiEnvelopeID.id(spokenText: "spell ALEX now then 4 5 more end", seconds: 60))
    }

    @Test func optionalPiIDSuffixIsReadAndChecked() throws {
        let id = PiEnvelopeID.id(spokenText: "Fix the build. then maybe rename the data model", seconds: 12.3456)
        let stamped = Self.stats.replacingOccurrences(of: ")*", with: ") · " + PiEnvelopeID.token(id) + "*")
        let parsed = try #require(PiEnvelope.parse(Self.current(Self.body, stats: stamped)))
        #expect(parsed.stats?.piID == id)
        #expect(PiEnvelopeVerifier.verify(parsed) == [])
        let edited = try #require(PiEnvelope.parse(Self.current(Self.body.replacingOccurrences(of: "data", with: "view"), stats: stamped)))
        #expect(PiEnvelopeVerifier.verify(edited).contains { if case .piID = $0 { true } else { false } })
    }

    @Test func largeBodyParsesQuickly() throws {
        var lines: [String] = []
        for index in 0..<256 {
            let words = Array(repeating: "word", count: index < 16 ? 40 : 39).joined(separator: " ")
            lines.append("*[pause 1.2500]* " + words)
        }
        let body = lines.joined(separator: "\n")
        let text = Self.current(body, stats: "> *2000.0000s · 10000 words · 300 wpm · 256x thinking (320.0000s)*")
        let clock = ContinuousClock()
        var mismatches: [PiMismatch] = [.words(stated: 0, counted: 0)]
        let elapsed = clock.measure {
            if let parsed = PiEnvelope.parse(text) { mismatches = PiEnvelopeVerifier.verify(parsed) }
        }
        #expect(mismatches == [])
        #expect(elapsed < .milliseconds(100))
    }
}

