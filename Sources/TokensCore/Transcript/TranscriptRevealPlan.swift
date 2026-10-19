import Foundation

/// Pure authored timing. Destination writes still require independent exact ACKs.
/// The curve counts non-whitespace graphemes; transport counts all graphemes.
public struct TranscriptRevealPlan: Sendable {
    public enum Tuning {
        public static let targetSeconds = 0.4
        public static let accelerationStarts = 0.1
        public static let pacingFloor = 72
    }

    public private(set) var marker: String
    public let body: String
    public let metadata: String
    public let duration: TimeInterval
    // Kept for source compatibility: there is no special opening-word phase.
    public let openingCharacters = 0
    public let hasSeparateOpening = false
    public let power = 3.0
    public let nonWhitespaceCount: Int
    private let characters: [Character]
    /// For each completed non-whitespace grapheme, the exact body prefix including
    /// whitespace before the next glyph. Entry zero contains leading whitespace.
    private let prefixCounts: [Int]

    public init(marker: String, body: String, metadata: String, spokenWordCount: Int) {
        self.marker = marker
        self.body = body
        self.metadata = metadata
        characters = Array(body)
        var boundaries: [Int] = []
        for (index, character) in characters.enumerated() where !character.isWhitespace {
            boundaries.append(index)
        }
        nonWhitespaceCount = boundaries.count
        boundaries.append(characters.count)
        prefixCounts = boundaries
        duration = Self.completionTime(nonWhitespaceCount)
        // Word counts deliberately have no influence on character pacing.
        _ = spokenWordCount
    }

    public func prependingMarker(_ prefix: String) -> Self {
        var copy = self; copy.marker = prefix + marker; return copy
    }
    public func removingMarker() -> Self {
        var copy = self; copy.marker = ""; return copy
    }
    public var completeText: String { marker + body + metadata }

    /// Fractional non-whitespace grapheme frontier, exactly the approved equation.
    public func position(at elapsed: TimeInterval) -> Double {
        let t = boundedTime(elapsed)
        guard nonWhitespaceCount > 0 else { return 0 }
        // Avoid a floating-point one-grapheme shortfall at the declared endpoint.
        if t >= duration { return Double(nonWhitespaceCount) }
        return min(Double(nonWhitespaceCount), Self.curve(t, count: nonWhitespaceCount))
    }

    /// Right derivative of the clamped frontier, zero once the body is complete.
    public func velocity(at elapsed: TimeInterval) -> Double {
        let t = boundedTime(elapsed)
        guard nonWhitespaceCount > 0, t < duration else { return 0 }
        let late = max(0, t - Tuning.accelerationStarts)
        let boost = Double(max(Tuning.pacingFloor, nonWhitespaceCount) - Tuning.pacingFloor) / pow(0.3, 3)
        return 72 + 540 * t + 3 * boost * late * late
    }

    /// Only whole graphemes are revealed. Whitespace is never synthesized/trimmed.
    public func visibleBodyCount(at elapsed: TimeInterval) -> Int {
        guard nonWhitespaceCount > 0 else { return characters.count }
        let t = boundedTime(elapsed)
        guard t > 0 else { return 0 }
        if t >= duration { return characters.count }
        let frontier = min(nonWhitespaceCount, max(0, Int(position(at: t).rounded(.down))))
        return prefixCounts[frontier]
    }

    /// Authored tags/code are literal raw text too: no protected-span jumps.
    public func safeBodyCount(upTo count: Int) -> Int { min(characters.count, max(0, count)) }
    public func nextSafeBodyCount(after count: Int) -> Int {
        let current = safeBodyCount(upTo: count)
        return current < characters.count ? current + 1 : current
    }
    public func visibleText(at elapsed: TimeInterval) -> String {
        marker + String(characters.prefix(visibleBodyCount(at: elapsed)))
            + (boundedTime(elapsed) >= duration ? metadata : "")
    }

    /// Compatibility helper only; a word count cannot determine early completion.
    public static func duration(forWordCount words: Int) -> TimeInterval {
        words <= 0 ? 0 : Tuning.targetSeconds
    }
    private static func completionTime(_ count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        guard count < Tuning.pacingFloor else { return Tuning.targetSeconds }
        // Stable positive root of 270t² + 72t = N; short bodies finish naturally.
        return 2 * Double(count) / (72 + sqrt(72 * 72 + 1080 * Double(count)))
    }
    private static func curve(_ t: Double, count: Int) -> Double {
        72 * t + 270 * t * t
            + Double(max(Tuning.pacingFloor, count) - Tuning.pacingFloor) / pow(0.3, 3)
            * pow(max(0, t - Tuning.accelerationStarts), 3)
    }
    private func boundedTime(_ elapsed: TimeInterval) -> Double {
        elapsed.isNaN ? 0 : max(0, min(Tuning.targetSeconds, elapsed))
    }
}
