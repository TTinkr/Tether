


//
import CoreGraphics
import Foundation


// ThinkingFidelity — Checks that formatting only decorates the words and never changes them


/// Decoration may be added to a paragraph; its content may not change.
enum ThinkingFidelity {
    /// Numbers, URLs, currency and operators are content, not decoration.
    /// The pattern finds, in order of the alternatives: web links, email addresses, numbers (with
    /// . , : inside them), single operator or currency symbols, and a minus sign right before a
    /// number. Trailing sentence punctuation is trimmed so "42." and "42" compare equal.
    static func protectedTokens(_ text: String) -> [String] {
        let pattern = #"https?://[^\s]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+|\d+(?:[.,:]\d+)*|[=+*/<>^%±×÷≤≥−$€£¥#@&|~\\]|-(?=\s*\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
        }.filter { !$0.isEmpty }
    }

    static func emojiCount(_ text: String) -> Int {
        text.filter { character in
            character.unicodeScalars.contains {
                $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C)
            }
        }.count
    }

    /*
    True only if `proposal` (a model's formatted version of `raw`) is safe to show. Every rule
    below can only say no: too long, too many lines, code fences or tags, list/heading/quote/table
    starts, any change to the words, unbalanced or too many bold marks, any change to the
    protected tokens (numbers, links, symbols), or more than two added emoji.
    */
    static func accepts(raw: String, proposal: String) -> Bool {
        let lines = proposal.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let words = LexicalFidelity.words(in: raw)
        guard !lines.isEmpty, !words.isEmpty,
              proposal.count <= raw.count + raw.count / 2 + 40,
              lines.count <= max(3, words.count / 4),
              !proposal.contains("```"), !proposal.contains("<transcript"), !proposal.contains("</"),
              // No bullets, headings, quotes or tables: emphasis only.
              !lines.contains(where: { $0.range(of: #"^\s*(?:[-*•‣·–—>#|]\s|#|\d{1,3}[.)]\s)"#, options: .regularExpression) != nil }),
              LexicalFidelity.preservesWords(raw: raw, formatted: proposal) else { return false }
        /*
        `bold` counts "**" marks, so it must be even (every bold span closed); at most 6 marks
        means at most 3 bold spans.
        */
        let bold = proposal.components(separatedBy: "**").count - 1
        guard bold % 2 == 0, bold <= 6, !proposal.contains("****"), !proposal.contains("__") else { return false }
        let plain = proposal.replacingOccurrences(of: "**", with: "")
        guard protectedTokens(plain) == protectedTokens(raw) else { return false }
        return emojiCount(proposal) - emojiCount(raw) <= 2
    }

    /// Strips wrappers a small model may echo; never touches words.
    static func sanitize(_ output: String) -> String {
        var text = output
        // Removes every <think>…</think> block, even across several lines, one block per loop pass.
        while let range = text.range(of: #"(?s)<think>.*?</think>"#, options: .regularExpression) { text.removeSubrange(range) }
        for tag in ["<transcript>", "</transcript>"] { text = text.replacingOccurrences(of: tag, with: "") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


// ThinkingTitle — Cleans a title and checks it only uses words the speaker actually said


/// The title is a label derived from the words; it is never part of the body
/// and can carry nothing but a few plain words.
enum ThinkingTitle {

//
// :)
//
//
    // Cleaning a proposed title — fallback and sanitize()


    static let fallback = "Thinking with tinkr"

    /*
    Turns raw model output into a title, or nil if it cannot be trusted as one. Order: strip
    wrappers, take the first non-empty line, drop a leading "Title:" or "Subject:" label, keep
    only letters, digits and a few plain marks, then require 1 to 8 words, at most 60
    characters, a letter in it, and no "http". Last, it must be grounded in the transcript (see below).
    */
    static func sanitize(_ output: String, transcript: String) -> String? {
        let cleaned = ThinkingFidelity.sanitize(output)
        guard let line = cleaned.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        var title = line.replacingOccurrences(of: #"(?i)^(?:title|subject)\s*[:\-–—]\s*"#, with: "", options: .regularExpression)
        title = String(title.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || " '’&-.".unicodeScalars.contains($0)
        }.map(Character.init))
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let words = title.split(separator: " ")
        guard (1...8).contains(words.count), title.count <= 60,
              title.contains(where: { $0.isLetter }), !title.lowercased().contains("http") else { return nil }
        /*
        A subject comes from what was said; anything else is the model talking.
        Words are compared by their first four letters (so "deploy" matches "deployment"), and
        more than half of the title's words of four letters or more must match a spoken word.
        */
        let spoken   = Set(LexicalFidelity.words(in: transcript).map { String($0.prefix(4)) })
        let content  = LexicalFidelity.words(in: title).filter { $0.count >= 4 }
        let grounded = content.filter { spoken.contains(String($0.prefix(4))) }.count
        guard !content.isEmpty, grounded * 2 > content.count else { return nil }
        return title
    }


    // Keyword title — a plain fallback label built from repeated words


    /*
    Word lists used by keywords(): filler words that never make a title (titleStopwords),
    negation words that mark the words just after them (titleNegations), and words never put
    in a title at all: profanity, and "password", "secret", "token" (titleUnfit).
    */
    private static let titleStopwords: Set<String> = ["about", "actually", "after", "again", "also", "alright", "another", "basically",
        "because", "been", "being", "could", "definitely", "doing", "does", "dont", "even", "every", "exactly", "from", "going", "gonna",
        "have", "here", "into", "just", "kind", "kinda", "know", "like", "little", "maybe", "mean", "more", "much", "need", "okay",
        "only", "other", "over", "really", "right", "should", "some", "something", "sort", "still", "such", "sure", "that", "thats",
        "their", "them", "then", "there", "these", "they", "thing", "things", "think", "this", "those", "very", "want", "well", "were",
        "what", "when", "where", "which", "while", "will", "with", "would", "yeah", "your", "youre"]

    private static let titleNegations: Set<String> = ["not", "no", "never", "dont", "doesnt", "didnt", "cant", "cannot", "wont", "without", "stop", "avoid"]
    private static let titleUnfit: Set<String> = ["fuck", "fucking", "fucked", "shit", "shitty", "damn", "crap", "hell", "bitch", "password", "secret", "token"]

    /// A plain label from words the speaker kept returning to, for when no model title is ready.
    /// Up to three words in the order first spoken. Nil unless every chosen word was said at least
    /// twice and none follows a negation ("do not delete the database" is not titled "Delete database").
    static func keywords(transcript: String) -> String? {
        let words = LexicalFidelity.words(in: transcript).map { $0.lowercased().filter { $0.isLetter } }
        // Talks shorter than 8 words get no keyword title.
        guard words.count >= 8 else { return nil }
        var counts: [String: Int] = [:], firstSeen: [String: Int] = [:], negated: Set<String> = []
        for (index, word) in words.enumerated() where word.count >= 4 && !titleStopwords.contains(word) && !titleUnfit.contains(word) {
            counts[word, default: 0] += 1
            if firstSeen[word] == nil { firstSeen[word] = index }
            // A word is "negated" if a negation word appears in the three words before any of its uses.
            if words[max(0, index - 3)..<index].contains(where: titleNegations.contains) { negated.insert(word) }
        }
        /*
        Take the three most-repeated words (earlier first-spoken wins a tie), then put them back
        in the order the speaker first said them.
        */
        let repeated = counts.keys.filter { counts[$0]! >= 2 }
        let chosen   = repeated.sorted { (counts[$0]!, -firstSeen[$0]!) > (counts[$1]!, -firstSeen[$1]!) }.prefix(3)
            .sorted { firstSeen[$0]! < firstSeen[$1]! }
        guard chosen.count >= 2, negated.isDisjoint(with: chosen) else { return nil }
        let label = chosen.joined(separator: " ")
        return label.prefix(1).uppercased() + label.dropFirst()
    }

//
// :)
//
//
    // Checking a title against the spoken words — best(), everyWordSpoken(), mostlySpoken()


    /// The first candidate, in priority order, that is still a grounded title
    /// for the final words. Earlier titles were grounded in fewer words.
    static func best(_ candidates: [String?], transcript: String) -> String? {
        for case let candidate? in candidates {
            if let clean = sanitize(candidate, transcript: transcript), everyWordSpoken(clean, transcript: transcript) { return clean }
        }
        return nil
    }

    /// A stored title may only rearrange the speaker's words. Short names, negation and
    /// numbers carry meaning too: "Sam", "not" and "2" cannot bypass this check.
    static func everyWordSpoken(_ title: String, transcript: String) -> Bool {
        let spoken  = Set(LexicalFidelity.words(in: transcript).map { $0.lowercased() })
        let content = LexicalFidelity.words(in: title)
        return !content.isEmpty && content.allSatisfy { spoken.contains($0.lowercased()) }
    }

    /// For a delivered summary line: most of its words were spoken, and it names no one the speaker
    /// did not name.
    /// Keep proposal capitalization until the name check; lowercasing first silently disables it.
    static func mostlySpoken(_ line: String, transcript: String) -> Bool {
        let spokenWords = LexicalFidelity.words(in: transcript).map { $0.lowercased() }
        let spoken      = Set(spokenWords)
        let words       = LexicalFidelity.casePreservingWords(in: line)
        let content     = words.filter { $0.count >= 4 }
        guard !content.isEmpty else { return false }
        let grounded = content.filter { spoken.contains($0.lowercased()) }.count
        guard Double(grounded) >= 0.7 * Double(content.count) else { return false }
        // A capitalised word after the first is a name: it must have been said.
        return words.dropFirst().allSatisfy { word in
            guard let first = word.first, first.isUppercase, word.count >= 3 else { return true }
            return spoken.contains(word.lowercased())
        }
    }


}


// ThinkingHeaderNote — One AI-labelled blockquote line for the delivered header


/// One AI-labelled blockquote line for the delivered header. It goes only into
/// the presented copy (TokensDecoration.decoratePrompt), never into
/// `faithful`, history or the dataset; spokenText already drops `>` lines.
enum ThinkingHeaderNote {
    static let maximumCharacters = 320

    /*
    Builds `> *label:* text`. The label keeps only letters, digits and " ·:.-_/"; the text loses
    markdown characters (* ` _ < > [ ] { } \ | #) and is squeezed to single spaces, so a model's
    text cannot add markdown formatting or extra lines. Nil when either part is empty (the text
    needs a letter) or the finished line is longer than `maximumCharacters`.
    */
    static func line(label: String, text: String) -> String? {
        let tag = label.filter { $0.isLetter || $0.isNumber || " ·:.-_/".contains($0) }
            .split(separator: " ").joined(separator: " ")
        let body = text.filter { !"*`_<>[]{}\\|#".contains($0) }
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !tag.isEmpty, body.contains(where: \.isLetter) else { return nil }
        let line = "> *\(tag):* \(body)"
        return line.count <= maximumCharacters ? line : nil
    }
}


// SpeechGapTiming — Pauses estimated from recognizer word times, not measured silence


/// Gaps on the recognizer's audio timeline, not proof of microphone silence.
/// Missing or contradictory word timing must never fabricate a gap.
enum SpeechGapTiming {

//
// :)
//
//
    /*
    Every gap between one word's end and the next word's start that is at least
    `minimumAnnotatedPause` becomes a ThinkingPause, plus a closing gap up to `audioEnd`.
    It gives up with an empty list (no gaps invented) if any word lacks a usable time, runs
    more than 0.5 s past the audio end, or if start times go backwards.
    */
    static func pauses(words: [TimedWord], audioEnd: Double, includeTrailing: Bool = true) -> [ThinkingPause] {
        guard audioEnd.isFinite, audioEnd > 0, !words.isEmpty,
              words.allSatisfy({ $0.hasTiming && $0.start >= 0 && $0.end <= audioEnd + 0.5 }) else { return [] }
        var previousEnd             = words[0].end
        var previousStart           = words[0].start
        var result: [ThinkingPause] = []
        for word in words.dropFirst() {
            guard word.start >= previousStart else { return [] }
            if word.start - previousEnd >= ThinkingPauseTracker.minimumAnnotatedPause {
                result.append(ThinkingPause(start: previousEnd, end: word.start))
            }
            previousStart = word.start
            // Words may overlap in time, so the running end is the latest end seen, not the last word's.
            previousEnd = max(previousEnd, word.end)
        }
        if includeTrailing && audioEnd - previousEnd >= ThinkingPauseTracker.minimumAnnotatedPause {
            result.append(ThinkingPause(start: previousEnd, end: audioEnd))
        }
        return Array(result.prefix(ThinkingPauseTracker.maximumPauses))
    }
    /*
    The gap in progress right now, in seconds, as an estimate: the newest word ended at least
    1 s before `audioEnd`, and the live transcript has not changed for 0.75 s (`revisionAge` is
    the seconds since its last change). Nil otherwise.
    */
    static func live(words: [TimedWord], audioEnd: Double, revisionAge: Double) -> Double? {
        guard revisionAge >= 0.75, let last = words.last, last.hasTiming,
              audioEnd.isFinite, audioEnd >= last.end,
              audioEnd - last.end >= 1 else { return nil }
        return audioEnd - last.end
    }
}


// ThinkingPrompt — Builds the delivered header (title, receipt, notes) plus the words


/// Tokens envelope with a separate subject title and measured-silence notes.
enum ThinkingPrompt {
    static let note = "> *Thinking tags record measured microphone silence only, not a claim about thought.*"

    /*
    The header is, in order: a "# π title" line (the fallback title if none), the receipt line
    (seconds, word count, words per minute, number and total of pauses), a fixed line saying the
    text was talked and may contain errors, and one note about the pauses. That last note says
    either that none were recorded, that they are estimated gaps (speechGapEstimate), or that
    they are measured silence. Words are counted from `countTranscript`; a talk of zero length
    or a non-finite time gives 0 words per minute rather than a bad number.
    */
    static func header(title: String?, durationSeconds: Double, countTranscript: String, pauses: [Double], speechGapEstimate: Bool = false) -> String {
        let words             = LexicalFidelity.words(in: countTranscript).count
        let time              = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        let rate              = time > 0 ? Double(words) * 60 / time : 0
        let wpm               = String(format: "%.0f", rate.isFinite ? rate : 0)
        let totalPauseSeconds = String(format: "%.4f", pauses.reduce(0, +))
        var stats             = "\(String(format: "%.4f", time))s · \(words) words · \(wpm) wpm"
        stats += " · \(pauses.count)x thinking (\(totalPauseSeconds)s)"
        var lines = ["# π \(title ?? ThinkingTitle.fallback)", "", "> *\(stats)*",
                     "> *Talked, not typed. Transcription may contain errors; use context to interpret unclear words.*"]
        lines.append(pauses.isEmpty
            ? "> *No thinking pauses recorded.*"
            : speechGapEstimate
            ? "> *Thinking timings are estimated gaps between recognized speech, not measured microphone silence or claims about thought.*"
            : note)
        return lines.joined(separator: "\n") + "\n\n"
    }

    // Header plus body, or an empty string when the body has no text, so an empty talk delivers nothing.
    static func format(title: String?, body: String, durationSeconds: Double,
                       countTranscript: String, pauses: [Double], speechGapEstimate: Bool = false) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return header(title: title, durationSeconds: durationSeconds,
                      countTranscript: countTranscript, pauses: pauses, speechGapEstimate: speechGapEstimate) + text
    }
}

