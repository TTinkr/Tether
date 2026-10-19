


//
/*
TokenPauseAsides+Requests.swift

Owns: Talk entry points, bounded live/final requests, cancellation, and deadline handling.
Never: Delay delivery, collect telemetry, or contact anything beyond loopback Ollama.
See: Sources/Tokens/LocalModel/TokenPauseAsides.swift and the related responsibility files below.
Related: TokenPauseAsides.swift
         TokenPauseAsides+Content.swift
Port provenance: Sources/System/TTTTinkering.swift, donor 2ac14df.
*/


import Combine
import Foundation


extension TokenPauseAsides {


    // Entry points — begin, reset, discard, observe during the talk, prepareFinal after it


    /*
    Opens a talk. Earlier work is cancelled, all per-talk text is cleared, and live requests are allowed.
    `sessionID` ties the audit records to the talk.
    */
    func begin(sessionID: UUID? = nil) {
        cancelPending(clearDisplay: false)
        auditSession = sessionID ?? UUID(); generationCount = 0
        completed = []; lastCompletedDisplay = ""; recentWorkspaceResponses = []; workspaceSource = ""; modelLabel = ""; currentText = ""; lastAttempt = nil; active = true; sessionOpen = true; finalRequested = false
        status = "Waiting for your words"
    }
    // Back to idle: clears like begin(), then switches live requests and the session off.
    func reset() { begin(); active = false; sessionOpen = false; status = "No completed reflection" }


    /// Ambient context has no history: explicitly clear its in-memory output too.
    func discard() {
        reset()
        cancelPending(clearDisplay: true)
        completed = []
    }


    /// Call during active Tokens capture, including while speech is continuing.
    /// pauseSeconds remains source-compatible; generation follows a monotonic
    /// five-second cadence, not pause boundaries. Empty context never requests.
    func observe(pauseSeconds: Double?, transcript: String) {
        guard active, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              job == nil else { return }
        /*
        At most one live request at a time (job == nil) and at least 5 s between starts, measured on the
        injected clock.
        */
        let now = clock()
        guard lastAttempt.map({ now - $0 >= 5 }) ?? true else { return }
        lastAttempt = now
        launch(transcript: transcript, provider: provider, budget: deadline, final: false)
    }


    /// Call once after capture stops, while the App's bounded delivery timer runs.
    /// This freezes input and never waits; stop() at the App deadline cancels it.
    /// A completed live fallback is retained only if its numbers fit frozen input.
    func prepareFinal(transcript: String, deadline: TimeInterval = 4.3) {
        guard sessionOpen, !finalRequested else { return }
        /*
        From here no more live requests are made; the final request runs once. A live request still running
        is cancelled.
        */
        finalRequested = true; active = false
        cancelPending(clearDisplay: false)
        /*
        A completed live aside is kept as a fallback only if every number in it appears in the frozen final
        transcript.
        */
        completed = completed.filter { Self.preservesNumbers($0.text, source: transcript) }
        /*
        Nothing to refine (blank text, or no time left): no final request, and the earlier aside, if any,
        stays.
        */
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deadline.isFinite, deadline > 0 else {
            status = "No final refinement requested"
            return
        }
        launch(transcript: transcript, provider: finalProvider, budget: min(4.3, deadline), final: true)
    }

//
// :)
//
//
    // Running a request — launch, stop, fail, cancelPending


    /*
    Starts one request, live or final. In order:
     1. Earlier work is cancelled, the transcript is cut to its last 900 characters (live) or 6,000 (final),
        and an audit record is opened.
     2. A deadline timer starts. If this request is still the current one when it fires, the run fails with
        "timed out".
     3. The job asks Ollama which model is present, checks that time is left, and streams. Pieces update
        `currentText` as they arrive: table text as is (up to the output cap); summary text only once it
        passes validated() and keeps the speaker's numbers.
     4. At the end the full text must pass the strict checks for its mode. Only then is it stored as the
        completed aside.
    Every callback compares `epoch` with `token`, so a request that was cancelled or replaced can no longer
    change anything.
    */
    private func launch(transcript: String, provider: any TokenPauseProvider,
                        budget: TimeInterval, final: Bool) {
        let transcript = String(transcript.suffix(final ? 6000 : 900))
        cancelPending(clearDisplay: false)
        status = final ? "Refining summary…" : "Checking Ollama…"
        if provider.structuredWorkspace { workspaceSource = transcript }
        let token   = epoch
        let started = ProcessInfo.processInfo.systemUptime
        generationCount += 1
        inflight = Inflight(generation: generationCount, kind: final ? .final : .live, source: transcript,
                            budget: budget, maxTokens: 0, promptVersion: provider.promptVersion)
        // Deadline timer. If this request is still current when it fires, the run fails as "timed out".
        timer = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000)) } catch { return }
            if self.epoch == token { self.fail("Local model timed out") }
        }
        job = Task { @MainActor [weak self] in
            let presence = await provider.resolvePresence()
            /*
            Stale-result guard: the presence check took time, and this request may have been replaced
            meanwhile.
            */
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            self.ollamaPresence = presence
            guard let model = presence.model else { self.fail("Local model unavailable · raw words still paste"); return }
            /*
            Time left is the budget minus what the presence check already used. None left counts as a
            timeout.
            */
            let remaining = budget - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { self.fail("Local model timed out"); return }
            // The model name is cut down to safe characters before it is shown or recorded.
            self.modelLabel = String(model.filter { $0.isLetter || $0.isNumber || ":.-_/".contains($0) }.prefix(80))
            self.inflight?.model = self.modelLabel
            self.inflight?.maxTokens = provider.maxTokens(for: remaining)
            var output = ""
            do {
                try await provider.stream(transcript: transcript, model: model, timeout: remaining) { [weak self] delta in
                    /*
                    Each piece is dropped if the request is no longer current. Otherwise it extends `output`
                    and updates the audit record and the screen text.
                    */
                    guard let self, self.epoch == token else { return }
                    output += delta
                    self.status = final ? "Streaming summary…" : "Streaming table…"
                    self.inflight?.output = output
                    if provider.structuredWorkspace {
                        if output.count <= ThoughtsPrompt.maximumOutputCharacters { self.currentText = output }
                    } else if let visible = Self.validated(output), Self.preservesNumbers(visible, source: transcript) { self.currentText = visible }
                }
                /*
                stream() returns normally only after a clean finish. Check again that this request is still
                current.
                */
                guard self.epoch == token, !Task.isCancelled else { return }
                /*
                Accepted only if the time budget was not used up AND the text passes the checks for its mode:
                table, validatedWorkspace; final summary, UsefulSummary.validated; other live text,
                validated. Everything except the table also has to keep the speaker's numbers. The table
                skips that here because TinkeringDocument.parse, just below, requires every quote to be found
                in the transcript.
                */
                guard ProcessInfo.processInfo.systemUptime - started < budget,
                      let text = provider.structuredWorkspace ? Self.validatedWorkspace(output)
                          : (final ? UsefulSummary.validated(output, source: transcript) : Self.validated(output)),
                      (provider.structuredWorkspace || Self.preservesNumbers(text, source: transcript)) else {
                    self.fail("No usable local-model response"); return
                }
                /*
                The appendix is the text kept as the aside. For the table it is the numbered rows that
                survived parse(). Empty means nothing was grounded, so the run fails.
                */
                let appendix = provider.structuredWorkspace
                    ? TinkeringDocument.parse(text, source: transcript).appendixText : text
                guard !appendix.isEmpty else { self.fail("No grounded local-model response"); return }
                /*
                Only now is the result stored: `completed` (what delivery can use), currentText and
                lastCompletedDisplay (what the panel shows), and the newest three table snapshots.
                */
                self.completed            = [Aside(text: appendix, model: self.modelLabel)]
                self.currentText          = text
                self.lastCompletedDisplay = text
                if provider.structuredWorkspace {
                    self.recentWorkspaceResponses.insert(WorkspaceSnapshot(text: text, source: transcript), at: 0)
                    self.recentWorkspaceResponses = Array(self.recentWorkspaceResponses.prefix(3))
                }
                self.status = "Latest completed reflection"
                // Write the audit record, stop the timer and free the slot.
                self.terminate(.completed, "stream finished with stop")
                self.timer?.cancel(); self.timer = nil; self.job = nil
            } catch {
                /*
                A throw (Ollama not running, a bad or cut-off stream) fails the run, but only if this request
                is still current.
                */
                if self.epoch == token { self.fail("Local model unavailable · raw words still paste") }
            }
        }
    }

//
// :)
//
//
    /// Synchronous: delivery never waits for generation; returns only the latest
    /// completed reflection, even if its replacement failed or was cancelled.
    @discardableResult func stop() -> [Aside] {
        active = false; sessionOpen = false; cancelPending(clearDisplay: false)
        status = completed.isEmpty ? "No completed reflection" : "Latest completed reflection"
        return completed
    }
    /*
    Ends the current run as failed: audit it as deadline (reason contains "timed out") or discarded, cancel
    what is left, and set the status. If an earlier aside exists, its text and model name go back on screen.
    */
    private func fail(_ reason: String) {
        terminate(reason.contains("timed out") ? .deadline : .discarded, reason)
        cancelPending(clearDisplay: false)
        status = reason + (completed.isEmpty ? " · no completed reflection" : " · previous reflection retained")
        if let latest = completed.last {
            currentText = lastCompletedDisplay.isEmpty ? latest.text : lastCompletedDisplay
            modelLabel  = latest.model
        }
    }
    /*
    Cancels the running request and its timer and files an audit record as cancelled if one was open. The new
    epoch makes every callback still in flight from the old request do nothing.
    */
    private func cancelPending(clearDisplay: Bool = true) {
        terminate(.cancelled, "superseded, stopped or reset")
        epoch = UUID(); job?.cancel(); timer?.cancel(); job = nil; timer = nil
        if clearDisplay { currentText = ""; modelLabel = "" }
    }


}

