


//
import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Speech
import SwiftUI


// Lense


enum Lense: String, CaseIterable, Codable, Identifiable {
    case signal    = "SIGNAL"
    case binary    = "BINARY"
    case color     = "COLOR"
    case character = "T CREATURE"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .signal:    return "local DSP baseline"
        case .binary:    return "feature threshold signature"
        case .color:     return "continuous energy mapping"
        case .character: return "original reactive renderer"
        }
    }
}


// Candidate


enum Candidate: String, Codable, Sendable {
    case silence
    case breath
    case whisper
    case voice
    case yell
    case laugh
    case cough
    case sigh
    case hum
    case whistle
    case snap
    case texture

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let storedValue = try container.decode(String.self)
        // Read the legacy dataset spelling; new records use the ordinary word.
        let value = storedValue == "wispr" ? "whisper" : storedValue
        guard let candidate = Candidate(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown sound category")
        }
        self = candidate
    }

    static let benchmarkClasses: [Candidate] = [
        .breath, .whisper, .voice, .yell, .laugh,
        .cough, .sigh, .hum, .whistle, .snap
    ]

    var displayName: String {
        switch self {
        case .silence: return "quiet"
        case .breath:  return "breath"
        case .whisper:   return "whisper"
        case .voice:   return "talk"
        case .yell:    return "yell"
        case .laugh:   return "laugh"
        case .cough:   return "cough"
        case .sigh:    return "sigh"
        case .hum:     return "hum"
        case .whistle: return "whistle"
        case .snap:    return "snap"
        case .texture: return "texture"
        }
    }

    var symbol: String? {
        switch self {
        case .breath:            return "≈"
        case .whisper:             return "·"
        case .voice:             return "\""
        case .yell:              return "!"
        case .laugh:             return "😄"
        case .cough:             return "🤧"
        case .sigh:              return "😮‍💨"
        case .hum:               return "〜"
        case .whistle:           return "♪"
        case .snap:              return "✦"
        case .silence, .texture: return nil
        }
    }
}

//
// :)
//
//
// Reaction


struct Reaction: Codable, Equatable {
    var candidate: Candidate
    var intensity: Double
    var bits: String
    var hue: Double
    var message: String
}


// Interpreter


enum Interpreter {
    static func interpret(_ features: AudioFeatures) -> Reaction {
        let candidate: Candidate
        let crest           = features.crestFactor ?? 1
        let pitch           = features.pitchHz ?? 0
        let pitchConfidence = features.pitchConfidence ?? 0
        let onset           = features.onsetStrength ?? 0
        if features.rmsDBFS < -58 {
            candidate = .silence
        } else if onset > 11 && crest > 6.0 {
            candidate = .snap
        } else if onset > 5.5 && crest > 3.4 && features.brightness > 0.10 {
            candidate = .cough
        } else if pitchConfidence > 0.76 && pitch > 850 && features.modulation < 4.5 {
            candidate = .whistle
        } else if pitchConfidence > 0.70 && pitch >= 75 && pitch < 420 && features.modulation < 3.2 && features.rmsDBFS < -18 {
            candidate = .hum
        } else if features.rmsDBFS > -16 || features.peakDBFS > -5 {
            candidate = .yell
        } else if features.modulation > 6.0 && features.zeroCrossingRate > 0.045 && features.zeroCrossingRate < 0.19 {
            candidate = .laugh
        } else if pitchConfidence < 0.28 && features.rmsDBFS > -38 && features.brightness > 0.12 && features.modulation < 4.8 {
            candidate = .sigh
        } else if features.rmsDBFS < -48 && pitchConfidence < 0.30 {
            candidate = .breath
        } else if features.rmsDBFS < -30 && pitchConfidence < 0.38 {
            candidate = .whisper
        } else {
            candidate = .voice
        }

        let bitValues: [Bool] = [
            features.rmsDBFS > -50,
            features.rmsDBFS > -35,
            features.rmsDBFS > -20,
            features.peakDBFS > -12,
            features.peakDBFS > -5,
            features.zeroCrossingRate > 0.05,
            features.zeroCrossingRate > 0.12,
            features.brightness > 0.12,
            features.brightness > 0.30,
            features.modulation > 2,
            features.modulation > 6,
            features.durationSeconds > 1
        ]
        let bits = bitValues.map { $0 ? "1" : "0" }.joined()
        let hue  = min(0.96, max(0.02, 0.60 - features.normalizedEnergy * 0.55 + features.brightness * 0.20))

        return Reaction(
            candidate: candidate,
            intensity: features.normalizedEnergy,
            bits: bits,
            hue: hue,
            message: message(for: candidate)
        )
    }

//
// :)
//
//
    private static func message(for candidate: Candidate) -> String {
        switch candidate {
        case .silence: return "waiting for a human signal"
        case .breath:  return "breath-like signal candidate"
        case .whisper:   return "soft signal candidate"
        case .voice:   return "voice-like signal candidate"
        case .yell:    return "high-energy signal candidate"
        case .laugh:   return "rhythmic signal candidate"
        case .cough:   return "broad transient signal candidate"
        case .sigh:    return "falling noisy signal candidate"
        case .hum:     return "steady low tonal candidate"
        case .whistle: return "steady high tonal candidate"
        case .snap:    return "impulse signal candidate"
        case .texture: return "noisy texture candidate"
        }
    }
}

