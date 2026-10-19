import Testing
@testable import Tokens

@Suite struct PersistentBubbleLifecycleTests {
    @Test func onboardingSleepAndNonpublicLaunchesSuppressEverything() {
        for input in [
            (false, true, true, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, true),
        ] {
            let presentation = PersistentBubblePolicy.presentation(
                publicTokens: input.0, normalLaunch: input.1, setupComplete: input.2,
                suspended: input.3, phase: .idle, tokensHomeFrontmost: false)
            #expect(presentation == .suppressed)
            let feedbackEnabled = PersistentBubblePolicy.persistentFeedbackEnabled(
                publicTokens: input.0, normalLaunch: input.1, setupComplete: input.2)
            #expect(feedbackEnabled == (input.0 && input.1 && input.2))
        }
    }

    @Test func wakingOneReasonDoesNotClearAnotherSuspension() {
        var state = PersistentBubbleSuspensionState()
        #expect(!state.isSuspended)
        state.set(.systemSleep, active: true)
        state.set(.inactiveSession, active: true)
        #expect(state.isSuspended)
        state.set(.systemSleep, active: false)
        #expect(state.isSuspended)
        state.set(.screensSleep, active: true)
        state.set(.inactiveSession, active: false)
        #expect(state.isSuspended)
        state.set(.screensSleep, active: false)
        #expect(!state.isSuspended)
    }

    @Test func visibleFailureRestoresOnlyAfterEverySuspensionReasonClears() {
        var suspensions = PersistentBubbleSuspensionState()
        var recovery = PersistentBubbleRecoveryRestoreState()

        suspensions.set(.systemSleep, active: true)
        let enteredSleep = recovery.transition(suspended: suspensions.isSuspended, failed: true,
                                               panelPresentationRequested: true)
        #expect(!enteredSleep)
        suspensions.set(.inactiveSession, active: true)
        let overlapped = recovery.transition(suspended: suspensions.isSuspended, failed: true,
                                             panelPresentationRequested: false)
        #expect(!overlapped)
        suspensions.set(.systemSleep, active: false)
        let partialWake = recovery.transition(suspended: suspensions.isSuspended, failed: true,
                                              panelPresentationRequested: false)
        #expect(!partialWake)
        suspensions.set(.inactiveSession, active: false)
        let finalWake = recovery.transition(suspended: suspensions.isSuspended, failed: true,
                                            panelPresentationRequested: false)
        #expect(finalWake)
        let repeatedWake = recovery.transition(suspended: false, failed: true,
                                               panelPresentationRequested: true)
        #expect(!repeatedWake)
    }

    @Test func hiddenOrResolvedFailureDoesNotReappearAfterWake() {
        var hidden = PersistentBubbleRecoveryRestoreState()
        let hiddenSleep = hidden.transition(suspended: true, failed: true,
                                            panelPresentationRequested: false)
        #expect(!hiddenSleep)
        let hiddenWake = hidden.transition(suspended: false, failed: true,
                                           panelPresentationRequested: false)
        #expect(!hiddenWake)

        var resolved = PersistentBubbleRecoveryRestoreState()
        let resolvedSleep = resolved.transition(suspended: true, failed: true,
                                                panelPresentationRequested: true)
        #expect(!resolvedSleep)
        let phaseChanged = resolved.transition(suspended: true, failed: false,
                                               panelPresentationRequested: false)
        #expect(!phaseChanged)
        let resolvedWake = resolved.transition(suspended: false, failed: true,
                                               panelPresentationRequested: false)
        #expect(!resolvedWake)
    }

    @Test func idleAndDeliveredRestoreStandby() {
        for phase in [TalkPhase.idle, .delivered] {
            #expect(PersistentBubblePolicy.presentation(
                publicTokens: true, normalLaunch: true, setupComplete: true,
                suspended: false, phase: phase, tokensHomeFrontmost: false) == .standby)
        }
        #expect(PersistentBubblePolicy.persistentFeedbackEnabled(
            publicTokens: true, normalLaunch: true, setupComplete: true))
    }

    @Test func externalTalkStaysVisibleButHomeOwnedTalkStaysHeldBack() {
        for phase in [TalkPhase.capturing, .finalizing] {
            #expect(PersistentBubblePolicy.presentation(
                publicTokens: true, normalLaunch: true, setupComplete: true,
                suspended: false, phase: phase, tokensHomeFrontmost: false) == .activeTalk)
            #expect(PersistentBubblePolicy.presentation(
                publicTokens: true, normalLaunch: true, setupComplete: true,
                suspended: false, phase: phase, tokensHomeFrontmost: true) == .suppressed)
        }
    }

    @Test func failureLeavesExistingRecoveryChoiceInControl() {
        #expect(PersistentBubblePolicy.presentation(
            publicTokens: true, normalLaunch: true, setupComplete: true,
            suspended: false, phase: .failed,
            tokensHomeFrontmost: false) == .modelControlledRecovery)
        #expect(PersistentBubblePolicy.convertsFailedDismissalToStandby(
            persistentPreviewEnabled: true, phase: .failed))
        #expect(!PersistentBubblePolicy.convertsFailedDismissalToStandby(
            persistentPreviewEnabled: false, phase: .failed))
        #expect(!PersistentBubblePolicy.convertsFailedDismissalToStandby(
            persistentPreviewEnabled: true, phase: .idle))
    }

    @Test func failedStandbyOverrideWaitsThroughSuspensionThenRestoresStandby() {
        var recovery = PersistentBubbleRecoveryRestoreState()
        let captureEnteredSleep = recovery.transition(
            suspended: true, failed: false, panelPresentationRequested: true)
        #expect(!captureEnteredSleep)
        let failedWhileSleeping = recovery.transition(
            suspended: true, failed: true, panelPresentationRequested: false)
        #expect(!failedWhileSleeping)

        #expect(PersistentBubblePolicy.persistentFeedbackEnabled(
            publicTokens: true, normalLaunch: true, setupComplete: true))
        #expect(PersistentBubblePolicy.presentation(
            publicTokens: true, normalLaunch: true, setupComplete: true,
            suspended: true, phase: .failed, tokensHomeFrontmost: false,
            standbyOverride: true) == .suppressed)
        #expect(PersistentBubblePolicy.presentation(
            publicTokens: true, normalLaunch: true, setupComplete: true,
            suspended: false, phase: .failed, tokensHomeFrontmost: false,
            standbyOverride: true) == .standby)
        let wakeRestore = recovery.transition(
            suspended: false, failed: true, panelPresentationRequested: false)
        #expect(!wakeRestore)
    }

    @Test func autoDismissedVisibleRecoveryWakesAsStandbyInsteadOfExpiredError() {
        var recovery = PersistentBubbleRecoveryRestoreState()
        let enteredSleep = recovery.transition(
            suspended: true, failed: true, panelPresentationRequested: true)
        #expect(!enteredSleep)
        let timedOutWhileSleeping = recovery.transition(
            suspended: true, failed: true, panelPresentationRequested: false)
        #expect(!timedOutWhileSleeping)
        let wakeRestore = recovery.transition(
            suspended: false, failed: true, panelPresentationRequested: false)
        #expect(wakeRestore)
        let wakePresentation = PersistentBubblePolicy.presentation(
            publicTokens: true, normalLaunch: true, setupComplete: true,
            suspended: false, phase: .failed, tokensHomeFrontmost: false,
            standbyOverride: true)
        #expect(wakePresentation == .standby)
    }
}
