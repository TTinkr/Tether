


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — FinishGate


extension TalkModel {

    /// Everything delivery needs, held by the stop gate until it opens.
    struct PendingDelivery {
        let payload: String
        let segment: CompletedSegment
        let sendReturn: Bool
    }

    // Stop gate — holding the finished words until the send delay ends

    /// Final delivery uses only the completed live reflection cache and never waits.
    /// Accepts final words only for the current talk, before delivery, and while its gate
    /// is still armed (or no gate was armed for it).
    func complete(
        session: UUID,
        payload rawPayload: String,
        segment: CompletedSegment,
        sendReturn: Bool,
        latencyStartUptime: TimeInterval? = nil
    ) {
        guard sessionID == session, !completedSessionIDs.contains(session),
              !finishLaunching, finishGate.session != session || finishGate.isArmed else { return }
        checkpointTranscript(rawPayload, session: session, state: .finalTextReady)
        // A bounded final refinement may replace the live cache; the gate never waits for it.
        guard finishGate.session == session else {
            // No countdown was armed for this session: deliver as before.
            deliver(session: session, payload: rawPayload, segment: segment, sendReturn: sendReturn,
                    latencyStartUptime: latencyStartUptime, tinkeringSection: nil)
            return
        }
        /*
        Recognized text is held verbatim until the stop gate opens (the send delay,
        at most 5 s). A recognizer that finishes after the gate is delivered on arrival.
        */
        let ready = PendingDelivery(payload: rawPayload, segment: segment, sendReturn: sendReturn)
        let elapsed = ProcessInfo.processInfo.systemUptime - (stopRequestedUptime ?? ProcessInfo.processInfo.systemUptime)
        // With time left before 4.3 s after Stop, ask the live notes for a final pass due then.
        if !publicTokens && thinkingExperience && !isSyntheticRun && elapsed < 4.3 {
            pauseAsides.prepareFinal(transcript: rawPayload, deadline: 4.3 - elapsed)
        }
        logStopTiming(stage: "final_text_held_for_gate", session: session)
        if let late = finishGate.offer(ready, session: session, now: ProcessInfo.processInfo.systemUptime) {
            launchGatedDelivery(late, session: session)
        }
    }

    /// Public Tokens has no fixed countdown and always finishes the captured words.
    /// No destination text is written while recognition drains. Legacy products
    /// retain their countdown. The gate still releases exactly once, never on a timer
    /// before a capture payload is offered. The Stop checkpoint protects recovery.
    func beginFinishCountdown(session: UUID, explicitPayload: String? = nil, sendReturn: Bool? = nil) {
        let streamingSnapshot = audio.stopStreamingSnapshot()
        let snapshot = streamingSnapshot.segment
        finishPayloadOverride = explicitPayload
        finishFallback = PendingDelivery(payload: explicitPayload ?? snapshot.transcript, segment: snapshot,
            sendReturn: TokensPrompt.requestsReturn(product: selectedProduct, explicit: sendReturn,
                                                    autoSendAfterPasting: autoSendAfterPasting))
        checkpointTranscript(explicitPayload ?? snapshot.transcript, session: session, state: .stopped)
        finishGate.arm(session: session, now: stopRequestedUptime ?? ProcessInfo.processInfo.systemUptime, delay: selectedProduct == "Tokens" ? 0 : sendDelaySeconds)
        finishLaunching         = false
        finishCountdownSeconds  = selectedProduct == "Tokens" ? 0 : Int(sendDelaySeconds.rounded(.up))
        finishCountdownProgress = 0
        // The destination is already captured; the bubble never takes key focus.
        showTalkSurface()
        finishGateTimer?.invalidate()
        /*
        .common mode keeps ticking while menus track; the first tick runs on the next
        main-loop turn.
        */
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickFinishCountdown(session: session)
        }
        RunLoop.main.add(timer, forMode: .common)
        finishGateTimer = timer
        DispatchQueue.main.async { [weak self] in self?.tickFinishCountdown(session: session) }
        // Reveal starts only after complete() freezes the final payload. Posting even
        // an immutable marker here would race finalization and bypass its recovery save.
    }

//
// :)
//
//
    /// What "Take off now" would deliver: the first non-blank of the held final words, the
    /// current recognizer snapshot, or the Stop snapshot. nil after launch or with no gate.
    var availableEarlyDelivery: PendingDelivery? {
        guard phase == .finalizing, !finishLaunching, finishGate.isArmed else { return nil }
        if audio.streamingPipeline?.requiresExplicitFinalization == true {
            // Legacy "Take off now" may skip presentation delay, never an
            // offline engine's final decode or its recoverable failure boundary.
            return finishGate.heldPayload.flatMap {
                $0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
        }
        let snapshot = audio.deliverySnapshot()
        let current = PendingDelivery(payload: finishPayloadOverride ?? snapshot.transcript,
            segment: snapshot, sendReturn: finishFallback?.sendReturn ?? false)
        return [finishGate.heldPayload, current, finishFallback].compactMap { $0 }
            .first { !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // Gate release — Take off now, the countdown tick, and launching delivery

    /// Whether "Take off now" can act right now (the bubble and Live notes show it).
    var canTakeOffNow: Bool { selectedProduct != "Tokens" && availableEarlyDelivery != nil }

    /// Skips the rest of the send delay and delivers now. Shares the gate's release-once latch.
    func takeOffNow() {
        guard selectedProduct != "Tokens",
              let session = sessionID, let available = availableEarlyDelivery,
              let ready = finishGate.releaseNow(session: session, payload: available) else { return }
        // Close every callback/timer path before cancelling its work.
        finishLaunching = true
        finishGateTimer?.invalidate()
        finishGateTimer = nil
        checkpointTranscript(ready.payload, session: session, state: .finalTextReady)
        _ = audio.stop()
        localFormatter.reset()
        tinkering.cancel()
        /*
        Synchronous rendering consumes already-completed title/commentary first.
        The main actor cannot resume pending refinement before this returns.
        */
        logStopTiming(stage: "take_off_now", session: session)
        launchGatedDelivery(ready, session: session)
        thinkingFormatter.reset()
    }

    /// Every 50 ms: update the countdown; at the deadline stop the timer and release
    /// held final words. If recognition is still draining, keep the gate open for
    /// complete(). AudioCapture already bounds its drain; a zero cosmetic delay must
    /// not consume the delivery latch using an earlier Stop snapshot.
    func tickFinishCountdown(session: UUID) {
        guard sessionID == session, phase == .finalizing, finishGate.session == session else {
            // Stale timer for a session that was discarded, failed, or replaced.
            if finishGate.session == session { cancelFinishCountdown() }
            return
        }
        let now                 = ProcessInfo.processInfo.systemUptime
        finishCountdownSeconds  = finishGate.secondsRemaining(now: now)
        finishCountdownProgress = finishGate.progress(now: now)
        guard finishGate.deadlineReached(now: now) else { return }
        finishGateTimer?.invalidate()
        finishGateTimer = nil
        logStopTiming(stage: "gate_open", session: session)
        if let ready = finishGate.fire(session: session, now: now) {
            launchGatedDelivery(ready, session: session)
        }
        // No final payload yet: complete() will offer the drained result and launch once.
    }

    /// Delivers what the gate released, now, inside this callback.
    func launchGatedDelivery(_ ready: PendingDelivery, session: UUID) {
        guard sessionID == session, phase == .finalizing,
              !completedSessionIDs.contains(session) else { return }
        if stopStream.gate.hold(ready, session: session) {
            finishLaunching = true
            return
        }
        dismissTinkeringAfterSend()
        finishLaunching         = true
        finishCountdownSeconds  = 0
        finishCountdownProgress = 1
        /*
        Start delivery in this deadline callback; never wait for a cosmetic frame.
        Dispatch is not a claim that the destination finished pasting.
        */
        let dispatch = { [weak self] in
            guard let self, self.sessionID == session, self.phase == .finalizing else { return }
            /*
            As before the countdown existed, the bubble is gone before text is
            inserted; recovery paths re-show it themselves.
            */
            self.hideSurface()
            self.deliver(session: session, payload: ready.payload, segment: ready.segment,
                         sendReturn: ready.sendReturn, latencyStartUptime: nil, tinkeringSection: nil)
            self.finishCountdownSeconds = nil
        }
        logStopTiming(stage: "gate_dispatch", session: session)
        dispatch()
    }

//
// :)
//
//
    /// Stops the countdown and forgets the gate and its held words.
    func cancelFinishCountdown() {
        finishGateTimer?.invalidate()
        finishGateTimer = nil
        finishGate.cancel()
        finishFallback          = nil
        finishPayloadOverride   = nil
        finishCountdownSeconds  = nil
        finishCountdownProgress = 0
        finishLaunching         = false
    }

}

