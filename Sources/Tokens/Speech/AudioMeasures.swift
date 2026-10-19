


//
import CoreGraphics
import Foundation


// SilenceInterval — one stretch of quiet audio, start and end in seconds


struct SilenceInterval: Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}


// SilenceTracker — collects quiet stretches of at least 0.25 s from buffer levels


struct SilenceTracker {
    private var intervals: [SilenceInterval] = []
    private var quietStart: Double?
    private var previousEnd = 0.0
    /*
    A buffer under -48 dB is quiet. A gap of more than 0.1 s in the audio clock drops
    any open quiet stretch (a hole in the audio is not silence). Only the last 30 s of
    intervals are kept. snapshot() also includes a quiet stretch still in progress.
    */
    mutating func observe(rmsDB: Double, start: Double, end: Double) {
        if start - previousEnd > 0.1 { quietStart = nil }
        previousEnd = end
        if rmsDB < -48 {
            if quietStart == nil { quietStart = start }
        } else if let began = quietStart {
            if start - began >= 0.25 { intervals.append(SilenceInterval(start: began, end: start)) }
            quietStart = nil
        }
        intervals.removeAll { $0.end < end - 30 }
    }
    func snapshot() -> [SilenceInterval] {
        intervals + (quietStart.map { [SilenceInterval(start: $0, end: previousEnd)] } ?? [])
    }
}


// AudioFeatures — level, peak, brightness and similar numbers for one buffer or a whole talk


/*
Levels are in dBFS (0 is the loudest possible, -80 is used for silence). The optional
fields are nil in `silence` and in demo mode; live microphone analysis fills them.
*/
struct AudioFeatures: Codable, Equatable {
    var rmsDBFS: Double
    var peakDBFS: Double
    var zeroCrossingRate: Double
    var brightness: Double
    var modulation: Double
    var durationSeconds: Double
    var crestFactor: Double?     = nil
    var pitchHz: Double?         = nil
    var pitchConfidence: Double? = nil
    var onsetStrength: Double?   = nil

    static let silence = AudioFeatures(
        rmsDBFS: -80,
        peakDBFS: -80,
        zeroCrossingRate: 0,
        brightness: 0,
        modulation: 0,
        durationSeconds: 0
    )

    // Level mapped to 0...1: -60 dBFS and below is 0, -12 dBFS and above is 1.
    var normalizedEnergy: Double {
        min(1, max(0, (rmsDBFS + 60) / 48))
    }
}

//
// :)
//
//
// InputMeter — the microphone level shown on screen; display only


/// Display-only envelope. Never feeds recognition, silence detection or delivery.
struct InputMeter {
    private(set) var level = 0.0
    private var lastTime: Double?

    static func target(rmsDBFS: Double) -> Double {
        guard rmsDBFS.isFinite else { return 0 }
        /*
        Display headroom: strong close speech can fill the meter without
        requiring digital clipping. Recognition receives unchanged audio.
        */
        let normalized = min(1, max(0, (rmsDBFS + 50) / 38))
        return pow(normalized, 1.6)
    }

    mutating func observe(rmsDBFS: Double, at time: Double) -> Double {
        guard time.isFinite else { return level }
        let db      = rmsDBFS.isFinite ? rmsDBFS : -100
        let elapsed = lastTime.map { min(0.25, max(0, time - $0)) } ?? 0.025
        lastTime    = time
        /*
        A quiet buffer is a hard visual stop: no hold, hysteresis, or red tail.
        This affects the display only; all audio still reaches recognition.
        */
        guard db >= -47 else {
            level = 0
            return 0
        }
        /*
        Smooth toward the target: rising settles in about 25 ms, falling in about 80 ms,
        using the real time since the last buffer (capped at 0.25 s).
        */
        let target = Self.target(rmsDBFS: db)
        let tau    = target > level ? 0.025 : 0.08
        level += (target - level) * (1 - exp(-elapsed / tau))
        if level < 0.003 { level = 0 }
        return level
    }
}

