
import ApplicationServices
import Foundation

/*
Each request was bounded, but nothing bounded the chain.
A destination could answer the first focus read and then stall on the window, the warmup
reads, the secure-field check, the text snapshot and its single-value fallback, each for a
full second, all on the main thread. Now one budget is shared by every request of a capture
or a delivery: TargetDelivery.ask charges it, a request that runs out of time stops it, and a
stopped budget answers every later request with "cannot complete" without asking the app.
Callers already treat that as "not the same target", so a stuck app fails closed: nothing
is pasted that was not checked, no Return is sent, and the words stay in recovery.
Used only on the thread or task that bound it, hence @unchecked Sendable.
*/
final class AXWaitBudget: @unchecked Sendable {
    enum Stop: String {
        /// A request waited its whole bound and the app still had not answered.
        case timedOut = "timed_out"
        /// All the waiting together reached the total.
        case spent = "spent"
    }

    /// The budget in force for this task (or thread); nil outside a capture or delivery.
    @TaskLocal static var current: AXWaitBudget?

    /*
    The two system-wide questions (the last focus fallback and the pointer hit test) cannot
    be given a wait of their own: the system-wide reference's timeout is Tokens' process-wide
    default (AXUIElement.h). That default is set to this short wait, and such a question is
    asked only while the whole wait still fits in the budget. It changes how long Tokens itself
    waits, never another app's timeouts (build 81).
    */
    static let systemWideWait: TimeInterval = 0.25
    /// Below this, a request is not worth starting: the budget counts as spent.
    static let minimumWait: TimeInterval = 0.01

    let total: TimeInterval
    let perRequest: TimeInterval
    private let now: () -> TimeInterval
    private(set) var spent: TimeInterval = 0
    private(set) var requests = 0
    private(set) var stop: Stop?

    init(total: TimeInterval, perRequest: TimeInterval = Double(TargetDelivery.messagingTimeout),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.total = total
        self.perRequest = perRequest
        self.now = now
    }

    var stopped: Bool { stop != nil }
    var remaining: TimeInterval { max(0, total - spent) }

    /*
    One capture: the stop key throws a capture away after 0.5 s anyway
    (GlobalKeyMonitor.deliveryEdgeIsCurrent), so a second of waiting in all is already generous.
    */
    static func forCapture() -> AXWaitBudget { AXWaitBudget(total: 1.0) }

    /// One small step on its own: the Return check, one staged insertion, a lone lease check.
    static func forStep() -> AXWaitBudget { AXWaitBudget(total: 1.0) }

    /*
    One delivery, from the pointer check and preflight through every piece to the last readback.
    A measured nine-write reveal took 0.45 s in all, waits included (build 80 live QA log,
    2026-10-15), so three seconds
    plus one per thousand UTF-16 units of the words leaves a healthy long reveal far inside it,
    while a slow app that answers each question just under the bound still stops (build 81).
    */
    static func forDelivery(characters: Int) -> AXWaitBudget {
        AXWaitBudget(total: 3.0 + Double(max(0, characters)) / 1000)
    }

    /*
    Asks one request with the wait it may use: the smaller of the per-request bound and what is
    left. A stopped or spent budget answers "cannot complete" and the request is never made.
    */
    func ask(_ request: (Float) -> AXError) -> AXError {
        guard stop == nil else { return .cannotComplete }
        let wait = min(perRequest, remaining)
        guard wait >= Self.minimumWait else { stop = .spent; return .cannotComplete }
        return charge(wait) { request(Float(wait)) }
    }

    /*
    A request whose wait is fixed elsewhere (the system-wide reference): asked only while that
    whole wait still fits, so the total can never be overrun. Not fitting is not a stop; the
    request is simply skipped, like a fallback that found nothing.
    */
    func askWhole(_ wait: TimeInterval, _ request: () -> AXError) -> AXError {
        guard stop == nil, remaining >= wait else { return .cannotComplete }
        return charge(wait, request)
    }

    private func charge(_ wait: TimeInterval, _ request: () -> AXError) -> AXError {
        requests += 1
        let started = now()
        let error = request()
        let elapsed = max(0, now() - started)
        spent += elapsed
        if TargetDelivery.requestTimedOut(error, elapsed: elapsed, bound: wait) {
            stop = .timedOut
        } else if spent >= total {
            stop = .spent
        }
        return error
    }

    /// Runs `body` under the budget already in force, or under a new one from `make` when there is none.
    static func within<T>(_ make: @autoclosure () -> AXWaitBudget, _ body: (AXWaitBudget) throws -> T) rethrows -> T {
        if let current { return try body(current) }
        let budget = make()
        return try $current.withValue(budget) { try body(budget) }
    }

    /// One line for the diagnostics log when a budget stopped: counts and times only.
    var summary: String {
        "stop=\(stop?.rawValue ?? "none") requests=\(requests) waited_ms=\(Int((spent * 1000).rounded())) total_ms=\(Int((total * 1000).rounded()))"
    }
}
