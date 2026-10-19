


//
import CoreGraphics
import Foundation


// ArrowChordAction — what a recognised arrow chord asks for (only toggle)


enum ArrowChordAction: Equatable, Sendable {
    case toggle
}


// ArrowChordDetector — state machine for the left+right arrow gesture


/// Pure state machine for TTT's global left/right-arrow gesture.
///
/// A real overlap works in either order. The only sequential fallback is the
/// right-then-left gesture inside a short window. Repeats,
/// modifier chords, and any intervening input cancel the candidate.
struct ArrowChordDetector: Sendable {
    static let leftKeyCode: UInt16  = 123
    static let rightKeyCode: UInt16 = 124

    var maximumInterval: TimeInterval = 0.11
    private var pressed: Set<UInt16>  = []
    private var lastRightDown: TimeInterval?
    private var chordConsumed = false

    init(maximumInterval: TimeInterval = 0.11) {
        self.maximumInterval = maximumInterval
    }

    mutating func keyDown(
        keyCode: UInt16,
        timestamp: TimeInterval,
        isRepeat: Bool = false,
        hasDisallowedModifiers: Bool = false
    ) -> ArrowChordAction? {
        guard !isRepeat, !hasDisallowedModifiers,
              keyCode == Self.leftKeyCode || keyCode == Self.rightKeyCode else {
            cancelSequence()
            return nil
        }

        /*
        Two ways to fire: both arrows down at once (either order), or Right then Left
        within maximumInterval seconds. chordConsumed makes one gesture fire once; it
        is cleared only when every arrow is back up.
        */
        let other           = keyCode == Self.leftKeyCode ? Self.rightKeyCode : Self.leftKeyCode
        let overlaps        = pressed.contains(other)
        let isRightThenLeft = keyCode == Self.leftKeyCode
            && lastRightDown.map { timestamp - $0 >= 0 && timestamp - $0 <= maximumInterval } == true
        pressed.insert(keyCode)
        if keyCode == Self.rightKeyCode { lastRightDown = timestamp }

        guard !chordConsumed, overlaps || isRightThenLeft else { return nil }
        chordConsumed = true
        lastRightDown = nil
        return .toggle
    }

    mutating func keyUp(keyCode: UInt16) {
        pressed.remove(keyCode)
        if pressed.isEmpty { chordConsumed = false }
    }

    mutating func cancelSequence() {
        pressed.removeAll()
        lastRightDown = nil
        chordConsumed = false
    }
}

//
// :)
//
//
// RightOptionHold — press and release edges of the Right Option key only


/// Device-specific modifier state. Left Option never triggers dictation.
struct RightOptionHold {
    private(set) var held = false
    /*
    61 is Right Option's key code and 0x40 is its own bit in the event flags, so Left
    Option (bit 0x20) never counts. Returns true on press, false on release, else nil.
    */
    mutating func update(keyCode: Int64, flags: UInt64) -> Bool? {
        guard keyCode == 61 else { return nil }
        let down = flags & 0x40 != 0
        guard down != held else { return nil }
        held = down
        return down
    }
}


// FastFinishChord — Return pressed while the talk key is held finishes the talk at once


/// Return (main or keypad Enter) finishes only while the caller-supplied talk
/// key is held. Further Return key repeats are consumed until that key is released.
struct FastFinishChord {
    enum Action: Equatable { case passThrough, consume, finish }
    private(set) var triggered = false

    mutating func optionReleased() { triggered = false }

    /*
    36 is Return and 76 is keypad Enter. GlobalKeyMonitor passes "the talk key is held"
    as rightOptionHeld, whichever key the talk key is. The first Return finishes; every
    later Return is consumed (kept from the app) until the talk key is released.
    */
    mutating func keyDown(
        keyCode: Int64,
        rightOptionHeld: Bool,
        enabled: Bool
    ) -> Action {
        guard enabled && rightOptionHeld && (keyCode == 36 || keyCode == 76) else {
            return .passThrough
        }
        guard !triggered else { return .consume }
        triggered = true
        return .finish
    }
}


// RightOptionMode — hold-to-talk or tap-to-start/tap-to-stop, from the same key edges


/// Shared activation preference; the press/release event source remains identical.
enum RightOptionMode: String, CaseIterable {
    case hold, tap
    enum Action: Equatable { case begin, finish, ignore }
    /*
    hold: press begins a talk, release finishes it.
    tap:  each press either begins or finishes; releases are ignored.
    While the previous talk is still finishing (finalizing), every edge is ignored.
    */
    func action(pressed: Bool, capturing: Bool, finalizing: Bool) -> Action {
        guard !finalizing else { return .ignore }
        if self == .tap {
            guard pressed else { return .ignore }
            return capturing ? .finish : .begin
        }
        if pressed { return capturing ? .ignore : .begin }
        return capturing ? .finish : .ignore
    }
}


// DeferredTalkPress — one talk-key press made while the last talk is still finishing


/*
While the last talk finishes, action() still ignores every edge: starting a talk then would
reset the session and abort the paste in flight. Build 81: the press is remembered here (one
slot) instead of being dropped, which lost the words spoken after it and, in tap mode, made the
next tap start the talk the person meant to stop. Once the last talk lands, the caller asks
take() whether to start the next one.
- tap:  each press while finishing flips the slot, so taps still count in order
        (stop, start: one new talk; stop, start, stop: none).
- hold: a press fills it and its release empties it; the talk starts only if the key is
        still down when the last talk lands.
A tap older than maximumAge is dropped; so is any press when the last talk did not land
cleanly (its words wait in the recovery pop-up) or another talk is already running.
A remembered press never starts a talk while the Mac is locked, asleep or switched to another
user (build 81 review): the next talk would record the room behind the lock screen with nothing
to end it. The lock handler forgets the press, and landing() checks again when it lands.
*/
struct DeferredTalkPress: Equatable {
    static let maximumAge: TimeInterval = 5
    enum Landing: Equatable { case landed, needsAttention, busy, suspended }
    enum Outcome: Equatable { case none, begin, dropped(String) }

    private(set) var pressedAt: TimeInterval?
    private(set) var mode: RightOptionMode?
    var isArmed: Bool { pressedAt != nil }

    /*
    Seconds on a clock that keeps counting while the Mac sleeps (build 81 review).
    systemUptime stops during sleep, so a tap remembered before closing the lid still looked
    fresh on wake. CLOCK_MONOTONIC_RAW is mach_continuous_time, which counts sleep and, unlike
    Date, never jumps when the wall clock is changed.
    */
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    /// How the last talk ended, as take() needs it. Locked, asleep or switched out wins over all.
    static func landing(phase: TalkPhase, keptInApp: Bool, suspended: Bool) -> Landing {
        if suspended { return .suspended }
        switch phase {
        case .idle, .delivered: return .landed
        // Words kept on Home while talking in the Tokens window: nothing pops up or waits.
        case .failed:           return keptInApp ? .landed : .needsAttention
        case .capturing, .finalizing: return .busy
        }
    }

    /// One edge that arrived while finishing. Returns true when the slot changed.
    @discardableResult
    mutating func note(pressed: Bool, mode: RightOptionMode, at time: TimeInterval) -> Bool {
        if pressed, !(mode == .tap && isArmed) {
            pressedAt = time
            self.mode = mode
            return true
        }
        // A second tap, or the hold key's release, takes the remembered press back.
        guard isArmed, pressed || mode == .hold else { return false }
        cancel()
        return true
    }

    /// Forget the press: the talk key was used as a modifier, the Mac locked, or the slot was settled.
    mutating func cancel() {
        pressedAt = nil
        mode = nil
    }

    /// The last talk has left finishing. Always empties the slot.
    mutating func take(now: TimeInterval, landing: Landing, keyDown: Bool) -> Outcome {
        guard let pressedAt, let mode else { return .none }
        cancel()
        switch landing {
        case .suspended:      return .dropped("locked")
        case .busy:           return .dropped("busy")
        case .needsAttention: return .dropped("needs_attention")
        case .landed:         break
        }
        if mode == .hold { return keyDown ? .begin : .dropped("released") }
        return now - pressedAt <= Self.maximumAge ? .begin : .dropped("stale")
    }
}

