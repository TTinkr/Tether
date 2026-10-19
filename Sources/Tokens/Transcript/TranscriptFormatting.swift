


//
import CoreGraphics
import Foundation


// ParagraphFormatter — Adds paragraph breaks at sentence ends; changes whitespace only


/// A zero-inference paragraph pass. Only existing horizontal whitespace at
/// conservative sentence boundaries may become a blank line. Never edits words,
/// case, punctuation, existing line breaks, or short prompts.
enum ParagraphFormatter {
    /*
    How it works: (1) every lone line break becomes a blank line; (2) find sentence ends, meaning
    . ! or ? followed by spaces or tabs and then a capital letter; (3) walk them in order,
    counting sentences in the current paragraph, and mark a cut when the count reaches
    `sentencesPerParagraph`, the paragraph reaches 110 words, or it reaches 65 words and the
    next word is a transition ("Also", "Anyway", ...); (4) turn each marked space into a blank line.
    */
    static func format(_ raw: String, sentencesPerParagraph: Int = 3) -> String {
        let cadence = max(1, sentencesPerParagraph)
        /*
        A line break with no neighbouring line break becomes a blank line (a paragraph break).
        Only whitespace changes; the last check below enforces that.
        */
        let promoted = raw.replacingOccurrences(
            of: #"(?<!\n)\n(?!\n)"#,
            with: "\n\n",
            options: .regularExpression
        )
        guard let expression = try? NSRegularExpression(pattern: #"(?<=[.!?])[\t ]+(?=[A-Z])"#) else { return raw }
        let source = promoted as NSString
        let boundaries = expression.matches(in: promoted, range: NSRange(location: 0, length: source.length))
        let transitions: Set<String> = ["Also", "Anyway", "Next", "However", "Separately", "Finally", "Meanwhile"]
        let abbreviations: Set<String> = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "St.", "Jr.", "Sr.", "U.S.", "U.K."]
        var cuts: [NSRange] = []
        var paragraphStart = 0
        var sentenceCount = 0
        var lastBoundaryEnd = 0
        for boundary in boundaries {
            /*
            Find the nearest earlier line break. The current line starts just after it, but
            never before the start of the paragraph being built (`lineStart` below).
            */
            let existingBreak = source.range(of: "\n", options: .backwards,
                                             range: NSRange(location: 0, length: boundary.range.location))
            let lineStart = existingBreak.location == NSNotFound ? paragraphStart : max(paragraphStart, NSMaxRange(existingBreak))
            if existingBreak.location != NSNotFound && existingBreak.location >= lastBoundaryEnd {
                // Respect existing paragraph boundaries and restart the sentence budget.
                sentenceCount = 0
            }
            let current = source.substring(with: NSRange(location: lineStart, length: boundary.range.location - lineStart))
            let words = current.split(whereSeparator: { $0.isWhitespace })
            /*
            A period after "Dr.", "U.S." and the like, or after a one-letter initial ("J."), does
            not end a sentence, so it is not counted and cannot start a new paragraph.
            */
            if let last = words.last, !abbreviations.contains(String(last)),
               !(last.count == 2 && last.first?.isLetter == true) {
                sentenceCount += 1
                let suffix = source.substring(from: NSMaxRange(boundary.range))
                let next   = String(suffix.prefix(while: { $0.isLetter }))
                if sentenceCount >= cadence || words.count >= 110 || (words.count >= 65 && transitions.contains(next)) {
                    cuts.append(boundary.range)
                    paragraphStart = NSMaxRange(boundary.range)
                    sentenceCount  = 0
                }
            }
            lastBoundaryEnd = NSMaxRange(boundary.range)
        }
        // Cuts are applied last-to-first so each earlier range is still where it was measured.
        let result = NSMutableString(string: promoted)
        for cut in cuts.reversed() { result.replaceCharacters(in: cut, with: "\n\n") }
        let proposed = result as String
        // Stronger than lexical comparison: every nonwhitespace scalar is exact.
        return raw.filter { !$0.isWhitespace } == proposed.filter { !$0.isWhitespace } ? proposed : raw
    }
}

//
// :)
//
//
// MarkdownFormatter — Title, optional metadata line, then the paragraph-formatted words


/// Incremental, zero-inference Markdown rendering. Each changing ASR snapshot
/// can be rendered immediately; syntax never edits or reorders transcript words.
enum MarkdownFormatter {
    static let title = "# Talked with Tinkr"

    /*
    Output shape: the title line, a blank line, an optional `> ` metadata line (only when
    `metadataEnabled` and a duration are given) with a blank line, then the body. Empty or
    whitespace-only input gives "". If paragraphing changed any word, the unparagraphed text is used.
    */
    static func format(
        _ raw: String,
        durationSeconds: Double? = nil,
        metadataEnabled: Bool = false,
        metadataTranscript: String? = nil
    ) -> String {
        let transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return "" }
        let body     = ParagraphFormatter.format(transcript, sentencesPerParagraph: 2)
        let safeBody = LexicalFidelity.preservesWords(raw: transcript, formatted: body)
            ? body
            : transcript
        var lines = [title, ""]
        if metadataEnabled,
           let durationSeconds,
           let metadata = metadataLine(
                for: metadataTranscript ?? transcript,
                durationSeconds: durationSeconds
           ) {
            lines.append(metadata)
            lines.append("")
        }
        lines.append(safeBody)
        return lines.joined(separator: "\n")
    }

    private static func metadataLine(for transcript: String, durationSeconds: Double) -> String? {
        TranscriptMetadata.line(for: transcript, durationSeconds: durationSeconds)
            .map { "> \($0)" }
    }
}


// LexicalFidelity — Compares two texts by their words only, ignoring case and punctuation


/*
Twin: Sources/TokensCore/LexicalFidelity.swift. Tokens depends on TokensCore,
but this local implementation also provides case-preserving title tokens.
*/
enum LexicalFidelity {
    /*
    Words are runs of letters, digits and apostrophes, lowercased, with the curly apostrophe
    made straight. Everything else separates words. Repeats and order are kept, so two texts
    match only if they have the same words the same number of times in the same order.
    */
    static func words(in text: String) -> [String] {
        casePreservingWords(in: text).map { $0.lowercased() }
    }

    /*
    Title grounding needs original capitalization to reject an invented name.
    Reuse the same token boundaries; ordinary fidelity checks remain case-insensitive.
    */
    static func casePreservingWords(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
    }

//
// :)
//
//
    static func preservesWords(raw: String, formatted: String) -> Bool {
        words(in: raw) == words(in: formatted)
    }

    static func acceptedText(raw: String, proposed: String) -> String {
        preservesWords(raw: raw, formatted: proposed) ? proposed : raw
    }
}


// VisualSentenceBatch — Picks how much text to reveal next: up to two more whole sentences


// Used by the on-screen word reveal (Features/TranscriptStream/WordReveal.swift).
enum VisualSentenceBatch {
    /*
    `visible` is what is already on screen and `canonical` is the full text so far. Returns
    `canonical` cut after the second complete sentence beyond `visible`; or after the last
    complete one if only one is finished; or `visible` unchanged if none is. A sentence is
    complete at . ! or ? followed by whitespace or the end of the text. If `visible` is not a
    prefix of `canonical` (the text was revised), the whole of `canonical` is returned.
    */
    static func target(canonical: String, visible: String) -> String {
        guard canonical.hasPrefix(visible) else { return canonical }
        let start      = canonical.index(canonical.startIndex, offsetBy: visible.count)
        var boundaries = 0
        var lastEnd    = start
        for index in canonical[start...].indices {
            let next = canonical.index(after: index)
            if ".!?".contains(canonical[index]),
               next == canonical.endIndex || canonical[next].isWhitespace {
                boundaries += 1
                lastEnd = next
                if boundaries == 2 { return String(canonical[..<next]) }
            }
        }
        return String(canonical[..<lastEnd])
    }
}

