


//
import Foundation


// TimedWordAlignment — carry the recognizer's word times onto the final words


/// Re-expresses recognizer timings per whitespace-separated word of the final text.
///
/// Trap: the speech recognizer times its own "runs", which are punctuated and grouped
/// differently from the text it returns ("2" + ".5." for "2.5.", a lone "," after "Okay").
/// Times are only trusted when both sides contain the same letters and digits in the same order.
public enum TimedWordAlignment {
    /// The lowercase letters and digits of a text, with spacing and punctuation removed.
    public static func alphanumerics(of text: String) -> [Unicode.Scalar] {
        Array(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// What a token contributes to the comparison.
    ///
    /// Symbols such as + or = are content when a token has no letters; sentence punctuation is not.
    private static func key(_ token: String) -> [Unicode.Scalar] {
        let letters = alphanumerics(of: token)
        return letters.isEmpty
            ? token.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
            : letters
    }

    /// One timed word per entry of `words`, or nil when the two sides differ in content.
    ///
    /// Punctuation, case and grouping may differ between the two sides; the characters may not.
    /// A word built from several timed runs spans from the first run's start to the last run's end.
    public static func align(words: [String], to timed: [TimedWord]) -> [TimedWord]? {
        guard !words.isEmpty, !timed.isEmpty else { return nil }
        if words == timed.map(\.text) { return timed }

        // Flatten the timed runs into one character stream, remembering which run owns each character.
        var owners: [Int]                 = []
        var timedStream: [Unicode.Scalar] = []
        for (index, word) in timed.enumerated() {
            let part = key(word.text)
            timedStream += part
            owners += Array(repeating: index, count: part.count)
        }
        let wordKeys = words.map(key)
        guard wordKeys.flatMap({ $0 }) == timedStream else { return nil }

        var cursor              = 0
        var result: [TimedWord] = []
        for (text, part) in zip(words, wordKeys) {
            guard !part.isEmpty else {
                // Free-standing punctuation rides with the word before it.
                let previous = result.last?.hasTiming == true ? result.last!.end : -1
                result.append(TimedWord(text: text, start: previous, end: previous, isFinal: true))
                continue
            }
            let sources = timed[owners[cursor]...owners[cursor + part.count - 1]]
            cursor += part.count
            let usable = sources.allSatisfy(\.hasTiming)
            result.append(TimedWord(text: text,
                                    start: usable ? sources.map(\.start).min() ?? -1 : -1,
                                    end: usable ? sources.map(\.end).max() ?? -1 : -1,
                                    isFinal: sources.allSatisfy(\.isFinal)))
        }
        return result
    }
}

