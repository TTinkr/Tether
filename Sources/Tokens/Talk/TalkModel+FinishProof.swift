


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — FinishProof


extension TalkModel {

    // Take-off-now proof — scripted checks of the stop gate (synthetic run)

    /// No microphone, target insertion, history or recovery writes in this explicit regression route.
    /// Launch-argument proof (synthetic run only); stops at the first failed precondition.
    func runTakeOffNowProof() {
        precondition(isSyntheticRun)
        let testSession     = UUID()
        sessionID           = testSession; phase = .finalizing; target = nil
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        finishGate.arm(session: testSession, now: stopRequestedUptime!)
        let raw        = "alpha beta 7.25 gamma"
        let segment    = CompletedSegment(id: UUID(), features: .silence, transcript: raw)
        finishFallback = PendingDelivery(payload: "  ", segment: segment, sendReturn: false)
        precondition(!canTakeOffNow)
        takeOffNow()
        precondition(finishGate.isArmed && !completedSessionIDs.contains(testSession))
        finishFallback = PendingDelivery(payload: raw, segment: segment, sendReturn: false)
        precondition(canTakeOffNow)
        let before = ProcessInfo.processInfo.systemUptime
        takeOffNow()
        let elapsed = ProcessInfo.processInfo.systemUptime - before
        precondition(completedSessionIDs.contains(testSession) && elapsed < 0.3)
        precondition(retainedFailurePayload.contains("7.25") && segment.transcript == raw)
        let retained = retainedFailurePayload
        takeOffNow()
        complete(session: testSession, payload: "late replacement", segment: segment, sendReturn: true)
        tickFinishCountdown(session: testSession)
        precondition(retainedFailurePayload == retained && completedSessionIDs.filter { $0 == testSession }.count == 1)
        // Exercise the normal deadline callback with already-finalized words.
        let deadlineSession = UUID()
        sessionID           = deadlineSession; phase = .finalizing; target = nil
        finishLaunching     = false
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime - 5.01
        finishGate.arm(session: deadlineSession, now: stopRequestedUptime!)
        finishFallback    = PendingDelivery(payload: raw, segment: segment, sendReturn: false)
        _ = finishGate.offer(finishFallback!, session: deadlineSession, now: stopRequestedUptime! + 1)
        let deadlineStart = ProcessInfo.processInfo.systemUptime
        tickFinishCountdown(session: deadlineSession)
        let deadlineElapsed = ProcessInfo.processInfo.systemUptime - deadlineStart
        precondition(completedSessionIDs.contains(deadlineSession) && deadlineElapsed < 0.3)
        let deadlinePayload = retainedFailurePayload
        tickFinishCountdown(session: deadlineSession)
        precondition(retainedFailurePayload == deadlinePayload)
        print("PASS normal deadline synchronous dispatch; ms=\(deadlineElapsed * 1000); no external target")
        let pausedSession = UUID()
        sessionID         = pausedSession; phase = .finalizing; finishLaunching = false
        finishGate.arm(session: pausedSession, now: ProcessInfo.processInfo.systemUptime)
        finishFallback = PendingDelivery(payload: raw, segment: segment, sendReturn: true)
        ambientEnabled = true
        toggleAmbientListening()
        precondition(!ambientEnabled && !finishGate.isArmed && sessionID == nil && !audio.hardwareRunning)
        precondition(retainedFailurePayload == raw)
        complete(session: pausedSession, payload: "late paused text", segment: segment, sendReturn: true)
        tickFinishCountdown(session: pausedSession)
        precondition(retainedFailurePayload == raw && !completedSessionIDs.contains(pausedSession))
        print("PASS pause during countdown: microphone stopped, queued delivery cancelled, raw held, late callbacks ignored")
        print("PASS takeoff-now actual model: empty no-op, immediate release, duplicate click, late complete/timer ignored, raw preserved, no external target; ms=\(elapsed * 1000)")
    }

}

