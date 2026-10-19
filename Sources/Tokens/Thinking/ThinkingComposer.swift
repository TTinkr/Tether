


//
import CoreGraphics
import Foundation


// ThinkingSegment — A run of the talk's words, plus the pauses that come right after it


struct ThinkingSegment: Equatable, Sendable {
    var text: String
    /// Measured silences between this segment's last word and the next one.
    var pausesAfter: [Double]
}


// ThinkingArrivalAnchors — Fallback placement from when words arrived (no word times)


/// Capture-time fallback when the recognizer supplies no word times (legacy
/// ASR). Each transcript update is stamped with the audio clock. Words that
/// had already arrived while a silence was still running were spoken before
/// it. Only a time, a length and a hash are kept; never text or audio.
struct ThinkingArrivalAnchors: Equatable, Sendable {
    struct Update: Equatable, Sendable { var time: Double; var length: Int; var hash: UInt64 }
    static let maximumUpdates = 4096
    /// The recognizer must have been quiet this long before the silence ended.
    static let settleSeconds           = 0.7
    private(set) var updates: [Update] = []
    private(set) var end               = 0.0

    /*
    A transcript is reduced to its lowercase letters and digits ("stream") so that punctuation,
    capitals and spacing changes between an early update and the final text do not matter.
    */
    static func stream(_ text: String) -> [Unicode.Scalar] {
        Array(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    // 64-bit FNV-1a hash (XOR each scalar in, then multiply by the FNV prime) of such a stream.
    static func hash(_ scalars: ArraySlice<Unicode.Scalar>) -> UInt64 {
        scalars.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1.value)) &* 1_099_511_628_211 }
    }

    /*
    Stamps one transcript update with the audio clock. Updates must arrive in time order and be
    finite. An update that looks the same as the previous one (same length and hash) adds
    nothing and is not stored, but `end` still moves forward to its time.
    */
    mutating func record(text: String, at time: Double) {
        guard time.isFinite, time >= end else { return }
        end        = time
        let stream = Self.stream(text)
        let update = Update(time: time, length: stream.count, hash: Self.hash(stream[...]))
        if let last = updates.last, last.length == update.length, last.hash == update.hash { return }
        guard updates.count < Self.maximumUpdates else { return }
        updates.append(update)
    }
    mutating func close(at time: Double) { if time.isFinite { end = max(end, time) } }

    /// Index of the raw word each pause follows, or nothing when the final
    /// text revised what was known during the silence.
    func boundaries(rawWords: [String], pauses: [ThinkingPause]) -> [Int: [Double]] {
        /*
        Lay the final words end to end as one stream, and remember at which stream length each
        word finishes. An update "knew" exactly the first `length` scalars of the final text.
        */
        var stream: [Unicode.Scalar] = []
        var wordEnd: [Int: Int]      = [:]   // stream length -> last word index
        for (index, word) in rawWords.enumerated() {
            stream += Self.stream(word)
            wordEnd[stream.count] = index
        }
        var result: [Int: [Double]] = [:]
        for pause in pauses where pause.duration > 0 {
            /*
            The newest update from before the silence ended must (a) be at least `settleSeconds`
            older than the end of the silence, so the recognizer had gone quiet, (b) stop exactly
            on a word boundary of the final text, and (c) match the final text's start by hash.
            If any of these fail, the final text changed what was known and the pause is skipped.
            */
            guard let known = updates.last(where: { $0.time < pause.end }),
                  known.time <= pause.end - Self.settleSeconds,
                  known.length > 0, known.length <= stream.count,
                  let index = wordEnd[known.length],
                  Self.hash(stream[..<known.length]) == known.hash else { continue }
            // A pause that ends within 0.05 s of the end of the capture is a closing silence.
            let trailing = pause.end >= end - 0.05
            /*
            A closing silence must follow the last word; a mid-talk silence must not.
            Words that arrived late after a closing silence have no anchor.
            */
            if trailing ? index != rawWords.count - 1 : index == rawWords.count - 1 { continue }
            result[index, default: []].append(pause.duration)
        }
        return result
    }
}

//
// :)
//
//
// ThinkingPlacement — Result of placing pauses: segments, unplaced pauses, diagnostics


struct ThinkingPlacement: Equatable, Sendable {
    var segments: [ThinkingSegment]
    /// Measured but not faithfully alignable to a word boundary; never guessed.
    var unplaced: [Double]
    /// Diagnostics only: whether recognizer word times matched the final words, and how many
    /// pauses each method placed.
    var wordTimesAligned  = false
    var placedByWordTimes = 0
    var placedByArrival   = 0
}


// ThinkingComposer — Decides which word each pause follows and writes the note lines


enum ThinkingComposer {


    // Lining recognizer word times up with the final words — key() and aligned()


    /*
    The comparison form of one word: its letters and digits if it has any; otherwise (a word
    made only of symbols or punctuation) its non-punctuation scalars. Empty means pure punctuation.
    */
    private static func key(_ token: String) -> [Unicode.Scalar] {
        let letters = ThinkingArrivalAnchors.stream(token)
        // Symbols such as + or = are content; sentence punctuation is not.
        return letters.isEmpty ? token.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) } : letters
    }

    /// Recognizer times re-expressed per whitespace word of the final text.
    /// Punctuation, case and grouping may differ; the characters may not.
    static func aligned(rawWords: [String], timed: [TimedWord]) -> [TimedWord]? {
        guard !rawWords.isEmpty, !timed.isEmpty else { return nil }
        if rawWords == timed.map(\.text) { return timed }
        /*
        `owners[i]` is the index of the recognizer word that scalar i of `timedStream` came from.
        When the final words' scalars equal that stream (checked just below), each final word can
        be given the earliest start and latest end of the recognizer words it was built from.
        */
        var owners: [Int]                 = []
        var timedStream: [Unicode.Scalar] = []
        for (index, word) in timed.enumerated() {
            let part = key(word.text)
            timedStream += part
            owners += Array(repeating: index, count: part.count)
        }
        let rawKeys = rawWords.map(key)
        /*
        If even one character differs, the final text is not the text the recognizer timed, so
        no times are carried over at all (nil) rather than lining up part of it.
        */
        guard rawKeys.flatMap({ $0 }) == timedStream else { return nil }
        var cursor              = 0
        var result: [TimedWord] = []
        for (text, part) in zip(rawWords, rawKeys) {
            guard !part.isEmpty else {
                // Free-standing punctuation rides with the word before it.
                let previous = result.last?.hasTiming == true ? result.last!.end : -1
                result.append(TimedWord(text: text, start: previous, end: previous, isFinal: true))
                continue
            }
            /*
            The recognizer words that supply this final word's characters. If any lacks a
            time (-1 means "no timing", see TimedWord.hasTiming), this word gets no time either.
            */
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

//
// :)
//
//
    // Deciding which word a pause follows — boundaries() and placed()


    /// Index of the word each pause follows. A pause is placed only when
    /// recognition timestamps put one word wholly before its midpoint and the
    /// next word wholly after it; otherwise it stays unplaced (never guessed).
    /// A closing silence follows the last word when that word ended before it.
    static func boundaries(words: [TimedWord], pauses: [ThinkingPause]) -> [Int: [Double]] {
        placed(words: words, pauses: pauses).reduce(into: [:]) { $0[$1.index, default: []].append($1.pause.duration) }
    }

    /// `weak` marks a placement that only held because the recognizer stretched a word into the
    /// silence; arrival evidence, when it exists, overrides it.
    private static func placed(words: [TimedWord], pauses: [ThinkingPause]) -> [(index: Int, pause: ThinkingPause, weak: Bool)] {
        guard !words.isEmpty else { return [] }
        /*
        Start times that run backwards mean the recognizer's timing is not trustworthy for this
        talk, so nothing at all is placed from it.
        */
        var previous = -Double.infinity
        for word in words where word.hasTiming {
            guard word.start >= previous else { return [] }
            previous = word.start
        }
        var result: [(Int, ThinkingPause, Bool)] = []
        for pause in pauses where pause.duration > 0 {
            /*
            The word a pause follows is the last timed word that ended by the pause's midpoint.
            A pause with no such word (one before the first word) is skipped and stays unplaced.
            */
            let middle = (pause.start + pause.end) / 2
            guard let before = words.lastIndex(where: { $0.hasTiming && $0.end <= middle }),
                  /*
                  Timestamps that contradict the silence are not an alignment. The recognizer may stretch
                  the word before a silence into it ("Wait." to 1.02 s, silence from 0.47 s); it must still
                  have begun before the silence did.
                  */
                  words[before].end <= pause.start + 0.5 || words[before].start < pause.start else { continue }
            let stretchedBefore = words[before].end > pause.start + 0.5
            /*
            After the very last word only the final pause of the talk can be a closing silence;
            an earlier pause with no word left after it is not placed.
            */
            if before + 1 == words.count {
                if pause == pauses.last { result.append((before, pause, stretchedBefore)) }
                continue
            }
            let next = words[before + 1]
            /*
            Apple's recognizer often stretches the next word back into the silence ("First," timed
            from 1.92 s when sound resumed at 3.03 s). A word that begins after the previous one and
            runs past the silence's end is still the first word after it.
            */
            let startsAfter     = next.start >= middle && next.start >= pause.end - 0.5
            let spansSilenceEnd = next.start >= words[before].end && next.end >= pause.end
            guard next.hasTiming, startsAfter || spansSilenceEnd else { continue }
            /*
            The placement is "weak" (arrival evidence may override it) when either neighbouring
            word was stretched into the silence.
            */
            result.append((before, pause, stretchedBefore || !startsAfter))
        }
        return result
    }


    // Splitting the words at placed pauses — segments() and placement()


    /// Splits at placed pauses. Words are never edited, dropped or reordered.
    static func segments(raw: String, words: [TimedWord], pauses: [ThinkingPause]) -> [ThinkingSegment] {
        placement(raw: raw, words: words, pauses: pauses).segments
    }

//
// :)
//
//
    /*
    Order of work: (1) place each pause by recognizer word times, or by arrival anchors; (2) drop
    any split that would change how spelled-out characters read; (3) cut the words into segments;
    (4) re-check that the cut text is word-for-word the input. Any doubt along the way returns
    `whole` (all the words in one segment, every pause unplaced) instead of a partial guess.
    */
    static func placement(raw: String, words: [TimedWord], pauses: [ThinkingPause],
                          anchors: ThinkingArrivalAnchors? = nil) -> ThinkingPlacement {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ThinkingPlacement(segments: [], unplaced: pauses.map(\.duration)) }
        let whole = ThinkingPlacement(segments: [ThinkingSegment(text: text, pausesAfter: [])],
                                         unplaced: pauses.map(\.duration))
        let rawWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !pauses.isEmpty else { return whole }
        var found: [Int: [Double]] = [:]
        let timed                  = aligned(rawWords: rawWords, timed: words)
        let byTimes                = timed.map { placed(words: $0, pauses: pauses) } ?? []
        var byWordTimes            = 0, byArrival = 0
        /*
        Pauses are matched by identity, never by duration: two equal pauses are still two pauses.
        Preference for each pause: a firm word-time placement, else an arrival-anchor placement,
        else the weak word-time placement; with none of these the pause stays unplaced.
        */
        for pause in pauses {
            let timedHit = byTimes.first { $0.pause == pause }
            if let timedHit, !timedHit.weak {
                found[timedHit.index, default: []].append(pause.duration); byWordTimes += 1
            } else if let anchors, let (index, durations) = anchors.boundaries(rawWords: rawWords, pauses: [pause]).first {
                // When the words arrived is direct evidence; it beats a stretched-word guess.
                found[index, default: []] += durations; byArrival += 1
            } else if let timedHit {
                found[timedHit.index, default: []].append(pause.duration); byWordTimes += 1
            }
        }
        // A split inside spelled characters would change how they are read.
        let reference = normalized(CharacterTalk.render(text).markdownText)
        found = found.filter { index, _ in
            guard index + 1 < rawWords.count else { return true }
            let left = rawWords[...index].joined(separator: " "), right = rawWords[(index + 1)...].joined(separator: " ")
            return normalized(CharacterTalk.render(left).markdownText + " " + CharacterTalk.render(right).markdownText) == reference
        }
        guard !found.isEmpty else { return whole }
        /*
        Cut after each placed word, in word order. Any words after the last cut become a final
        segment with no pauses after it.
        */
        var result: [ThinkingSegment] = []
        var start = 0
        for index in found.keys.sorted() {
            result.append(ThinkingSegment(text: rawWords[start...index].joined(separator: " "),
                                             pausesAfter: found[index] ?? []))
            start = index + 1
        }
        if start < rawWords.count {
            result.append(ThinkingSegment(text: rawWords[start...].joined(separator: " "), pausesAfter: []))
        }
        /*
        Last check before trusting the cut: the segments joined back together must be exactly the
        input words in the same order, and must render the same as the uncut text.
        */
        let rebuilt = result.map(\.text).joined(separator: " ")
        guard rebuilt.split(whereSeparator: { $0.isWhitespace }).map(String.init) == rawWords,
              normalized(result.map { CharacterTalk.render($0.text).markdownText }.joined(separator: " ")) == reference
        else { return whole }
        /*
        Whatever was not placed is reported as "unplaced". Placed durations are crossed off by
        value, one for one, which is safe because equal durations are interchangeable here.
        */
        var remaining = pauses.map(\.duration)
        for duration in found.values.flatMap({ $0 }) {
            if let index = remaining.firstIndex(of: duration) { remaining.remove(at: index) }
        }
        return ThinkingPlacement(segments: result, unplaced: remaining, wordTimesAligned: timed != nil,
                                    placedByWordTimes: byWordTimes, placedByArrival: byArrival)
    }

//
// :)
//
//
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }


    // Writing and removing the "Thinking" note lines


    // One standalone note line, e.g. THINK (3.2304s), separate from the spoken words.
    static func annotation(seconds: Double) -> String {
        "THINK (\(String(format: "%.4f", max(0, seconds)))s)"
    }

    /// Honest remainder: silence that was measured but could not be aligned.
    static func unplacedSummary(_ pauses: [Double]) -> String? {
        guard !pauses.isEmpty else { return nil }
        return "THINK (unplaced ×\(pauses.count) · \(String(format: "%.4f", pauses.reduce(0, +)))s · measured silence, position not aligned to words)"
    }

    /// `paragraphs` renders one segment's words (formatting is optional and
    /// already validated); annotations are separate lines between segments.
    static func body(_ segments: [ThinkingSegment], unplaced: [Double] = [], paragraphs: (String) -> String) -> String {
        var blocks: [String] = []
        for segment in segments {
            blocks.append(paragraphs(segment.text))
            blocks.append(contentsOf: segment.pausesAfter.map(annotation(seconds:)))
        }
        if let summary = unplacedSummary(unplaced) { blocks.append(summary) }
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Stored prompts can contain either unplaced spelling or the original italic markers.
    /// Whole-line matching keeps prose that merely mentions THINK in the spoken text.
    static func isAnnotation(_ line: String) -> Bool {
        line.range(of: #"^(?:THINK \((?:\d+\.\d{4}s|unplaced ×\d+ · \d+\.\d{4}s · measured silence, position not aligned to words)\)|THINK unplaced ×\d+ \(\d+\.\d{4}s\) · measured silence, position not aligned to words|\*Thinking · (?:\d+\.\d{2,3} s|unplaced ×\d+ · \d+\.\d{3} s · measured silence, position not aligned to words)\*)$"#,
                   options: .regularExpression) != nil
    }

    // Read both historical standalone notes and the launch inline TK presentation.
    static func removingAnnotations(_ body: String) -> String {
        InlineTalkMarkdown.removingMarkers(body)
    }


}

