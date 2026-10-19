


//
import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Speech
import SwiftUI


// Receipt — wraps delivered text in ⟨π … ⟩ with one timing line, at most once


/*
Output shape (plain transcript mode, receipt switched on):

  ⟨π
  the spoken words
  42 characters · 8 words · 3.1s · 155 wpm ⟩

Re-rendering the same text must never stack a second receipt, so append()
first looks for an existing one in either form below and leaves such text alone.
*/
enum Receipt {
    /*
    One timing line, short form ("3.1s" or "3.1s · 155 wpm") or full form
    ("42 characters · 8 words · 3.1s · 155 wpm"). Separators may be "·" or "|".
    */
    private static let metricLinePattern = #"(?:\d+(?:\.\d+)?s(?:\s*[·|]\s*\d+\s*wpm)?|\d+\s+characters?\s*[·|]\s*\d+\s+words?\s*[·|]\s*\d+(?:\.\d+)?s\s*[·|]\s*\d+\s+wpm)"#
    // Older form: a timing line in ⟨ ⟩ or [ ] as the last line, optionally after "π".
    private static let legacyFooter = try? NSRegularExpression(
        pattern: "(?i)(?:^|\\n)\\s*(?:π\\s*)?[⟨\\[]\\s*\(metricLinePattern)\\s*[⟩\\]]\\s*$"
    )
    /*
    Current form: the whole text is "⟨π", a newline, the body, a newline,
    then the timing line and "⟩" (or the same with [ ]).
    */
    private static let wrappedMetadata = try? NSRegularExpression(
        pattern: "(?is)^\\s*[⟨\\[]\\s*π\\s*\\n.+\\n\\s*\(metricLinePattern)\\s*[⟩\\]]\\s*$"
    )

    /// Adds the receipt to `text`. Counts come from `transcript` when given (the
    /// spoken words before layout), otherwise from `text` itself.
    /// Returns `text` unchanged when the duration is not a positive finite number,
    /// when a receipt is already present, or when there are no words to count.
    static func append(to text: String, durationSeconds: Double, transcript: String? = nil) -> String {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return text }
        /*
        If a pattern ever failed to compile (`try?` gives nil), its check is
        skipped here rather than crashing; the patterns are constant.
        */
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        if legacyFooter?.firstMatch(in: text, range: fullRange) != nil ||
            wrappedMetadata?.firstMatch(in: text, range: fullRange) != nil {
            return text
        }
        guard let metrics = TranscriptMetadata.line(
            for: transcript ?? text,
            durationSeconds: durationSeconds
        ) else { return text }
        return "⟨π\n\(text)\n\(metrics) ⟩"
    }
}


// TranscriptMetadata — the counts line: characters · words · seconds · wpm


/// Compact measured counts shared by plain and Markdown transcript modes.
/// Character counts use Unicode grapheme clusters from the spoken transcript;
/// internal whitespace and punctuation count, while surrounding whitespace,
/// rendered Markdown, and appended metadata do not.
///
/// Example: "42 characters · 8 words · 3.1s · 155 wpm". Under 10 seconds the
/// duration keeps one decimal; from 10 seconds it is whole seconds. Words per
/// minute is never shown below 1. Returns nil for a bad duration or no words.
enum TranscriptMetadata {

//
// :)
//
//
    static func line(for rawTranscript: String, durationSeconds: Double) -> String? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }

        /*
        Words are counted with LexicalFidelity.words, the same rule the "every word
        kept" checks use: runs of letters, digits and apostrophes.
        */
        let characters     = transcript.count
        let words          = LexicalFidelity.words(in: transcript).count
        let characterLabel = characters == 1 ? "character" : "characters"
        let wordLabel      = words == 1 ? "word" : "words"
        let duration       = durationSeconds < 10
            ? String(format: "%.1f", durationSeconds)
            : String(Int(durationSeconds.rounded()))
        let wordsPerMinute = max(1, Int((Double(words) * 60 / durationSeconds).rounded()))
        return "\(characters) \(characterLabel) · \(words) \(wordLabel) · \(duration)s · \(wordsPerMinute) wpm"
    }
}

