


import Foundation

/// A display-only snapshot. Measured silence and estimated recognition gaps stay distinct.
/// This never creates or changes transcript annotations; those retain their one-second minimum.
struct LiveThinkingPause: Equatable {
    let seconds: Double
    let estimated: Bool

    static func resolve(recording: Bool, measured: ThinkingPauseTracker,
                        words: [TimedWord], revisionAge: Double, host: Double) -> Self? {
        guard recording, host.isFinite else { return nil }
        if let seconds = measured.openPauseSeconds(at: host) {
            return Self(seconds: seconds, estimated: false)
        }
        guard let gap = SpeechGapTiming.live(words: words, audioEnd: measured.clock,
                                             revisionAge: revisionAge) else { return nil }
        return Self(seconds: gap + measured.hostSinceLastBuffer(at: host), estimated: true)
    }
}


/// Only the bubble uses this noise-aware display state. Transcript pause evidence and
/// AI cancellation keep their existing detectors. Read on main, from one tap snapshot.
struct LiveThinkingPauseDisplay {
    private var quickNoiseGap = NoisyBubblePause()
    private var clock = 0.0
    private var noiseFloor: Double?
    private var blockedWordEnd: Double?

    mutating func read(recording: Bool, measured: ThinkingPauseTracker,
                       words: [TimedWord], revisionAge: Double, host: Double) -> LiveThinkingPause? {
        if !recording || measured.clock < clock { self = Self() }
        clock = measured.clock
        let quick = quickNoiseGap.read(recording: recording, measured: measured,
                                       words: words, revisionAge: revisionAge, host: host)
        if let quick {
            noiseFloor = measured.latestRMSDB
            return quick
        }
        guard let pause = LiveThinkingPause.resolve(recording: recording, measured: measured,
                words: words, revisionAge: revisionAge, host: host) else {
            noiseFloor = nil
            return nil
        }
        guard pause.estimated else {
            noiseFloor = nil
            blockedWordEnd = nil
            return pause
        }
        // In a quiet room, recognition often lags after speech has already resumed.
        // Recent real quiet makes that stale word gap insufficient to show a timer.
        if let quiet = measured.lastQuietEnd,
           measured.clock - quiet < ThinkingPresence.estimateNeedsNoQuietFor { return nil }
        guard measured.latestRMSDB.isFinite else { return nil }
        let wordEnd = words.last?.end
        if let blockedWordEnd, blockedWordEnd == wordEnd { return nil }
        self.blockedWordEnd = nil
        // Once a noise-room estimate exists, sound clearly above that room level
        // immediately restores the waveform, even before recognition catches up.
        if let floor = noiseFloor, measured.latestRMSDB >= floor + ThinkingPresence.loudRoomMargin {
            blockedWordEnd = wordEnd
            noiseFloor = nil
            return nil
        }
        if noiseFloor == nil { noiseFloor = measured.latestRMSDB }
        return pause
    }
}

