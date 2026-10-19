import AppKit
import Foundation
import TokensCore

/// Deliver only recognizer-finalized opening words before the final result. The
/// title is frozen from that stable speech; counts and pauses remain final values.
/// When no safe spoken opening exists, the immutable marker remains the fallback.
enum StopStream {
    static let prefix = "# π"

    static func spokenOpening(payload: String, stableText: String) -> String? {
        let stable = InlineTalkMarkdown.render(BrandVocabulary.apply(to: stableText))
        guard let plan = ThreeStepPaste.plan(payload), let first = plan.steps.first,
              !stable.isEmpty, (plan.header + stable).hasPrefix(first) else { return nil }
        return first
    }

    static func remainderSteps(prefix: String, payload: String) -> [String]? {
        if payload.hasPrefix("# π\n") {
            return AcceleratingPaste.remainder(prefix: prefix, payload: payload)
        }
        guard payload.hasPrefix(prefix), let plan = ThreeStepPaste.plan(payload) else { return nil }
        // Merge any unfinished first tier into the streaming tier. Overall this
        // remains three pastes, whether the early piece was a marker or spoken text.
        let endOfStream = plan.steps.dropLast().joined().count
        guard prefix.count < endOfStream else { return nil }
        let remainder = String(payload.dropFirst(prefix.count))
        let stream = String(remainder.prefix(endOfStream - prefix.count))
        let rest = String(remainder.dropFirst(stream.count))
        let pieces = [stream, rest].filter { !$0.isEmpty }
        return pieces.count > 1 && pieces.joined() == remainder ? pieces : nil
    }
}

/// Reset the entire stream together when a new talk replaces a retained failure.
struct StopStreamState<Payload> {
    var prefix: String?
    var frozenTitle: String?
    var uncertain = false
    var stoppedText = ""
    var gate = StopStreamGate<Payload>()
    mutating func reset() { self = Self() }
}

/// One session's final payload can arrive while the prefix is being acknowledged.
/// Only the first result is retained, and reset/stale callbacks cannot release another talk.
struct StopStreamGate<Payload> {
    private var session: UUID?
    private var pending = false
    private var held: Payload?

    mutating func begin(session: UUID) -> Bool {
        guard self.session == nil else { return false }
        self.session = session
        pending = true
        return true
    }
    mutating func hold(_ payload: Payload, session: UUID) -> Bool {
        guard self.session == session, pending else { return false }
        if held == nil { held = payload }
        return true
    }
    mutating func finish(session: UUID) -> Payload? {
        guard self.session == session, pending else { return nil }
        pending = false
        defer { held = nil }
        return held
    }
    mutating func reset() { self = Self() }
}

extension TalkModel {
    static let stopMarkerAvailable = false

    /// Schedule after the capture callback has had a chance to finish synchronously.
    /// If it did, normal final delivery already owns the session and no marker is posted.
    func streamMarkerAtStop(session: UUID, snapshot: (segment: CompletedSegment, stableText: String)) {
        // The chill footer (2026-10-18) has no "# π" opening line, so nothing is streamed at Stop.
        guard Self.stopMarkerAvailable, selectedProduct == "Tokens", metadataEnabled, Self.threeStepPasteEnabled, !isSyntheticRun,
              target != nil else { return }
        let stoppedText = snapshot.segment.transcript
        guard !stoppedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == session, self.phase == .finalizing,
                  !self.finishLaunching, !self.completedSessionIDs.contains(session),
                  let destination = self.target,
                  self.stopStream.gate.begin(session: session) else { return }
            // Recognition has already been asked to finish before this queued work.
            // Rendering a long preview must not keep the microphone running after Stop.
            // The first phase is just the pi line. It is immutable
            // and does not need to wait for any final words or generated title.
            let proposedOpening = StopStream.prefix + "\n"
            let proposedTitle: String? = nil
            self.stopStream.stoppedText = stoppedText
            self.stopStream.frozenTitle = proposedTitle
            TargetDelivery.beginStopPrefix(proposedOpening, into: destination, isCurrent: { [weak self] in
                guard let self else { return false }
                return self.sessionID == session && self.phase == .finalizing
                    && !self.completedSessionIDs.contains(session)
            }, completion: { [weak self] result in
                guard let self, self.sessionID == session, self.phase == .finalizing,
                      !self.completedSessionIDs.contains(session) else { return }
                switch result {
                case .skipped:
                    self.stopStream.frozenTitle = nil // No text attempted; use final title normally.
                case .verified(let next):
                    self.stopStream.prefix = proposedOpening
                    self.target = next
                case .uncertain:
                    self.stopStream.prefix = proposedOpening
                    self.stopStream.uncertain = true
                }
                if let ready = self.stopStream.gate.finish(session: session) {
                    self.launchGatedDelivery(ready, session: session)
                }
            })
        }
    }

    /// Once a marker may have landed, every failure is partial: retain the complete
    /// prompt, never replay it, and never submit an uncertain or incomplete insertion.
    @MainActor func deliverStreamedRemainder(_ payload: String, into destination: CapturedTarget,
                                  latencyStartUptime: TimeInterval?, revealPlan: TranscriptRevealPlan? = nil, session: UUID) async -> DeliveryOutcome? {
        guard let prefix = stopStream.prefix else { return nil }
        guard !stopStream.uncertain else { return .failed("partial_stop_prefix_unconfirmed") }
        guard payload.hasPrefix(prefix) else { return .failed("partial_streamed_prefix_mismatch") }
        let remainder = String(payload.dropFirst(prefix.count))
        guard !remainder.isEmpty else { return .failed("partial_streamed_payload_empty") }
        return await TargetDelivery.insert(remainder, into: destination, latencyStartUptime: latencyStartUptime,
                                     threeSteps: true, exactContinuation: true,
                                     continuationPieces: StopStream.remainderSteps(prefix: prefix, payload: payload),
                                     revealPlan: revealPlan.flatMap { plan in
            guard plan.completeText == payload, plan.marker == prefix else { return nil }
            return plan.removingMarker()
        }, isCurrent: { self.sessionID == session && self.phase == .finalizing })
    }
}
