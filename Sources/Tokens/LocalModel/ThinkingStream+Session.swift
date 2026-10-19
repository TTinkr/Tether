


//
/*
ThinkingStream+Session.swift

Owns: Talk lifetime, pause transitions, and grounded title/header handoff.
Never: Persist streamed text or contact a remote model; delivery only receives validated metadata.
See: Sources/Tokens/LocalModel/ThinkingStream.swift and the related responsibility files below.
Related: ThinkingStream.swift
         ThinkingStream+Execution.swift
         ThinkingStream+Content.swift
Port provenance: Sources/System/TokensThinkingStream.swift, donor 2ac14df.
*/


import Combine
import Foundation


extension TokensThinkingStream {


    // Session — begin, prewarm, end


    /// New capture: clears every lane, title and summary, then warms enabled models.
    func begin() {
        /*
        Cancel anything left from the previous talk first, without keeping its text, so each talk starts
        clean.
        */
        cancelAll(keep: false)
        presence.reset()
        isThinking = false; title = nil; titleSourceWords = 0; summary = nil; latestTranscript = ""
        // A fresh Runtime for each lane (new epoch, no history), and the lanes go back to empty text.
        for lane in TokensThinkingLane.allCases {
            runtime[lane] = Runtime()
            publish(lane, TokensThinkingLaneOutput(model: model(for: lane)))
        }
        recentQuestions  = []
        sessionOpen      = true
        soundInterrupted = false
        prewarm()
    }


    /// Probes /api/tags (2 s) and loads enabled lane models without generating.
    /// Idempotent; an unreachable Ollama is re-probed at most every reprobeInterval.
    func prewarm() {
        let now = clock()
        // A probe is already in flight: do nothing, so calling prewarm() repeatedly is safe.
        if availability == .checking { return }
        /*
        Ollama was unreachable and was probed less than reprobeInterval ago: do not probe again yet, only
        refresh what the lanes show.
        */
        if availability == .ollamaOff, let last = lastProbe, now - last < tuning.reprobeInterval { refreshLaneAvailability(); return }
        // Probed successfully within the last 300 s: skip the probe and warm enabled installed models.
        if availability == .ready, let last = lastProbe, now - last < 300 {
            /*
            Cheap when the runner is resident with num_ctx 2048; absorbs the
            stop-time num_ctx 4096 reload left by the final summary pass.
            */
            refreshLaneAvailability()
            let provider = self.provider
            let names    = enabledModels.filter(installed.contains)
            Task { @MainActor in for name in names { await provider.warm(model: name) } }
            return
        }
        /*
        Full probe. lastProbe is set and availability becomes .checking before the await, which blocks a
        second probe until the answer arrives.
        */
        lastProbe    = now
        availability = .checking
        let provider = self.provider
        let wanted   = enabledModels
        Task { @MainActor [weak self] in
            let models = await provider.installedModels()
            guard let self else { return }
            self.installed    = models ?? []
            self.availability = models == nil ? .ollamaOff : .ready
            self.refreshLaneAvailability()
            self.onEvent?("thinking_stream_probe ready=\(models != nil) questions=\(self.installed.contains(self.tuning.questionsModel)) reflection=\(self.tuning.reflectionEnabled && self.installed.contains(self.tuning.reflectionModel))")
            // Load each installed lane model so the first real request does not wait for it to load.
            for name in wanted where self.installed.contains(name) { await provider.warm(model: name) }
        }
    }

//
// :)
//
//
    private var enabledModels: [String] {
        tuning.reflectionEnabled ? [tuning.questionsModel, tuning.reflectionModel] : [tuning.questionsModel]
    }


    /// Stop, discard or product switch. Idempotent; cancels at once and keeps
    /// the shown text, title and summary until the next begin().
    func end() {
        guard sessionOpen || isThinking || runtime.values.contains(where: { $0.job != nil }) else { return }
        sessionOpen = false
        presence.reset()
        isThinking = false
        cancelAll(keep: true)
    }


    // Thinking pause — watch the talk, then start or stop the lanes


    /// One call per analysed buffer while capturing. Drives the sticky
    /// presence and, on its transitions, pauseBegan / speechResumed.
    func observe(pauseSeconds: Double?, estimated: Bool, rmsDB: Double, transcript: String, host: TimeInterval) {
        guard sessionOpen else { return }
        latestTranscript = transcript
        /*
        Keep UI presence stable through noise, but stop generation immediately.
        The displayed "thinking" state and the lanes are separate. ThinkingPresence keeps the display until
        speech has clearly resumed, but speech-level sound cancels the lanes at once. soundInterrupted
        remembers that, so when a full second of silence returns the lanes start again for the same held
        pause.
        */
        if isThinking, presence.isSpeechLevel(rmsDB) {
            soundInterrupted = true
            cancelAll(keep: true)
        } else if soundInterrupted, isThinking, let pauseSeconds, pauseSeconds >= 1 {
            soundInterrupted = false
            pauseBegan(transcript: transcript)
        }
        /*
        Let the presence tracker see this buffer. Its transitions are the official start and end of a
        thinking pause: .entered calls pauseBegan(), .released calls speechResumed().
        */
        switch presence.observe(pauseSeconds: pauseSeconds, estimated: estimated, rmsDB: rmsDB,
                                words: Self.wordCount(transcript), host: host) {
        case .entered?:  pauseBegan(transcript: transcript)
        case .released?: speechResumed()
        case nil:        break
        }
    }


    /// The speaker has fully stopped (sticky presence entered).
    func pauseBegan(transcript: String) {
        // A stop before anything was said is not a thinking pause: there is nothing to think about yet.
        guard sessionOpen, Self.wordCount(transcript) >= tuning.questionsMinimumWords else { return }
        latestTranscript = transcript
        isThinking       = true
        // Questions start at once; the legacy reflection lane is opt-in.
        start(.questions, transcript: transcript)
        if tuning.reflectionEnabled { scheduleReflection() }
    }


    /// Speech resumed: both lanes cancel, including a reflection already writing.
    func speechResumed() {
        isThinking = false
        reflectionTimer?.cancel(); reflectionTimer = nil
        cancel(.questions, keep: true)
        cancel(.reflection, keep: true)
    }


    // Handing results to delivery — title and header notes, for the presented copy only


    /// The reflection's title, offered only when the reflection had read most of the final words;
    /// a title from an early pause must not outrank fresher ones for the rest of a long dictation.
    func title(coveringFinalTranscript finalTranscript: String) -> String? {
        let words = Self.wordCount(finalTranscript)
        // The reflection must have read at least 70% of the words in the final text.
        guard let title, words > 0, Double(titleSourceWords) >= 0.7 * Double(words) else { return nil }
        return title
    }

//
// :)
//
//
    /// The reflection's SUMMARY as one AI-labelled header line, only when it
    /// covered most of the final words and invents no number. Never `faithful`.
    func headerNotes(finalTranscript: String) -> [String] {
        guard let summary else { return [] }
        let words = Self.wordCount(finalTranscript)
        /*
        The summary becomes a header note only if it read at least 70% of the final words, adds no number the
        speaker did not say (preservesNumbers), and is mostly made of spoken words with no new names
        (ThinkingTitle.mostlySpoken). Otherwise there is no note.
        */
        guard words > 0, Double(summary.sourceWords) >= 0.7 * Double(words),
              TokenPauseAsides.preservesNumbers(summary.text, source: finalTranscript),
              ThinkingTitle.mostlySpoken(summary.text, transcript: finalTranscript) else { return [] }
        return [ThinkingHeaderNote.line(label: "AI summary · \(summary.model) · may be inaccurate", text: summary.text)].compactMap { $0 }
    }


}

