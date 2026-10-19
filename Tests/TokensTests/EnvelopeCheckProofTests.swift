


//
import Foundation
import Testing
import TokensCore
@testable import Tokens

struct EnvelopeCheckProofTests {
    // Built by the real writers, so parse and verify are checked against what Tokens pastes.
    static let spoken = "Fix the build. then rename the data model"
    static let current = TokensDecoration.parts(ThinkingPrompt.format(
        title: "Build fix", body: "Fix the build.\n*[pause 2.3500]* then rename the data model",
        durationSeconds: 12.3456, countTranscript: spoken, pauses: [2.35])).text
    static let legacy = TokensPrompt.format("hello there friend from tokens", durationSeconds: 3.04,
                                            countTranscript: "hello there friend from tokens")

    @Test func writerOutputParsesAndVerifiesClean() throws {
        let current = try #require(PiEnvelope.parse(Self.current))
        #expect(current.layout == .current)
        #expect(current.pauses.count == 1)
        #expect(current.stats?.pauseCount == 1)
        #expect(PiEnvelopeVerifier.verify(current) == [])
        let legacy = try #require(PiEnvelope.parse(Self.legacy))
        #expect(legacy.layout == .legacyHeaderFirst)
        #expect(PiEnvelopeVerifier.verify(legacy) == [])
        let typed = try #require(PiEnvelope.parse(AuthoredPrompt.appendingTyped("typed note", to: Self.current)))
        #expect(typed.typed == "typed note")
        #expect(PiEnvelopeVerifier.verify(typed) == [])
    }

    // Tag names are not words: the JSON count must agree with the receipt the verifier passed.
    @Test func checkWordCountMatchesReceiptWithTags() throws {
        let body = "Set the port to <num>8080</num> then print <char>@</char> now"
        let delivery = "Set the port to 8080 then print @ now"
        let text = TokensDecoration.parts(ThinkingPrompt.format(
            title: "Port", body: body, durationSeconds: 6, countTranscript: delivery, pauses: [])).text
        let report = EnvelopeCheckProof.report(for: text)
        #expect(report.parsed)
        #expect(report.mismatches == [])
        #expect(report.words == report.stats?.words)
    }

    // What Dev pastes with the local model on: the receipt, then "---" and the generated note.
    @Test func devTinkeringAppendixIsSeparatedFromReceipt() throws {
        let note = TinkeringSection.render(.init(summary: "Fix the build", context: "A failing target",
                                                 suggestion: "Rename the model"), model: "llama3")
        let pasted = TinkeringSection.appending(note, to: Self.current)
        let envelope = try #require(PiEnvelope.parse(pasted))
        let plain = try #require(PiEnvelope.parse(Self.current))
        #expect(envelope.layout == .current)
        #expect(envelope.body == plain.body)
        #expect(envelope.notes == plain.notes)
        #expect(envelope.stats == plain.stats)
        #expect(envelope.generated == note)
        #expect(PiEnvelopeVerifier.verify(envelope) == [])
        #expect(TinkeringSection.removing(from: pasted) == Self.current)
        #expect(EnvelopeCheckProof.report(for: pasted).generatedSection)
        #expect(!EnvelopeCheckProof.report(for: Self.current).generatedSection)
    }

    @Test func renderArmsWritesEveryArmAndCheckReadsOneBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("envelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = UUID(), second = UUID()
        let document = PromptHistoryDocument(version: 1, entries: [
            PromptHistoryEntry(id: first, createdAt: Date(timeIntervalSince1970: 1_760_000_000),
                               authored: AuthoredPrompt(transcript: Self.current, spokenText: Self.spoken, typed: "typed note")),
            PromptHistoryEntry(id: second, createdAt: Date(timeIntervalSince1970: 1_760_000_100), text: Self.legacy),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let history = root.appendingPathComponent("history.json")
        try encoder.encode(document).write(to: history)
        let arms = root.appendingPathComponent("arms")
        #expect(EnvelopeCheckProof.renderArms(historyPath: history.path, outputDirectory: arms.path, skill: "skill text") == 0)

        var markdownFiles = 0
        for id in [first, second] {
            let folder = arms.appendingPathComponent(id.uuidString)
            for arm in TalkArm.allCases where FileManager.default.fileExists(atPath: folder.appendingPathComponent(arm.rawValue + ".md").path) {
                markdownFiles += 1
            }
            let manifest = try JSONDecoder().decode(ArmManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            #expect(manifest.sourceID == id.uuidString)
            #expect(manifest.records.allSatisfy { $0.preservesSpokenWords })
        }
        #expect(markdownFiles == 8)

        let output = root.appendingPathComponent("check.json")
        let input = arms.appendingPathComponent(first.uuidString).appendingPathComponent("tinkrMarkdown.md")
        #expect(EnvelopeCheckProof.check(inputPath: input.path, outputPath: output.path) == 0)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        #expect(json["parsed"] as? Bool == true)
        #expect((json["mismatches"] as? [Any])?.isEmpty == true)
        #expect(json["layout"] as? String == "current")
        let checked = try #require(PiEnvelope.parse(String(contentsOf: input, encoding: .utf8)))
        #expect(json["words"] as? Int == checked.stats?.words)
        #expect(EnvelopeCheckProof.check(inputPath: root.appendingPathComponent("missing.md").path, outputPath: output.path) == 2)
    }
}

