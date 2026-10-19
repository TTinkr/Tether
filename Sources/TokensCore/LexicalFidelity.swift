


//
/*
LexicalFidelity — preserve the spoken word sequence
Owns: the final check before a presentation change replaces recognized text.
Never: accept deletion, reordering, or a changed contraction as cosmetic formatting.
*/


import Foundation

/// Compares recognized words without allowing a presentation step to delete,
/// reorder, or replace them.
public enum LexicalFidelity {
    /// Returns case-insensitive lexical tokens while retaining apostrophes in words.
    public static func words(in text: String) -> [String] {
        /*
        Ignore presentation punctuation, but preserve apostrophes so 'do not' and
        'don't' remain different utterances. Array equality also retains repeated words.
        */
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'").lowercased() }
    }

    /// True only when both inputs contain the same lexical tokens in the same order.
    public static func preservesWords(raw: String, formatted: String) -> Bool {
        words(in: raw) == words(in: formatted)
    }

    /// Accepts a proposed presentation only when it retains the raw lexical sequence.
    public static func acceptedText(raw: String, proposed: String) -> String {
        preservesWords(raw: raw, formatted: proposed) ? proposed : raw
    }
}

