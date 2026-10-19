


//
import Testing
@testable import Tokens


@Suite struct BackgroundListeningConsentTests {
    @Test func everyLaunchStartsOff() {
        var running   = BackgroundListeningConsent()
        let request   = running.beginRequest()!
        let decision1 = running.complete(request, warningAccepted: true, microphoneGranted: true)
        #expect(decision1)
        let relaunched = BackgroundListeningConsent()
        #expect(!relaunched.isEnabled)
        #expect(relaunched.pendingRequest == nil)
    }

    @Test func warningAndPermissionAreBothRequired() {
        for (accepted, granted) in [(false, false), (false, true), (true, false), (true, true)] {
            var consent = BackgroundListeningConsent()
            let request = consent.beginRequest()!
            let decision2 = consent.complete(request, warningAccepted: accepted, microphoneGranted: granted) == (accepted && granted)
            #expect(decision2)
            #expect(consent.isEnabled == (accepted && granted))
        }
    }

    @Test func offInvalidatesPermissionCallback() {
        var consent = BackgroundListeningConsent()
        let stale   = consent.beginRequest()!
        consent.revoke()
        let decision3 = !consent.complete(stale, warningAccepted: true, microphoneGranted: true)
        #expect(decision3)
        #expect(!consent.isEnabled)
    }

    @Test func lockSleepAndSessionSwitchRequireFreshConsent() {
        for reason in [BackgroundListeningConsent.Suspension.screenLock, .sleep, .inactiveSession] {
            var consent   = BackgroundListeningConsent()
            let request   = consent.beginRequest()!
            let decision4 = consent.complete(request, warningAccepted: true, microphoneGranted: true)
            #expect(decision4)
            consent.suspend(reason)
            #expect(!consent.isEnabled)
            let decision5 = consent.beginRequest() == nil
            #expect(decision5)
            consent.resume(reason)
            #expect(!consent.isEnabled)
            let fresh     = consent.beginRequest()!
            let decision6 = consent.complete(fresh, warningAccepted: true, microphoneGranted: true)
            #expect(decision6)
        }
    }

    @Test func unlockCannotRevivePermissionDialogFromBeforeLock() {
        var consent = BackgroundListeningConsent()
        let stale   = consent.beginRequest()!
        consent.suspend(.screenLock)
        consent.resume(.screenLock)
        let decision7 = !consent.complete(stale, warningAccepted: true, microphoneGranted: true)
        #expect(decision7)
        let fresh     = consent.beginRequest()!
        let decision8 = !consent.complete(stale, warningAccepted: true, microphoneGranted: true)
        #expect(decision8)
        let decision9 = consent.complete(fresh, warningAccepted: true, microphoneGranted: true)
        #expect(decision9)
    }

    @Test func overlappingSuspensionsDoNotClearEachOther() {
        var consent = BackgroundListeningConsent()
        consent.suspend(.screenLock)
        consent.suspend(.sleep)
        consent.resume(.sleep)
        let decision10 = consent.beginRequest() == nil
        #expect(decision10)
        consent.resume(.screenLock)
        #expect(!consent.isEnabled)
        let decision11 = consent.beginRequest() != nil
        #expect(decision11)
    }
}

