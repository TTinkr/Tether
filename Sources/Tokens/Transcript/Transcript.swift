


//
import CoreGraphics
import Foundation


// TimedWord — One recognized word with the recognizer's start and end seconds


/*
Public twins live in Sources/TokensCore/Transcript/. Tokens now depends on TokensCore
(see Package.swift), but these app-local types remain in use in this file.
Keep parity explicit until remaining transcript consumers migrate.
*/
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var isFinal: Bool
    /// False for a placeholder whose time the recognizer did not supply.
    /// Untimed placeholders are stored with start and end of -1, which fails this test. Placement
    /// of thinking pauses (ThinkingComposer) compares these times with pause times, so both sit on
    /// one audio clock.
    var hasTiming: Bool { start.isFinite && end.isFinite && start >= 0 && end >= start }
    /*
    The word reduced to a lowercase command candidate: punctuation and spaces trimmed from the
    ends. It is "" when the word contains any quote mark (straight or curly), so a quoted word
    never matches a command.
    */
    var command: String {
        guard !text.contains("\""), !text.contains("“"), !text.contains("”") else { return "" }
        return text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
    }
}


// TimedWordRevision — Merges a new recognizer result into the timed words already held


enum TimedWordRevision {
    /*
    `start`...`end` is the audio range the incoming result covers. Existing words that overlap
    that range are replaced by `incoming`; everything else is kept (except, for a non-final
    result, older non-final words from `start` on, as explained below); the merged list is
    sorted by start time.
    */
    static func replacing(_ existing: [TimedWord], with incoming: [TimedWord],
                          start: Double, end: Double, isFinal: Bool) -> [TimedWord] {
        let retained = existing.filter { word in
            if word.start < end && word.end > start { return false }
            /*
            A volatile replacement may shrink its tail. Finalizing an earlier
            range, however, must preserve newer nonoverlapping hypotheses.
            */
            if !isFinal && !word.isFinal && word.start >= start { return false }
            return true
        }
        return (retained + incoming).sorted { $0.start < $1.start }
    }
}


// TranscriptSnapshot — The transcript at one moment: finalized text plus a changing tail


// Twin: Sources/TokensCore/Transcript/TranscriptSnapshot.swift (see the note on TimedWord).
struct TranscriptSnapshot: Equatable, Sendable {
    var finalizedText: String
    var volatileText: String
    /// Recognition timestamps for `text`'s words when the recognizer supplied
    /// them for every word; empty otherwise. Never estimated.
    var timedWords: [TimedWord] = []

    /*
    finalizedText first, then volatileText, trimmed. A single space goes between them only when
    neither side already has whitespace at the join.
    */
    var text: String {
        [finalizedText, volatileText]
            .filter { !$0.isEmpty }
            .joined(separator: needsSeparator ? " " : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

//
// :)
//
//
    // Words in the finalized part only; the volatile tail can still change, so it is not counted.
    var stableWordCount: Int {
        finalizedText.split(whereSeparator: { $0.isWhitespace }).count
    }

    private var needsSeparator: Bool {
        guard let last = finalizedText.last, let first = volatileText.first else { return false }
        return !last.isWhitespace && !first.isWhitespace
    }
}


// TranscriptAccumulator — Builds the transcript from partial and final recognizer results


// Twin: Sources/TokensCore/Transcript/TranscriptAccumulator.swift (see the note on TimedWord).
/// Applies SpeechTranscriber results without allowing a volatile revision to
/// accumulate while preserving each finalized phrase literally and in order.
struct TranscriptAccumulator: Equatable, Sendable {
    private(set) var finalizedText          = ""
    private(set) var volatileText           = ""
    private var finalizedWords: [TimedWord] = []
    private var volatileWords: [TimedWord]  = []

    /*
    Timed words are attached to the snapshot only if at least one has a real time and the
    words line up one-to-one with the snapshot's text (same words, same order). Otherwise
    `timedWords` stays empty rather than hold times for text that does not match.
    */
    var snapshot: TranscriptSnapshot {
        var snapshot = TranscriptSnapshot(finalizedText: finalizedText, volatileText: volatileText)
        let words    = finalizedWords + volatileWords
        /*
        Untimed words stay as placeholders, so one gap never hides the
        recognizer's timing for every other word.
        */
        if words.contains(where: \.hasTiming),
           words.map(\.text) == snapshot.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            snapshot.timedWords = words
        }
        return snapshot
    }

    /*
    One recognizer result in. A final result is appended to the finalized text and clears the
    partial tail; a partial result replaces the previous partial. Word times ride along only
    when ThinkingComposer.aligned can match them to the text; otherwise each word gets an
    untimed placeholder.
    */
    mutating func apply(_ rawText: String, isFinal: Bool, words: [TimedWord] = []) {
        let text   = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        /*
        The recognizer may group or punctuate timed runs differently from the
        text; times are carried over only when the characters line up.
        */
        let timed = ThinkingComposer.aligned(rawWords: tokens, timed: words)
            ?? tokens.map { TimedWord(text: $0, start: -1, end: -1, isFinal: isFinal) }
        if isFinal {
            finalizedText = appendFinalized(text)
            volatileText  = ""
            volatileWords = []
            finalizedWords += timed
        } else {
            /*
            A partial is a replacement for the previous partial, not a new
            segment. This keeps corrections from duplicating visible text.
            */
            volatileText  = text
            volatileWords = timed
        }
    }

    private func appendFinalized(_ next: String) -> String {
        guard !next.isEmpty else { return finalizedText }
        guard !finalizedText.isEmpty else { return next }
        /*
        SpeechTranscriber emits phrases in order; a final result is the
        phrase for its audio range, not permission to rewrite earlier text.
        Keep literal repeated words because they may be a real new phrase.
        */
        return TranscriptSnapshot(finalizedText: finalizedText, volatileText: next).text
    }
}

