


//
import Foundation


// TranscriptAccumulator — build the transcript from partial and final results


/// Collects recognizer results into one transcript.
///
/// Theorem: every finalized phrase is kept literally and in order. A partial result replaces
/// only the previous partial, so corrections never duplicate visible text.
public struct TranscriptAccumulator: Equatable, Sendable {
    public private(set) var finalizedText   = ""
    public private(set) var volatileText    = ""
    private var finalizedWords: [TimedWord] = []
    private var volatileWords: [TimedWord]  = []

    public init() {}

    public var snapshot: TranscriptSnapshot {
        var snapshot = TranscriptSnapshot(finalizedText: finalizedText, volatileText: volatileText)
        let words    = finalizedWords + volatileWords
        /*
        Untimed words stay as placeholders, so one gap never hides the recognizer's timing
        for every other word.
        */
        if words.contains(where: \.hasTiming),
           words.map(\.text) == snapshot.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            snapshot.timedWords = words
        }
        return snapshot
    }

    /// Applies one recognizer result.
    ///
    /// - Parameters:
    ///   - isFinal: true when the recognizer will not revise this phrase again.
    ///   - words: the recognizer's timed runs for this phrase, when it supplied any.
    public mutating func apply(_ rawText: String, isFinal: Bool, words: [TimedWord] = []) {
        let text   = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let timed  = TimedWordAlignment.align(words: tokens, to: words)
            ?? tokens.map { TimedWord.untimed($0, isFinal: isFinal) }
        if isFinal {
            finalizedText = appendFinalized(text)
            volatileText  = ""
            volatileWords = []
            finalizedWords += timed
        } else {
            volatileText  = text
            volatileWords = timed
        }
    }

    private func appendFinalized(_ next: String) -> String {
        guard !next.isEmpty else { return finalizedText }
        guard !finalizedText.isEmpty else { return next }
        /*
        The recognizer emits phrases in order. A final result is the phrase for its own audio
        range, not permission to rewrite earlier text. A literally repeated phrase is kept,
        because the person may really have said it twice.
        */
        return TranscriptSnapshot(finalizedText: finalizedText, volatileText: next).text
    }
}

