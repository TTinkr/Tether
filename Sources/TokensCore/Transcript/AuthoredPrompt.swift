


//
import Foundation


/// Markdown is presentation, never a provenance delimiter. Keeping these fields
/// separately means even a literal whole-line "## Typed" remains ordinary text.
public struct AuthoredPrompt: Codable, Equatable, Sendable {
    public let transcript: String
    public let spokenText: String
    public let typed: String

    public init(transcript: String, spokenText: String, typed: String = "") {
        self.transcript = transcript
        self.spokenText = spokenText
        self.typed      = typed
    }

    public var text: String { Self.appendingTyped(typed, to: transcript) }
    public var spokenWordCount: Int { spokenText.split(whereSeparator: { $0.isWhitespace }).count }
    public var isEmpty: Bool { transcript.isEmpty && typed.isEmpty }

    /// Presentation-only decorations are passed separately, never persisted in
    /// the faithful fields or used as model input or spoken word counts.
    public func presented(over transcriptPresentation: String) -> String {
        Self.appendingTyped(typed, to: transcriptPresentation)
    }

    public func correctingSpoken(_ correct: (String) -> String) -> Self {
        Self(transcript: correct(transcript), spokenText: correct(spokenText), typed: typed)
    }

    /// No trimming or newline normalization: a deliberate space, tab, CRLF or
    /// empty line is user-authored data. Only a truly empty string has no section.
    public static func appendingTyped(_ typed: String, to transcript: String) -> String {
        guard !typed.isEmpty else { return transcript }
        /*
        When the presentation ends with the metadata block, the typed section goes just before
        it: transcript → --- → ## Typed → # Metadata. The block is recognised only as the LAST
        "# Metadata" heading followed by nothing but `> ` lines, so words that merely look like
        that heading stay where the speaker put them.
        */
        let marker = "\n\n" + metadataHeading + "\n\n"
        if let block = transcript.range(of: marker, options: .backwards),
           transcript[block.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
               .allSatisfy({ $0.hasPrefix("> ") }) {
            return transcript[..<block.lowerBound] + "\n\n## Typed\n\n" + typed + transcript[block.lowerBound...]
        }
        // Legacy title/metadata/transcript layout keeps historical typed notes separate.
        if transcript.hasPrefix("# π "),
           let metadata = transcript.range(of: "\n\n# Metadata\n\n"),
           let words = transcript.range(of: "\n\n## Transcript\n\n"),
           metadata.lowerBound < words.lowerBound {
            return transcript + "\n\n---\n\n## Typed\n\n" + typed
        }
        let preceding = transcript.isEmpty ? "## Transcript" : transcript
        return preceding + "\n\n## Typed\n\n" + typed
    }

    /// Ends the spoken words: a rule, then two blank lines before whatever follows.
    public static let transcriptEnd = "\n\n---\n\n\n"
    /// Heading of the closing block that holds the timing lines and any AI-labelled notes.
    public static let metadataHeading = "# Metadata"
}

