


//
/*
AudioCapture+Finish.swift

Owns: Stop/drain decisions, final snapshots, completion, and per-talk cleanup.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Hardware.swift
         AudioCapture+Signal.swift
         AudioCapture+Recognition.swift
         AudioCapture+Demo.swift
         AudioCapture+Measurement.swift
         AudioCapture+Features.swift
Port provenance: Sources/Audio/TTTAudioCapture.swift, donor 2ac14df.
*/


import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech


extension AudioCapture {


    // Finishing a talk — stop, discard, finish now, or finish after a short drain


    /*
    Ends the session without finishing it: no completion is called and nothing is
    delivered. A kept-open microphone keeps running. Returns the averaged features of the
    current sound segment, or the latest buffer's features when there is none.
    */
    @discardableResult
    func stop() -> AudioFeatures {
        session.cancel()
        cleanupCapture()
        voiceCommandsAvailable = false
        permissionMessage      = "stopped"
        return aggregateCount > 0 ? aggregate : features
    }


    /// Explicit cancellation never finalizes or emits a completed segment.
    func discardCapture() {
        stop()
        resetSession()
    }


    /// Fast freezes the current recognized words synchronously. If no words are
    /// available yet, keep the bounded drain so a short utterance is not discarded.
    /// Slow uses the existing adaptive final-word drain, with no cosmetic wait.
    func finishForPaste(timing: TokensPasteTiming, completion: @escaping (CompletedSegment) -> Void) {
        guard session.id != nil, session.phase != .finalizing else { return }
        quiesceForFinish { [weak self] in self?.finishForPasteQuiescent(timing: timing, completion: completion) }
    }

    private func finishForPasteQuiescent(timing: TokensPasteTiming, completion: @escaping (CompletedSegment) -> Void) {
        if streamingPipeline?.requiresExplicitFinalization == true {
            finishAdaptivelyQuiescent(completion: completion)
            return
        }
        // Use one canonical snapshot for both the decision and the completion. A
        // concurrent volatile retraction must not replace the snapshot we chose.
        let result = timing == .fast ? streamingPipeline?.currentResult : nil
        let frozen = result?.snapshot
        let hasWords = !(frozen?.text ?? transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if timing == .fast && hasWords {
            stopRequestedAt = ProcessInfo.processInfo.systemUptime
            stopWordCount = transcript.split(whereSeparator: { $0.isWhitespace }).count
            Diagnostics.event("stop_requested mode=fast_snapshot grace_ms=0")
            finishImmediately(snapshot: frozen, failure: result?.failure, completion: completion)
        } else {
            finishAdaptively(completion: completion)
        }
    }

    /// End capture immediately; drain already captured speech only when the tail
    /// is not demonstrably quiet and finalized. UI reveal never delays delivery.
    func finishAdaptively(completion: @escaping (CompletedSegment) -> Void) {
        guard session.id != nil, session.phase != .finalizing else { return }
        quiesceForFinish { [weak self] in self?.finishAdaptivelyQuiescent(completion: completion) }
    }

    private func finishAdaptivelyQuiescent(completion: @escaping (CompletedSegment) -> Void) {

        // Freeze input, then choose whether the last words need time to settle


        /*
        The completion returns a CompletedSegment to the caller; this method does not paste.
        A repeated finish request must not start a second drain. Stop new input before
        comparing final-word count with the quiet-tail measurements.
        */
        guard session.id != nil, session.phase != .finalizing else { return }
        /*
        Quiesce the tap before reading readiness and canonical state so the
        final buffer cannot race a supposedly ready immediate snapshot.
        */
        stopEngineCapture()
        let now = ProcessInfo.processInfo.systemUptime
        if let result = streamingPipeline?.currentResult {
            let snapshot = result.snapshot
            timedWords      = snapshot.timedWords
            transcript      = snapshot.text
            stableWordCount = snapshot.stableWordCount
            if let failure = result.failure, let generation = session.id {
                fail(failure, generation: generation)
                return
            }
        }
        /*
        Finish at once only when the tail was measured quiet and every word is final;
        otherwise wait the short grace StopReadiness chose for the last words to arrive.
        */
        let count       = transcript.split(whereSeparator: { $0.isWhitespace }).count
        let decision    = stopReadiness.decision(at: now, transcriptFinalized: count > 0 && stableWordCount >= count)
        stopRequestedAt = now
        stopDecision    = decision
        stopWordCount   = count
        if let pipeline = streamingPipeline, pipeline.requiresExplicitFinalization {
            Diagnostics.event("stop_requested mode=explicit_final engine=\(pipeline.engineIdentity)")
            finishQuiescent(after: pipeline.finalizationTimeout, completion: completion)
            return
        }
        Diagnostics.event("stop_requested mode=\(decision.reason) grace_ms=\(Int(decision.graceSeconds * 1000)) quiet_ms=\(Int(decision.quietSeconds * 1000))")
        if decision.graceSeconds == 0 { finishImmediately(completion: completion) }
        else { finish(after: decision.graceSeconds, completion: completion) }


    }

//
// :)
//
//
    /// Deliver a synchronized best-effort snapshot without waiting for final ASR.
    /// Visual sentence reveal is independent and must never hold this completion.
    func finishImmediately(snapshot frozen: TranscriptSnapshot? = nil, failure frozenFailure: String? = nil,
                           completion: @escaping (CompletedSegment) -> Void) {
        quiesceForFinish { [weak self] in
            self?.finishImmediatelyQuiescent(snapshot: frozen, failure: frozenFailure, completion: completion)
        }
    }

    private func finishImmediatelyQuiescent(snapshot frozen: TranscriptSnapshot?, failure frozenFailure: String?,
                                           completion: @escaping (CompletedSegment) -> Void) {
        // Offline-prefix engines must produce their explicit final result; a stable
        // looking prefix is never authority to deliver the recording.
        if let pipeline = streamingPipeline, pipeline.requiresExplicitFinalization {
            finishQuiescent(after: pipeline.finalizationTimeout, completion: completion)
            return
        }
        guard let generation = session.beginFinishing() else { return }
        let result = frozen.map { (snapshot: $0, failure: frozenFailure) }
            ?? streamingPipeline?.currentResult
        if let result {
            let snapshot = result.snapshot
            timedWords      = snapshot.timedWords
            transcript      = snapshot.text
            stableWordCount = snapshot.stableWordCount
            if let failure = result.failure {
                fail(failure, generation: generation)
                return
            }
        }
        finishCompletion = completion
        finishSegment(generation: generation, outcome: "ready_snapshot")
    }


    /// Final recognition results may arrive after endAudio. Drain until a final
    /// result or a bounded deadline, then deliver the latest canonical snapshot.
    func finish(after delay: TimeInterval = 1.5, completion: @escaping (CompletedSegment) -> Void) {
        guard session.id != nil, session.phase != .finalizing else { return }
        quiesceForFinish { [weak self] in self?.finishQuiescent(after: delay, completion: completion) }
    }

    private func finishQuiescent(after delay: TimeInterval, completion: @escaping (CompletedSegment) -> Void) {
        guard let generation = session.beginFinishing() else {
            /*
            A second finish during the same drain must not complete twice.
            (A drain already running: this call is ignored. No session at all: the
            caller still gets one completion with the current words.)
            */
            if session.id == nil {
                completion(CompletedSegment(id: UUID(), features: aggregateCount > 0 ? aggregate : features, transcript: transcript))
            }
            return
        }
        finishCompletion = completion
        startupTask?.cancel()
        startupTask = nil
        demoTimer?.invalidate()
        demoTimer = nil
        stopEngineCapture()
        let wasRecording  = isRecording
        isRecording       = false
        permissionMessage = "finalizing"
        guard wasRecording || streamingPipeline?.requiresExplicitFinalization == true else {
            finishSegment(generation: generation)
            return
        }
        /*
        Two ways to end the drain, and the first one wins: the recognizer's final result,
        or this deadline (the delay kept between 0.1 and 3 s). finishSegment ends the
        session, so whichever comes second does nothing.
        */
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session.id == generation else { return }
            print("TTT_EVENT recognition_drain_deadline")
            /*
            Read the synchronized canonical state even if its queued UI
            publication has not run yet at the deadline.
            */
            if let result = self.streamingPipeline?.currentResult {
                let snapshot = result.snapshot
                self.timedWords      = snapshot.timedWords
                self.transcript      = snapshot.text
                self.stableWordCount = snapshot.stableWordCount
                if let failure = result.failure {
                    self.fail(failure, generation: generation)
                    return
                }
            }
            if self.streamingPipeline?.requiresExplicitFinalization == true {
                // Shut the late worker down before cleanup cancels the pipeline; a plain cancel
                // keeps it leased until its 25 s limit and the next talk fails as busy (build 81).
                (self.streamingPipeline as? AbandonableFinish)?.abandonFinish()
                self.fail("\(LocalSpeechModelName.current) did not finish in time. Your recognized words are kept for recovery; nothing was sent.", generation: generation)
                return
            }
            self.finishSegment(generation: generation, outcome: "deadline")
        }
        finishTimeout = timeout
        // An explicit-final engine bounds itself: Orukeet scales the final decode with
        // the undecoded audio (3 s + 0.2 s/s, at most 8 s per window) and adds any
        // model load still pending when the key was released (pre-roll).
        let budget = streamingPipeline?.requiresExplicitFinalization == true
            ? max(0.1, min(streamingPipeline?.finalizationTimeout ?? 30, 60))
            : max(0.1, min(delay, 3))
        DispatchQueue.main.asyncAfter(deadline: .now() + budget, execute: timeout)
        if let pipeline = streamingPipeline {
            pipeline.finish { [weak self] snapshot in
                guard let self, self.session.id == generation else { return }
                self.timedWords      = snapshot.timedWords
                self.transcript      = snapshot.text
                self.stableWordCount = snapshot.stableWordCount
                if let failure = pipeline.currentResult.failure {
                    self.fail(failure, generation: generation)
                    return
                }
                self.finishSegment(generation: generation)
            }
        } else {
            /*
            Older recognizer: its final result arrives in the recognitionTask callback in
            startLegacy, which then calls finishSegment. Demo mode has no recognizer.
            */
            speechRequest?.endAudio()
            speechTask?.finish()
            if demoMode { finishSegment(generation: generation) }
        }
    }

//
// :)
//
//
    // Completed segment — the delivery snapshot, the final segment, failure and cleanup


    /*
    Builds a segment from the words and pauses so far without changing any state; the
    talk keeps going. Thinking pauses: measured silence if there is any, else gaps between
    timed words, marked as estimates.
    */
    /// Synchronized recognized-text fallback for an independent delivery deadline.
    /// Never synthesizes words and never saves microphone samples.
    func deliverySnapshot() -> CompletedSegment {
        deliverySnapshot(canonical: streamingPipeline?.currentSnapshot)
    }

    /// One recognition revision supplies both the rendered preview and its stable
    /// prefix. Never pair a newer published word count with an older transcript.
    func stopStreamingSnapshot() -> (segment: CompletedSegment, stableText: String) {
        let canonical = streamingPipeline?.currentSnapshot
        let stable = canonical?.finalizedText
            ?? StagedPrompt.stablePrefix(transcript, wordCount: stableWordCount)
        return (deliverySnapshot(canonical: canonical), stable)
    }

    private func deliverySnapshot(canonical: TranscriptSnapshot?) -> CompletedSegment {
        var segment = CompletedSegment(id: UUID(), features: aggregateCount > 0 ? aggregate : features,
                                          transcript: canonical?.text ?? transcript)
        segment.requiresReview = legacyTranscript.hasAmbiguousReset
        segment.timedWords = canonical?.timedWords ?? timedWords
        let measured       = thinking.snapshot()
        Diagnostics.event(thinking.diagnosticSummary())
        segment.thinkingPauses = measured.pausesIncludingCurrent
        /*
        Acoustic silence remains authoritative when present. In a noisy
        room, expose timed recognition gaps explicitly as estimates.
        */
        if segment.thinkingPauses.isEmpty {
            let estimated = SpeechGapTiming.pauses(words: segment.timedWords, audioEnd: measured.clock)
            if !estimated.isEmpty {
                segment.thinkingPauses                   = estimated
                segment.thinkingPausesAreSpeechEstimates = true
            }
        }
        Diagnostics.event("pause_result estimated=\(segment.thinkingPausesAreSpeechEstimates) count=\(segment.thinkingPauses.count) timed_words=\(segment.timedWords.count)")
        var anchors = thinkingAnchors
        anchors.close(at: measured.clock)
        segment.thinkingAnchors = anchors
        return segment
    }


    /*
    Runs at most once per talk: it needs the finalizing phase and then ends the session,
    so a late recognizer result or deadline finds nothing to do. The completion is read
    before cleanup clears it, and called last, once all state is settled.
    */
    func finishSegment(generation: UUID, outcome: String = "final") {
        guard session.phase == .finalizing, session.end(generation) else { return }
        var segment = CompletedSegment(
            id: UUID(), features: aggregateCount > 0 ? aggregate : features, transcript: transcript
        )
        segment.requiresReview = legacyTranscript.hasAmbiguousReset
        segment.timedWords = timedWords
        let measured       = thinking.snapshot()
        Diagnostics.event(thinking.diagnosticSummary())
        segment.thinkingPauses = measured.pausesIncludingCurrent
        /*
        Acoustic silence remains authoritative when present. In a noisy
        room, expose timed recognition gaps explicitly as estimates.
        */
        if segment.thinkingPauses.isEmpty {
            let estimated = SpeechGapTiming.pauses(words: segment.timedWords, audioEnd: measured.clock)
            if !estimated.isEmpty {
                segment.thinkingPauses                   = estimated
                segment.thinkingPausesAreSpeechEstimates = true
            }
        }
        Diagnostics.event("pause_result estimated=\(segment.thinkingPausesAreSpeechEstimates) count=\(segment.thinkingPauses.count) timed_words=\(segment.timedWords.count)")
        thinkingAnchors.close(at: measured.clock)
        segment.thinkingAnchors = thinkingAnchors
        if let requested = stopRequestedAt {
            let elapsed = (ProcessInfo.processInfo.systemUptime - requested) * 1000
            let added   = transcript.split(whereSeparator: { $0.isWhitespace }).count - stopWordCount
            Diagnostics.event("stop_ready mode=\(stopDecision?.reason ?? "unknown") outcome=\(outcome) elapsed_ms=\(String(format: "%.1f", elapsed)) words_delta=\(added)")
            stopRequestedAt = nil
        }
        /*
        Hold the callback locally before cleanup clears the stored callback. Close this
        session first, clear its asynchronous work second, then notify the caller last.
        That caller may immediately begin another Talk session, so old cleanup must be done.
        */
        let completion = finishCompletion
        cleanupCapture()
        stableWordCount   = transcript.split(whereSeparator: { $0.isWhitespace }).count
        permissionMessage = ""
        completion?(segment)
    }

//
// :)
//
//
    /*
    Ends the talk with an error message and stops the hardware even if it is kept open.
    A pending finish completion is dropped, not called.
    */
    func fail(_ message: String, generation: UUID) {
        guard session.end(generation) else { return }
        // The canonical recognizer snapshot can be newer than queued UI updates.
        // Retain it before detaching/canceling so failure recovery never loses words.
        if let pipeline = streamingPipeline, pipeline.requiresExplicitFinalization {
            let snapshot = pipeline.currentResult.snapshot
            transcript = snapshot.text
            timedWords = snapshot.timedWords
            stableWordCount = snapshot.stableWordCount
        }
        stopEngineCapture(force: true)
        cleanupCapture()
        permissionMessage = message
        captureError      = message
    }


    /*
    Lets go of everything one talk holds: timers, the drain deadline, the recognizer and
    the tap consumer. It uses the non-forced stop, so a kept-open microphone keeps running.
    */
    private func cleanupCapture() {
        labCommandTimer?.invalidate()
        labCommandTimer = nil
        print("TTT_EVENT capture_stopped")
        voiceCommandsAvailable = false
        finishTimeout?.cancel()
        finishTimeout    = nil
        finishCompletion = nil
        startupTask?.cancel()
        startupTask = nil
        demoTimer?.invalidate()
        demoTimer = nil
        quiescenceDeadline?.cancel(); quiescenceDeadline = nil
        quiescingGeneration = nil
        let oldSpeechTask = speechTask
        let oldPipeline = streamingPipeline
        speechTask = nil; speechRequest = nil; streamingPipeline = nil
        // The owner detaches the sink before recognizer cancellation. A late cleanup
        // captures only this generation's recognizers, never a newer session's fields.
        stopEngineCapture {
            oldSpeechTask?.cancel()
            oldPipeline?.cancel()
        }
        isRecording       = false
        hasReceivedAudio  = false
        speechModelLoading = false
        inputMeter        = InputMeter()
        inputLevel        = 0
        liveCandidate     = .silence
        isSignalActive    = false
    }


}

