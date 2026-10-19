


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// FinishGate — the stop gate: holds finished words until the send delay ends


/*
How TalkModel drives it, for one talk:
  Stop pressed   → arm(session:now:delay:)   the send delay from Settings, 0 to 5 s
  words ready    → offer(...)                returns them only if the delay already passed
  deadline tick  → fire(...)                 returns held final words once; otherwise waits
  "Take off now" → releaseNow(...)           the user skips the rest of the delay
  discard/reset  → cancel()
Whichever of offer, fire or releaseNow returns words first wins; the others then return nil.
*/

// TTT_FINISH_GATE_BEGIN (extracted verbatim by Scripts/test_finish_gate.sh)
/// Hard stop-to-delivery gate. Pure: callers pass a monotonic clock. A payload
/// is released exactly once, never before the deadline, and never for a
/// session other than the one armed at Stop.
struct FinishGate<Payload> {

    // State and arming — which talk is armed, and the release-once latch


    /// The longest send delay, in seconds. The countdown never shows more than this.
    static var window: TimeInterval { 5 }

    private(set) var session: UUID?
    private var startUptime: TimeInterval = 0
    private var delay: TimeInterval       = 5
    private var pending: Payload?
    /*
    The release-once latch. Once true, offer, fire and releaseNow all return nil
    until cancel() or a different talk is armed.
    */
    private var released = false
    // Smallest whole second shown so far, so the countdown never goes back up.
    private var lowestShown = 5

    var isArmed: Bool { session != nil && !released }
    var heldPayload: Payload? { pending }

    /// Explicit early release shares the deadline's exactly-once latch.
    /// A missing payload does not consume the gate; later recognition can finish.
    mutating func releaseNow(session: UUID, payload: Payload?) -> Payload? {
        guard self.session == session, !released, let payload else { return nil }
        released = true
        pending  = nil
        return payload
    }

    /// Arms once per session; re-arming the same session keeps the first Stop edge.
    /// The delay is clamped to 0...5 seconds; a non-finite delay becomes 0 (open at once).
    mutating func arm(session: UUID, now: TimeInterval, delay: TimeInterval = 5) {
        guard self.session != session else { return }
        self.session = session
        startUptime  = now
        self.delay   = delay.isFinite ? min(5, max(0, delay)) : 0
        pending      = nil
        released     = false
        lowestShown  = Int(self.delay.rounded(.up))
    }

    /// Forgets the armed talk and any held words (talk discarded, paused or reset).
    mutating func cancel() {
        session  = nil
        pending  = nil
        released = false
    }

//
// :)
//
//
    // Clock reads and release — deadline, countdown, offer and fire


    /// True once the delay has passed since Stop. With a zero delay this is true at once.
    func deadlineReached(now: TimeInterval) -> Bool {
        session != nil && now - startUptime >= delay
    }

    /// 0 at Stop, 1 at the deadline. TalkModel publishes it to the bubble
    /// as finishCountdownProgress.
    func progress(now: TimeInterval) -> Double {
        guard session != nil else { return 0 }
        return delay == 0 ? 1 : min(1, max(0, (now - startUptime) / delay))
    }

    /// Whole seconds left, 5 down to 0. Never increases within a session.
    mutating func secondsRemaining(now: TimeInterval) -> Int {
        guard session != nil else { return 0 }
        let left    = Int((delay - (now - startUptime)).rounded(.up))
        lowestShown = min(lowestShown, max(0, min(Int(Self.window), left)))
        return lowestShown
    }

    /// The final text became ready. Returns it only when the deadline already
    /// passed; otherwise holds the newest offer for `fire`.
    mutating func offer(_ payload: Payload, session: UUID, now: TimeInterval) -> Payload? {
        guard self.session == session, !released else { return nil }
        guard deadlineReached(now: now) else {
            pending = payload
            return nil
        }
        released = true
        pending  = nil
        return payload
    }

    /// Deadline tick. Returns the held payload at most once; nil when the
    /// recognizer has not produced one yet (a later `offer` releases it).
    /// The Stop snapshot is deliberately not accepted here: a zero send delay must
    /// not beat the recognizer's bounded drain and discard the last spoken words.
    /// Explicit early release remains available through `releaseNow`.
    mutating func fire(session: UUID, now: TimeInterval) -> Payload? {
        guard self.session == session, !released, deadlineReached(now: now),
              let payload = pending else { return nil }
        released = true
        pending  = nil
        return payload
    }


}


/// Fast takes the current words; Slow lets recognition settle. The legacy numeric
/// values are storage compatibility only, never an extra delivery delay.
enum TokensPasteTiming: String, CaseIterable {
    case fast, slow
    init(delay: Double) { self = delay.isFinite && delay > 0 ? .slow : .fast }
    var delay: Double { self == .fast ? 0 : 2 }
    var caption: String {
        self == .fast ? "Paste captured words immediately" : "Finish the last words, then paste"
    }
}
