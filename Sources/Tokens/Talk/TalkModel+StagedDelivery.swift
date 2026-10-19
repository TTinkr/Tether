


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — StagedDelivery


extension TalkModel {

    // Stop target and staged delivery — freezing where the words go

    /// Staged delivery: write the header and the settled words into the editor while
    /// recognition finishes, then the rest at the end. Only for proven native editors
    /// (TargetDelivery.supportsStagedInsertion). Nothing in this class calls it.
    private func beginStagedTokensDelivery(sendReturn: Bool) -> Bool {
        guard selectedProduct == "Tokens", metadataEnabled, phase == .capturing,
              !thinkingExperience || (!thinkingFormatter.enabled && !tinkering.enabled && audio.thinkingPauses.isEmpty),
              audio.isRecording, !audio.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let requestedSession = sessionID else { return false }
        captureStopTarget()
        guard let destination = target,
              TargetDelivery.supportsStagedInsertion(destination) else { return false }
        frozenRecordingDurationSeconds = audio.recordingDurationSeconds
        cancelStartupDeadline()
        phase               = .finalizing
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        stagedCommitted     = ""
        stagedFailed        = false
        // Only Apple's finalized prefix is eligible for the flowing middle.
        let raw = audio.transcript
        let stable = BrandVocabulary.apply(to:
            StagedPrompt.stablePrefix(raw, wordCount: audio.stableWordCount))
        let chunks = StagedPrompt.chunks(stableText: stable)
        /*
        Each piece is appended only if the editor reads back as expected; one failure
        stops every later piece.
        */
        func append(_ text: String) {
            guard !self.stagedFailed, let current = self.target,
                  let next = TargetDelivery.appendVerified(text, to: current) else {
                self.stagedFailed = true
                return
            }
            self.target          = next
            self.stagedCommitted = (self.stagedCommitted ?? "") + text
        }
        stagedHeader = StagedPrompt.snapshotHeader(body: raw, duration: frozenRecordingDurationSeconds ?? 0)
        append(stagedHeader ?? StagedPrompt.header)
        let firstWriteMS = (ProcessInfo.processInfo.systemUptime - (stopRequestedUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000
        Diagnostics.event("staged_delivery_first_write verified=\(!stagedFailed) elapsed_ms=\(firstWriteMS)")
        var finalSegment: CompletedSegment?
        var flowDone = chunks.isEmpty
        func finishIfReady() {
            guard self.sessionID == requestedSession, self.phase == .finalizing,
                  flowDone, let segment = finalSegment else { return }
            self.complete(session: requestedSession, payload: segment.transcript,
                          segment: segment, sendReturn: sendReturn)
        }
        // The settled chunks follow, one every 30 ms.
        for (index, chunk) in chunks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index + 1) * 0.03) { [weak self] in
                guard let self, self.sessionID == requestedSession, self.phase == .finalizing else { return }
                append(chunk)
                if index == chunks.count - 1 { flowDone = true; finishIfReady() }
            }
        }
        /*
        Stop audio now, allowing already-captured tail recognition to finish
        concurrently with the visible writes. Never wait on an LLM here.
        */
        audio.finishAdaptively { [weak self] segment in
            guard let self, self.sessionID == requestedSession, self.phase == .finalizing else { return }
            finalSegment = segment
            finishIfReady()
        }
        return true
    }

}

