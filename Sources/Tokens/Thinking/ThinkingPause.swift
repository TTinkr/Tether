


//
import CoreGraphics
import Foundation


// ThinkingPause — One interval of measured microphone silence, start and end in seconds


// MARK: - Tokens “Thinking” (measured silence only)

/// A closed interval of measured microphone silence between two sounds, on the
/// capture's audio clock. It says nothing about what the speaker was doing.
struct ThinkingPause: Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}


// ThinkingPauseTracker — Finds thinking pauses by watching the level of every tap buffer


/// Fed by every tap buffer. Only level and time are retained; never audio.
struct ThinkingPauseTracker: Sendable {


    // Feeding buffers in — tuning numbers, stored state, and observe()


    /*
    How a pause is found, in one paragraph: a buffer louder than `quietDB` is sound; a quieter
    one is silence. The first silent buffer after sound opens a silence (`quietStart`). The
    pause is only written down when sound comes back, and only if the silence lasted at least
    `minimumAnnotatedPause`. Silence before the first sound this tracker hears never counts.
    */
    static let quietDB = -48.0
    /// Shorter silences are ordinary gaps between words.
    static let minimumAnnotatedPause = 1.0
    /*
    The live counter (openPauseSeconds) reports a silence from this length, which is shorter
    than a silence that gets stored as a pause (minimumAnnotatedPause).
    */
    static let minimumDisplayedPause = 0.20
    // At most this many pauses are stored; once the list is full, further pauses are dropped.
    static let maximumPauses = 256

    private(set) var pauses: [ThinkingPause] = []
    private(set) var heardSound              = false
    /// The live counter may run this far past the latest buffer on the host
    /// clock. A stalled tap is not evidence of silence.
    static let maximumLiveExtrapolation = 0.25

    /*
    quietStart: audio-clock second where the silence now in progress began; nil when none is open.
    lastEnd: audio-clock second where the newest buffer ended.
    lastHost: host (uptime) second when the newest buffer arrived; used only by the live counter.
    */
    private var quietStart: Double?
    private var lastEnd = 0.0
    /// Fresh tap-level facts for display-only speech-resumption checks.
    private(set) var latestRMSDB = -120.0
    /// Display-only continuity evidence; a missing buffer is never a pause.
    private(set) var latestBufferStart = 0.0
    private(set) var lastQuietEnd: Double?
    private var lastHost: Double?

    /// `rmsDB` of the whole buffer decides sound or silence. `soundStart` and
    /// `soundEnd` are where sound begins and ends inside a sounding buffer, on
    /// the same sample clock; without them the buffer's own edges are used, so
    /// a pause is never finer than what the caller measured. `host` is the
    /// monotonic uptime at which the buffer arrived, for the live counter only.
    mutating func observe(rmsDB: Double, start: Double, end: Double,
                          soundStart: Double? = nil, soundEnd: Double? = nil, host: Double? = nil) {
        guard start.isFinite, end.isFinite, end >= start else { return }
        /*
        A hole in the audio clock is not evidence of silence.
        (Buffers more than 0.1 s apart, or one that steps backwards, throw away the open silence
        instead of counting the missing audio as quiet.)
        */
        if start - lastEnd > 0.1 || end < lastEnd { quietStart = nil }
        lastEnd  = end
        latestBufferStart = start
        latestRMSDB = rmsDB
        if rmsDB.isFinite && rmsDB < Self.quietDB { lastQuietEnd = end }
        lastHost = host
        if rmsDB.isFinite && rmsDB >= Self.quietDB {
            /*
            A sounding buffer ends any open silence. `onset` is where sound begins inside this
            buffer and `tail` is where it stops, both clamped into [start, end] so a bad value
            from the caller cannot place a pause outside the buffer.
            */
            let onset = min(max(soundStart.flatMap { $0.isFinite ? $0 : nil } ?? start, start), end)
            let tail  = min(max(soundEnd.flatMap { $0.isFinite ? $0 : nil } ?? end, onset), end)
            /*
            The silence is closed at `onset` and kept only if sound was heard before it, it was
            long enough, and there is room in the list.
            */
            if let began = quietStart, heardSound, onset - began >= Self.minimumAnnotatedPause,
               pauses.count < Self.maximumPauses {
                pauses.append(ThinkingPause(start: began, end: onset))
            }
            /*
            If sound stops before the buffer ends, the rest of the buffer is already the start of
            the next silence; otherwise no silence is open.
            */
            quietStart = tail < end ? tail : nil
            heardSound = true
        } else if quietStart == nil {
            // A quiet buffer opens a silence only if none is open already, so the start stays put.
            quietStart = start
        }
    }

//
// :)
//
//
    // Reading pauses out — totals and the live counter for the bubble


    /// Include the final measured pause in session totals even if Send ends it.
    var pausesIncludingCurrent: [ThinkingPause] {
        guard heardSound, let quietStart, lastEnd - quietStart >= Self.minimumAnnotatedPause,
              pauses.count < Self.maximumPauses else { return pauses }
        return pauses + [ThinkingPause(start: quietStart, end: lastEnd)]
    }

    /// Audio clock at the end of the latest buffer.
    var clock: Double { lastEnd }

    /// Length of the silence in progress, once sound has been heard.
    /// This version counts audio-clock time only (up to the end of the latest buffer);
    /// `openPauseSeconds(at:)` below adds host time so the number can move between buffers.
    var openPauseSeconds: Double? {
        guard heardSound, let quietStart else { return nil }
        let seconds = lastEnd - quietStart
        return seconds >= Self.minimumDisplayedPause ? seconds : nil
    }

    /// Host time since the latest buffer, capped like the live counter, so any
    /// clock read from buffers can advance smoothly between them.
    func hostSinceLastBuffer(at host: Double) -> Double {
        let since = lastHost.map { min(max(0, host - $0), Self.maximumLiveExtrapolation) } ?? 0
        return since.isFinite ? since : 0
    }

    /// Live counter: measured silence up to the latest buffer, plus monotonic
    /// host time elapsed since that buffer arrived. Never a tick count. The
    /// stored pause is still closed on the sample clock alone.
    func openPauseSeconds(at host: Double) -> Double? {
        guard heardSound, let quietStart else { return nil }
        let since   = lastHost.map { min(max(0, host - $0), Self.maximumLiveExtrapolation) } ?? 0
        let seconds = lastEnd - quietStart + (since.isFinite ? since : 0)
        return seconds >= Self.minimumDisplayedPause ? seconds : nil
    }


}


// ThinkingLevelScan — Measures one tap buffer: its loudness and where sound starts and stops


/// Level of one tap buffer, and where sound begins and ends inside it, in
/// frames. Edges are located to whole analysis windows of real samples; that
/// window is the measurement resolution, nothing finer is claimed.
enum ThinkingLevelScan {
    /// About one millisecond of samples.
    static func windowFrames(sampleRate: Double) -> Int { max(1, Int((sampleRate / 1000).rounded())) }

    /*
    Walks the buffer in `window`-sized steps (see windowFrames: about 1 ms).
     - `rmsDB` is the loudest channel's level over the whole buffer, in dB; -120 when there is
       nothing to measure, and never lower than -120.
     - `soundStart` / `soundEnd` are frame positions: the start of the first window and the end
       of the last window whose loudest channel reaches the same threshold the tracker calls
       quiet (quietDB). Both are nil when no window reaches it.
    The tracker uses rmsDB to decide sound versus silence; the two edges only say where inside a
    sounding buffer to cut, so a pause starts and ends near the real sound rather than on a buffer edge.
    */
    static func scan(channels: [UnsafeBufferPointer<Float>], window: Int)
        -> (rmsDB: Double, soundStart: Int?, soundEnd: Int?) {
        let count = channels.map(\.count).min() ?? 0
        guard count > 0, window > 0 else { return (-120, nil, nil) }
        /*
        quietDB is a level in dB of amplitude. `quietSquare` is that level as mean-square power,
        so each window's mean square is compared with it directly (no log per window).
        */
        let quiet  = pow(10, ThinkingPauseTracker.quietDB / 20), quietSquare = quiet * quiet
        var totals = [Double](repeating: 0, count: channels.count)
        var first: Int?, last: Int?
        var from = 0
        while from < count {
            let to      = min(count, from + window)
            var loudest = 0.0
            for (channel, samples) in channels.enumerated() {
                var sum = 0.0
                for index in from..<to { let value = Double(samples[index]); sum += value * value }
                totals[channel] += sum
                loudest = max(loudest, sum / Double(to - from))
            }
            // `first` is set once, `last` keeps moving to the end of the latest loud window.
            if loudest >= quietSquare {
                if first == nil { first = from }
                last = to
            }
            from = to
        }
        // The 0.000001 floor keeps log10 finite for digital silence (it gives exactly -120 dB).
        let maximumRMS = sqrt((totals.max() ?? 0) / Double(count))
        return (20 * log10(max(maximumRMS, 0.000001)), first, last)
    }
}

