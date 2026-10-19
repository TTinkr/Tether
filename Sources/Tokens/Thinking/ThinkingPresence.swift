


//
import CoreGraphics
import Foundation


// ThinkingPresence — Display-only "is the user thinking" latch for the bubble


/// Display-only "is the user thinking" state for the bubble and the thinking panel, with hysteresis.
/// The measured tracker ends a pause on one buffer at or above `quietDB`, which in a noisy room made the
/// bubble flick between "Thinking" and the waveform. This latches instead: it enters once a pause reaches
/// `enterSeconds`, and leaves only when speech has clearly resumed. It never alters measured pauses,
/// stored notes, or what "Thinking · n s" means; it only decides what the screen shows.
struct ThinkingPresence: Equatable, Sendable {


    // Settings and stored state — the numbers that decide enter and release


    /*
    Two ways in: a measured pause (the tracker saw real silence) or a speech-gap estimate (a
    loud room where silence cannot be measured). `measuredEntry` remembers which one.
    Ways out: speech clearly resumes (enough recent sound AND enough new words), or, for a
    measured entry only, a long run of loud sound that the recognizer produced no words for.
    */
    enum Transition: Equatable, Sendable { case entered, released }
    struct Display: Equatable, Sendable {
        var seconds: Double
        /// The count bridged sound or came from the speech-gap estimate, so show it as "≈".
        var approximate: Bool
    }

    /// Enter when a pause would be written as a thinking note.
    static let enterSeconds = ThinkingPauseTracker.minimumAnnotatedPause
    /// Normal resume: this much recent sound (hesitant phrases add up) and this many new recognized words.
    static let releaseSoundSeconds = 0.45
    static let releaseNewWords     = 2
    /// Backstop for a recognizer that produces no words: sustained, clearly louder sound.
    static let releaseUnrecognizedSoundSeconds = 1.5
    static let releaseUnrecognizedDB           = ThinkingPauseTracker.quietDB + 8
    /// Quiet gaps this short inside speech (stop consonants) do not reset a sound run.
    static let soundGapBridge = 0.3
    /// Observations further apart than this say nothing about what happened between them.
    static let maximumObservationGap = 0.5

    private(set) var isThinking  = false
    private(set) var approximate = false
    private var startHost        = 0.0
    private var lastHost: Double?
    private var wordsAtPause  = 0
    private var measuredEntry = false
    /// Sound heard in the last `soundWindowSeconds`, as (host, seconds) steps. Gaps between hesitant
    /// phrases do not empty it, and a cough long ago no longer counts.
    private var recentSound: [SoundStep] = []
    private struct SoundStep: Equatable, Sendable { var host: Double; var seconds: Double }
    private var soundInWindow: Double { recentSound.reduce(0) { $0 + $1.seconds } }
    private var quietSinceSound = 0.0
    private var unrecognizedRun = 0.0
    /// When a quiet buffer was last seen. A room that goes quiet between words measures its own pauses.
    private var lastQuietHost: Double?
    /// Room level when an estimated pause was entered; only sound clearly above it counts as speech.
    private var floorDB = ThinkingPauseTracker.quietDB

    /// A speech-gap estimate may start thinking only in a room too loud to measure silence: no quiet
    /// buffer for this long. In a quiet room the estimate also grows while the speaker is already
    /// talking again and the recognizer has not caught up, which is not a pause.
    static let estimateNeedsNoQuietFor = 3.0
    /// Sound must rise this far above a loud room's level to count as speech.
    static let loudRoomMargin = 6.0
    /// Only sound this recent counts toward a release.
    static let soundWindowSeconds = 1.5
    /// Words that arrive while it is quiet are late recognition only while almost no sound was heard.
    static let lateWordSoundAllowance = 0.15


    // Watching each buffer — observe(), the enter and release rules


    /// One call per analysed buffer (about 10 Hz). `pauseSeconds` is the live counter (measured or estimated),
    /// `words` the live transcript's word count, `host` monotonic uptime.
    /// Returns .entered or .released only on the call where the state flips, nil on every other call.
    mutating func observe(pauseSeconds: Double?, estimated: Bool, rmsDB: Double, words: Int, host: Double) -> Transition? {
        // Time must move forward. A non-finite or backwards host time is ignored entirely.
        guard host.isFinite else { return nil }
        if let last = lastHost, host < last { return nil }
        let gap  = lastHost.map { host - $0 } ?? 0
        lastHost = host
        /*
        After a gap, start the sound runs over and credit nothing for the time unseen.
        `step` is the time this call stands for; it is what gets added to the sound and quiet tallies.
        */
        let step = gap > Self.maximumObservationGap ? 0 : gap
        if gap > Self.maximumObservationGap { recentSound = []; quietSinceSound = 0; unrecognizedRun = 0 }
        // Forget sound heard longer ago than the window; only recent sound counts toward a release.
        recentSound.removeAll { host - $0.host > Self.soundWindowSeconds }
        let quietBuffer = !rmsDB.isFinite || rmsDB < ThinkingPauseTracker.quietDB
        if quietBuffer { lastQuietHost = host }

        // --- Not thinking yet: decide whether to enter. ---
        guard isThinking else {
            guard let pause = pauseSeconds, pause.isFinite, pause >= Self.enterSeconds else { return nil }
            /*
            An estimated pause is trusted only in a room with no quiet buffer for a while. In a
            quiet room the estimate can lag behind speech that has already resumed.
            */
            if estimated {
                if let quiet = lastQuietHost, host - quiet < Self.estimateNeedsNoQuietFor { return nil }
            }
            isThinking = true
            // Back-date the start so the counter shows the whole pause, not just time since entering.
            startHost     = host - pause
            wordsAtPause  = words
            measuredEntry = !estimated
            approximate   = estimated
            floorDB       = estimated && rmsDB.isFinite ? rmsDB : ThinkingPauseTracker.quietDB
            recentSound   = []; quietSinceSound = 0; unrecognizedRun = 0
            return .entered
        }

        /*
        --- Thinking: tally sound and quiet, then decide whether to release. ---
        In a loud room the steady room level is not speech; only sound clearly above it is.
        */
        let speechLevel = measuredEntry ? ThinkingPauseTracker.quietDB
            : max(ThinkingPauseTracker.quietDB, floorDB + Self.loudRoomMargin)
        let loud = rmsDB.isFinite && rmsDB >= speechLevel
        if loud {
            if step > 0 { recentSound.append(SoundStep(host: host, seconds: step)) }
            quietSinceSound = 0
            /*
            Sound happened inside a pause that was entered as silence, so the number on screen
            now spans sound and is shown with "≈".
            */
            if measuredEntry { approximate = true }
        } else {
            quietSinceSound += step
            // Words recognized late are not new speech, as long as (almost) no sound was just heard.
            if soundInWindow <= Self.lateWordSoundAllowance { wordsAtPause = max(wordsAtPause, words) }
        }
        /*
        The backstop is for a recognizer that gives no pause signal at all. While the speech-gap estimate
        reports a gap, wordless sound is still a gap by its definition: releasing would only re-enter.
        (`unrecognizedRun` is how long clearly loud sound has run with no pause signal; a quiet
        stretch longer than soundGapBridge resets it, shorter stop-consonant gaps do not.)
        */
        if rmsDB.isFinite, rmsDB >= max(Self.releaseUnrecognizedDB, speechLevel), pauseSeconds == nil {
            unrecognizedRun += step
        } else if quietSinceSound > Self.soundGapBridge {
            unrecognizedRun = 0
        }

        /*
        Release needs BOTH enough recent sound and enough new words, so a cough or a few late
        recognized words alone cannot end the pause. The unrecognized-sound backstop applies
        only to a pause entered from measured silence.
        */
        let resumed      = soundInWindow >= Self.releaseSoundSeconds && words - wordsAtPause >= Self.releaseNewWords
        let unrecognized = measuredEntry && unrecognizedRun >= Self.releaseUnrecognizedSoundSeconds
        guard resumed || unrecognized else { return nil }
        // Keep the clock fields so the next call's gap and quiet-room checks still work.
        reset(keepingClock: true)
        return .released
    }

//
// :)
//
//
    // Reading and clearing — isSpeechLevel(), display(), reset()


    /// Whether this level is sound that could be speech: above the measured-silence line, and in a
    /// loud room clearly above the room's own level.
    func isSpeechLevel(_ rmsDB: Double) -> Bool {
        /*
        Same threshold rule observe() uses for `speechLevel`; before a pause starts, the plain
        measured-silence line applies.
        */
        let level = !isThinking || measuredEntry ? ThinkingPauseTracker.quietDB
            : max(ThinkingPauseTracker.quietDB, floorDB + Self.loudRoomMargin)
        return rmsDB.isFinite && rmsDB >= level
    }

    /// The counter to show, or nil while not thinking. It keeps running on the host clock, capped a little
    /// past the last observation so a stalled audio tap never looks like a growing silence.
    func display(at host: Double) -> Display? {
        guard isThinking, let last = lastHost else { return nil }
        /*
        `now` is clamped between the last observation and the cap past it, so the counter never
        runs backwards and never races ahead of the audio when buffers stop arriving.
        */
        let now = min(max(host, last), last + ThinkingPauseTracker.maximumLiveExtrapolation)
        return Display(seconds: max(0, now - startHost), approximate: approximate)
    }

    // Full reset, for the start and end of a talk: forgets everything, including the clock.
    mutating func reset() { reset(keepingClock: false) }

    /*
    Wipes every field back to its starting value. With `keepingClock` the last observation time
    and the last quiet-buffer time survive (used on release, in the middle of a talk).
    */
    private mutating func reset(keepingClock: Bool) {
        let clock = lastHost, quiet = lastQuietHost
        self      = Self()
        if keepingClock { lastHost = clock; lastQuietHost = quiet }
    }


}

