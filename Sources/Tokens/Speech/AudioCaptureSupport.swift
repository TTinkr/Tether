


//
import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech


// AudioTapRouter — one hardware tap; each talk swaps in its own buffer consumer


/// One hardware tap; changing recognition sessions swaps its consumer atomically.
/// Buffers are borrowed for this call only; no ambient audio queue or disk sink.
final class AudioTapRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var lastSample: TimeInterval = 0
    /*
    Called only by the hardware owner. Because route() holds the same lock while it calls the old sink,
    once replace() returns the old sink will never be called again.
    */
    func replace(_ next: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        sink = next
    }
    /*
    Called on the audio thread for every buffer, even when no talk is listening (the
    sink is nil); lastSample still updates, which is how sampleAge shows the mic is alive.
    */
    func route(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        lastSample = ProcessInfo.processInfo.systemUptime
        sink?(buffer)
    }
    var sampleAge: TimeInterval {
        // UI liveness probes must not wait behind a recognizer append.
        guard lock.try() else { return .infinity }
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastSample
    }
}


// CompletedSegment — words, features and timing for a finished talk or a heard sound segment


struct CompletedSegment: Equatable {
    let id: UUID
    let features: AudioFeatures
    let transcript: String
    // Voice commands: the command words, and the transcript before them.
    var commandUtterance: String?        = nil
    var transcriptBeforeCommand: String? = nil
    // The capture session this came from, so a stale segment can be recognised and ignored.
    var captureGeneration: UUID?        = nil
    var timedWords: [TimedWord]         = []
    var thinkingPauses: [ThinkingPause] = []
    /*
    True when thinkingPauses came from gaps between recognised words, not from measured
    silence (used when no silence could be measured, for example in a noisy room).
    */
    var thinkingPausesAreSpeechEstimates = false
    var thinkingAnchors                  = ThinkingArrivalAnchors()
    /*
    True when the words are kept but their order or overlap could not be proven (the older
    recogniser restarted after a pause without timing). They are still pasted in spoken order,
    but Auto-send never presses Return for them (paste both, no Enter).
    */
    var requiresReview                   = false
}


// LockedThinkingPauses — thinking pause tracker: the tap writes it, the main thread reads it


/*
observe() runs on the audio thread; snapshot() and diagnosticSummary() run on main.
The lock keeps them from seeing a half-updated tracker. The counters below exist
only for the pause_capture diagnostic line.
*/
/// Level and time only, written by the real audio tap. No samples are kept.
final class LockedThinkingPauses {

//
// :)
//
//
    private let lock         = NSLock()
    private var state        = ThinkingPauseTracker()
    private var buffers      = 0
    private var quietBuffers = 0
    private var minimumDB    = Double.infinity
    private var maximumDB    = -Double.infinity
    private var longestQuiet = 0.0
    private var quietRun     = 0.0
    private var sampleRate   = 0.0
    private var channelCount = 0
    func reset() {
        lock.lock(); defer { lock.unlock() }
        state        = ThinkingPauseTracker()
        buffers      = 0; quietBuffers = 0; minimumDB = .infinity; maximumDB = -.infinity
        longestQuiet = 0; quietRun = 0; sampleRate = 0; channelCount = 0
    }
    /// Aggregate levels only. No words, device identifiers or audio samples.
    func diagnosticSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "pause_capture buffers=\(buffers) quiet_buffers=\(quietBuffers) threshold_db=\(ThinkingPauseTracker.quietDB) min_db=\(minimumDB.isFinite ? minimumDB : -120) max_db=\(maximumDB.isFinite ? maximumDB : -120) longest_quiet_buffer_run_s=\(String(format: "%.3f", longestQuiet)) sample_rate=\(sampleRate) channels=\(channelCount) pauses=\(state.pausesIncludingCurrent.count)"
    }
    func snapshot() -> ThinkingPauseTracker { lock.lock(); defer { lock.unlock() }; return state }
    /*
    `end` is where this buffer ends on the talk's audio clock (seconds of audio since the
    tap started for this talk); `host` is the system uptime when the buffer arrived.
    The level scan runs before taking the lock, so the lock is held only briefly.
    */
    func observe(buffer: AVAudioPCMBuffer, end: Double, host: Double) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength), rate = buffer.format.sampleRate
        /*
        The tap delivers about 0.1 s at a time whatever size is requested.
        Timing silence by whole buffers rounds every pause to tenths, so the
        edges of sound are located inside the buffer on the sample clock.
        */
        let level = ThinkingLevelScan.scan(
            channels: (0..<Int(buffer.format.channelCount)).map { UnsafeBufferPointer(start: channels[$0], count: count) },
            window: ThinkingLevelScan.windowFrames(sampleRate: rate))
        let start = end - Double(count) / rate
        lock.lock()
        buffers += 1
        sampleRate = rate; channelCount = Int(buffer.format.channelCount)
        if level.rmsDB.isFinite {
            minimumDB = min(minimumDB, level.rmsDB); maximumDB = max(maximumDB, level.rmsDB)
        }
        if level.rmsDB < ThinkingPauseTracker.quietDB {
            quietBuffers += 1; quietRun += Double(count) / rate
            longestQuiet = max(longestQuiet, quietRun)
        } else { quietRun = 0 }
        state.observe(rmsDB: level.rmsDB, start: start, end: end,
                      soundStart: level.soundStart.map { start + Double($0) / rate },
                      soundEnd: level.soundEnd.map { start + Double($0) / rate }, host: host)
        lock.unlock()
    }
}


// LabCommandEvent — a voice command heard in the lab, tied to the capture that heard it


struct LabCommandEvent: Equatable {
    let id: UUID
    let command: VoiceCommand
    let captureGeneration: UUID
}


// LockedStopReadiness — is the tail quiet enough to finish at once? Read at the stop edge


/// Written by the real audio tap, read synchronously at the stop key edge.
/// Never infer a quiet tail from throttled or delayed UI feature publication.
final class LockedStopReadiness {

//
// :)
//
//
    private let lock  = NSLock()
    private var state = StopReadiness()
    func reset() { lock.lock(); state = StopReadiness(); lock.unlock() }
    /*
    Uses the loudest channel's level, so a microphone on only one channel of a stereo
    input still counts. `time` is the system uptime when the buffer arrived.
    */
    func observe(buffer: AVAudioPCMBuffer, at time: Double) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count      = Int(buffer.frameLength)
        var maximumRMS = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            var sum = 0.0
            for index in 0..<count { let value = Double(channels[channel][index]); sum += value * value }
            maximumRMS = max(maximumRMS, sqrt(sum / Double(count)))
        }
        let rmsDB = 20 * log10(max(maximumRMS, 0.000001))
        lock.lock()
        state.observe(rmsDB: rmsDB, at: time, duration: Double(count) / buffer.format.sampleRate)
        lock.unlock()
    }
    func decision(at time: Double, transcriptFinalized: Bool) -> StopDecision {
        lock.lock(); defer { lock.unlock() }
        return state.decision(at: time, transcriptFinalized: transcriptFinalized)
    }
}

