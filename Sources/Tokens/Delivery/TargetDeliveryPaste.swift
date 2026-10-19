


//
import AppKit
import ApplicationServices
import Darwin
import TokensCore


extension TargetDelivery {


    // Paste — clipboard, Command-V, and watching for the words to land


    /// `threeSteps` enables an acknowledged reveal when a frozen plan is supplied. It is used only when the
    /// editor's text can be read back, so each piece is seen to land before the next is put on the
    /// clipboard; anywhere else, and for any text without a plan, this is the single paste it always was.
    @MainActor static func insert(
        _ rawText: String,
        into captured: CapturedTarget,
        latencyStartUptime: TimeInterval? = nil,
        threeSteps: Bool = false,
        exactContinuation: Bool = false,
        continuationPieces: [String]? = nil,
        revealPlan: TranscriptRevealPlan? = nil,
        textReadyUptime: TimeInterval? = nil,
        revealObserver: ((RevealDeliveryTiming) -> Void)? = nil,
        isCurrent: @escaping () -> Bool = { true }
    ) async -> DeliveryOutcome {
        /*
        One Accessibility wait budget for the whole delivery: pointer check, preflight, every
        piece, every readback and the closing diagnostics. Each read waits at most one second,
        the first read the app cannot answer in time stops all later reads, and the total is
        sized by the words (AXWaitBudget.forDelivery). A stopped budget only ever makes reads
        fail, so a paste is never posted unchecked, never confirmed without its readback and
        never followed by Return; the words stay in recovery.
        */
        let budget = AXWaitBudget.current ?? AXWaitBudget.forDelivery(characters: rawText.utf16.count)
        let result = await AXWaitBudget.$current.withValue(budget) {
            await insertPiece(rawText, into: captured, latencyStartUptime: latencyStartUptime,
                              threeSteps: threeSteps, exactContinuation: exactContinuation,
                              continuationPieces: continuationPieces, revealPlan: revealPlan,
                              textReadyUptime: textReadyUptime ?? ProcessInfo.processInfo.systemUptime,
                              revealObserver: revealObserver, isCurrent: isCurrent)
        }
        if budget.stopped {
            Diagnostics.event("delivery_target_busy bundle=\(captured.application.bundleIdentifier ?? "unknown") \(budget.summary)")
        }
        // The prefix is already in the editor. Even a failure before the next paste
        // is a partial delivery; recovery must never replay the whole prompt.
        guard exactContinuation, result != .verified else { return result }
        if case .failed(let reason) = result, reason.hasPrefix("partial_") { return result }
        return .failed("partial_continuation_unconfirmed")
    }

    @MainActor private static func insertPiece(
        _ rawText: String,
        into captured: CapturedTarget,
        latencyStartUptime: TimeInterval?,
        threeSteps: Bool,
        exactContinuation: Bool,
        continuationPieces: [String]?,
        revealPlan: TranscriptRevealPlan?,
        textReadyUptime: TimeInterval,
        revealObserver: ((RevealDeliveryTiming) -> Void)?,
        isCurrent: @escaping () -> Bool
    ) async -> DeliveryOutcome {
        guard isCurrent() else { return .failed("delivery_cancelled") }
        // A browser must never receive a suffix as if it were the whole dictation.
        // A legacy/in-flight prefix is already a partial delivery: retain recovery and
        // refuse a continuation instead of appending or blindly replaying the full text.
        guard !exactContinuation || !PasteAckHistory.requiresSingleFinalPaste(bundle: captured.application.bundleIdentifier) else {
            return .failed("partial_browser_continuation_refused")
        }
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("nothing_to_insert")
        }
        // A new delivery cancels any staged-submit permission left from an earlier one.
        stagedSubmissionPID    = nil
        stagedSubmissionTarget = nil
        var target             = captured
        if captured.pointerPosition != nil {
            guard let prepared = preparePointerTarget(captured) else {
                return .failed("pointer_editor_changed_or_unavailable")
            }
            target = prepared
        }
        /*
        Terminals get the words trimmed and nothing else. Other editors may get one
        leading space so the words do not run into the text before the caret.
        */
        // Paste the authored payload without app-wide synthetic newlines. A bundle ID
        // does not establish that the focused field is a chat composer.
        let frozenReveal = revealPlan?.completeText.utf8.elementsEqual(rawText.utf8) == true
        let text = exactContinuation ? rawText
            : isTerminal(target) ? rawText.trimmingCharacters(in: .whitespacesAndNewlines) : preparedText(rawText, for: target, preservingWhitespace: frozenReveal)
        guard !text.isEmpty else { return .failed("nothing_to_insert") }
        guard accessibilityTrusted(), !target.application.isTerminated else {
            return .failed("target_or_accessibility_unavailable")
        }
        /*
        Codex can expose its window without exposing a focused editor. The user
        explicitly chooses its current keyboard destination with the stop key.
        Never reactivate an opaque destination or generalize this to other apps.
        */
        let opaqueCodex = target.application.bundleIdentifier == "com.openai.codex"
            && target.element == nil && target.window != nil
            && target.pointerPosition == nil && (target.windowCount ?? 0) > 0
        if opaqueCodex {
            guard exactWindow(target),
                  windowCount(in: applicationElement(target.pid)) == target.windowCount else {
                return .failed("opaque_window_changed")
            }
        } else {
            guard exactWindow(target) else { return .failed("target_changed_after_stop") }
        }

        /*
        Preflight: same window, same field, same caret, same text as at stop (Codex without
        a field checks window only). The user's clipboard is copied out here too; if it
        cannot be read in full, nothing is pasted.
        */
        let windowMatches    = exactWindow(target)
        let focusMatches     = exactFocus(target)
        let selectionMatches = exactSelection(target)
        let valueMatches     = exactValue(target)
        let initialClipboardChangeCount = NSPasteboard.general.changeCount
        Diagnostics.event("delivery_preflight bundle=\(target.application.bundleIdentifier ?? "unknown") window=\(windowMatches) focus=\(focusMatches) selection=\(selectionMatches) value=\(valueMatches) range=\(target.selection != nil)")
        guard windowMatches, (opaqueCodex || (focusMatches && selectionMatches && valueMatches)),
              !isSecure(target.element),
              let snapshot = PasteboardSnapshot.capture() else {
            return .failed("original_editor_changed")
        }
        /*
        Apply the same lease checks to every destination, including controls
        without a selection range. AX calls can yield to another application.
        */
        let leaseIsCurrent = {
            guard isCurrent(), exactWindow(target), !isSecure(target.element) else { return false }
            if opaqueCodex {
                return windowCount(in: applicationElement(target.pid)) == target.windowCount
            }
            return exactFocus(target) && exactSelection(target) && exactValue(target)
        }
        guard leaseIsCurrent() else { return .failed("target_changed_before_clipboard") }
        let focusStructure = target.application.bundleIdentifier == "com.openai.codex"
            ? target.element.map(FocusTransitionDiagnostics.init) : nil
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == initialClipboardChangeCount else { return .failed("clipboard_changed_before_paste") }
        /*
        Evidence for staged delivery: how soon the editor's readable value moves after Command-V,
        and whether it then contains a word of what was pasted. Counts and timings only, never text.
        */
        let probe = text.prefix(160).split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 5 }).map(String.init)
        var changedAfterMS: Int?, probeSeen = false
        var verified = false
        /*
        The clipboard's change count right after our own write. If it differs later,
        someone else (usually the user) has copied since, and that copy is theirs.
        */
        var ownedChangeCount = pasteboard.changeCount

        /*
        currentLease is the observed editor text and caret after accepted pieces.
        readable() promotes a pending piece only after the shared acknowledgement policy
        verifies the actual text and caret, including rich-editor empty-line behavior.
        The editor's text as last read; nil when it cannot be read at all.
        */
        var currentLease = target
        var pendingPiece: String?
        // Claude desktop's caret offsets skip single line breaks (PasteAcknowledgement.lineBreakSkippingInsertion).
        let caretSkipsLineBreaks = target.application.bundleIdentifier == "com.anthropic.claudefordesktop"
        func readable() -> String? {
            guard isCurrent(), exactWindow(target), exactFocus(target), !isSecure(target.element),
                  let element = target.element, let text = value(in: element) else { return nil }
            if let piece = pendingPiece, let before = currentLease.valueBefore,
               let range = currentLease.selection {
                // Text and caret may become visible on different AX turns. Do not
                // let the next clipboard piece outrun the caret acknowledgement.
                let caret = selectedRange(in: element)
                let result = PasteAcknowledgement.evaluate(before: before,
                    selection: NSRange(location: range.location, length: range.length), inserted: piece,
                    after: text, caret: caret.map { NSRange(location: $0.location, length: $0.length) },
                    richComposer: target.richComposer, caretSkipsLineBreaks: caretSkipsLineBreaks)
                if result == .verified {
                    currentLease.valueBefore = text
                    currentLease.selection = caret
                    pendingPiece = nil
                } else if PasteAcknowledgement.waitsForReadback(result, richComposer: target.richComposer) {
                    return nil
                }
            }
            return text
        }
        func currentLeaseIsValid() -> Bool {
            isCurrent() && exactWindow(currentLease) && exactFocus(currentLease) && !isSecure(currentLease.element)
                && exactSelection(currentLease) && exactValue(currentLease)
        }
        /// Puts one piece on the clipboard and posts Command-V. `expecting` is the editor text as last
        /// seen: for a later piece it must be unchanged, or someone else has typed there.
        func paste(_ piece: String, expecting: String?) -> String? {
            if let expecting {
                guard currentLeaseIsValid(), currentLease.valueBefore == expecting else { return "target_changed_between_steps" }
            } else {
                guard leaseIsCurrent() else { return "target_changed_before_clipboard" }
            }
            guard pasteboard.changeCount == ownedChangeCount else { return "clipboard_changed_between_steps" }
            pasteboard.clearContents()
            // Marked as Tokens' own paste, so clipboard-history apps skip each piece (build 81).
            guard DeliveryClipboard.write(piece, to: pasteboard) else { return "clipboard_write_failed" }
            ownedChangeCount = pasteboard.changeCount
            #if TTT_DELIVERY_TESTING
            beforePasteTestBarrier?()
            #endif
            /*
            Check again after the clipboard write and just before Command-V: the target
            must be unchanged and the clipboard must still hold our piece.
            */
            if expecting == nil {
                guard leaseIsCurrent(), pasteboard.changeCount == ownedChangeCount else { return "target_changed_before_paste" }
            } else {
                guard currentLeaseIsValid(), pasteboard.changeCount == ownedChangeCount else { return "target_or_clipboard_changed_between_steps" }
            }
            pendingPiece = piece
            guard postCommandV(to: target.pid) else { return "paste_event_failed" }
            /*
            A second paste into a browser editor can fire paste/beforeinput and
            insert nothing while a manual Command-V works. On a Dev diagnostic trial only, right after
            posting (so the paste is not delayed), record whether the target app, window and field
            still held the keyboard. Off by default: nothing is asked or awaited before the readback.
            */
            if PasteRoute.devLogsTargetState {
                Diagnostics.event("paste_target_state \(pasteTargetState(target))")
            }
            return nil
        }
        /*
        Restore only the clipboard version we own. A user copy during the
        paste belongs to the user and must not be replaced with old contents.
        */
        let restoreOwnedClipboard = {
            guard pasteboard.changeCount == ownedChangeCount else { return }
            if !snapshot.restore() { Diagnostics.event("clipboard_restore_failed_after_paste") }
        }

        // Staging needs a readable editor with a known caret; otherwise it is one paste, as before.
        let bundle = target.application.bundleIdentifier
        let stageable = target.element != nil && target.valueBefore != nil && target.selection != nil && !isTerminal(target)
        let exactReveal = revealPlan.map { plan in
            plan.completeText.utf8.elementsEqual(rawText.utf8) && text.utf8.suffix(rawText.utf8.count).elementsEqual(rawText.utf8)
                && String(decoding: text.utf8.dropLast(rawText.utf8.count), as: UTF8.self).allSatisfy({ $0.isWhitespace })
        } ?? false
        let trialBefore = CodexStreamingTrial.status()
        let boundaryTrial = threeSteps && stageable && !exactContinuation
            && CodexStreamingTrial.consume(bundle: bundle, richComposer: target.richComposer, exactPlan: exactReveal)
        let staging = PasteAckHistory.deliveryStagingEligibility(bundle: bundle,
            richComposer: target.richComposer, exactPlan: exactReveal, continuation: exactContinuation,
            threeSteps: threeSteps, stageable: stageable, boundaryTrial: boundaryTrial)
        let historyAllows = staging.historyAllows
        let codexFinalReveal = staging.finalRevealAllows
        let mayStage = staging.mayStage
        // Name every guard so a single-paste fallback says which one declined (no text logged).
        Diagnostics.event("staging_gate bundle=\(bundle ?? "unknown") three_steps=\(threeSteps) stageable=\(stageable)"
            + " element=\(target.element != nil) value=\(target.valueBefore != nil) selection=\(target.selection != nil)"
            + " terminal=\(isTerminal(target)) rich=\(target.richComposer) ack_count=\(PasteAckHistory.count(bundle: bundle))"
            + " history_allows=\(historyAllows) reveal_plan=\(revealPlan != nil) exact_plan=\(exactReveal)"
            + " continuation=\(exactContinuation) final_reveal_allows=\(codexFinalReveal) trial=\(trialBefore) trial_used=\(boundaryTrial)")
        if boundaryTrial { Diagnostics.event("codex_boundary_trial consumed=true early_prefix=false") }
        // Carry exact formatter components. Any preparation beyond an added whitespace
        // separator falls back rather than reparsing or changing authored text.
        let continuousPlan: TranscriptRevealPlan? = {
            guard mayStage, let revealPlan, revealPlan.completeText.utf8.elementsEqual(rawText.utf8),
                  text.utf8.suffix(rawText.utf8.count).elementsEqual(rawText.utf8) else { return nil }
            let separator = String(decoding: text.utf8.dropLast(rawText.utf8.count), as: UTF8.self)
            guard separator.allSatisfy({ $0.isWhitespace }) else { return nil }
            return revealPlan.prependingMarker(separator)
        }()
        let plan = mayStage && continuousPlan == nil ? AcceleratingPaste.plan(text) : nil
        // A continuation is authored once by the stop-stream coordinator. Never trim
        // or add a separator per piece; reject a plan that changes even one byte.
        let pieces: [String]
        if exactContinuation, mayStage, let continuationPieces,
           continuationPieces.count > 1, continuationPieces.allSatisfy({ !$0.isEmpty }),
           continuationPieces.joined() == text {
            pieces = continuationPieces
        } else {
            pieces = plan?.steps ?? [text]
        }
        Diagnostics.event("staging_plan bundle=\(bundle ?? "unknown") eligible=\(mayStage) pieces=\(pieces.count) continuation=\(exactContinuation)")
        let guardedSubmission = exactContinuation || plan != nil || continuousPlan != nil
        /*
        From here a later Return to this app must match the exact final editor state
        (see sendReturn); if staging never reaches that state, Return is refused.
        */
        if guardedSubmission { stagedSubmissionPID = target.pid }
        var seen         = target.valueBefore
        var stagedPieces = 0
        let run: StagedPasteDriver.Outcome
        if let continuousPlan {
            var postedWrites = 0
            var configuration = AcknowledgedRevealDriver.Configuration()
            configuration.deferTrailingWhitespace = boundaryTrial || codexFinalReveal
            var timing = RevealDeliveryTiming(targetMS: continuousPlan.duration * 1000,
                maximumBatchCharacters: configuration.maximumBodyBatch)
            func elapsedMS() -> Double { max(0, ProcessInfo.processInfo.systemUptime - textReadyUptime) * 1000 }
            var postedCharacters = 0
            let result = await AcknowledgedRevealDriver.runAsync(plan: continuousPlan,
                configuration: configuration,
                guardFailure: {
                    guard currentLeaseIsValid() else { return "target_changed_during_reveal" }
                    return pasteboard.changeCount == ownedChangeCount ? nil : "clipboard_changed_during_reveal"
                }, post: { piece in
                    let failure = paste(piece, expecting: postedWrites == 0 ? nil : currentLease.valueBefore)
                    if let failure {
                        return failure == "paste_event_failed" ? .uncertain(failure) : .refused(failure)
                    }
                    postedWrites += 1
                    postedCharacters += piece.count
                    timing.writes.append(.init(characters: piece.count, cumulativeCharacters: postedCharacters,
                        postedMS: elapsedMS(), acknowledgedMS: nil))
                    return .posted
                }, acknowledge: { _ in
                    for poll in 0...StagedPasteDriver.pollsPerPiece {
                        guard isCurrent(), exactWindow(target), exactFocus(target), !isSecure(target.element) else {
                            return "target_changed_during_reveal_ack"
                        }
                        guard pasteboard.changeCount == ownedChangeCount else { return "clipboard_changed_during_reveal_ack" }
                        let observation = readable()
                        if pendingPiece == nil, observation != nil, currentLeaseIsValid() {
                            timing.writes[timing.writes.count - 1].acknowledgedMS = elapsedMS()
                            return nil
                        }
                        if let observation, observation != currentLease.valueBefore { return "unexpected_editor_text" }
                        if poll < StagedPasteDriver.pollsPerPiece {
                            try? await Task.sleep(nanoseconds: UInt64(StagedPasteDriver.pollMicroseconds) * 1_000)
                        }
                    }
                    return "unacknowledged"
                }, now: { ProcessInfo.processInfo.systemUptime }, wait: {
                    try? await Task.sleep(nanoseconds: UInt64($0) * 1_000)
                })
            switch result {
            case .delivered(let count):
                timing.outcome = "delivered"
                Diagnostics.event("continuous_reveal acknowledged=\(count) target_ms=\(Int(continuousPlan.duration * 1000))"
                    + " first_post_ms=\(timing.firstPostMS ?? -1) first_ack_ms=\(timing.firstAcknowledgedMS ?? -1)"
                    + " complete_ack_ms=\(timing.completeAcknowledgedMS ?? -1) clock=text_ready")
                run = .posted(acknowledged: count)
            case .stopped(let reason, let posted, _, _):
                timing.outcome = reason
                if codexFinalReveal, isCurrent() {
                    let disabled = PasteAckHistory.recordCodexFinalRevealFailure(reason: reason, bundle: bundle ?? "com.openai.codex")
                    Diagnostics.event("codex_final_reveal_stopped reason=\(reason) build_disabled=\(disabled)")
                }
                run = posted == 0 ? .failedBeforeAnything(reason) : .failedPartway(reason, posted: posted)
            }
            timing.finishedMS = elapsedMS()
            revealObserver?(timing)
        } else {
            run = {
            return StagedPasteDriver.run(pieces: pieces, initial: target.valueBefore,
                                        selection: target.selection.map { NSRange(location: $0.location, length: $0.length) },
                                        post: paste, read: readable, sleep: { usleep($0) },
                                        minimumAcknowledgedPieces: 1,
                                        interPieceHolds: AcceleratingPaste.gapsMicroseconds,
                                        budgetSeconds: AcceleratingPaste.deliveryBudgetSeconds,
                                        accepts: { before, range, piece, after in
            guard pendingPiece == nil, currentLease.valueBefore == after,
                  let caret = currentLease.selection else { return false }
            return PasteAcknowledgement.evaluate(before: before, selection: range, inserted: piece,
                after: after, caret: NSRange(location: caret.location, length: caret.length),
                richComposer: target.richComposer, caretSkipsLineBreaks: caretSkipsLineBreaks) == .verified
        })
            }()
        }
        // A newer session owns all global delivery state after cancellation. Do not
        // clear its trust, restore its clipboard, or install an older Return lease.
        guard isCurrent() else { return .failed("partial_delivery_cancelled") }
        switch run {
        case .posted(let acknowledged):
            stagedPieces = acknowledged
            if acknowledged > 0 { seen = readable() }
            if pieces.count > 1 { Diagnostics.event("three_step_paste acknowledged=\(acknowledged) planned=\(pieces.count)") }
        case .failedBeforeAnything(let failure):
            // Nothing reached the editor. Put the user's clipboard back unless they copied since.
            if pasteboard.changeCount == ownedChangeCount { _ = snapshot.restore() }
            return .failed(failure)
        case .failedPartway(let failure, let posted):
            /*
            The last posted Command-V may still be waiting to read its piece.
            Restoring old clipboard data on a timer could insert those old words.
            Leave this piece until the user copies again; never overwrite that copy.
            */
            Diagnostics.event("clipboard_held_for_unacknowledged_paste")
            // This editor did not behave as its history promised: single pastes until it proves itself again.
            PasteAckHistory.record(bundle: bundle, acknowledged: false)
            Diagnostics.event("three_step_paste stopped=\(failure) posted=\(posted)")
            return .failed("partial_\(failure)")
        }
        if let latencyStartUptime {
            let elapsedMS = max(0, ProcessInfo.processInfo.systemUptime - latencyStartUptime) * 1000
            Diagnostics.event("speed_of_sound_paste_dispatched elapsed_ms=\(String(format: "%.3f", elapsedMS))")
        }
        /*
        Watch unchanged editors for at most 60 × 25 ms = 1.5 s of polling sleeps;
        observed changes retain the original 500 ms budget unless verified sooner.
        AX calls add wall time. Verified means its exact text contains the insertion
        at the captured selection and the caret sits immediately after that insertion.
        Missing captured element or value ends after the first polling turn. Without
        selection, value changes remain observable but never prove exact acceptance.
        A temporarily unreadable live value can recover within the remaining budget.
        changedAfterMS and probeSeen are diagnostics only, never acknowledgement evidence.
        */
        let posted     = ProcessInfo.processInfo.systemUptime
        let beforeLast = seen
        var lastObservation: PasteReadbackWatch.Observation?
        let readback = PasteReadbackWatch.run(before: target.valueBefore,
            selection: target.selection.map { NSRange(location: $0.location, length: $0.length) },
            inserted: text, elementAvailable: target.element != nil,
            wait: { usleep(UInt32($0) * 1_000) },
            windowCurrent: { isCurrent() && exactWindow(target) }, focusCurrent: { isCurrent() && exactFocus(target) },
            read: {
                guard let element = target.element else { return .init(after: nil, caret: nil) }
                return .init(after: value(in: element), caret: selectedRange(in: element).map {
                    NSRange(location: $0.location, length: $0.length)
                })
            }, maximumWaitAttempts: 60, richComposer: target.richComposer,
            caretSkipsLineBreaks: caretSkipsLineBreaks, onRead: { observation in
                lastObservation = observation
                let after = observation.after
                if changedAfterMS == nil, after != (beforeLast ?? target.valueBefore) {
                    changedAfterMS = Int((ProcessInfo.processInfo.systemUptime - posted) * 1000)
                }
                if let probe, let after, let before = target.valueBefore,
                   !probeSeen, after.contains(probe), !before.contains(probe) { probeSeen = true }
            })
        let acknowledgement = readback.reason
        if acknowledgement == "focus_changed" {
            FocusTransitionDiagnostics.record(target: target, before: focusStructure, inserted: text)
        }
        verified = readback.verified
        if let before = target.valueBefore, let selection = target.selection {
            Diagnostics.event("paste_ack_rules rich=\(target.richComposer) verified=\(verified) \(PasteAcknowledgement.shapeFlags(before: before, selection: NSRange(location: selection.location, length: selection.length), inserted: text, after: lastObservation?.after))")
        }
        if !verified {
            // Counts and offsets only, never editor text or the dictated payload.
            let expectedCaret = target.selection.map { $0.location + text.utf16.count } ?? -1
            Diagnostics.event("paste_ack_shape before_utf16=\(target.valueBefore?.utf16.count ?? -1) inserted_utf16=\(text.utf16.count) after_utf16=\(lastObservation?.after?.utf16.count ?? -1) selection_start=\(target.selection?.location ?? -1) selection_length=\(target.selection?.length ?? -1) expected_caret=\(expectedCaret) actual_caret=\(lastObservation?.caret?.location ?? -1) actual_selection_length=\(lastObservation?.caret?.length ?? -1)")
            if let before = target.valueBefore, let selection = target.selection {
                Diagnostics.event("paste_ack_diff \(PasteAcknowledgement.mismatchShape(before: before, selection: NSRange(location: selection.location, length: selection.length), inserted: text, after: lastObservation?.after))")
            }
        }
        /*
        Return lease for every confirmed paste, not only staged ones: Auto-send's Return goes only
        if the editor still reads exactly the confirmed text with the caret where it was confirmed
        (TargetDelivery.sendReturn checks this when stagedSubmissionPID matches).
        */
        if let finalRead = readback.verifiedSnapshot, let after = finalRead.after,
           let caret = finalRead.caret {
            var final = target
            final.valueBefore = after
            final.selection = CFRange(location: caret.location, length: caret.length)
            stagedSubmissionPID    = target.pid
            stagedSubmissionTarget = final
        }
        /*
        A single paste recovers a failed rich-editor stage only after full acknowledgement.
        Native editors retain exact-readback calibration. Every rich-editor piece now uses
        the same acknowledgement policy and carries its observed lease forward.
        */
        let exactReadback: Bool = {
            guard verified, let before = target.valueBefore, let selection = target.selection,
                  let after = readback.verifiedSnapshot?.after else { return false }
            return after == (before as NSString).replacingCharacters(
                in: NSRange(location: selection.location, length: selection.length), with: text)
        }()
        if stageable, (target.richComposer || (plan == nil && !exactContinuation)) {
            PasteAckHistory.record(bundle: bundle, acknowledged: target.richComposer ? verified : exactReadback,
                                   richComposer: target.richComposer)
        }
        // Only fixed reason codes: never write the editor text, selected text or payload.
        Diagnostics.event("paste_ack bundle=\(target.application.bundleIdentifier ?? "unknown") readable=\(target.valueBefore != nil) changed_ms=\(changedAfterMS.map(String.init) ?? "none") probe=\(probeSeen) verified=\(verified) staged=\(stagedPieces) reason=\(acknowledgement)")
        /*
        A confirmed paste no longer needs our clipboard text. An unconfirmed
        Command-V may read it later, at an unbounded time. Keep our piece until
        the user copies again: a timed restore could paste the old clipboard.
        */
        if verified { restoreOwnedClipboard() }
        else if PasteAcknowledgement.pasteConsumed(before: target.valueBefore,
                    selection: target.selection.map { NSRange(location: $0.location, length: $0.length) },
                    after: lastObservation?.after, observedChange: readback.observedChange, inserted: text) {
            /*
            Not an exact acknowledgement, but the editor visibly took this Command-V: outside the
            captured selection nothing changed, and inside it stand these words (case and spacing
            aside). The paste has been read, so the user's own clipboard comes back (build 81: it
            was replaced for good after every unconfirmed paste). Still guarded by
            restoreOwnedClipboard's change count, so a copy the user made meanwhile is kept.
            */
            Diagnostics.event("clipboard_restored_after_observed_paste")
            restoreOwnedClipboard()
        } else { Diagnostics.event("clipboard_held_for_unacknowledged_paste") }
        Diagnostics.event("paste_posted verified=\(verified)")
        if verified { return .verified }
        if guardedSubmission {
            if codexFinalReveal {
                let reason = ["focus_changed", "window_changed"].contains(acknowledgement)
                    ? acknowledgement : "final_unacknowledged"
                let disabled = PasteAckHistory.recordCodexFinalRevealFailure(reason: reason, bundle: bundle ?? "com.openai.codex")
                Diagnostics.event("codex_final_reveal_stopped reason=\(reason) build_disabled=\(disabled)")
            }
            PasteAckHistory.record(bundle: bundle, acknowledged: false)
            return .failed("partial_final_unacknowledged")
        }
        /*
        Once Command-V was posted, a slow or opaque editor may accept it
        later. Treat acceptance as uncertain: never submit or replay it.
        */
        print("TTT_EVENT paste_posted_acceptance_unverified")
        let role = target.element.flatMap { stringAttribute(kAXRoleAttribute as String, from: $0) }
        return readback.insertionNotObserved(role: role, hasSelection: target.selection != nil)
            ? .notObserved : .delivered
    }


}

