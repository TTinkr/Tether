


//
import Foundation
import TokensCore

/*
Two offscreen launch routes behind ProofRoutes: --envelope-check reads one saved .md talk and
writes what it found; --tth-arms renders every TTH arm for each entry of a prompt-history file.
No microphone, clipboard, window or network. Printed lines carry numbers and labels only.
*/
enum EnvelopeCheckProof {
    struct Report: Encodable {
        let parsed: Bool
        let layout: PiLayout?
        let stats: PiStats?
        let mismatches: [PiMismatch]
        let piID: String
        let words: Int
        let pauseCount: Int
        /// True when a model-written appendix (Dev "## Tinkering") followed the receipt; it is not read as words.
        let generatedSection: Bool
    }

    struct Summary: Encodable {
        var entries = 0, written = 0, fidelityFailures = 0, edited = 0, unparsed = 0
        var layouts: [String: Int] = [:]
    }

    static func check(inputPath: String, outputPath: String) -> Int32 {
        guard let text = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
            print("ENVELOPE_CHECK parsed=false layout=unreadable mismatches=0 id=-")
            return 2
        }
        let report = report(for: text)
        let written = write(report, to: URL(fileURLWithPath: outputPath))
        print("ENVELOPE_CHECK parsed=\(report.parsed) layout=\(report.layout?.rawValue ?? "none") mismatches=\(report.mismatches.count) id=\(report.piID)")
        return written ? 0 : 1
    }

    static func report(for text: String) -> Report {
        let envelope = PiEnvelope.parse(text)
        let spoken = envelope?.spokenText ?? PiEnvelope.spokenText(of: text)
        return Report(parsed: envelope != nil, layout: envelope?.layout, stats: envelope?.stats,
                      mismatches: envelope.map(PiEnvelopeVerifier.verify) ?? [],
                      piID: PiEnvelopeID.id(spokenText: spoken, seconds: envelope?.stats?.seconds),
                      words: PiEnvelope.wordCount(of: spoken),
                      pauseCount: envelope?.pauses.count ?? 0,
                      generatedSection: envelope?.generated != nil)
    }

    static func renderArms(historyPath: String, outputDirectory: String, skill: String = RecommendedSkill.text) -> Int32 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: historyPath),
              let document = try? decoder.decode(PromptHistoryDocument.self, from: data),
              document.version == 1 else {
            print("TTH_ARMS entries=0 written=0 fidelity_failures=0 error=unreadable")
            return 2
        }
        let root = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        var summary = Summary()
        for entry in document.entries {
            summary.entries += 1
            let source = entry.authored.map { ArmSource(transcript: $0.transcript, spokenText: $0.spokenText, typed: $0.typed) }
                ?? ArmSource(transcript: entry.text, spokenText: PiEnvelope.parse(entry.text)?.spokenText ?? entry.text)
            let manifest = TalkArmRenderer.manifest(sourceID: entry.id.uuidString, source: source, skill: skill)
            summary.layouts[manifest.layout?.rawValue ?? "none", default: 0] += 1
            if manifest.layout == nil { summary.unparsed += 1 }
            if let envelope = PiEnvelope.parse(source.transcript), !PiEnvelopeVerifier.verify(envelope).isEmpty { summary.edited += 1 }
            if !manifest.records.allSatisfy(\.preservesSpokenWords) { summary.fidelityFailures += 1 }
            // A UUID string is a single safe path component, so every write stays under root.
            let folder = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { continue }
            for (arm, text) in TalkArmRenderer.render(source, skill: skill)
            where (try? text.write(to: folder.appendingPathComponent(arm.rawValue + ".md"), atomically: true, encoding: .utf8)) != nil {
                summary.written += 1
            }
            if write(manifest, to: folder.appendingPathComponent("manifest.json")) { summary.written += 1 }
        }
        _ = write(summary, to: root.appendingPathComponent("summary.json"))
        let layouts = summary.layouts.keys.sorted().map { "\($0):\(summary.layouts[$0] ?? 0)" }.joined(separator: ",")
        print("TTH_ARMS entries=\(summary.entries) written=\(summary.written) fidelity_failures=\(summary.fidelityFailures) edited=\(summary.edited) layouts=\(layouts)")
        return 0
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(value) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

