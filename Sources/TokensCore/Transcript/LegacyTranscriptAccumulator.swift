import Foundation

/// SFSpeechRecognizer normally revises the whole request, but can start reporting only
/// the next utterance after silence. Preserve earlier, disjoint audio ranges while
/// continuing to replace revisions of the same range. Never infer a boundary merely
/// from shorter text, punctuation, a pause timer, or a matching/repeated phrase.
public struct LegacyTranscriptAccumulator: Sendable {
    private struct Chunk: Sendable {
        var text: String
        var words: [TimedWord]
        var start: Double?
        var end: Double?
    }
    private var chunks: [Chunk] = []
    private var final = false
    private var lastPauseRevision = 0
    private var pendingPause = false
    public private(set) var failure: String?
    public private(set) var hasAmbiguousReset = false

    public init() {}

    public var snapshot: TranscriptSnapshot {
        let text = chunks.map(\.text).joined(separator: " ")
        let words = chunks.flatMap(\.words)
        return TranscriptSnapshot(finalizedText: final && !hasAmbiguousReset ? text : "",
                                  volatileText: final && !hasAmbiguousReset ? "" : text,
                                  timedWords: words.contains(where: \.hasTiming) ? words : [])
    }

    public mutating func apply(_ rawText: String, isFinal: Bool, words: [TimedWord], pauseRevision: Int = 0) {
        guard failure == nil else { return }
        let crossedPause = !chunks.isEmpty && (pendingPause || pauseRevision != lastPauseRevision)
        pendingPause = crossedPause
        defer { lastPauseRevision = pauseRevision }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some on-device recognizers emit an empty final after a quiet tail. It is
        // completion of recognition, not an instruction to erase the words already heard.
        guard !text.isEmpty else {
            if isFinal { final = true }
            return
        }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let aligned = TimedWordAlignment.align(words: tokens, to: words)
            ?? tokens.map { TimedWord.untimed($0, isFinal: isFinal) }
        let reliable = aligned.allSatisfy { $0.hasTiming && $0.end > $0.start }
            && zip(aligned, aligned.dropFirst()).allSatisfy { $0.start <= $1.start }
        let start = reliable ? aligned.first?.start : nil
        let end = reliable ? aligned.map(\.end).max() : nil
        let chunk = Chunk(text: text, words: aligned, start: start, end: end)

        let previous = chunks.map(\.text).joined(separator: " ")
        let disjointNewRange = start.flatMap { start in chunks.last?.end.map { start >= $0 } } ?? false
        if text == previous && !disjointNewRange {
            // Repeated callbacks without timestamps must not erase known audio ranges.
            if reliable && !hasAmbiguousReset { chunks = [chunk]; pendingPause = false }
            final = final || isFinal
            return
        }
        if hasAmbiguousReset {
            // Once an untimed boundary is ambiguous, keep its earlier words immutable.
            // Continue revising only the latest utterance so each partial is not appended.
            let prefix = chunks.dropLast().map(\.text).joined(separator: " ")
            let active = chunks.last!
            if text == active.text && !disjointNewRange {
                if reliable { chunks[chunks.count - 1] = chunk }
                final = final || isFinal
                return
            }
            if !prefix.isEmpty, text.hasPrefix(prefix + " ") {
                let tail = String(text.dropFirst(prefix.count + 1))
                let tailWords = reliable
                    ? Array(aligned.dropFirst(prefix.split(whereSeparator: { $0.isWhitespace }).count))
                    : tail.split(separator: " ").map { .untimed(String($0), isFinal: isFinal) }
                chunks[chunks.count - 1] = Chunk(text: tail, words: tailWords,
                    start: reliable ? tailWords.first?.start : nil,
                    end: reliable ? tailWords.map(\.end).max() : nil)
            } else if (crossedPause && text != active.text)
                        || (start != nil && active.end != nil && start! >= active.end!) {
                chunks.append(chunk)
            } else {
                chunks[chunks.count - 1] = chunk
            }
            pendingPause = false
            final = isFinal
            return
        }
        if final {
            if text.hasPrefix(previous + " ") { chunks = [chunk] }
            else { chunks.append(chunk) }
        } else if let start, let end, end > start,
           chunks.allSatisfy({ $0.start != nil && $0.end != nil }) {
            // Request-relative timestamps establish which earlier phrases cannot
            // belong to this revision. A cumulative callback starting at zero replaces
            // all of them; a later utterance keeps them. Equal words at different times
            // remain separate spoken words.
            let ambiguousOverlap = chunks.contains {
                $0.start! < end && $0.end! > start
                    && abs($0.start! - start) > 0.02
                    && !(start <= $0.start! && end >= $0.end!)
            }
            if ambiguousOverlap {
                // A suffix-only revision must not remove an earlier cumulative chunk.
                // Its exact word boundary is uncertain: preserve both for manual review.
                hasAmbiguousReset = true
                chunks.append(chunk)
                pendingPause = false
                final = isFinal
                return
            }
            chunks.removeAll { $0.start! < end && $0.end! > start }
            chunks.append(chunk)
            chunks.sort { $0.start! < $1.start! }
            pendingPause = false
        } else if chunks.isEmpty {
            chunks = [chunk]
        } else {
            let prefix = chunks.dropLast().map(\.text).joined(separator: " ")
            if !previous.isEmpty, text.hasPrefix(previous + " ") {
                if reliable {
                    chunks = [chunk]
                    pendingPause = false
                    final = isFinal
                    return
                }
                // Default legacy callbacks are cumulative. Preserve known earlier
                // range provenance; only the newly appended tail is untimed.
                let tail = String(text.dropFirst(previous.count + 1))
                chunks.append(Chunk(text: tail, words: tail.split(separator: " ").map {
                    .untimed(String($0), isFinal: isFinal)
                }, start: nil, end: nil))
            } else if !prefix.isEmpty, text.hasPrefix(prefix + " "), !crossedPause {
                let tail = String(text.dropFirst(prefix.count + 1))
                chunks[chunks.count - 1] = Chunk(text: tail, words: tail.split(separator: " ").map {
                    .untimed(String($0), isFinal: isFinal)
                }, start: nil, end: nil)
            } else if crossedPause
                        || (start != nil && chunks.count > 1 && chunks.contains { $0.start == nil })
                        || (start == nil && chunks.last?.start != nil) {
                // Preservation in the editor is chosen over interrupting dictation:
                // retain both fragments, keep recognizing, and require manual review
                // before Return. The ambiguity flag stays latched for this whole talk.
                hasAmbiguousReset = true
                chunks.append(chunk)
                pendingPause = false
            } else {
                // An ordinary untimed revision before a pause can still correct
                // the active hypothesis, including a shorter, different sentence.
                chunks[chunks.count - 1] = chunk
            }
        }
        final = isFinal
    }
}
