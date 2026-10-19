


//
/*
BackgroundListeningPolicy — explicit permission to listen
Owns: default-off authorization, warning consent, permission loss and lock handling.
Never: treat authorization as proof of capture, or implicitly permit saved memory.
*/


/// Pure policy for the optional background-listening feature.
///
/// Privacy invariants:
/// - Listening starts off and can start only after an accepted warning and granted permission.
/// - Locking, disabling, or revoking permission immediately withdraws listening authorization.
///   The speech adapter must observe this state and stop real capture.
/// - Unlocking and relaunching never resume listening.
public struct BackgroundListeningPolicy: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Attempts to start listening. Both inputs must be true for this to take effect.
        case enableRequested(warningAccepted: Bool, microphonePermissionGranted: Bool)
        case disableRequested
        case microphonePermissionChanged(isGranted: Bool)
        case deviceLocked
        case deviceUnlocked
        case appRelaunched
    }

    /// Whether a caller may begin listening. This does not report actual microphone state.
    public private(set) var isListeningAuthorized: Bool
    public private(set) var isDeviceLocked: Bool

    public init() {
        isListeningAuthorized = false
        isDeviceLocked        = false
    }


    // Apply consent, permission and device-lock events


    /// Applies one externally observed event without performing any system work.
    public mutating func reduce(_ event: Event) {
        switch event {
        case let .enableRequested(warningAccepted, microphonePermissionGranted):
            guard !isDeviceLocked, warningAccepted, microphonePermissionGranted else {
                isListeningAuthorized = false
                return
            }
            isListeningAuthorized = true

        case .disableRequested, .appRelaunched:
            isListeningAuthorized = false

        case .deviceLocked:
            isListeningAuthorized = false
            isDeviceLocked        = true

        case let .microphonePermissionChanged(isGranted):
            if !isGranted {
                isListeningAuthorized = false
            }

        case .deviceUnlocked:
            // An explicit, newly authorized enable request is required after a lock.
            isDeviceLocked = false
        }
    }


}

