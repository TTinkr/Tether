


//
import Foundation

/// One receipt field that no longer matches the words it describes.
public enum PiMismatch: Equatable, Sendable, Codable {
    case words(stated: Int, counted: Int)
    case wpm(stated: Int, computed: Int)
    case pauseCount(stated: Int, counted: Int)
    case pauseTotal(stated: Double, counted: Double)
    case piID(stated: String, computed: String)
}

public enum PiEnvelopeVerifier {
    /*
    Words use LexicalFidelity like the writers. Words per minute uses the writers' "%.0f"
    rounding; when the stated seconds were printed with fewer than four decimals (legacy
    "56.6s"), any rate reachable inside that printed rounding interval is accepted, because
    the writer divided by the unrounded time.
    */
    public static func verify(_ envelope: PiEnvelope) -> [PiMismatch] {
        guard let stats = envelope.stats else { return [] }
        var result: [PiMismatch] = []
        let counted = PiEnvelope.wordCount(of: envelope.spokenText)
        if counted != stats.words { result.append(.words(stated: stats.words, counted: counted)) }
        let computed = rate(words: counted, seconds: stats.seconds)
        if !wpmMatches(stated: stats.wpm, words: counted, seconds: stats.seconds) {
            result.append(.wpm(stated: stats.wpm, computed: computed))
        }
        let pauseCount = envelope.pauses.count + envelope.unplacedPauseCount
        if let stated = stats.pauseCount, stated != pauseCount {
            result.append(.pauseCount(stated: stated, counted: pauseCount))
        }
        if let stated = stats.pauseTotal {
            let sum = envelope.pauses.reduce(envelope.unplacedPauseTotal) { $0 + $1.seconds }
            let total = Double(String(format: "%.4f", sum)) ?? 0
            /*
            The writer rounds the unrounded sum once; each marker is rounded on its own. Allow
            half a unit in the last place per printed value, plus the stated total's own rounding.
            */
            let tolerance = 0.00005 * Double(max(1, envelope.pauses.count + markerGroups(envelope)) + 1) + 1e-9
            if abs(total - stated) > tolerance { result.append(.pauseTotal(stated: stated, counted: total)) }
        }
        if let stated = stats.piID {
            let computed = PiEnvelopeID.id(spokenText: envelope.spokenText, seconds: stats.seconds)
            if computed != stated { result.append(.piID(stated: stated, computed: computed)) }
        }
        return result
    }

    /// Unplaced pauses print one rounded total per note line, not one per pause.
    private static func markerGroups(_ envelope: PiEnvelope) -> Int { envelope.unplacedPauseCount > 0 ? 1 : 0 }

    /// Same formula and rounding as TokensPrompt.format / ThinkingPrompt.header.
    static func rate(words: Int, seconds: Double) -> Int {
        let time = seconds.isFinite ? max(0, seconds) : 0
        let value = time > 0 ? Double(words) * 60 / time : 0
        return Int(String(format: "%.0f", value.isFinite ? value : 0)) ?? 0
    }

    static func wpmMatches(stated: Int, words: Int, seconds: Double) -> Bool {
        if rate(words: words, seconds: seconds) == stated { return true }
        let decimals = (0...4).first { abs(seconds * pow(10, Double($0)) - (seconds * pow(10, Double($0))).rounded()) < 1e-6 } ?? 4
        let half = 0.5 * pow(10, -Double(decimals))
        let low = rate(words: words, seconds: seconds + half)
        let high = seconds - half > 0 ? rate(words: words, seconds: seconds - half) : Int.max
        return (low...high).contains(stated)
    }
}

