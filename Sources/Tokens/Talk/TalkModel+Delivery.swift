


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// TalkModel — Delivery


extension TalkModel {
    /// Home's calm status after a talk with the Tokens window in front (not an error).
    static let keptInAppMessage = "Saved to Recent below"

    /*
    The status kept after a paste that could not be confirmed. Return is never pressed after
    one, even when Auto-send or a Return the person pressed after Stop asked for a send. Before,
    Tokens swallowed that Return and went quiet, so the words sat unsent while the person thought
    they had gone. Now the status starts with "Not sent"; it shows on Home and in the recovery
    pop-up (build 81).
    */
    static func unconfirmedPasteMessage(sendWithheld: Bool) -> String {
        sendWithheld ? "Not sent · paste not confirmed · Copy latest" : "Paste sent · not confirmed · Copy latest"
    }


    // Delivery — put the words into the target app, or hold them

    /// Final delivery for one talk. Renders the final text, then:
    ///   no words      → delivered, reset
    ///   no target     → hold the words ("Paste unavailable") and show them
    ///   verified      → press Return if asked or reserved; if an asked-for Return fails,
    ///                   hold the words; otherwise count it, resolve recovery, celebrate
    ///   unconfirmed   → keep recovery and clipboard payload, never press Return or replay;
    ///                   stay quiet unless a readable text target showed no insertion; the
    ///                   kept status says "Not sent" when a send was asked for
    ///   failed        → hold the words; a partial insert is never replayed
    /// New launch history gets faithful speech; stored typed-note history is preserved.
    func deliver(
        session: UUID,
        payload receivedPayload: String,
        segment: CompletedSegment,
        sendReturn: Bool,
        latencyStartUptime: TimeInterval?,
        tinkeringSection: String?
    ) {
        // Claim delivery before queuing the task. A queued stop-prefix callback
        // must see this latch and cannot race the full payload's first write.
        guard sessionID == session, phase == .finalizing,
              completedSessionIDs.insert(session).inserted else { return }
        Task { @MainActor [weak self] in
            await self?.deliverAsynchronously(session: session, payload: receivedPayload, segment: segment,
                sendReturn: sendReturn, latencyStartUptime: latencyStartUptime, tinkeringSection: tinkeringSection)
        }
    }

    @MainActor private func deliverAsynchronously(
        session: UUID,
        payload receivedPayload: String,
        segment: CompletedSegment,
        sendReturn: Bool,
        latencyStartUptime: TimeInterval?,
        tinkeringSection: String?
    ) async {
        // Recovery retries must inherit the same no-Return decision as normal delivery.
        let sendReturn = sendReturn && !segment.requiresReview
        // Even a same-session failure between enqueue and execution releases its
        // reservation. A replaced session keeps ownership of its own Return gate.
        defer { if sessionID == session { input.finishReturnReservation() } }
        // The synchronous entry owns the once-only latch; recheck lifecycle after queuing.
        guard sessionID == session, phase == .finalizing else { return }
        // If the recognizer retracts every word after a marker was posted, preserve
        // the saved Stop words for recovery. A marker alone is never empty success.
        let retractedAfterPrefix = stopStream.prefix != nil
            && receivedPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rawPayload = retractedAfterPrefix ? stopStream.stoppedText : receivedPayload
        let canonical = BrandVocabulary.apply(
            to: rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        /*
        The words in their final layout: staged, the Tokens thinking layout, or the
        plain/Markdown renderer.
        */
        let faithful = stagedCommitted != nil
            ? StagedPrompt.render(body: CharacterTalk.render(canonical).markdownText,
                                     duration: frozenRecordingDurationSeconds ?? 0, frozenHeader: stagedHeader)
            : thinkingMetadataEnabled
            ? thinkingPayload(raw: rawPayload, segment: segment,
                              durationSeconds: frozenRecordingDurationSeconds ?? 0,
                              titleOverride: stopStream.frozenTitle)
            : renderTranscript(canonical,
                               durationSeconds: frozenRecordingDurationSeconds ?? 0,
                               includePlainMetadata: true)
        /*
        Public launch delivers speech and measured context only. Keep older
        AuthoredPrompt.typed history readable; do not consume or erase old notes.
        */
        let publicTalk = selectedProduct == "Tokens"
        let useDecorations = !publicTalk && shouldDecorateDelivery(session: session)
        _ = pauseAsides.stop()
        let spokenText = CharacterTalk.render(canonical).deliveryText
        let authoredParts = publicTalk ? TokensOutputOptions.parts(faithful, metadata: metadataEnabled) : nil
        let authored = publicTalk
            ? AuthoredPrompt(transcript: authoredParts!.text, spokenText: spokenText)
            : AuthoredPrompt(transcript: faithful, spokenText: spokenText)
        let composedPayload = publicTalk ? authored.text
            : TinkeringSection.appending(tinkeringSection, to: authored.text)
        // The early marker is immutable; final words, title and measured metadata stay intact.
        let payload = composedPayload
        let revealPlan = authoredParts?.revealPlan(spokenWordCount: authored.spokenWordCount)
        let textReadyUptime = ProcessInfo.processInfo.systemUptime
        logStopTiming(stage: "text_ready", session: session)
        lastTranscriptForCopy  = payload
        displayText            = payload
        displayStableWordCount = authored.spokenWordCount
        // Persist the immutable transcript before any asynchronous delivery. An old
        // reveal must not repopulate History after the user clears it or starts anew.
        // The captured stop target's app, kept with the entry on this Mac only (Stats by app, History).
        recordPromptHistory(authored, session: session,
                            targetApp: target.flatMap { PromptTargetApp(bundleID: $0.application.bundleIdentifier,
                                                                        name: $0.application.localizedName) })

        if retractedAfterPrefix {
            checkpointTranscript(rawPayload, session: session, state: .deliveryUncertain)
            retainForRecovery(payload, authored: authored,
                              message: "Final words unavailable · Copy captured words",
                              shouldRecordHistory: false)
            return
        }

        guard !payload.isEmpty else {
            Diagnostics.event("delivery_empty session=\(session.uuidString)")
            logStopTiming(stage: "delivery_empty", session: session)
            phase = .delivered
            hideSurface()
            resetSession()
            return
        }
        guard let target else {
            checkpointTranscript(rawPayload, session: session, state: .held)
            logStopTiming(stage: "delivery_held", session: session)
            /*
            Talking with the Tokens window in front has no other app to paste into. The words
            are already in History and on Home with Copy, so no bubble or held-words pop-up
            appears (it must not pop up while the person is in the app).
            */
            let inApp = publicTokens && tokensWindowIsFrontmost
            if inApp { Diagnostics.event("delivery_kept_in_app session=\(session.uuidString)") }
            retainForRecovery(
                payload,
                authored: authored,
                message: inApp ? TalkModel.keptInAppMessage : "Paste unavailable · Copy latest",
                sendReturn: sendReturn,
                shouldRecordHistory: false,
                showOverlay: !inApp,
                holdWords: true
            )
            if inApp { hideSurface() }
            return
        }

        logStopTiming(stage: "paste_initiated", session: session)
        let delivery: DeliveryOutcome
        if let committed = stagedCommitted {
            if !stagedFailed,
               let tail = StagedPrompt.remainder(final: payload, committed: committed),
               let next = TargetDelivery.appendVerified(tail, to: target) {
                self.target = next
                delivery    = .verified
            } else {
                /*
                Some text may already be in the editor. Never replay it or
                issue Return after a revision, caret move, or failed readback.
                */
                checkpointTranscript(rawPayload, session: session, state: .deliveryUncertain)
                retainForRecovery(payload, authored: authored, message: "Partial text inserted · Copy latest", shouldRecordHistory: false)
                return
            }
        } else if let streamed = await deliverStreamedRemainder(payload, into: target, latencyStartUptime: latencyStartUptime, revealPlan: revealPlan, session: session) {
            delivery = streamed
        } else {
            // Three-step paste only in Tokens, and only when threeStepPasteEnabled.
            delivery = await TargetDelivery.insert(payload, into: target, latencyStartUptime: latencyStartUptime,
                                                threeSteps: selectedProduct == "Tokens" && Self.threeStepPasteEnabled,
                                                revealPlan: revealPlan, textReadyUptime: textReadyUptime,
                                                isCurrent: { self.sessionID == session && self.phase == .finalizing })
        }
        guard sessionID == session, phase == .finalizing else { return }
        if case .failed(let reason) = delivery, reason.hasPrefix("partial_") {
            // Some pieces are already in the editor. Never replay them or press Return.
            Diagnostics.event("delivery_failed session=\(session.uuidString) reason=\(reason)")
            logStopTiming(stage: "delivery_failed", session: session)
            checkpointTranscript(rawPayload, session: session, state: .deliveryUncertain)
            retainForRecovery(payload, authored: authored, message: "Partial text inserted · Copy latest", shouldRecordHistory: false)
            return
        }
        switch delivery {
        case .verified:
            /*
            The editor read the text back. Return goes only if Auto-send or an explicit
            override requested it, or if the user pressed Return after Stop.
            Unconfirmed paste and Copy recovery never enter this branch.
            */
            let returnRequested = TokensAutoSendDelivery.returnRequested(
                autoSend: sendReturn, reservedReturn: input.hasReservedReturn, requiresReview: segment.requiresReview)
            if segment.requiresReview, sendReturn || input.hasReservedReturn {
                // Pasted in full; Return is left to the person (no recovery window for this).
                Diagnostics.event("auto_send_suppressed session=\(session.uuidString) reason=requires_review")
            }
            let returnSent = TokensAutoSendDelivery.submitIfVerified(delivery, requested: returnRequested,
                                                                      reservedReturn: false) {
                TargetDelivery.sendReturn(to: target)
            }
            print("TTT_EVENT delivery_verified characters=\(payload.utf16.count) return=\(returnSent)")
            Diagnostics.event("delivery_verified session=\(session.uuidString) return=\(returnSent)")
            logStopTiming(stage: "delivery_verified", session: session)
            if returnRequested && !returnSent {
                checkpointTranscript(rawPayload, session: session, state: .deliveryUncertain)
                retainForRecovery(payload, authored: authored, message: "Text inserted · Send unavailable · Copy latest", shouldRecordHistory: false)
            } else {
                recordVerifiedAllowance(session: session, wasClean: !useDecorations)
                /*
                History was saved before delivery suspended. Do not reinsert it after
                a concurrent Clear History action; a failed save leaves the journal intact.
                */
                if historyStoreWritable { resolveTranscriptRecovery(session) }
                celebrateDelivery(session: session)
            }
        case .delivered, .notObserved:
            // Command-V was posted, but the editor's acceptance could not be verified.
            if selectedProduct == "Tokens" { dailyDeliveryNotice = "Delivery unconfirmed · clean use not counted" }
            checkpointTranscript(rawPayload, session: session, state: .deliveryUncertain)
            /*
            A posted paste is not an accepted paste. Sending Return now could
            submit old or partial text, including in an opaque editor. Leave
            the journal and exact Copy latest payload available; never replay.
            */
            // Read before the deferred finishReturnReservation clears the swallowed Return.
            let reservedReturn = input.hasReservedReturn
            let sendWithheld = TokensAutoSendDelivery.returnRequested(
                autoSend: sendReturn, reservedReturn: reservedReturn, requiresReview: segment.requiresReview)
            if sendWithheld {
                Diagnostics.event("auto_send_suppressed session=\(session.uuidString) reason=unconfirmed_paste"
                    + " auto_send=\(sendReturn) reserved_return=\(reservedReturn)")
            }
            print("TTT_EVENT delivery_unverified characters=\(payload.utf16.count) return=false")
            Diagnostics.event("delivery_unverified session=\(session.uuidString)")
            logStopTiming(stage: "delivery_unverified", session: session)
            retainForRecovery(
                payload,
                authored: authored,
                message: Self.unconfirmedPasteMessage(sendWithheld: sendWithheld),
                shouldRecordHistory: false,
                showOverlay: delivery == .notObserved,
                holdWords: delivery == .notObserved,
                showRecoveryWindow: delivery == .notObserved
            )
            if delivery == .delivered {
                // Opaque editors commonly accept text without exact AX acknowledgement.
                // Keep Copy latest and the journal without interrupting the next talk.
                phase = .idle
                hideSurface()
            }
        case .failed(let reason):
            // Delivery failed (a partial insert was handled above): hold the words and show them.
            checkpointTranscript(rawPayload, session: session, state: .held)
            print("TTT_EVENT delivery_failed characters=\(payload.utf16.count) reason=\(reason)")
            Diagnostics.event("delivery_failed session=\(session.uuidString) reason=\(reason)")
            logStopTiming(stage: "delivery_failed", session: session)
            let message = "Paste unavailable · Copy latest"
            retainForRecovery(
                payload,
                authored: authored,
                message: message,
                sendReturn: sendReturn,
                shouldRecordHistory: false,
                holdWords: true
            )
        }
    }

}

