
import Foundation

@MainActor
final class ModelTransferSlots {
    /// The attempt the store shows for each model; nil when none is running.
    private var running: [String: Task<Void, Never>] = [:]
    /// The last thing scheduled for each model (an attempt or a chained step); the next waits for it.
    private var tails: [String: Task<Void, Never>] = [:]
    private var generation: [String: Int] = [:]

    /// An attempt is running for this model (not cancelled).
    func isRunning(_ id: String) -> Bool { running[id] != nil }

    /// Anything is still scheduled for this model, running or draining after Cancel.
    func isBusy(_ id: String) -> Bool { running[id] != nil || tails[id] != nil }

    /*
    Starts `work` once every earlier attempt and step for this model has returned. `current()` is
    true until Cancel (or a newer attempt) makes this one stale; an attempt cancelled while it waits
    never runs its work at all.
    */
    func start(_ id: String, _ work: @escaping @MainActor (_ current: @escaping @MainActor () -> Bool) async -> Void) {
        let previous = tails[id]
        let mine = (generation[id] ?? 0) + 1
        generation[id] = mine
        let current: @MainActor () -> Bool = { [weak self] in self?.generation[id] == mine }
        let task = Task { @MainActor in
            await previous?.value
            guard current(), !Task.isCancelled else { return }
            await work(current)
        }
        running[id] = task
        tails[id] = task
        settle(id, task)
    }

    /// Makes the running attempt stale and cancels it; it stays in the chain until it returns.
    func cancel(_ id: String) {
        generation[id, default: 0] += 1
        running[id]?.cancel()
        running[id] = nil
    }

    /// Runs `step` after everything scheduled for this model so far has returned.
    func then(_ id: String, _ step: @escaping @MainActor () async -> Void) {
        let previous = tails[id]
        let task = Task { @MainActor in
            await previous?.value
            await step()
        }
        tails[id] = task
        settle(id, task)
    }

    /// Waits for everything scheduled for this model so far (tests and proofs).
    func drained(_ id: String) async {
        while let tail = tails[id] { await tail.value; if tails[id] == tail { break } }
    }

    private func settle(_ id: String, _ task: Task<Void, Never>) {
        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            if self.running[id] == task { self.running[id] = nil }
            if self.tails[id] == task { self.tails[id] = nil }
        }
    }
}
