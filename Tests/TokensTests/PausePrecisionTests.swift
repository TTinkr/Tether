


//
import Foundation
import Testing
@testable import Tokens

/// Pause timing regression: the tap delivers about 0.1 s buffers, and silence
/// used to be timed by whole buffers, so every pause came out in tenths.
@Suite(.serialized) struct PausePrecisionTests {
    static let rate         = 48_000.0
    static let bufferFrames = 4_800

    /// A 220 Hz tone with two silences cut at exact sample positions.
    static func signal(silences: [(from: Double, to: Double)], length: Double) -> [Float] {
        (0..<Int(length * rate)).map { frame in
            let t = Double(frame) / rate
            if silences.contains(where: { t >= $0.from - 1e-9 && t < $0.to - 1e-9 }) { return 0 }
            return Float(0.1 * sin(2 * .pi * 220 * t + 0.4))
        }
    }

    /// Same arithmetic as the capture tap: frames accumulate into the audio
    /// clock, one tracker observation per delivered buffer.
    static func run(_ samples: [Float], locateEdges: Bool, host: ((Double) -> Double)? = nil) -> ThinkingPauseTracker {
        var tracker      = ThinkingPauseTracker()
        var audioElapsed = 0.0, from = 0
        while from < samples.count {
            let to = min(samples.count, from + bufferFrames)
            audioElapsed += Double(to - from) / rate
            let end = audioElapsed, start = end - Double(to - from) / rate
            samples[from..<to].withUnsafeBufferPointer { pointer in
                let level = ThinkingLevelScan.scan(channels: [UnsafeBufferPointer(rebasing: pointer[...])],
                                                      window: ThinkingLevelScan.windowFrames(sampleRate: rate))
                tracker.observe(rmsDB: level.rmsDB, start: start, end: end,
                                soundStart: locateEdges ? level.soundStart.map { start + Double($0) / rate } : nil,
                                soundEnd: locateEdges ? level.soundEnd.map { start + Double($0) / rate } : nil,
                                host: host?(end))
            }
            from = to
        }
        return tracker
    }

    static func isTenth(_ value: Double) -> Bool { abs(value * 10 - (value * 10).rounded()) < 1e-6 }

    @Test static func run() {
        let cuts    = [(from: 3.211, to: 5.348), (from: 8.020, to: 12.603)]   // 2.137 s and 4.583 s
        let samples = signal(silences: cuts, length: 14)

        // MARK: cause, reproduced
        let coarse = run(samples, locateEdges: false).pauses
        precondition(coarse.count == 2 && coarse.allSatisfy { isTenth($0.duration) })
        print("PASS cause: whole-buffer timing gives \(coarse.map { String(format: "%.3f", $0.duration) }) — tenths only")

        // MARK: measured on the sample clock
        let tracker = run(samples, locateEdges: true)
        let pauses  = tracker.pauses
        precondition(pauses.count == 2)
        let window = Double(ThinkingLevelScan.windowFrames(sampleRate: rate)) / rate
        precondition(window == 0.001)
        for (pause, cut) in zip(pauses, cuts) {
            precondition(abs(pause.start - cut.from) <= window + 1e-9 && abs(pause.end - cut.to) <= window + 1e-9)
            precondition(pause.duration == pause.end - pause.start)                 // start/end/duration agree
            precondition(abs(pause.start * rate - (pause.start * rate).rounded()) < 1e-6)   // whole frames, no invented digits
            precondition(abs(pause.end * rate - (pause.end * rate).rounded()) < 1e-6)
        }
        precondition(String(format: "%.3f", pauses[0].duration) == "2.137")
        precondition(String(format: "%.3f", pauses[1].duration) == "4.583")
        precondition(!isTenth(pauses[0].duration) && !isTenth(pauses[1].duration))
        print("PASS measured: 2.137 s and 4.583 s located to a \(Int(window * 1000)) ms window of real samples")

        // MARK: persisted / rendered text and the sum
        let durations = pauses.map(\.duration)
        precondition(ThinkingComposer.annotation(seconds: durations[0]) == "THINK (2.1370s)")
        precondition(ThinkingComposer.annotation(seconds: durations[1]) == "THINK (4.5830s)")
        let summary = ThinkingComposer.unplacedSummary(durations)!
        precondition(summary.contains("×2") && summary.contains("6.7200s"))
        precondition(abs(durations.reduce(0, +) - pauses.reduce(0) { $0 + ($1.end - $1.start) }) < 1e-12)
        precondition(abs(durations.reduce(0, +) - 6.720) <= 2 * window)
        precondition(tracker.pausesIncludingCurrent == pauses)      // no pause invented at the end
        print("PASS rendered: annotations and the ×2 · 6.720 s sum agree with start/end")

        /*
        An unchanged room tone above the fixed threshold is sound, even
        if the person has stopped speaking. Do not invent a measured pause.
        */
        for (db, expected) in [(-60.0, 1), (-49.0, 1), (-47.0, 0), (-35.0, 0)] {
            let amplitude = Float(pow(10, db / 20))
            var room      = signal(silences: [(from: 1, to: 3)], length: 4)
            for index in Int(rate)..<Int(3 * rate) { room[index] = amplitude }
            let result = run(room, locateEdges: true)
            precondition(result.pauses.count == expected, "threshold regression at \(db)dB")
            if expected == 1 {
                precondition(abs(result.pauses[0].duration - 2) <= window + 1e-9)
                let header = ThinkingPrompt.header(title: nil, durationSeconds: 4,
                    countTranscript: "one two", pauses: result.pauses.map(\.duration))
                precondition(header.contains("1x thinking (2.0000s)"))
            }
        }
        print("PASS threshold: -60/-49 dB room tone yields measured pause; -47/-35 dB does not; header preserves detected counts")

        // MARK: a directly fed interval survives untouched
        var direct = ThinkingPauseTracker()
        direct.observe(rmsDB: -20, start: 0, end: 0.1)
        var t = 0.1
        while t < 2.2 { direct.observe(rmsDB: -70, start: t, end: t + 0.1); t += 0.1 }
        direct.observe(rmsDB: -20, start: t, end: t + 0.1, soundStart: 2.237, soundEnd: t + 0.1)
        precondition(String(format: "%.3f", direct.pauses[0].duration) == "2.137")
        // Edges outside the buffer are clamped, never extrapolated.
        var clamped = ThinkingPauseTracker()
        clamped.observe(rmsDB: -20, start: 0, end: 0.1, soundStart: -5, soundEnd: 9)
        clamped.observe(rmsDB: -70, start: 0.1, end: 1.5)
        clamped.observe(rmsDB: -20, start: 1.5, end: 1.6, soundStart: 99)
        precondition(clamped.pauses == [ThinkingPause(start: 0.1, end: 1.6)])
        print("PASS tracker: caller's edges preserved, clamped to the buffer")

        // MARK: live counter reads the clock, not buffer arrivals
        let silent   = signal(silences: [(from: 1.0137, to: 99)], length: 3)
        let live     = run(silent, locateEdges: true, host: { 500 + $0 })   // last buffer arrived at host 503.0
        let atBuffer = live.openPauseSeconds(at: 503.0)!
        precondition(abs(atBuffer - (3 - 1.014)) <= window + 1e-9 && live.openPauseSeconds! == atBuffer)
        precondition(abs(live.openPauseSeconds(at: 503.037)! - atBuffer - 0.037) < 1e-9)   // between buffers
        precondition(abs(live.openPauseSeconds(at: 503.0583)! - atBuffer - 0.0583) < 1e-9)
        precondition(live.openPauseSeconds(at: 502)! == atBuffer)                           // never runs backwards
        precondition(abs(live.openPauseSeconds(at: 560)! - atBuffer - ThinkingPauseTracker.maximumLiveExtrapolation) < 1e-9)
        precondition(live.pauses.isEmpty)   // the host clock never enters a stored pause
        print("PASS live: elapsed follows the host clock between buffers, capped at a stalled tap")
    }
}

