


//
import CoreGraphics
import Foundation


// TranscriptRenderMode — plain or Markdown output, saved per user


/// Persisted display/delivery mode. Existing installs stay plain unless the
/// user explicitly opts in to Markdown.
/// A missing or unknown saved value reads as plain. TalkModel applies this only
/// when the product is not Tokens; Tokens builds its own prompt layout.
enum TranscriptRenderMode: String, CaseIterable {
    case plain
    case markdown

    // Stored on the user's Mac; renaming it would need a migration.
    static let preferenceKey = "TTTTranscriptRenderMode.v1"

    static func current(in defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: preferenceKey) else { return .plain }
        return Self(rawValue: raw) ?? .plain
    }
}


// SpeedOfSoundPreference — finish fast, accepting rougher words; on unless turned off


/// Explicit, deliberately lossy low-latency finish preference. Missing
/// settings mean enabled so existing installs receive the requested default.
/// When on, TalkModel finishes a talk without waiting for the local formatter,
/// and Return pressed while the talk key is held finishes the talk at once.
enum SpeedOfSoundPreference {
    // Stored on the user's Mac; renaming it would need a migration.
    static let key            = "TTTSpeedOfSoundEnabled.v1"
    static let defaultEnabled = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        /*
        object(forKey:) tells "never set" apart from "set to false";
        bool(forKey:) alone would read a missing value as false.
        */
        guard defaults.object(forKey: key) != nil else { return defaultEnabled }
        return defaults.bool(forKey: key)
    }
}


// LocalFormattingPolicy — small chunks for the local model, and checks on what comes back


/// Small inference units keep context bounded; no acoustic or semantic claims.
/// Used by LocalFormatter: each chunk goes to the local model on its own, and a
/// proposal replaces its chunk only when `accepts` says every word survived.
enum LocalFormattingPolicy {
    /// Cuts after every second sentence end (. ! or ? followed by space or the end),
    /// after a sentence end once a chunk reaches 500 UTF-16 units, or at a blank line.
    /// Any chunk still over 1000 characters is split into 80-word pieces.
    static func chunks(_ text: String) -> [String] {
        let source           = text as NSString
        let regex            = try! NSRegularExpression(pattern: #"[.!?](?:\s+|$)|\n{2,}"#)
        var chunks: [String] = []
        var start            = 0
        var sentences        = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            sentences += 1
            let end = NSMaxRange(match.range)
            if sentences >= 2 || end - start >= 500 || source.substring(with: match.range).contains("\n\n") {
                let chunk = source.substring(with: NSRange(location: start, length: end-start)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { chunks.append(chunk) }
                start = end; sentences = 0
            }
        }
        // Whatever follows the last cut (often an unfinished sentence) is its own chunk.
        let tail = source.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        // Extremely long unpunctuated speech is split at word boundaries.
        return chunks.flatMap { chunk -> [String] in
            guard chunk.count > 1000 else { return [chunk] }
            let words = chunk.split(whereSeparator: { $0.isWhitespace })
            return stride(from: 0, to: words.count, by: 80).map { start in
                words[start..<min(start + 80, words.count)].joined(separator: " ")
            }
        }
    }

//
// :)
//
//
    /// A model's proposal for one chunk is accepted only when all of these hold:
    /// it is not empty; it is at most twice the raw length plus 100 characters;
    /// it has no more non-blank lines than max(3, raw word count / 4); it contains
    /// no "<transcript>" tag and no code fence; and it keeps exactly the same
    /// words in the same order, ignoring case and punctuation (LexicalFidelity.preservesWords).
    static func accepts(raw: String, proposal: String) -> Bool {
        !proposal.isEmpty && proposal.count <= raw.count * 2 + 100 &&
        proposal.components(separatedBy: "\n").filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count <= max(3, LexicalFidelity.words(in: raw).count / 4) &&
        !proposal.contains("<transcript>") && !proposal.contains("```") &&
        LexicalFidelity.preservesWords(raw: raw, formatted: proposal)
    }
}

