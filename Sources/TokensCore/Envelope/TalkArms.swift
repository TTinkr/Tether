


//
import CryptoKit
import Foundation

/// The four ways one saved talk can be shown to an agent in a TTH (talk-to-harness) study.
public enum TalkArm: String, CaseIterable, Sendable, Codable {
    case plain, tinkrText, tinkrMarkdown, tinkrMarkdownWithSkill
}

/// Mirrors AuthoredPrompt's fields; the app maps one to the other.
public struct ArmSource: Sendable {
    public var transcript: String
    public var spokenText: String
    public var typed: String

    public init(transcript: String, spokenText: String, typed: String = "") {
        self.transcript = transcript; self.spokenText = spokenText; self.typed = typed
    }
}

/// Counts and a hash for one rendered arm; never the words themselves.
public struct ArmRecord: Codable, Equatable, Sendable {
    public var arm: TalkArm
    public var sha256: String
    public var utf8Count: Int
    public var words: Int
    public var pauseCount: Int
    public var pauseTotal: Double
    /// No arm may add, drop or reorder a spoken word (typed text and the skill are not spoken).
    public var preservesSpokenWords: Bool
}

public struct ArmManifest: Codable, Equatable, Sendable {
    public var sourceID: String
    public var layout: PiLayout?
    public var piID: String
    public var records: [ArmRecord]
}

public enum TalkArmRenderer {
    /*
    The study design lives in these two private lines. `table` says what each arm shows;
    `skillArms` says which arms get the skill on top. Putting the same skill on every arm is the
    one-line change `Set(TalkArm.allCases)`.
    */
    private enum Content { case plain, tinkrText, tinkrMarkdown }
    private static let table: [(TalkArm, Content)] = [(.plain, .plain), (.tinkrText, .tinkrText), (.tinkrMarkdown, .tinkrMarkdown), (.tinkrMarkdownWithSkill, .tinkrMarkdown)]
    private static let skillArms: Set<TalkArm> = [.tinkrMarkdownWithSkill]

    private static let typedHeading = "\n\n## Typed\n\n"

    public static func render(_ source: ArmSource, skill: String) -> [TalkArm: String] {
        Dictionary(uniqueKeysWithValues: rendered(source, skill: skill).map { ($0.arm, $0.text) })
    }

    public static func manifest(sourceID: String, source: ArmSource, skill: String) -> ArmManifest {
        let envelope = PiEnvelope.parse(source.transcript)
        let spoken = spokenBase(source)
        let expected = LexicalFidelity.words(in: stripTags(spoken))
        let records = rendered(source, skill: skill).map { item -> ArmRecord in
            let words = LexicalFidelity.words(in: stripTags(spokenPart(item.content, of: item.body)))
            let pauses = PiMarkers.scan(item.text).pauses
            let total = Double(String(format: "%.4f", pauses.reduce(0) { $0 + $1.seconds })) ?? 0
            return ArmRecord(arm: item.arm, sha256: sha256(item.text), utf8Count: item.text.utf8.count,
                             words: words.count, pauseCount: pauses.count, pauseTotal: total,
                             preservesSpokenWords: words == expected)
        }
        return ArmManifest(sourceID: sourceID, layout: envelope?.layout,
                           piID: PiEnvelopeID.id(spokenText: spoken, seconds: envelope?.stats?.seconds),
                           records: records)
    }

    // MARK: Rendering

    private struct Rendered { var arm: TalkArm; var content: Content; var body: String; var text: String }

    private static func rendered(_ source: ArmSource, skill: String) -> [Rendered] {
        let envelope = PiEnvelope.parse(source.transcript)
        return table.map { arm, content in
            let body = text(content, source: source, envelope: envelope)
            return Rendered(arm: arm, content: content, body: body,
                            text: skillArms.contains(arm) ? skill + "\n\n" + body : body)
        }
    }

    private static func text(_ content: Content, source: ArmSource, envelope: PiEnvelope?) -> String {
        switch content {
        case .plain:
            return PiMarkers.collapse(stripTags(spokenBase(source)))
        case .tinkrText:
            let typed = source.typed.isEmpty ? (envelope?.typed ?? "") : source.typed
            let words = envelope?.spokenText ?? spokenBase(source)
            return typed.isEmpty ? words : words + typedHeading + typed
        case .tinkrMarkdown:
            return AuthoredPrompt.appendingTyped(source.typed, to: source.transcript)
        }
    }

    /// The spoken words of an arm body, without typed text, metadata or headings.
    private static func spokenPart(_ content: Content, of body: String) -> String {
        switch content {
        case .plain:
            return body
        case .tinkrText:
            return body.range(of: typedHeading).map { String(body[..<$0.lowerBound]) } ?? body
        case .tinkrMarkdown:
            if let envelope = PiEnvelope.parse(body) { return envelope.spokenText }
            let words = body.range(of: typedHeading).map { String(body[..<$0.lowerBound]) } ?? body
            return PiEnvelope.spokenText(of: words)
        }
    }

    private static func spokenBase(_ source: ArmSource) -> String {
        PiEnvelope.spokenText(of: source.spokenText)
    }

    static func stripTags(_ text: String) -> String { PiMarkers.stripTags(text) }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

