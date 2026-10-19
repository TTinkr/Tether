


//
import Foundation

/// One misheard name: what the recognizer wrote, what was meant, and the words that decide it.
/// `heard` is a case-insensitive regular expression matched as a whole word. The rule fires only
/// when the same sentence (at most 96 characters on each side) contains a `requiresNearby` word
/// and no `blockedBy` word.
public struct ContextualAliasRule: Sendable, Equatable {
    public let heard: String
    public let written: String
    public let requiresNearby: [String]
    public let blockedBy: [String]

    public init(heard: String, written: String, requiresNearby: [String], blockedBy: [String]) {
        self.heard          = heard
        self.written        = written
        self.requiresNearby = requiresNearby
        self.blockedBy      = blockedBy
    }
}

public enum ContextualAlias {
    /*
    Exactly three rules. Quinn -> Qwen stays in Vocabulary.swift. A blocked word anywhere in the
    sentence window always wins over a nearby word.
    */
    public static let rules: [ContextualAliasRule] = [
        ContextualAliasRule(
            heard: #"cloud\s+code"#,
            written: "Claude Code",
            requiresNearby: ["fable", "opus", "sonnet", "haiku", "codex", "agent", "chat", "session",
                             "terminal", "skill", "harness", "worktree"],
            blockedBy: ["storage", "bucket", "aws", "azure", "gcp"]
        ),
        ContextualAliasRule(
            heard: #"codecs"#,
            written: "Codex",
            requiresNearby: ["claude", "gpt", "agent", "chat", "thread", "cli", "exec", "luna", "sol",
                             "terra", "astra", "worktree", "session"],
            blockedBy: ["audio", "video", "ffmpeg", "mp3", "h264", "h265", "aac", "opus audio",
                        "encoder", "decoder", "codec", "compression", "lossless", "lossy",
                        "bitrate", "container", "format", "formats", "media", "streaming"]
        ),
        ContextualAliasRule(
            heard: #"\bsoul\b"#,
            written: "Sol",
            // Model words only: chat, session and agent are in almost every prompt, so
            // "put your soul into this session" must stay soul.
            requiresNearby: ["gpt", "luna", "terra", "astra", "model", "codex"],
            blockedBy: ["music", "brand", "heart", "food", "mate", "searching", "soulful"]
        ),
    ]

    /*
    Code, links, paths, e-mail addresses and spans Tokens already rendered keep their bytes; no
    match may touch them. A link is anything with a scheme ("https://…") or a leading "www.";
    a path is any run of non-space characters containing a slash or backslash
    (~/work/codecs, src/chat/soul.md), and a file or host name is a dotted run (soul.md,
    codecs.swift, example.com), so a word inside one is never rewritten. Every alternative is
    anchored at a token start or bounded, so a long run without spaces stays linear.
    */
    static let protectedPattern =
        #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|`[^`\n]*(?:`|$)|(?i:\b[a-z][a-z0-9+.-]{0,63}://\S*)|(?i:\bwww\.\S*)|(?<!\S)[^\s/\\]*[/\\]\S*|(?<!\S)[^\s@]+@\S*\.\S+|(?<!\S)[^\s.]+(?:\.[^\s.]+)+(?!\S)|<num>.*?(?:</num>|\z)|<char>.*?(?:</char>|\z)|<TC>.*?(?:</TC>|\z)|⟦TC⟧.*?(?:⟦/TC⟧|\z)|<TN>.*?(?:</TN>|\z)|⟦TN⟧.*?(?:⟦/TN⟧|\z)"#

    static let windowLimit = 96

//
// :)
//
//
    /*
    1. Find protected spans. 2. For each rule, longest heard pattern first, find whole-word
    matches that do not touch a protected span or an already accepted match. 3. Keep a match
    only when its sentence window has a nearby word and no blocked word (judged on the input
    text, so the order of rules never changes the outcome). 4. Replace last-to-first so earlier
    ranges stay valid. Text with no accepted match is returned unchanged.

    Words to the right of a match count as context, so a prefix cut mid-sentence can brand
    differently from the full text ("send that to codecs" vs "... codecs in this session"). A caller
    that brands an early prefix should brand the whole partial transcript first and cut the
    prefix from that result. A prefix cut at a finished sentence always agrees with the final.
    */
    public static func apply(_ text: String, rules: [ContextualAliasRule] = rules) -> String {
        guard !text.isEmpty else { return text }
        // The shipped rules compile once per process; only a custom rule list compiles per call.
        let compiled = rules == Self.rules ? CompiledAliasRules.shipped : CompiledAliasRules(rules)
        guard !compiled.rules.isEmpty else { return text }
        let source = text as NSString
        let whole  = NSRange(location: 0, length: source.length)
        var taken  = IndexSet()
        for span in compiled.protected?.matches(in: text, range: whole) ?? [] {
            taken.insert(integersIn: span.range.location ..< NSMaxRange(span.range))
        }
        var accepted: [(range: NSRange, written: String)] = []
        for rule in compiled.rules {
            for match in rule.heard.matches(in: text, range: whole) {
                let span = match.range.location ..< NSMaxRange(match.range)
                guard !taken.intersects(integersIn: span) else { continue }
                let window = sentenceWindow(around: match.range, in: source)
                let windowRange = NSRange(location: 0, length: (window as NSString).length)
                guard rule.blocked.firstMatch(in: window, range: windowRange) == nil,
                      rule.nearby.firstMatch(in: window, range: windowRange) != nil
                else { continue }
                taken.insert(integersIn: span)
                accepted.append((match.range, rule.written))
            }
        }
        guard !accepted.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for item in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: item.range, with: item.written)
        }
        return mutable as String
    }

    /// Sentence stops as UTF-16 units: . ! ? and line feed. Scanned unit by unit because
    /// NSString.rangeOfCharacter can miss a stop when its range starts inside a surrogate pair.
    static func isStop(_ unit: unichar) -> Bool {
        unit == 0x2E || unit == 0x21 || unit == 0x3F || unit == 0x0A
    }

    static func lastStop(in range: NSRange, of source: NSString) -> Int? {
        var index = NSMaxRange(range) - 1
        while index >= range.location {
            if isStop(source.character(at: index)) { return index }
            index -= 1
        }
        return nil
    }

    static func firstStop(in range: NSRange, of source: NSString) -> Int? {
        var index = range.location
        while index < NSMaxRange(range) {
            if isStop(source.character(at: index)) { return index }
            index += 1
        }
        return nil
    }

    /// The same sentence on each side of the match (cut at . ! ? or a line break), at most 96
    /// characters each, joined by a space. The matched words themselves are not included.
    /// Each side scans outward from the match only as far as it needs, so long text with many
    /// matches stays linear instead of re-splitting the whole string per match.
    static func sentenceWindow(around range: NSRange, in source: NSString) -> String {
        leftContext(before: range.location, in: source) + " " + rightContext(after: NSMaxRange(range), in: source)
    }

    /// Text after the last stop before `end`, cut to its last 96 characters.
    static func leftContext(before end: Int, in source: NSString) -> String {
        var span = windowLimit * 2
        while true {
            let raw   = max(0, end - span)
            let start = raw == 0 ? 0 : min(end, source.rangeOfComposedCharacterSequence(at: raw).location)
            let scan  = NSRange(location: start, length: end - start)
            if let stop = lastStop(in: scan, of: source) {
                let from = stop + 1
                return String(source.substring(with: NSRange(location: from, length: end - from)).suffix(windowLimit))
            }
            let text = source.substring(with: scan)
            if start == 0 || text.count > windowLimit { return String(text.suffix(windowLimit)) }
            span *= 2
        }
    }

    /// Text before the first stop after `begin`, cut to its first 96 characters.
    static func rightContext(after begin: Int, in source: NSString) -> String {
        var span = windowLimit * 2
        while true {
            let raw  = min(source.length, begin + span)
            let end  = raw == source.length ? raw : max(begin, NSMaxRange(source.rangeOfComposedCharacterSequence(at: raw)))
            let scan = NSRange(location: begin, length: end - begin)
            if let stop = firstStop(in: scan, of: source) {
                return String(source.substring(with: NSRange(location: begin, length: stop - begin)).prefix(windowLimit))
            }
            let text = source.substring(with: scan)
            if end == source.length || text.count > windowLimit { return String(text.prefix(windowLimit)) }
            span *= 2
        }
    }

    /// Whole-word, case-insensitive alternation of the given words; spaces inside a phrase match
    /// any run of whitespace.
    static func wordExpression(_ words: [String]) -> NSRegularExpression? {
        guard !words.isEmpty else { return try? NSRegularExpression(pattern: #"(?!)"#) }
        let alternatives = words.map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#)
        }
        return try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        )
    }
}

/*
The compiled form of a rule list: the protected-span expression plus each rule's heard, nearby
and blocked expressions, ordered longest heard pattern first (ties keep list order). Compiling
costs milliseconds, so the shipped rules compile once per process. NSRegularExpression is
immutable and documented thread-safe, which is what makes the unchecked Sendable sound.
*/
final class CompiledAliasRules: @unchecked Sendable {
    struct Rule {
        let heard: NSRegularExpression
        let nearby: NSRegularExpression
        let blocked: NSRegularExpression
        let written: String
    }

    static let shipped = CompiledAliasRules(ContextualAlias.rules)

    let protected: NSRegularExpression?
    let rules: [Rule]

    init(_ source: [ContextualAliasRule]) {
        protected = try? NSRegularExpression(pattern: ContextualAlias.protectedPattern)
        let ordered = source.enumerated().sorted { lhs, rhs in
            lhs.element.heard.count == rhs.element.heard.count
                ? lhs.offset < rhs.offset
                : lhs.element.heard.count > rhs.element.heard.count
        }.map(\.element)
        rules = ordered.compactMap { rule in
            guard let heard = try? NSRegularExpression(
                    pattern: #"(?<![\p{L}\p{N}])(?:"# + rule.heard + #")(?![\p{L}\p{N}])"#,
                    options: [.caseInsensitive]),
                  let nearby  = ContextualAlias.wordExpression(rule.requiresNearby),
                  let blocked = ContextualAlias.wordExpression(rule.blockedBy)
            else { return nil }
            return Rule(heard: heard, nearby: nearby, blocked: blocked, written: rule.written)
        }
    }
}

