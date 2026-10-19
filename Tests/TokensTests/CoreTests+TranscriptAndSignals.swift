


//
/*
CoreTests+TranscriptAndSignals.swift
Tokens · Tests

Owns: transcript state, capture generations, signals and dataset round trips
Never: changes the assertion order or weakens checks.
See: CoreTests.swift (ordered suite entry point).
*/


import Foundation
import Testing
@testable import Tokens


extension CoreTests {
    static func transcriptAndSignals() throws {
        let volatileSnapshot = TranscriptSnapshot(
            finalizedText: "Words appear",
            volatileText: "instantly even when wrong"
        )
        precondition(volatileSnapshot.text == "Words appear instantly even when wrong")
        precondition(volatileSnapshot.stableWordCount == 2)
        let finalSnapshot = TranscriptSnapshot(
            finalizedText: "Words appear instantly even when corrected",
            volatileText: ""
        )
        precondition(finalSnapshot.stableWordCount == 6)

        var transcript = TranscriptAccumulator()
        transcript.apply("hello", isFinal: false)
        precondition(transcript.snapshot == TranscriptSnapshot(
            finalizedText: "", volatileText: "hello"
        ))
        transcript.apply("hello brave", isFinal: false)
        precondition(transcript.snapshot.text == "hello brave")
        transcript.apply("hello brave", isFinal: true)
        transcript.apply("world", isFinal: false)
        transcript.apply("world corrected", isFinal: false)
        transcript.apply("world corrected", isFinal: true)
        precondition(transcript.snapshot.text == "hello brave world corrected")
        // A repeated final phrase is retained as literal transcript text.
        transcript.apply("world corrected", isFinal: true)
        precondition(transcript.snapshot.text == "hello brave world corrected world corrected")

        // Permission, startup and drain callbacks must belong to one session.
        var capture = CaptureSession()
        let first   = capture.begin()!
        precondition(capture.begin() == nil)
        precondition(capture.beginFinishing() == first) // stop before permission
        precondition(!capture.advance(first, from: .awaitingAccess, to: .starting))
        precondition(capture.beginFinishing() == nil) // duplicate finish
        precondition(capture.end(first))
        precondition(!capture.end(first)) // completion exactly once
        let second = capture.begin()!
        precondition(!capture.advance(first, from: .awaitingAccess, to: .starting))
        precondition(!capture.end(first)) // old result cannot retire a new session
        precondition(capture.advance(second, from: .awaitingAccess, to: .starting))
        capture.cancel() // cancel during async analyzer construction
        precondition(!capture.advance(second, from: .starting, to: .recording))
        let third = capture.begin()!
        precondition(capture.advance(third, from: .awaitingAccess, to: .starting))
        precondition(capture.advance(third, from: .starting, to: .recording))
        precondition(capture.beginFinishing() == third)
        precondition(capture.begin() == nil) // no overlapping recognition drain
        precondition(capture.end(third))
        precondition(capture.id == nil && capture.phase == nil)

        /*
        Pointer targeting must reject non-editable and protected controls,
        even when a different editor elsewhere still has keyboard focus.
        */
        func pointerAllowed(_ role: String = "AXTextArea", subrole: String? = nil,
                            enabled: Bool = true, selection: Bool = true,
                            value: Bool = true, selectedText: Bool = false,
                            editable: Bool? = nil) -> Bool {
            PointerTargetPolicy.allows(role: role, subrole: subrole, enabled: enabled,
                selectionAvailable: selection, valueSettable: value,
                selectedTextSettable: selectedText, explicitlyEditable: editable)
        }
        precondition(pointerAllowed())
        precondition(pointerAllowed("AXTextField", subrole: "AXSearchField"))
        precondition(pointerAllowed(value: false, selectedText: true))
        precondition(!pointerAllowed("AXButton"))
        precondition(!pointerAllowed("AXStaticText"))
        precondition(!pointerAllowed("AXTextField", subrole: "AXSecureTextField"))
        precondition(!pointerAllowed(enabled: false))
        precondition(!pointerAllowed(selection: false))
        precondition(!pointerAllowed(value: false))
        precondition(!pointerAllowed(editable: false))

        let fixtures: [(Candidate, AudioFeatures)] = [
            (.breath, AudioFeatures(
                rmsDBFS: -52, peakDBFS: -42, zeroCrossingRate: 0.12,
                brightness: 0.12, modulation: 1, durationSeconds: 0.7,
                crestFactor: 2.1, pitchHz: 0, pitchConfidence: 0.05, onsetStrength: 1
            )),
            (.whisper, AudioFeatures(
                rmsDBFS: -40, peakDBFS: -31, zeroCrossingRate: 0.10,
                brightness: 0.10, modulation: 2, durationSeconds: 0.9,
                crestFactor: 2.4, pitchHz: 0, pitchConfidence: 0.12, onsetStrength: 2
            )),
            (.voice, AudioFeatures(
                rmsDBFS: -25, peakDBFS: -12, zeroCrossingRate: 0.08,
                brightness: 0.09, modulation: 4, durationSeconds: 1.2,
                crestFactor: 2.2, pitchHz: 180, pitchConfidence: 0.55, onsetStrength: 2
            )),
            (.yell, AudioFeatures(
                rmsDBFS: -10, peakDBFS: -2, zeroCrossingRate: 0.06,
                brightness: 0.12, modulation: 3, durationSeconds: 1.1,
                crestFactor: 2.5, pitchHz: 220, pitchConfidence: 0.62, onsetStrength: 3
            )),
            (.laugh, AudioFeatures(
                rmsDBFS: -25, peakDBFS: -8, zeroCrossingRate: 0.11,
                brightness: 0.18, modulation: 8.4, durationSeconds: 1.5,
                crestFactor: 2.7, pitchHz: 190, pitchConfidence: 0.48, onsetStrength: 3
            )),
            (.cough, AudioFeatures(
                rmsDBFS: -22, peakDBFS: -6, zeroCrossingRate: 0.13,
                brightness: 0.22, modulation: 4, durationSeconds: 0.5,
                crestFactor: 4.2, pitchHz: 0, pitchConfidence: 0.12, onsetStrength: 7
            )),
            (.sigh, AudioFeatures(
                rmsDBFS: -30, peakDBFS: -18, zeroCrossingRate: 0.18,
                brightness: 0.20, modulation: 3, durationSeconds: 1.4,
                crestFactor: 2.6, pitchHz: 0, pitchConfidence: 0.10, onsetStrength: 2
            )),
            (.hum, AudioFeatures(
                rmsDBFS: -28, peakDBFS: -20, zeroCrossingRate: 0.02,
                brightness: 0.04, modulation: 1.2, durationSeconds: 1.8,
                crestFactor: 1.8, pitchHz: 165, pitchConfidence: 0.84, onsetStrength: 1
            )),
            (.whistle, AudioFeatures(
                rmsDBFS: -24, peakDBFS: -17, zeroCrossingRate: 0.05,
                brightness: 0.06, modulation: 1.4, durationSeconds: 1.2,
                crestFactor: 1.7, pitchHz: 1_240, pitchConfidence: 0.91, onsetStrength: 1
            )),
            (.snap, AudioFeatures(
                rmsDBFS: -18, peakDBFS: -1, zeroCrossingRate: 0.24,
                brightness: 0.40, modulation: 4, durationSeconds: 0.2,
                crestFactor: 8.2, pitchHz: 0, pitchConfidence: 0.08, onsetStrength: 15
            ))
        ]
        precondition(Candidate.benchmarkClasses.count == 10)
        for (expected, features) in fixtures {
            precondition(Interpreter.interpret(features).candidate == expected, "expected \(expected)")
        }

        let whisper = Interpreter.interpret(AudioFeatures(
            rmsDBFS: -46, peakDBFS: -35, zeroCrossingRate: 0.04,
            brightness: 0.05, modulation: 1, durationSeconds: 0.8
        ))
        precondition(whisper.candidate == .whisper)

        let yell = Interpreter.interpret(AudioFeatures(
            rmsDBFS: -10, peakDBFS: -2, zeroCrossingRate: 0.06,
            brightness: 0.12, modulation: 3, durationSeconds: 1.1
        ))
        precondition(yell.candidate == .yell)
        precondition(yell.bits.count == 12)

        let laugh = Interpreter.interpret(AudioFeatures(
            rmsDBFS: -25, peakDBFS: -8, zeroCrossingRate: 0.11,
            brightness: 0.18, modulation: 8.4, durationSeconds: 1.5
        ))
        precondition(laugh.candidate == .laugh)
    }
}

