


//
/*
CaptureSession — reject stale callbacks across recordings
Owns: capture identity and allowed lifecycle transitions.
Never: start a microphone, save audio, or let an old callback change a new recording.
*/


import Foundation

/// Owns one capture generation so stale asynchronous callbacks cannot change a newer session.
public struct CaptureSession: Equatable {
    /// The recorder adapter advances these stages; the core never performs their side effects.
    public enum Phase: Equatable {
        case awaitingAccess
        case starting
        case recording
        case finalizing
    }

    /// A new UUID distinguishes fresh recording work from late callbacks of an older one.
    public private(set) var id: UUID?
    public private(set) var phase: Phase?

    public init() {}

    /// Starts one generation. A current generation must end or cancel before another starts.
    public mutating func begin() -> UUID? {
        guard id == nil else { return nil }
        let next = UUID()
        id       = next
        phase    = .awaitingAccess
        return next
    }

    /// Moves only the named current generation through its expected state.
    public mutating func advance(_ generation: UUID, from expected: Phase, to next: Phase) -> Bool {
        // Check identity AND phase: a same-generation callback can still arrive out of order.
        guard id == generation, phase == expected else { return false }
        phase = next
        return true
    }


    // Finalize or invalidate this recording generation


    /// Marks the current generation as finalizing and returns its identity once.
    public mutating func beginFinishing() -> UUID? {
        guard let id, phase != .finalizing else { return nil }
        phase = .finalizing
        return id
    }

    /// Ends only the named current generation.
    @discardableResult
    public mutating func end(_ generation: UUID) -> Bool {
        guard id == generation else { return false }
        id    = nil
        phase = nil
        return true
    }

    /// Invalidates the active generation; later callbacks for it are stale.
    public mutating func cancel() {
        id    = nil
        phase = nil
    }


}

