


//
import Foundation


struct BackgroundListeningConsent {
    enum Suspension: Hashable { case sleep, screenLock, inactiveSession }

    private(set) var isEnabled = false
    private(set) var pendingRequest: UUID?
    private(set) var suspensions: Set<Suspension> = []

    /// A warning or permission dialog may outlive Off, Lock, or another request.
    /// Its callback must carry this exact identity before it can enable anything.
    mutating func beginRequest() -> UUID? {
        revoke()
        guard suspensions.isEmpty else { return nil }
        let id         = UUID()
        pendingRequest = id
        return id
    }

    @discardableResult
    mutating func complete(_ id: UUID, warningAccepted: Bool, microphoneGranted: Bool) -> Bool {
        guard pendingRequest == id else { return false }
        pendingRequest = nil
        isEnabled      = warningAccepted && microphoneGranted && suspensions.isEmpty
        return isEnabled
    }

    mutating func revoke() {
        isEnabled      = false
        pendingRequest = nil
    }

    mutating func suspend(_ reason: Suspension) {
        suspensions.insert(reason)
        revoke()
    }

    /// Wake and unlock remove a restriction; they never recreate permission to listen.
    mutating func resume(_ reason: Suspension) { suspensions.remove(reason) }
}

