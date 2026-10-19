


//
/// The transcript at one moment of a Talk session.
public struct TranscriptSnapshot: Equatable, Sendable {
    /// Words the recognizer has committed to.
    public var finalizedText: String
    /// The recognizer's current guess for the audio after `finalizedText`. It may still change.
    public var volatileText: String
    /// Recognizer times for the words of `text`. Empty unless the times line up with every
    /// word. Never estimated.
    public var timedWords: [TimedWord]

    public init(finalizedText: String, volatileText: String, timedWords: [TimedWord] = []) {
        self.finalizedText = finalizedText
        self.volatileText  = volatileText
        self.timedWords    = timedWords
    }

    /// The whole transcript, settled words first.
    public var text: String {
        [finalizedText, volatileText]
            .filter { !$0.isEmpty }
            .joined(separator: needsSeparator ? " " : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many leading words will no longer change. The bubble draws these as settled.
    public var stableWordCount: Int {
        finalizedText.split(whereSeparator: { $0.isWhitespace }).count
    }

    private var needsSeparator: Bool {
        guard let last = finalizedText.last, let first = volatileText.first else { return false }
        return !last.isWhitespace && !first.isWhitespace
    }
}

