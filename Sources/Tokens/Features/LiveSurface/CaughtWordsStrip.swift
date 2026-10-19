
import SwiftUI

/// One consistent snapshot of recognition for the strip (words, settled prefix, audio-clock now).
struct CaughtWords: Equatable {
    var words: [TimedWord]
    var stableWordCount: Int
    /// Seconds on the audio clock: tracker.clock + hostSinceLastBuffer(at:).
    var now: Double
}

struct CaughtWordsStrip: View {
    let caught: CaughtWords
    var vertical = false

    static let ink = Color(red: 0.94, green: 0.40, blue: 0.36)
    static func window(vertical: Bool) -> Double { vertical ? 3 : 4 }
    /// The bubble envelope's end inset (ThinkingBubble talkingInsets/stripInsets). The dot track runs
    /// from the envelope's oldest stroke to its newest, so the dots read as the envelope's own
    /// baseline (oldest left/top, newest right/bottom) rather than a second object.
    static let envelopeEndInset: CGFloat = 2

    /// The dot track inside `along` (the full readout length): start and length.
    static func track(along: CGFloat) -> (start: CGFloat, length: CGFloat) {
        let inner = TinyEnvelope.track(along: max(0, along - 2 * envelopeEndInset))
        return (envelopeEndInset + inner.start, inner.length)
    }

    struct Mark: Equatable { var position: CGFloat; var final: Bool }

    /// Pure placement: 0 = oldest edge, `length` = newest edge. Untimed and out-of-window words are dropped.
    /// No latch: settled or provisional follows the snapshot passed in, every frame.
    static func marks(words: [TimedWord], stableWordCount: Int, now: Double,
                      window: Double, length: CGFloat) -> [Mark] {
        guard length > 0, window > 0, now.isFinite else { return [] }
        return words.enumerated().compactMap { index, word in
            guard word.hasTiming else { return nil }
            let age = now - word.end
            guard age <= window else { return nil }
            let fraction = 1 - max(0, age) / window
            return Mark(position: CGFloat(fraction) * length, final: index < stableWordCount || word.isFinal)
        }
    }

    var body: some View {
        Canvas { context, size in
            let track = Self.track(along: vertical ? size.height : size.width)
            let across = (vertical ? size.width : size.height) / 2
            let marks = Self.marks(words: caught.words, stableWordCount: caught.stableWordCount,
                                   now: caught.now, window: Self.window(vertical: vertical), length: track.length)
            for mark in marks {
                let along = track.start + mark.position
                let c = vertical ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
                if mark.final {
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 0.8, y: c.y - 0.8, width: 1.6, height: 1.6)),
                                 with: .color(Self.ink.opacity(0.85)))
                } else {
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - 0.6, y: c.y - 0.6, width: 1.2, height: 1.2)),
                                   with: .color(Self.ink.opacity(0.55)), lineWidth: 0.6)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
