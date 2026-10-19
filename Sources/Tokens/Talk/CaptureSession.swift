


//
import CoreGraphics
import Foundation


// CaptureSession — one capture's id and phase, so stale callbacks cannot act on a new one


/// Main-thread session identity shared by permission, startup, recognition and
/// finalization callbacks. A superseded callback can never claim a new session.
///
/// AudioCapture owns one of these. The pattern: begin() hands out a fresh UUID;
/// every async callback carries that UUID and must pass advance() or end() with it.
/// A callback from an earlier capture holds an old UUID, so its calls return false/nil.
/// Phases: awaitingAccess → starting → recording → finalizing, then end() or cancel().
/// Some AudioCapture paths advance straight from awaitingAccess to recording.
struct CaptureSession: Equatable {
    enum Phase: Equatable { case awaitingAccess, starting, recording, finalizing }
    private(set) var id: UUID?
    private(set) var phase: Phase?

    /// Starts a capture. Returns nil (and changes nothing) while another is still open.
    mutating func begin() -> UUID? {
        guard id == nil else { return nil }
        let next = UUID()
        id       = next
        phase    = .awaitingAccess
        return next
    }

    /// Moves to `next` only if `generation` is still the current capture and it is
    /// exactly in `expected`. Returns false for a stale or out-of-order callback.
    mutating func advance(_ generation: UUID, from expected: Phase, to next: Phase) -> Bool {
        guard id == generation, phase == expected else { return false }
        phase = next
        return true
    }

    /// Enters finalizing once. A second call during the same finish returns nil,
    /// so one capture cannot complete twice.
    mutating func beginFinishing() -> UUID? {
        guard let id, phase != .finalizing else { return nil }
        phase = .finalizing
        return id
    }

    /// Closes the capture only if `generation` is still current.
    @discardableResult
    mutating func end(_ generation: UUID) -> Bool {
        guard id == generation else { return false }
        id    = nil
        phase = nil
        return true
    }

    /// Closes whatever capture is open, without checking its id.
    mutating func cancel() { id = nil; phase = nil }
}


// PointerTargetPolicy — only an editable text field under the pointer may receive words


/// Pointer delivery is restricted to editable text controls. A hovered button,
/// static label, password field, or TTT itself must never become a paste target.
///
/// All of these must hold: the control is enabled; it reports a text selection;
/// its role is a text field or text area; it is not a secure (password) field; and
/// it does not say it is read-only. Then it must either say it is editable, or
/// let its value or selected text be set.
/// The inputs are Accessibility (AX) attribute values read by TargetDelivery.
enum PointerTargetPolicy {

//
// :)
//
//
    static func allows(
        role: String,
        subrole: String?,
        enabled: Bool,
        selectionAvailable: Bool,
        valueSettable: Bool,
        selectedTextSettable: Bool,
        explicitlyEditable: Bool?
    ) -> Bool {
        guard enabled, selectionAvailable,
              role == "AXTextField" || role == "AXTextArea",
              subrole != "AXSecureTextField",
              explicitlyEditable != false else { return false }
        return explicitlyEditable == true || valueSettable || selectedTextSettable
    }
}


// StopTarget — the delivery target, decided once at the stop gesture and then frozen


/// Resolve the destination once at the stop gesture, including an absent target.
/// Recognition may finish later; never recapture into a newly focused app then.
///
/// `captured` and `value` are kept apart: after capture, `captured` is true even
/// when `value` is nil ("no target"), so a later capture() call cannot fill in
/// whatever app is in front by then. Only reset() clears it (TalkModel calls it
/// when a new talk begins and when a session is reset).
struct StopTarget<T> {
    private(set) var captured = false
    private(set) var value: T?
    mutating func capture(_ resolve: () -> T?) {
        guard !captured else { return }
        captured = true
        value    = resolve()
    }
    mutating func reset() { captured = false; value = nil }
}


// StopDecision — how long to wait for the last words after Stop, and why


/// Conservative amplitude-based stop readiness, not semantic voice detection.
/// Missing buffers cannot establish silence; low-energy whispers extend grace.
///
/// graceSeconds 0 means finish at once from the current words; otherwise
/// AudioCapture lets recognition drain for up to that long first. quietSeconds is
/// the measured silence at the end, and reason is logged in the stop_requested event.
struct StopDecision: Equatable {
    let graceSeconds: Double
    let quietSeconds: Double
    let reason: String
}


// StopReadiness — tracks trailing silence in the audio buffers to decide StopDecision


/*
Fed once per audio buffer. AudioCapture wraps it in LockedStopReadiness: the audio
tap writes it and the stop key edge reads it. Thresholds, all from the code below:
  quiet buffer     rms below -55 dBFS
  continuity       a gap over 0.08 s between buffers, or time going back, breaks the quiet run
  fresh audio      the last buffer must be at most 0.15 s old at Stop, or nothing is assumed
  finish at once   at least 0.30 s of trailing quiet AND every recognized word is final
  otherwise        wait 0.45 s for recognition to drain
*/
struct StopReadiness {

//
// :)
//
//
    private(set) var lastBufferAt: Double?
    private var quietSince: Double?

    /// `time` is the buffer's end and `duration` its length, both in seconds.
    mutating func observe(rmsDB: Double, at time: Double, duration: Double) {
        guard rmsDB.isFinite, time.isFinite, duration > 0, duration.isFinite else { return }
        let start = time - duration
        if let last = lastBufferAt, start - last > 0.08 || time < last { quietSince = nil }
        lastBufferAt = time
        if rmsDB < -55 {
            if quietSince == nil { quietSince = start }
        } else { quietSince = nil }
    }

    func decision(at time: Double, transcriptFinalized: Bool) -> StopDecision {
        // No recent buffer: silence cannot be proven, so wait the full grace.
        guard let last = lastBufferAt, time >= last, time - last <= 0.15 else {
            return StopDecision(graceSeconds: 0.45, quietSeconds: 0, reason: "unconfirmed_audio")
        }
        let quiet = max(0, last - (quietSince ?? last))
        if quiet >= 0.30 && transcriptFinalized {
            return StopDecision(graceSeconds: 0, quietSeconds: quiet, reason: "quiet_finalized")
        }
        return StopDecision(graceSeconds: 0.45, quietSeconds: quiet,
                               reason: quiet < 0.30 ? "recent_signal" : "pending_recognition")
    }
}

