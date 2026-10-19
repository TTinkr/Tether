


//
import Foundation
import Testing
@testable import TokensCore

struct TalkArmsTests {
    static let skill = "---\nname: ttoken-talk\n---\n# TToken talk\nItalic `*[pause 2.3500]*` prefixes are timing notes."
    static let body = "Spell it *<char>RILEY</char>* please.\n*[pause 1.2500]* then count *<num>1 2 3</num>* aloud\n*[pause 0.5000]* done"
    // Words counted as the writer counts deliveryText (no tag names): 11.
    static let transcript = "# π\n" + body + "\n\n---\n\n# Metadata\n\n> *6.0000s · 11 words · 110 wpm · 2x thinking (1.7500s)*\n> *Talked, not typed. Transcription may contain errors; use context to interpret unclear words.*"
    static let spoken = "Spell it *<char>RILEY</char>* please. then count *<num>1 2 3</num>* aloud done"
    static let typed = "see ~/notes.md\nline two"
    static let source = ArmSource(transcript: transcript, spokenText: spoken, typed: typed)

    @Test func armsShowTheIntendedNotation() throws {
        let arms = TalkArmRenderer.render(Self.source, skill: Self.skill)
        let plain = try #require(arms[.plain])
        for absent in ["*[pause", "<num>", "<char>", "# π", "# Metadata", "## Typed"] { #expect(!plain.contains(absent)) }
        #expect(plain.contains("1 2 3"))
        #expect(plain.contains("RILEY"))
        let text = try #require(arms[.tinkrText])
        #expect(text.contains("## Typed"))
        #expect(text.contains("<num>1 2 3</num>"))
        #expect(!text.contains("*[pause"))
        #expect(!text.contains("# Metadata"))
        let markdown = try #require(arms[.tinkrMarkdown])
        #expect(markdown == AuthoredPrompt(transcript: Self.transcript, spokenText: Self.spoken, typed: Self.typed).text)
        #expect(markdown.hasPrefix(Self.transcript.components(separatedBy: "\n\n---\n\n").first!))
        let skilled = try #require(arms[.tinkrMarkdownWithSkill])
        #expect(skilled.hasPrefix(Self.skill))
        #expect(skilled.hasSuffix(markdown))
    }

    @Test func noArmAddsOrDropsASpokenWord() {
        let manifest = TalkArmRenderer.manifest(sourceID: "a", source: Self.source, skill: Self.skill)
        #expect(manifest.records.map(\.arm) == TalkArm.allCases)
        #expect(manifest.records.allSatisfy { $0.preservesSpokenWords })
        #expect(Set(manifest.records.map(\.words)).count == 1)
        #expect(manifest.layout == .current)
        #expect(manifest.records.first?.words == 11)
        #expect(PiEnvelopeVerifier.verify(PiEnvelope.parse(Self.transcript)!) == [])
        let pauses = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.arm, $0.pauseCount) })
        #expect(pauses == [.plain: 0, .tinkrText: 0, .tinkrMarkdown: 2, .tinkrMarkdownWithSkill: 2])
    }

    @Test func manifestIsDeterministicAndArmsDiffer() {
        let first = TalkArmRenderer.manifest(sourceID: "a", source: Self.source, skill: Self.skill)
        #expect(first == TalkArmRenderer.manifest(sourceID: "a", source: Self.source, skill: Self.skill))
        #expect(Set(first.records.map(\.sha256)).count == 4)
        #expect(first.records.allSatisfy { $0.sha256.count == 64 })
        let arms = TalkArmRenderer.render(Self.source, skill: Self.skill)
        for record in first.records {
            #expect(record.utf8Count == arms[record.arm]?.utf8.count)
            #expect(record.sha256 == TalkArmRenderer.sha256(arms[record.arm] ?? ""))
        }
    }

    @Test func rawWordsWithoutEnvelopeStillRender() {
        let raw = "just some raw words with no marker"
        let source = ArmSource(transcript: raw, spokenText: raw)
        let arms = TalkArmRenderer.render(source, skill: Self.skill)
        #expect(arms.count == 4)
        #expect(arms[.tinkrMarkdown] == raw)
        let manifest = TalkArmRenderer.manifest(sourceID: "raw", source: source, skill: Self.skill)
        #expect(manifest.layout == nil)
        #expect(manifest.records.allSatisfy { $0.preservesSpokenWords })
    }
}

