import Foundation
import Testing
@testable import Tokens

struct StopPrefixReadbackTests {
    private final class Queue {
        var time: TimeInterval = 0
        var pending: [(TimeInterval, () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { pending.append((delay, work)) }
        func tick() {
            let (delay, work) = pending.removeFirst()
            time += delay
            work()
        }
    }

    @Test func asynchronousAcknowledgementDoesNotDelayOtherCallbacksAndFinishesOnce() {
        let queue = Queue()
        var reads = 0, completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { true }, inspect: {
            reads += 1
            return reads == 2 ? .verified : .waiting
        }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        #expect(reads == 0 && completions.isEmpty)
        queue.tick()
        #expect(reads == 1 && completions.isEmpty)
        let repeatedCallback = queue.pending[0].1
        queue.tick()
        repeatedCallback()
        #expect(reads == 2)
        #expect(completions == [.verified])
    }

    @Test func cancelledSessionNeverReadsAndStaleCallbacksCannotCompleteTwice() {
        let queue = Queue()
        var current = true, reads = 0, completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { current }, inspect: {
            reads += 1; return .waiting
        }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        current = false
        let repeatedCallback = queue.pending[0].1
        queue.tick()
        current = true
        repeatedCallback()
        #expect(reads == 0)
        #expect(completions == [.cancelled])
    }

    @Test func cancellationDuringReadCannotBePromotedToVerification() {
        let queue = Queue()
        var current = true, completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { current }, inspect: {
            current = false; return .verified
        }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        queue.tick()
        #expect(completions == [.cancelled])
    }

    @Test func unresolvedReadbackStopsAtTwoHundredMilliseconds() {
        let queue = Queue()
        var completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { true }, inspect: { .waiting },
            now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        while !queue.pending.isEmpty { queue.tick() }
        #expect(queue.time <= 0.200_001)
        #expect(completions == [.uncertain])
    }

    @Test func slowObservationCannotVerifyAfterTheDeadline() {
        let queue = Queue()
        var completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { true }, inspect: {
            queue.time = 0.3
            return .verified
        }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        queue.tick()
        #expect(completions == [.uncertain])
        #expect(queue.pending.isEmpty)
    }

    @Test func invalidOrLateReadbackNeverVerifies() {
        for late in [false, true] {
            let queue = Queue()
            var reads = 0, completions: [StopPrefixReadback.Result] = []
            StopPrefixReadback.run(isCurrent: { true }, inspect: {
                reads += 1; return late ? .verified : .invalid
            }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
            if late { queue.time = 0.3 }
            queue.tick()
            #expect(reads == (late ? 0 : 1))
            #expect(completions == [.uncertain])
            #expect(queue.pending.isEmpty)
        }
    }

    // Build 37, Codex composer right after an Auto-send: a transient redraw must be waited out.
    @Test func richComposerWaitsOutTransientValuesNativeStillAbortsAtOnce() {
        #expect(StopPrefixReadback.unconfirmed(valueChanged: true, caretMoved: false, richComposer: true) == .waiting)
        #expect(StopPrefixReadback.unconfirmed(valueChanged: false, caretMoved: true, richComposer: true) == .waiting)
        #expect(StopPrefixReadback.unconfirmed(valueChanged: true, caretMoved: false, richComposer: false) == .invalid)
        #expect(StopPrefixReadback.unconfirmed(valueChanged: false, caretMoved: true, richComposer: false) == .invalid)
        #expect(StopPrefixReadback.unconfirmed(valueChanged: false, caretMoved: false, richComposer: false) == .waiting)
    }

    @Test func aTransientRedrawThenTheRealPrefixVerifies() {
        let queue = Queue()
        var reads = 0, completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { true }, inspect: {
            reads += 1
            // Two unrecognised reads (the composer redrawing), then the pasted prefix.
            return reads < 3 ? StopPrefixReadback.unconfirmed(valueChanged: true, caretMoved: false, richComposer: true)
                             : .verified
        }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        while completions.isEmpty && !queue.pending.isEmpty { queue.tick() }
        #expect(completions == [.verified] && reads == 3)
    }

    @Test func aRichComposerThatNeverShowsThePrefixStillEndsUncertainAtTheDeadline() {
        let queue = Queue()
        var completions: [StopPrefixReadback.Result] = []
        StopPrefixReadback.run(isCurrent: { true }, inspect: {
            StopPrefixReadback.unconfirmed(valueChanged: true, caretMoved: false, richComposer: true)
        }, now: { queue.time }, schedule: queue.schedule, completion: { completions.append($0) })
        var ticks = 0
        while completions.isEmpty && !queue.pending.isEmpty && ticks < 1000 { queue.tick(); ticks += 1 }
        #expect(completions == [.uncertain])
    }
}
