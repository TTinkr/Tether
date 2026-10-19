import Foundation
import Testing
@testable import Tokens

/// Build 82: Cancel then Download never lets two transfers of one model
/// write its .partial file at once; a cancelled attempt finishes its file work before the next starts,
/// and a transfer cancelled before its request starts answers instead of touching a dead session.
@MainActor
struct ModelTransferSlotsTests {
    /// A gate a fake transfer waits on, like URLSession's delegate still finishing after Cancel. On the
    /// main actor with the slots' work, so wait() and release() never race (review, 2026-10-17).
    @MainActor final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    private static func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func aCancelledTransferFinishesItsFileWorkBeforeTheNextStarts() async {
        let slots = ModelTransferSlots()
        let gate = Gate()
        var log: [String] = []
        var aWasCurrentAfterCancel: Bool?
        slots.start("m") { current in
            log.append("A start")
            await gate.wait()            // the old transfer is still writing after Cancel
            aWasCurrentAfterCancel = current()
            log.append("A end")
        }
        await Self.settle()
        #expect(slots.isRunning("m"))
        slots.cancel("m")
        #expect(!slots.isRunning("m") && slots.isBusy("m"), "Cancel frees the row but keeps the old transfer in line")
        slots.start("m") { _ in log.append("B start") }
        await Self.settle()
        #expect(log == ["A start"], "the new transfer waits for the old one: \(log)")
        gate.release()
        await slots.drained("m")
        #expect(log == ["A start", "A end", "B start"])
        #expect(aWasCurrentAfterCancel == false, "a cancelled attempt is stale at once")
    }

    @Test func anAttemptCancelledWhileWaitingNeverStarts() async {
        let slots = ModelTransferSlots()
        let gate = Gate()
        var log: [String] = []
        slots.start("m") { _ in log.append("A"); await gate.wait() }
        await Self.settle()
        slots.cancel("m")
        slots.start("m") { _ in log.append("B") }
        slots.cancel("m")
        slots.start("m") { _ in log.append("C") }
        gate.release()
        await slots.drained("m")
        #expect(log == ["A", "C"], "B was cancelled before it began: \(log)")
    }

    @Test func removeStepsRunAfterTheTransferStopsAndModelsDoNotWaitForEachOther() async {
        let slots = ModelTransferSlots()
        let gate = Gate()
        var log: [String] = []
        slots.start("a") { _ in await gate.wait(); log.append("a file moved") }
        slots.start("b") { _ in log.append("b") }
        await Self.settle()
        #expect(log == ["b"], "another model never waits")
        slots.cancel("a")
        slots.then("a") { log.append("a removed") }
        await Self.settle()
        #expect(!log.contains("a removed"))
        gate.release()
        await slots.drained("a")
        #expect(log == ["b", "a file moved", "a removed"], "a late finish cannot outlast Remove: \(log)")
    }
}
