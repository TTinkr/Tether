


//
/// One word of a Talk session with the recognizer's start and end time, in seconds from the
/// start of the recording.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// False while the recognizer may still revise this word.
    public var isFinal: Bool

    public init(text: String, start: Double, end: Double, isFinal: Bool) {
        self.text    = text
        self.start   = start
        self.end     = end
        self.isFinal = isFinal
    }

    /// A placeholder for a word the recognizer gave no time for.
    public static func untimed(_ text: String, isFinal: Bool) -> TimedWord {
        TimedWord(text: text, start: -1, end: -1, isFinal: isFinal)
    }

    /// False for a placeholder whose time the recognizer did not supply.
    public var hasTiming: Bool { start.isFinite && end.isFinite && start >= 0 && end >= start }
}

