


//
import CoreGraphics
import Foundation


// WakeVocabulary


enum WakeVocabulary {
    static let start      = "on"
    static let stop       = "off"
    static let dictionary = ["on": "🟢 Start dictation", "off": "📋 Finish and paste"]
}


// WakeEvent


struct WakeEvent {
    enum Kind { case began, updated, stopping, finished }
    var id = UUID()
    var spanID: UUID
    var kind: Kind
    var text: String
    var features: AudioFeatures = .silence
}


// WakeRouter — Commands are anchored to recognition audio times, never shifting text indices


/// Commands are anchored to recognition audio times, never shifting text indices.
/// An endpoint must be an isolated utterance (or repeated isolated Off tokens).
struct WakeRouter {
    private(set) var spanID: UUID?
    private(set) var startTime = 0.0
    private(set) var stopTime: Double?
    private var consumedThrough     = -Double.infinity
    private var lastText            = ""
    private var latest: [TimedWord] = []

    mutating func begin(at time: Double) -> WakeEvent? {
        guard spanID == nil else { return nil }
        let id = UUID(); spanID = id; startTime = time; stopTime = nil; lastText = ""
        return WakeEvent(spanID: id, kind: .began, text: "")
    }

    mutating func requestStop(at time: Double) -> WakeEvent? {
        guard let id = spanID, stopTime == nil else { return nil }
        stopTime = time
        return WakeEvent(spanID: id, kind: .stopping, text: payload(until: time))
    }

    mutating func finish() -> WakeEvent? {
        guard let id = spanID, let cutoff = stopTime else { return nil }
        let text        = payload(until: cutoff)
        consumedThrough = max(consumedThrough, cutoff)
        spanID          = nil; stopTime = nil; lastText = ""
        return WakeEvent(spanID: id, kind: .finished, text: text)
    }

    mutating func observe(_ words: [TimedWord], audioTime: Double,
                          silences: [SilenceInterval]? = nil) -> [WakeEvent] {
        latest                  = words.filter { $0.start.isFinite && $0.end.isFinite }.sorted { $0.start < $1.start }
        var events: [WakeEvent] = []
        if spanID == nil {
            for (index, word) in latest.enumerated() where word.start >= consumedThrough {
                let gap = index == 0 ? Double.infinity : word.start - latest[index - 1].end
                let acousticStart = silences?.contains { $0.duration >= 0.4 && $0.start <= word.start && abs($0.end - word.start) <= 0.3 } ?? false
                guard word.command == WakeVocabulary.start, gap >= 0.4 || acousticStart else { continue }
                // A following word confirms a prefix; an isolated On settles first.
                guard index + 1 < latest.count || audioTime - word.end >= 0.35 else { continue }
                if let began = begin(at: word.end) { events.append(began) }
                break
            }
        }
        guard let id = spanID else { return events }
        if stopTime == nil {
            let active = latest.filter { $0.start >= startTime - 0.015 }
            for (index, word) in active.enumerated() where word.command == WakeVocabulary.stop {
                let priorEnd = index == 0 ? startTime : active[index - 1].end
                let before = silences.map { ranges in ranges.contains {
                    $0.duration >= 0.4 && $0.start <= word.start && abs($0.end - word.start) <= 0.3
                } } ?? (word.start - priorEnd >= 0.4)
                guard before else { continue }
                var last = index
                while last + 1 < active.count,
                      active[last + 1].start - active[last].end < 0.4,
                      active[last + 1].command == WakeVocabulary.stop { last += 1 }
                let end          = active[last].end
                let followingGap = last + 1 < active.count ? active[last + 1].start - end : audioTime - end
                guard followingGap >= 0.45 else { continue }
                if let silences {
                    guard silences.contains(where: { $0.duration >= 0.45 && abs($0.start - end) <= 0.6 && $0.start > word.start }) else { continue }
                }
                // If another word follows within this utterance it was ordinary prose.
                if let stopping = requestStop(at: word.start) { events.append(stopping) }
                consumedThrough = max(consumedThrough, end)
                if let finished = finish() { events.append(finished) }
                return events
            }
        }
        let text = payload(until: stopTime ?? .infinity)
        if text != lastText { lastText = text; events.append(WakeEvent(spanID: id, kind: .updated, text: text)) }
        return events
    }

//
// :)
//
//
    private func payload(until cutoff: Double) -> String {
        latest.filter { $0.start >= startTime - 0.015 && $0.start < cutoff }
            .map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


// FinishCommand


enum FinishCommand: Equatable, Sendable {
    case finish
    case finishAndReturn
}


// FinishMatch


struct FinishMatch: Equatable, Sendable {
    var payload: String
    var command: FinishCommand
}


// VoiceCommand — Commands occupy a separate, whole utterance


/// Commands occupy a separate, whole utterance. Ordinary endings and quoted
/// command names remain literal transcript. No fuzzy spelling/intent matching.
enum VoiceCommand: Equatable, Sendable {
    case copyTalk, minimize, fullScreen, restoreSize, closeWindow, paste, send, stopListening
    case labSound(Candidate)

    var rawValue: String {
        switch self {
        case .copyTalk: return "copyTalk"
        case .minimize: return "minimize"
        case .fullScreen: return "fullScreen"
        case .restoreSize: return "restoreSize"
        case .closeWindow: return "closeWindow"
        case .stopListening: return "stopListening"
        case .paste: return "paste"
        case .send: return "send"
        case .labSound(let candidate): return "labSound.\(candidate.displayName)"
        }
    }
}


// VoiceCommandParser


enum VoiceCommandParser {
    static let labRecognitionHints = [
        "Tinkr", "Tinker", "Stop Tinkr", "Stop Tinker", "Tinkr close",
        "Tinkr minimize", "Tinkr full screen", "Tinkr resize", "Tinkr pause"
    ] + Candidate.benchmarkClasses.map { "Tinkr " + $0.displayName }

    /// Lab-only controls may act on a settled partial; they never deliver or
    /// rewrite dictated text. Explicit finite ASR aliases stay in this context.
    static func standaloneLabCommand(in raw: String) -> VoiceCommand? {
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        switch phrase {
        case "stop tinkr", "stop tinker", "tinkr stop", "tinker stop", "tinkr pause", "tinker pause":
            return .stopListening
        case "tinkr clothes", "tinker clothes", "tinkr, clothes", "tinker, clothes":
            return .closeWindow
        default:
            switch standaloneCommand(in: raw) {
            case .minimize, .fullScreen, .restoreSize, .closeWindow, .labSound:
                return standaloneCommand(in: raw)
            default: return nil
            }
        }
    }

//
// :)
//
//
    static func standaloneCommand(in raw: String) -> VoiceCommand? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.contains(where: { "\"“”‘’".contains($0) }) else { return nil }
        let phrase = clean.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        /*
        Apple ASR spells the spoken brand as both Tinkr and Tinker. This
        finite command-only alias never rewrites dictated lexical text.
        */
        let commandPhrase: String
        if phrase.hasPrefix("tinker, ") {
            commandPhrase = "tinkr " + phrase.dropFirst(8)
        } else if phrase.hasPrefix("tinkr, ") {
            commandPhrase = "tinkr " + phrase.dropFirst(7)
        } else {
            commandPhrase = phrase.hasPrefix("tinker ") ? "tinkr " + phrase.dropFirst(7) : phrase
        }
        switch commandPhrase {
        case "copy talk":         return .copyTalk
        case "tinkr minimize":    return .minimize
        case "tinkr full screen": return .fullScreen
        case "tinkr resize":      return .restoreSize
        case "tinkr close":       return .closeWindow
        case "tinkr paste":       return .paste
        case "tinkr send":        return .send
        case "tinkr breath":      return .labSound(.breath)
        case "tinkr whisper":     return .labSound(.whisper)
        case "tinkr talk":        return .labSound(.voice)
        case "tinkr yell":        return .labSound(.yell)
        case "tinkr laugh":       return .labSound(.laugh)
        case "tinkr cough":       return .labSound(.cough)
        case "tinkr sigh":        return .labSound(.sigh)
        case "tinkr hum":         return .labSound(.hum)
        case "tinkr whistle":     return .labSound(.whistle)
        case "tinkr snap":        return .labSound(.snap)
        default:                  return nil
        }
    }
}


// FinishCommandParser — Compatibility for the delivery API


/// Compatibility for the delivery API. Never strips an ordinary text suffix.
enum FinishCommandParser {
    static func trailingCommand(in raw: String) -> FinishMatch? {
        switch VoiceCommandParser.standaloneCommand(in: raw) {
        case .paste: return FinishMatch(payload: "", command: .finish)
        case .send:  return FinishMatch(payload: "", command: .finishAndReturn)
        default:     return nil
        }
    }
}


// CommandUtterance


struct CommandUtterance: Equatable {
    let text: String
    let precedingTranscript: String
}


// CommandUtteranceTracker — A revised earlier hypothesis invalidates command extraction at that pause


/// A revised earlier hypothesis invalidates command extraction at that pause.
/// The full raw transcript is still retained, including any ambiguous phrase.
struct CommandUtteranceTracker {

//
// :)
//
//
    private var previousSnapshot = ""

    mutating func consume(_ snapshot: String) -> CommandUtterance? {
        defer { previousSnapshot = snapshot }
        guard snapshot.hasPrefix(previousSnapshot) else { return nil }
        let suffix = String(snapshot.dropFirst(previousSnapshot.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return nil }
        return CommandUtterance(text: suffix, precedingTranscript: previousSnapshot)
    }
}


// LabCommandTracker — A Lab command is a whole recognition chunk settled for 650 ms


/// A Lab command is a whole recognition chunk settled for 650 ms. Final ASR
/// status is deliberately not required: Lab controls cannot paste or send.
/// Revising an earlier chunk fails closed for that chunk, preserving raw words.
struct LabCommandTracker {
    private var snapshot                = ""
    private var changedAt               = 0.0
    private var consumed                = true
    private var previousWords: [String] = []

    mutating func observe(_ text: String, at time: TimeInterval) {
        guard text != snapshot else { return }
        snapshot  = text
        changedAt = time
        consumed  = false
    }

    mutating func poll(at time: TimeInterval) -> VoiceCommand? {
        guard !consumed, time - changedAt >= 0.65 else { return nil }
        consumed    = true
        let words   = snapshot.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let lexical = words.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        /*
        Late capitalization and punctuation are not lexical revisions. ASR
        frequently finalizes those after a quiet partial was already seen.
        */
        guard lexical.starts(with: previousWords) else {
            previousWords = lexical
            return nil
        }
        let utteranceWords = words.dropFirst(previousWords.count)
        let pending        = lexical.dropFirst(previousWords.count).joined(separator: " ")
        /*
        Recognition may emit the wake word a full second before the next
        word. Do not consume that incomplete command as ordinary speech.
        */
        if ["stop", "tinkr", "tinker", "tinkr full", "tinker full"].contains(pending) {
            return nil
        }
        previousWords = lexical
        return VoiceCommandParser.standaloneLabCommand(in: utteranceWords.joined(separator: " "))
    }
}

