


import Foundation

/// Relative audio-level heuristic, not a voice classifier or evidence of thinking.
/// Only fresh, contiguous tap observations can extend a candidate; redraws cannot.
struct NoisyBubblePause {
    private var levels: [(time: Double, db: Double)] = []
    private var clock = 0.0
    private var start: Double?
    private var floor: Double?
    private var blockedWordEnd: Double?

    mutating func read(recording: Bool, measured: ThinkingPauseTracker,
                       words: [TimedWord], revisionAge: Double, host: Double) -> LiveThinkingPause? {
        let end = measured.clock
        let delta = end - clock
        if !recording || delta < 0 || delta > 0.5
            || measured.latestBufferStart - clock > 0.1 { self = Self() }
        let previous = clock
        clock = end
        guard recording, host.isFinite, measured.latestRMSDB.isFinite,
              measured.hostSinceLastBuffer(at: host) < ThinkingPauseTracker.maximumLiveExtrapolation,
              let word = words.last, word.hasTiming, word.end.isFinite,
              word.end <= end,
              measured.latestRMSDB >= ThinkingPauseTracker.quietDB else {
            start = nil; floor = nil; levels = []
            return nil
        }
        /*
        Recent true quiet belongs to the measured detector. Recognition often lags when
        speech resumes; don't turn that old word timestamp into another estimated pause.
        */
        if let quiet = measured.lastQuietEnd,
           end - quiet < ThinkingPresence.estimateNeedsNoQuietFor {
            start = nil; floor = nil; levels = []
            return nil
        }
        if previous != end {
            let db = measured.latestRMSDB
            levels.removeAll { end - $0.time > 0.8 }
            let peak = levels.map(\.db).max()
            levels.append((end, db))
            if levels.count > 128 { levels.removeFirst(levels.count - 128) }
            if let baseline = floor, db >= baseline + ThinkingPresence.loudRoomMargin {
                start = nil; floor = nil; blockedWordEnd = word.end
                levels = [(end, db)]
            } else if start == nil, blockedWordEnd != word.end,
                      let peak, db <= peak - 8, end - previous <= 0.25 {
                start = previous
                floor = db
            } else if let baseline = floor {
                floor = min(baseline, db)
            }
        }
        guard let start, end - start >= ThinkingPauseTracker.minimumDisplayedPause,
              revisionAge >= 0.15, word.end <= start + 0.12 else { return nil }
        return LiveThinkingPause(seconds: end - start + measured.hostSinceLastBuffer(at: host), estimated: true)
    }
}

