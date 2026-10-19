


//
/*
ThinkingStream+Execution.swift

Owns: Lane scheduling, streaming callbacks, cancellation, and throttled publication.
Never: Persist streamed text or contact a remote model; delivery only receives validated metadata.
See: Sources/Tokens/LocalModel/ThinkingStream.swift and the related responsibility files below.
Related: ThinkingStream.swift
         ThinkingStream+Session.swift
         ThinkingStream+Content.swift
Port provenance: Sources/System/TokensThinkingStream.swift, donor 2ac14df.
*/


import Combine
import Foundation


extension TokensThinkingStream {


    // Scheduling — lane availability, and when each lane may start


    func model(for lane: TokensThinkingLane) -> String { lane == .questions ? tuning.questionsModel : tuning.reflectionModel }


    /*
    Re-derives each lane's "unavailable" label from availability, installed models and failures, and clears
    it once it no longer applies. A lane's text and its other states are left alone.
    */
    func refreshLaneAvailability() {
        for lane in TokensThinkingLane.allCases {
            if lane == .reflection && !tuning.reflectionEnabled { continue }
            var shown = output(lane)
            if let reason = unavailableReason(lane) { shown.state = .unavailable(reason) }
            else if case .unavailable = shown.state { shown.state = .idle }
            publish(lane, shown)
        }
    }


    /*
    Why a lane may not run right now: Ollama is off, its model is not installed, or it paused after too many
    failures in a row. nil while still checking, or when the lane is fine.
    */
    private func unavailableReason(_ lane: TokensThinkingLane) -> String? {
        switch availability {
        case .unknown, .checking: return nil
        case .ollamaOff:          return "Ollama off"
        case .ready:
            if !installed.contains(model(for: lane)) { return "\(model(for: lane)) not installed" }
            if (runtime[lane]?.failures ?? 0) >= tuning.maximumFailuresPerSession { return "Paused after \(tuning.maximumFailuresPerSession) failures" }
            return nil
        }
    }


    /*
    Arms one delayed start of the reflection lane; does nothing if one is already armed or running. The wait
    is reflectionDelay, or longer when the last reflection began less than reflectionMinimumInterval ago.
    When it fires it checks that the pause is still on and the session still open, then starts with the
    NEWEST transcript (latestTranscript), not the one seen when it was armed.
    */
    func scheduleReflection() {
        guard tuning.reflectionEnabled, reflectionTimer == nil, runtime[.reflection]?.job == nil else { return }
        // The minimum interval postpones a reflection; it never costs a long pause its reflection.
        var delay = tuning.reflectionDelay
        if let last = runtime[.reflection]?.lastStart { delay = max(delay, last + tuning.reflectionMinimumInterval - clock()) }
        reflectionTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
            guard let self else { return }
            self.reflectionTimer = nil
            guard self.isThinking, self.sessionOpen else { return }
            self.start(.reflection, transcript: self.latestTranscript)
        }
    }

//
// :)
//
//
    /*
    Decides whether a lane may start a new request for this transcript. Both lanes need Ollama ready and no
    "unavailable" reason.
     - questions: enough words; not the same words it already completed; not the text already being streamed.
     - reflection: enough words; no reflection already running; at least reflectionMinimumInterval since the
       last start; and, after a first one, at least reflectionNewWords new words, so a repeat pause with
       nothing new says nothing.
    */
    private func eligible(_ lane: TokensThinkingLane, transcript: String, words: Int) -> Bool {
        if lane == .reflection && !tuning.reflectionEnabled { return false }
        guard let state = runtime[lane], unavailableReason(lane) == nil, availability == .ready else { return false }
        let normalized = Self.normalized(transcript)
        switch lane {
        case .questions:
            // Re-stream on every pause with new words; the same words never re-run.
            return words >= tuning.questionsMinimumWords && normalized != state.completedSource
                && !(state.job != nil && normalized == Self.normalized(state.source))
                && (state.askedWords == 0 || words - state.askedWords >= tuning.questionsNewWords)
        case .reflection:
            guard words >= tuning.reflectionMinimumWords, state.job == nil else { return false }
            if let last = state.lastStart, clock() - last < tuning.reflectionMinimumInterval { return false }
            return state.completedWords == 0 || words - state.completedWords >= tuning.reflectionNewWords
        }
    }


    // Running a lane — start the request, then receive its pieces


    /*
    Starts (or restarts) one lane for this transcript, if eligible() allows. The lane's previous request is
    cancelled with its text kept, per-request state is reset, and the lane shows "waiting" without clearing
    the text already on screen. Only the last questionsInputCharacters or reflectionInputCharacters of the
    transcript are sent.
    */
    func start(_ lane: TokensThinkingLane, transcript: String) {
        let words = Self.wordCount(transcript)
        guard eligible(lane, transcript: transcript, words: words) else { return }
        /*
        A running request for this lane is cancelled first. keep: true leaves its complete lines on screen
        until the new answer's first validated text replaces them.
        */
        cancel(lane, keep: true)
        var state       = runtime[lane]!
        state.epoch     = UUID(); state.raw = ""; state.receivedDelta = false; state.bumped = false
        state.source    = transcript
        state.lastStart = clock()
        state.shown     = output(lane)
        /*
        `token` is this request's identity: receive() and finish() ignore any callback whose epoch no longer
        matches (cancelled or replaced).
        */
        let token     = state.epoch
        runtime[lane] = state
        var shown     = output(lane); shown.state = .waiting
        publish(lane, shown)
        let messages = Self.messages(lane, transcript: String(transcript.suffix(
            lane == .questions ? tuning.questionsInputCharacters : tuning.reflectionInputCharacters)), previousQuestions: recentQuestions)
        let provider  = self.provider, model = model(for: lane), started = clock()
        let maxTokens = lane == .questions ? tuning.questionsMaxTokens : tuning.reflectionMaxTokens
        let timeout   = lane == .questions ? tuning.questionsTimeout : tuning.reflectionTimeout
        /*
        The task streams on the main actor. Each piece goes to receive(); the end, clean or with an error,
        goes to finish(). Both are guarded by `token`.
        */
        runtime[lane]?.job = Task { @MainActor [weak self] in
            do {
                try await provider.stream(lane: lane, model: model, messages: messages, maxTokens: maxTokens,
                                          timeout: timeout) { [weak self] delta in
                    self?.receive(delta, lane: lane, token: token, started: started)
                }
                self?.finish(lane, token: token, error: nil)
            } catch {
                self?.finish(lane, token: token, error: error)
            }
        }
    }

//
// :)
//
//
    /*
    One piece of streamed text arrives. A piece from a request that was cancelled or replaced is dropped (the
    epoch and job checks). The first piece also logs a time-to-first-token event (milliseconds only). Pieces
    are added to `raw` and published at most once per publishInterval: now, or by one delayed flush.
    */
    private func receive(_ delta: String, lane: TokensThinkingLane, token: UUID, started: TimeInterval) {
        guard var state = runtime[lane], state.epoch == token, state.job != nil else { return } // late or cancelled
        if !state.receivedDelta { onEvent?("thinking_stream_first_token lane=\(lane.rawValue) ms=\(Int((clock() - started) * 1000))") }
        state.receivedDelta = true
        state.raw += delta
        runtime[lane] = state
        let now       = clock()
        /*
        Throttle: publish now if the last flush was at least publishInterval ago. Otherwise schedule one
        delayed flush; flushScheduled stops several from stacking up.
        */
        if now - state.lastFlush >= tuning.publishInterval { flush(lane, token: token) }
        else if !state.flushScheduled {
            runtime[lane]?.flushScheduled = true
            let wait = max(0, tuning.publishInterval - (now - state.lastFlush))
            // If the request ended before this fires, flush() sees a different epoch and does nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard self?.runtime[lane]?.epoch == token,
                      self?.runtime[lane]?.job != nil else { return }
                self?.runtime[lane]?.flushScheduled = false
                self?.flush(lane, token: token)
            }
        }
    }


    // Showing and finishing — flush, absorb, finish, cancel and publish


    /*
    Turns the raw text so far into what the screen shows. display() keeps only lines that pass the grounding
    checks, so unchecked model text never reaches the panel. The reflection lane also hands its TITLE and
    SUMMARY lines to absorb().
    */
    private func flush(_ lane: TokensThinkingLane, token: UUID, final: Bool = false) {
        guard let state = runtime[lane], state.epoch == token, state.job != nil else { return }
        runtime[lane]?.lastFlush = clock()
        let parsed = Self.display(lane, raw: state.raw, source: state.source, final: final)
        if lane == .reflection { absorb(parsed, source: state.source) }
        if lane == .questions {
            /*
            Only terminated lines enter repeat-avoidance context during streaming. A cancelled
            partial must not suppress the same question when its set resumes.
            */
            let complete = Self.display(lane, raw: state.raw, source: state.source, final: final,
                                        completeLinesOnly: !final).text
            rememberQuestions(complete)
        }
        // Zero flicker: nothing validated yet keeps the previous answer on screen.
        guard !parsed.text.isEmpty else { return }
        var shown = output(lane)
        /*
        The first validated text of a new answer advances `generation` once; the panel uses that to crossfade
        to the new answer.
        */
        if !state.bumped { shown.generation = state.shown.generation + 1; runtime[lane]?.bumped = true }
        shown.text        = parsed.text
        shown.state       = final ? .done : .streaming
        shown.sourceWords = Self.wordCount(state.source)
        publish(lane, shown)
    }


    /*
    Keeps the newest grounded title and summary from the reflection. Both remember how many words of the
    transcript the model actually read (at most the last reflectionInputCharacters characters), so they can
    be refused later if that was too little of the final talk (see title(coveringFinalTranscript:) and
    headerNotes).
    */
    private func absorb(_ parsed: (text: String, title: String?, summary: String?), source: String) {
        if let candidate = parsed.title, let clean = ThinkingTitle.sanitize(candidate, transcript: source) {
            title            = clean
            titleSourceWords = Self.wordCount(String(source.suffix(tuning.reflectionInputCharacters)))
        }
        if let line = parsed.summary {
            // Coverage is what the model actually read, not the whole dictation.
            summary = Summary(text: line, model: tuning.reflectionModel,
                              sourceWords: Self.wordCount(String(source.suffix(tuning.reflectionInputCharacters))))
        }
    }

//
// :)
//
//
    /*
    A request ended, cleanly (error nil) or not. A stale token (cancelled or replaced) is ignored first.
     - Clean: flush once more as final, remember the words as answered, and count a failure if nothing usable
       came out (a usable answer resets the count).
     - Error other than cancellation: count a failure, fall back to the earlier text and show "No answer".
     - A cancelled request normally never gets this far: cancel() changed the epoch, so the guard above
       ignores it. A CancellationError that does arrive is not counted as a failure.
    Last, the lane is freed (no job, new epoch) and a reflection may be armed again if the pause is still on.
    */
    private func finish(_ lane: TokensThinkingLane, token: UUID, error: Error?) {
        guard let state = runtime[lane], state.epoch == token else { return }
        if error == nil {
            flush(lane, token: token, final: true)
            if lane == .questions {
                let accepted = Self.display(lane, raw: state.raw, source: state.source, final: true).text
                if !accepted.isEmpty { runtime[lane]?.askedWords = Self.wordCount(state.source) }
            }
            // Either way these words have had their answer: they are not sent again.
            runtime[lane]?.completedSource = Self.normalized(state.source)
            runtime[lane]?.completedWords = Self.wordCount(state.source)
            if Self.display(lane, raw: state.raw, source: state.source, final: true).text.isEmpty {
                runtime[lane]?.failures += 1
                fallBack(lane, to: .failed("No usable answer from \(model(for: lane))"))
                refreshLaneAvailability()
            } else {
                runtime[lane]?.failures = 0
            }
            onEvent?("thinking_stream_done lane=\(lane.rawValue) chars=\(state.raw.count)")
        } else if !(error is CancellationError) {
            runtime[lane]?.failures += 1
            fallBack(lane, to: .failed("No answer from \(model(for: lane))"))
            onEvent?("thinking_stream_failed lane=\(lane.rawValue) failures=\(runtime[lane]?.failures ?? 0)")
            refreshLaneAvailability()
        }
        runtime[lane]?.job = nil
        runtime[lane]?.epoch = UUID()
        /*
        A reflection that finished while the speaker is still paused, with
        enough new words since its source, may run once more.
        */
        if lane == .reflection, tuning.reflectionEnabled, isThinking, sessionOpen { scheduleReflection() }
    }


    /// Cancelled or failed: complete lines of the partial answer, else the previous answer.
    private func fallBack(_ lane: TokensThinkingLane, to state: TokensThinkingLaneOutput.State) {
        guard let run = runtime[lane] else { return }
        let complete = Self.display(lane, raw: run.raw, source: run.source, final: false, completeLinesOnly: true).text
        if lane == .questions { rememberQuestions(complete) }
        var shown = complete.isEmpty ? run.shown : output(lane)
        if !complete.isEmpty {
            if !run.bumped { shown.generation = run.shown.generation + 1 }
            shown.text        = complete
            shown.sourceWords = Self.wordCount(run.source)
        }
        shown.state = state
        publish(lane, shown)
    }


    /// A bounded, case-insensitive context of complete questions, including interrupted sets.
    /// This is model context only; the panel owns its visible session history separately.
    private func rememberQuestions(_ text: String) {
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard !recentQuestions.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else { continue }
            recentQuestions.append(line)
        }
        recentQuestions = Array(recentQuestions.suffix(9))
    }


    /*
    Stops one lane's request; does nothing if the lane is not running. The new epoch makes any callback still
    in flight from that request a no-op. keep: true leaves the complete lines on screen (state .kept); keep:
    false skips that, because begin() clears the lanes itself.
    */
    func cancel(_ lane: TokensThinkingLane, keep: Bool) {
        guard let run = runtime[lane], run.job != nil else { return }
        run.job?.cancel()
        if keep { fallBack(lane, to: .kept) }
        runtime[lane]?.job = nil
        runtime[lane]?.epoch = UUID()
    }

//
// :)
//
//
    func cancelAll(keep: Bool) {
        reflectionTimer?.cancel(); reflectionTimer = nil
        for lane in TokensThinkingLane.allCases { cancel(lane, keep: keep) }
    }


    // Assigns only when the value really changed, so SwiftUI is not told about identical updates.
    func publish(_ lane: TokensThinkingLane, _ value: TokensThinkingLaneOutput) {
        if lane == .questions { if questions != value { questions = value } }
        else if reflection != value { reflection = value }
    }


}

