


//
import Foundation
import Testing
@testable import Tokens

/*
Runs in the TokensTests SwiftPM target against Talk/FinishGate.swift.
Historical provenance: the donor ran an extracted FinishGate block as a standalone program.
*/
@Suite(.serialized) struct FinishGateTests {
    @Test static func run() {
        let session = UUID()
        for delay in [0.0, 0.5, 2.5, 5.0] {
            var adjustable = FinishGate<String>()
            adjustable.arm(session: session, now: 10, delay: delay)
            precondition(adjustable.fire(session: session, now: 10 + delay) == nil)
            precondition(adjustable.isArmed)
            precondition(adjustable.offer("final trailing word", session: session, now: 10 + delay + 0.3) == "final trailing word")
            precondition(adjustable.fire(session: session, now: 20) == nil)
            precondition(adjustable.progress(now: 10 + delay).isFinite)
        }


        // Text ready early is held until the 5 s deadline, then released exactly once.
        var gate = FinishGate<String>()
        gate.arm(session: session, now: 100)
        precondition(gate.isArmed)
        precondition(gate.offer("twenty 3 Qwen", session: session, now: 100.4) == nil)
        precondition(gate.fire(session: session, now: 104.99) == nil)
        precondition(gate.fire(session: session, now: 105) == "twenty 3 Qwen")
        precondition(gate.fire(session: session, now: 105.1) == nil)
        precondition(gate.offer("again", session: session, now: 106) == nil)
        precondition(!gate.isArmed)

        // A newer final from the recognizer replaces the held one; still one release.
        gate = FinishGate<String>()
        gate.arm(session: session, now: 0)
        _ = gate.offer("partial", session: session, now: 1)
        _ = gate.offer("final", session: session, now: 2)
        precondition(gate.fire(session: session, now: 5) == "final")

        // Recognizer slower than the gate: deadline yields nothing, arrival delivers once.
        gate = FinishGate<String>()
        gate.arm(session: session, now: 0)
        precondition(gate.fire(session: session, now: 5.2) == nil)
        precondition(gate.offer("late", session: session, now: 6) == "late")
        precondition(gate.offer("late", session: session, now: 6.1) == nil)
        precondition(gate.fire(session: session, now: 7) == nil)

        // An expired send delay cannot consume the latch before recognition drains.
        // The audio layer provides its latest snapshot at its own bounded deadline.
        gate = FinishGate<String>()
        gate.arm(session: session, now: 0)
        precondition(gate.fire(session: session, now: 4.9) == nil)
        precondition(gate.fire(session: session, now: 5) == nil && gate.isArmed)
        precondition(gate.offer("recognized through the final word", session: session, now: 6) == "recognized through the final word")
        precondition(gate.offer("duplicate recognizer", session: session, now: 6.1) == nil)

        // Stale sessions and cancelled gates never release.
        gate = FinishGate<String>()
        gate.arm(session: session, now: 0)
        _        = gate.offer("old", session: session, now: 1)
        let next = UUID()
        precondition(gate.offer("stale", session: next, now: 9) == nil)
        precondition(gate.fire(session: next, now: 9) == nil)
        gate.cancel()
        precondition(!gate.isArmed)
        precondition(gate.fire(session: session, now: 9) == nil)
        precondition(gate.offer("old", session: session, now: 9) == nil)
        gate.arm(session: next, now: 10)
        precondition(gate.fire(session: next, now: 20) == nil) // old payload did not leak
        precondition(gate.offer("new", session: next, now: 20) == "new")

        // Re-arming the same session keeps the first Stop edge.
        gate = FinishGate<String>()
        gate.arm(session: session, now: 0)
        gate.arm(session: session, now: 3)
        precondition(gate.deadlineReached(now: 5))

        // Visible countdown: 5 → 0, never increasing, clamped, even with clock jitter.
        gate = FinishGate<String>()
        gate.arm(session: session, now: 50)
        var shown: [Int] = []
        for now in [50, 50.01, 50.99, 51.0, 51.5, 51.2, 52.7, 53.9, 54.2, 54.999, 55, 58] {
            shown.append(gate.secondsRemaining(now: now))
        }
        precondition(shown == [5, 5, 5, 4, 4, 4, 3, 2, 1, 1, 0, 0], "\(shown)")
        precondition(gate.progress(now: 52.5) == 0.5 && gate.progress(now: 99) == 1)
        // All click/timer/recognizer orderings share one release latch.
        let sequences = [["click", "click", "timer", "late"], ["timer", "click", "late"],
                         ["late", "click", "timer"], ["click", "late", "timer"]]
        for sequence in sequences {
            gate                   = FinishGate<String>(); gate.arm(session: session, now: 0)
            var releases: [String] = []
            for event in sequence {
                let value: String?
                switch event {
                case "click": value = gate.releaseNow(session: session, payload: "raw 7.25 unchanged")
                case "timer": value = gate.fire(session: session, now: 5)
                default:      value = gate.offer("late raw", session: session, now: 6)
                }
                if let value { releases.append(value) }
            }
            precondition(releases.count == 1, "duplicate release: \(sequence)")
        }
        gate = FinishGate<String>(); gate.arm(session: session, now: 0)
        precondition(gate.releaseNow(session: session, payload: nil) == nil && gate.isArmed)
        precondition(gate.releaseNow(session: UUID(), payload: "stale") == nil && gate.isArmed)
        _ = gate.offer("newest available", session: session, now: 0.2)
        precondition(gate.releaseNow(session: session, payload: gate.heldPayload) == "newest available")
        precondition(gate.offer("late replacement", session: session, now: 6) == nil)
        gate.cancel()
        precondition(gate.releaseNow(session: session, payload: "cancelled") == nil)
        gate.arm(session: next, now: 10)
        precondition(gate.releaseNow(session: session, payload: "old session") == nil)
        precondition(gate.offer("normal", session: next, now: 11) == nil)
        precondition(gate.fire(session: next, now: 14.99) == nil)
        precondition(gate.fire(session: next, now: 15) == "normal")
        print("TTTFinishGateTests passed")
    }
}


@Suite struct PasteTimingTests {
    @Test func preservesLegacyTimingSelection() {
        #expect(TokensPasteTiming(delay: 0) == .fast)
        for old in [0.5, 1, 2.5, 5] { #expect(TokensPasteTiming(delay: old).delay == 2) }
        #expect(TokensPasteTiming(delay: .nan) == .fast)
    }
    @Test func zeroDelayGateAcceptsEitherReadySnapshotOrFinalWordsExactlyOnce() {
        for readyAt in [0.0, 0.2] {
            let id = UUID()
            var gate = FinishGate<String>()
            gate.arm(session: id, now: 0, delay: 0)
            #expect(gate.fire(session: id, now: 0) == nil)
            #expect(gate.offer("last word", session: id, now: readyAt) == "last word")
            #expect(gate.offer("duplicate", session: id, now: 11) == nil)
        }
    }
}
