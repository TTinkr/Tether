import AppKit
import ApplicationServices

/// Skipped guarantees that this operation never attempted Command-V. Once an event
/// is attempted, an unconfirmed prefix must never trigger a replay of the full text.
enum StopPrefixResult {
    case skipped
    case verified(CapturedTarget)
    case uncertain
}

extension TargetDelivery {
    /// Borrow the clipboard for one immutable prefix while recognition drains.
    /// Called on main; only polling is scheduled, never a blocking sleep. A verified
    /// prefix updates the lease but does not grant permission to submit the prompt.
    static func beginStopPrefix(_ rawPrefix: String, into target: CapturedTarget,
                                isCurrent: @escaping () -> Bool,
                                completion: @escaping (StopPrefixResult) -> Void) {
        precondition(Thread.isMainThread)
        /*
        One Accessibility wait budget for this prefix, from the first lease check to the last
        scheduled readback: the readback polls run later on the main queue, so each one binds the
        same budget again. An app that stops answering ends the prefix as skipped or uncertain,
        never as verified (build 81).
        */
        let budget = AXWaitBudget.forDelivery(characters: rawPrefix.utf16.count)
        let report: (StopPrefixResult) -> Void = { result in
            if budget.stopped { Diagnostics.event("stop_prefix_target_busy \(budget.summary)") }
            completion(result)
        }
        AXWaitBudget.$current.withValue(budget) {
            startStopPrefix(rawPrefix, into: target, budget: budget, isCurrent: isCurrent, completion: report)
        }
    }

    private static func startStopPrefix(_ rawPrefix: String, into target: CapturedTarget, budget: AXWaitBudget,
                                        isCurrent: @escaping () -> Bool,
                                        completion: @escaping (StopPrefixResult) -> Void) {
        guard isCurrent(), target.pointerPosition == nil, !isTerminal(target),
              PasteAckHistory.allowsStaging(bundle: target.application.bundleIdentifier, richComposer: target.richComposer),
              let element = target.element, let before = target.valueBefore,
              let range = target.selection, range.length == 0,
              range.location >= 0, range.location <= before.utf16.count else {
            completion(.skipped)
            return
        }
        let text = preparedText(rawPrefix, for: target, preservingTrailingWhitespace: true)
        guard !text.isEmpty else { completion(.skipped); return }
        let expected = (before as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: 0), with: text)
        var next = target
        next.valueBefore = expected
        next.selection = CFRange(location: range.location + text.utf16.count, length: 0)

        // Check the session between AX calls: a callback can invalidate a capture
        // while another process is servicing a synchronous accessibility request.
        func leaseMatches(_ lease: CapturedTarget) -> Bool {
            guard isCurrent(), !lease.application.isTerminated,
                  accessibilityTrusted(), isCurrent(), exactWindow(lease),
                  isCurrent(), exactFocus(lease), isCurrent(), !isSecure(lease.element),
                  isCurrent(), exactSelection(lease), isCurrent(), exactValue(lease) else { return false }
            return isCurrent()
        }
        guard leaseMatches(target) else { completion(.skipped); return }
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        guard isCurrent(), let snapshot = PasteboardSnapshot.capture(),
              isCurrent(), pasteboard.changeCount == originalChangeCount,
              leaseMatches(target), isCurrent(),
              pasteboard.changeCount == originalChangeCount else { completion(.skipped); return }

        pasteboard.clearContents()
        guard isCurrent() else { completion(.skipped); return }
        // Marked as Tokens' own paste, so clipboard-history apps skip the marker (build 81).
        let wrote = DeliveryClipboard.write(text, to: pasteboard)
        guard isCurrent() else { completion(.skipped); return }
        let ownedChangeCount = pasteboard.changeCount
        func restoreIfOwned() {
            guard isCurrent(), pasteboard.changeCount == ownedChangeCount else { return }
            if !snapshot.restore() { Diagnostics.event("stop_prefix_clipboard_restore_failed") }
        }
        guard wrote, leaseMatches(target), isCurrent(),
              pasteboard.changeCount == ownedChangeCount else {
            // Before any post attempt, restoring our own clipboard is safe. A stale
            // session performs no further clipboard or delivery-state operations.
            restoreIfOwned()
            completion(.skipped)
            return
        }
        stagedSubmissionPID = target.pid
        stagedSubmissionTarget = nil
        let posted = postCommandV(to: target.pid)
        guard isCurrent() else { completion(.uncertain); return }
        guard posted else {
            PasteAckHistory.record(bundle: target.application.bundleIdentifier, acknowledged: false)
            Diagnostics.event("stop_prefix_uncertain reason=post_attempt")
            completion(.uncertain)
            return
        }

        StopPrefixReadback.run(isCurrent: isCurrent, inspect: { AXWaitBudget.$current.withValue(budget) {
            () -> StopPrefixReadback.Observation in
            guard isCurrent(), exactWindow(target), isCurrent(), exactFocus(target),
                  isCurrent(), !isSecure(element), isCurrent() else { return .invalid }
            let value = self.value(in: element)
            guard isCurrent() else { return .invalid }
            let caret = selectedRange(in: element)
            guard isCurrent() else { return .invalid }
            let result = PasteAcknowledgement.evaluate(before: before,
                selection: NSRange(location: range.location, length: range.length), inserted: text,
                after: value, caret: caret.map { NSRange(location: $0.location, length: $0.length) },
                richComposer: target.richComposer)
            if result == .verified {
                // Keep the observed state, including the rich editor's empty-line representation.
                next.valueBefore = value
                next.selection = caret
                return leaseMatches(next) ? .verified : .invalid
            }
            if result == .caretMismatch || result == .unreadableCaret { return .waiting }
            // Allow an unchanged or temporarily unreadable editor to catch up. In a native field
            // an unrelated edit or caret move aborts the lease immediately; a rich composer is
            // waited out until the deadline (StopPrefixReadback.unconfirmed).
            let changed = value.map { $0 != before && $0 != expected } ?? false
            let moved = value == before && (caret.map {
                $0.location != range.location || $0.length != range.length } ?? false)
            return StopPrefixReadback.unconfirmed(valueChanged: changed, caretMoved: moved,
                                                  richComposer: target.richComposer)
        } }, completion: { result in
            guard isCurrent(), result != .cancelled else {
                completion(.uncertain)
                return
            }
            switch result {
            case .verified:
                restoreIfOwned()
                guard isCurrent() else { completion(.uncertain); return }
                Diagnostics.event("stop_prefix_verified")
                completion(.verified(next))
            case .uncertain:
                // A delayed Command-V may still read this piece. Leave it in place;
                // never restore the old clipboard or award trust for this marker.
                PasteAckHistory.record(bundle: target.application.bundleIdentifier, acknowledged: false)
                Diagnostics.event("stop_prefix_uncertain reason=readback")
                completion(.uncertain)
            case .cancelled:
                completion(.uncertain)
            }
        })
    }
}

/// Pure callback-driven polling policy. Tests inject time, observations and a queue;
/// no test of this policy touches AX, the clipboard, key events or another app.
enum StopPrefixReadback {
    enum Observation { case waiting, verified, invalid }
    enum Result { case verified, uncertain, cancelled }

    /*
    One readback that did not verify. Rich composers (Codex, ChatGPT) re-render after a paste,
    and right after an Auto-send they redraw their empty line, so an unrecognised value is waited
    out until the deadline; the Command-V is already posted, so waiting can never paste twice.
    Native fields keep the immediate abort on an unrelated edit or caret move. Measured
    2026-10-12 build 37: an empty Codex composer six seconds after a send gave up on the first
    read and showed a partial recovery, while the same shape verified every other time.
    */
    static func unconfirmed(valueChanged: Bool, caretMoved: Bool, richComposer: Bool) -> Observation {
        if richComposer { return .waiting }
        return valueChanged || caretMoved ? .invalid : .waiting
    }

    static func run(isCurrent: @escaping () -> Bool,
                    inspect: @escaping () -> Observation,
                    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                    }, completion: @escaping (Result) -> Void) {
        let deadline = now() + 0.2
        var finished = false
        func finish(_ result: Result) {
            guard !finished else { return }
            finished = true
            completion(result)
        }
        func poll() {
            guard !finished else { return }
            guard isCurrent() else { finish(.cancelled); return }
            guard now() <= deadline else { finish(.uncertain); return }
            let observation = inspect()
            guard isCurrent() else { finish(.cancelled); return }
            guard now() <= deadline else { finish(.uncertain); return }
            switch observation {
            case .verified: finish(.verified)
            case .invalid: finish(.uncertain)
            case .waiting:
                let remaining = deadline - now()
                guard remaining > 0 else { finish(.uncertain); return }
                schedule(min(0.008, remaining), poll)
            }
        }
        schedule(0, poll)
    }
}
