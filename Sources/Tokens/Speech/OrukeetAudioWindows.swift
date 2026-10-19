import Foundation

/// Contiguous windows, never a sliding-tail replacement for the whole talk.
/// The caller may drop PCM only after a successful full-window decode. Quiet is
/// preferred after softCloseSeconds; at 30s a hard split can still bisect speech (not hidden).
/*
Live-word pacing for Orukeet. After softCloseSeconds a window closes at the first 0.4 s pause
(a sentence break); from 20 s a 0.2 s pause is enough, so the 30 s hard limit stays rare. A live
update needs firstStepSamples of new audio until words first appear, then stepSamples. A Dev
fixture run may override these with
--orukeet-tuning soft=<s>,first=<samples>,step=<samples> to compare settings on identical audio;
normal launches always use the defaults.
*/
struct OrukeetLiveTuning: Sendable, Equatable {
    /*
    Window defaults balance first-word latency, finalization latency and contextual accuracy.
    Use the synthetic tuning route above to measure changes on a controlled fixture.
    */
    var softCloseSeconds = 10
    var firstStepSamples = 4800
    var stepSamples = 6400

    static func parse(_ spec: String) -> OrukeetLiveTuning? {
        var tuning = OrukeetLiveTuning()
        for part in spec.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]), value > 0 else { return nil }
            switch pair[0] {
            case "soft" where value <= 30: tuning.softCloseSeconds = value
            case "first": tuning.firstStepSamples = value
            case "step": tuning.stepSamples = value
            default: return nil
            }
        }
        return tuning
    }

    static let current: OrukeetLiveTuning = {
        let arguments = ProcessInfo.processInfo.arguments
        guard DevChannel.isActive, arguments.contains("--local-speech-fixture-proof"),
              let flag = arguments.firstIndex(of: "--orukeet-tuning"), flag + 1 < arguments.count,
              let tuning = parse(arguments[flag + 1]) else { return OrukeetLiveTuning() }
        return tuning
    }()
}

struct OrukeetAudioWindows {
    let sampleRate: Int
    var softCloseSeconds = OrukeetLiveTuning.current.softCloseSeconds
    private(set) var samples: [Float] = []
    private(set) var originSamples: Int64 = 0
    private(set) var boundary: Int?
    private var scanned = 0
    private var quietSamples = 0
    init(sampleRate: Int = 16000) { self.sampleRate = sampleRate }
    var maximumWindow: Int { sampleRate * 30 }
    var retainedLimit: Int { sampleRate * 60 }
    mutating func append(_ incoming: [Float]) throws {
        guard incoming.allSatisfy(\.isFinite) else { throw OrukeetFailure.invalidAudio }
        guard samples.count + incoming.count <= retainedLimit else { throw OrukeetFailure.overload }
        samples.append(contentsOf: incoming)
        locateBoundary()
    }
    /*
    Each closed window is decoded on its own, and the model ends it like a whole utterance: a
    period, then a capital at the start of the next window. Closing at the first 0.2 s breath
    after 10 s put "we could. Go to the store" in the middle of long talks about every 10 s.
    Before shortPauseAfterSeconds a window now waits for a 0.4 s pause, the length of a break
    between sentences; after it a 0.2 s pause still closes the window, as in build 78, so a talk
    with no long pause is still cut in quiet rather than at the hard split (build 81).
    */
    static let shortPauseAfterSeconds = 20
    private mutating func locateBoundary() {
        guard boundary == nil else { return }
        let frame = max(1, sampleRate / 100)
        let limit = min(samples.count, maximumWindow)
        let sentencePause = sampleRate * 2 / 5, shortPause = sampleRate / 5
        while scanned + frame <= limit {
            var sum: Double = 0
            for sample in samples[scanned..<(scanned + frame)] { sum += Double(sample) * Double(sample) }
            quietSamples = sum / Double(frame) <= Self.quietMeanSquare ? quietSamples + frame : 0
            scanned += frame
            guard scanned >= sampleRate * softCloseSeconds else { continue }
            let pause = scanned >= sampleRate * Self.shortPauseAfterSeconds ? shortPause : sentencePause
            if quietSamples >= pause { boundary = scanned; return }
        }
        if samples.count >= maximumWindow { boundary = maximumWindow }
    }
    /// Mean square of a 10 ms frame at or below this is quiet (about -42 dBFS), as for boundaries.
    static let quietMeanSquare = 0.000064
    /// Less voiced audio than this in a window is no speech at all.
    static let minimumVoicedSeconds = 0.15

    /*
    True when the first `count` samples hold less than 0.15 s of non-quiet audio. Such a window
    is never decoded (build 81): models make up short phrases from room noise ("Fair play.",
    "Thank you."), and a quiet first 10 s (waiting for the model to load, thinking before
    speaking) used to close as its own window and paste one ahead of the real words.
    */
    func isQuiet(_ count: Int) -> Bool {
        let frame = max(1, sampleRate / 100)
        let needed = Int(Double(sampleRate) * Self.minimumVoicedSeconds)
        let end = min(count, samples.count)
        var start = 0, voiced = 0
        while start < end {
            let stop = min(start + frame, end)
            var sum: Double = 0
            for sample in samples[start..<stop] { sum += Double(sample) * Double(sample) }
            if sum / Double(stop - start) > Self.quietMeanSquare {
                voiced += stop - start
                if voiced >= needed { return false }
            }
            start = stop
        }
        return true
    }

    mutating func commit(_ count: Int) {
        precondition(count > 0 && count <= samples.count && count <= maximumWindow)
        samples.removeFirst(count)
        originSamples += Int64(count)
        boundary = nil; scanned = 0; quietSamples = 0
        locateBoundary()
    }
}
