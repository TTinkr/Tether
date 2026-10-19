


//
/*
BackgroundListeningPolicyTests — consent and stop conditions
Owns: permission and lock transitions for the pure policy.
Never: mistake a state transition for a measured microphone stop.
*/


import XCTest
@testable import TokensCore

final class BackgroundListeningPolicyTests: XCTestCase {
    func testStartsUnauthorized() {
        let policy = BackgroundListeningPolicy()

        XCTAssertFalse(policy.isListeningAuthorized)
        XCTAssertFalse(policy.isDeviceLocked)
    }

    func testEnablingRequiresAcceptedWarningAndGrantedPermission() {
        var policy = BackgroundListeningPolicy()

        policy.reduce(.enableRequested(warningAccepted: false, microphonePermissionGranted: true))
        XCTAssertFalse(policy.isListeningAuthorized)

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: false))
        XCTAssertFalse(policy.isListeningAuthorized)

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        XCTAssertTrue(policy.isListeningAuthorized)
    }

    func testDisablePermissionRevocationAndLockStopListening() {
        var policy = BackgroundListeningPolicy()

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        policy.reduce(.disableRequested)
        XCTAssertFalse(policy.isListeningAuthorized)

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        policy.reduce(.microphonePermissionChanged(isGranted: false))
        XCTAssertFalse(policy.isListeningAuthorized)

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        policy.reduce(.deviceLocked)
        XCTAssertFalse(policy.isListeningAuthorized)
    }

    func testUnlockAndRelaunchNeverResumeListening() {
        var policy = BackgroundListeningPolicy()

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        policy.reduce(.deviceLocked)
        policy.reduce(.deviceUnlocked)
        XCTAssertFalse(policy.isListeningAuthorized)

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        policy.reduce(.appRelaunched)
        XCTAssertFalse(policy.isListeningAuthorized)
    }

    func testEnableRequestWhileLockedFailsClosed() {
        var policy = BackgroundListeningPolicy()

        policy.reduce(.deviceLocked)
        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        XCTAssertTrue(policy.isDeviceLocked)
        XCTAssertFalse(policy.isListeningAuthorized)
    }

    func testRefusedEnableRequestRevokesExistingAuthorization() {
        var policy = BackgroundListeningPolicy()

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        XCTAssertTrue(policy.isListeningAuthorized)

        policy.reduce(.enableRequested(warningAccepted: false, microphonePermissionGranted: true))
        XCTAssertFalse(policy.isListeningAuthorized)
    }

//
// :)
//
//
    func testPermissionRegainedDoesNotResumeAuthorization() {
        var policy = BackgroundListeningPolicy()

        policy.reduce(.enableRequested(warningAccepted: true, microphonePermissionGranted: true))
        policy.reduce(.microphonePermissionChanged(isGranted: false))
        policy.reduce(.microphonePermissionChanged(isGranted: true))

        XCTAssertFalse(policy.isListeningAuthorized)
    }
}

