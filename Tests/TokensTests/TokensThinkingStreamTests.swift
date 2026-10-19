


//
import Combine
import Foundation
import Testing
@testable import Tokens

@MainActor final class FakeThinking: TokensThinkingProvider {
    var installed: Set<String>?              = ["qwen3.5:0.8b", "qwen3.5:4b"]
    var calls: [TokensThinkingLane: Int]     = [.questions: 0, .reflection: 0]
    var cancelled: [TokensThinkingLane: Int] = [.questions: 0, .reflection: 0]
    var outputs: [TokensThinkingLane: String] = [
        .questions: "Who draws the pencil lane?\nShould the panel shrink tiny?\nWhen should the temple panel shrink?\n",
        .reflection: "TITLE: Temple panel pencil lane\nSUMMARY: Building a temple panel with a pencil lane that can shrink tiny.\n- Open: who draws the pencil lane.\n- Settled: the panel can shrink tiny.\n"]
    var firstDelay: [TokensThinkingLane: UInt64] = [.questions: 0, .reflection: 0]
    var chunkDelay: UInt64 = 2_000_000
    var fail: Set<TokensThinkingLane> = []
    var warmed: [String] = []
    var lastMessages: [[String: String]] = []
    var onFirstDelta: ((TokensThinkingLane) -> Void)?
    func installedModels() async -> Set<String>? { installed }
    func warm(model: String) async { warmed.append(model) }
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]], maxTokens: Int,
                timeout: TimeInterval, onDelta: @escaping @MainActor (String) -> Void) async throws {
        calls[lane, default: 0] += 1
        lastMessages = messages
        do {
            try await Task.sleep(nanoseconds: firstDelay[lane] ?? 0)
            if fail.contains(lane) { throw URLError(.cannotConnectToHost) }
            let text = outputs[lane] ?? ""
            var i    = text.startIndex
            while i < text.endIndex {
                let j = text.index(i, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                let first = i == text.startIndex
                onDelta(String(text[i..<j])); i = j
                if first { onFirstDelta?(lane) }
                try await Task.sleep(nanoseconds: chunkDelay)
            }
        } catch is CancellationError {
            cancelled[lane, default: 0] += 1
            onDelta("LATE delta after cancel") // misbehaving provider
            throw CancellationError()
        }
    }
}

@Suite(.serialized) struct TokensThinkingStreamTests {
    @MainActor static func wait(_ ms: UInt64 = 80) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    /// Bounded event wait, independent of CI timer resolution and actor scheduling latency.
    @MainActor static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            await wait(5)
        }
        return true
    }

    @Test @MainActor static func run() async {
        // MARK: presence (pure)
        var p = ThinkingPresence()
        var host = 100.0
        var transitions: [ThinkingPresence.Transition] = []
        func tick(_ pause: Double?, _ db: Double, words: Int, estimated: Bool = false) {
            if let t = p.observe(pauseSeconds: pause, estimated: estimated, rmsDB: db, words: words, host: host) { transitions.append(t) }
            host += 0.1
        }
        for _ in 0..<10 { tick(nil, -25, words: 10) }                      // speaking
        var quiet = 0.0
        for _ in 0..<9 { quiet += 0.1; tick(quiet >= 0.35 ? quiet : nil, -70, words: 10) }
        precondition(transitions.isEmpty, "entered before 1.0 s")
        tick(1.0, -70, words: 10)
        precondition(transitions == [.entered] && p.isThinking && !p.approximate)
        let before = p.display(at: host)!.seconds
        tick(nil, -30, words: 10)                                           // 0.1 s cough
        for _ in 0..<5 { tick(nil, -70, words: 10) }                        // tracker's 0.35 s regate: pause nil
        precondition(transitions == [.entered] && p.isThinking && p.approximate, "cough released")
        precondition(p.display(at: host)!.seconds > before + 0.5, "counter restarted")
        for i in 0..<30 { tick(nil, i.isMultiple(of: 2) ? -49 : -47, words: 10) } // room floor in the -48 dead band, no pause reported
        precondition(transitions == [.entered], "dead-band flicker")
        for _ in 0..<20 { tick(1.5, -70, words: 10) }                       // 2 s of quiet: the room noise is forgotten
        for i in 0..<3 { tick(nil, -22, words: 11 + i) }                    // 0.3 s speech, 3 words: not yet
        precondition(p.isThinking)
        for _ in 0..<3 { tick(nil, -22, words: 14) }
        precondition(transitions == [.entered, .released] && !p.isThinking && p.display(at: host) == nil)
        print("PASS presence: enter at 1.0 s, cough and -48 dead band held, counter continuous, speech+words releases")

        // late recognition during quiet is not new speech; long unrecognized sound ends a measured hold
        transitions = []; p.reset()
        tick(1.1, -70, words: 20)
        tick(1.2, -70, words: 25)                                           // late words while quiet
        for _ in 0..<6 { tick(nil, -25, words: 25) }
        precondition(transitions == [.entered], "late words + short sound released")
        for _ in 0..<12 { tick(nil, -25, words: 25) }
        precondition(transitions == [.entered, .released], "1.5 s unrecognized sound kept Thinking")
        // soft speech with words still releases through the quietDB run
        transitions = []; p.reset()
        tick(1.1, -70, words: 40)
        for i in 0..<6 { tick(nil, -45, words: 40 + i) }
        precondition(transitions == [.entered, .released], "soft resumed speech stuck in Thinking")
        // estimated entry in a loud room: sound is everywhere, only 2+ new words release
        transitions = []; p.reset()
        tick(1.3, -40, words: 30, estimated: true)
        for _ in 0..<30 { tick(nil, -40, words: 31) }
        precondition(transitions == [.entered] && p.approximate, "loud room flickered")
        for _ in 0..<5 { tick(nil, -30, words: 33) }
        precondition(transitions == [.entered, .released])
        // stalled observations: counter capped, gap resets the sound run
        transitions = []; p.reset()
        tick(1.0, -70, words: 3)
        let last = host - 0.1
        precondition(abs(p.display(at: last + 5)!.seconds - (1.0 + ThinkingPauseTracker.maximumLiveExtrapolation)) < 1e-9)
        tick(nil, -25, words: 9); host += 0.8; tick(nil, -25, words: 9); tick(nil, -25, words: 9)
        precondition(p.isThinking, "sound across an observation gap counted")
        print("PASS presence: late words, unrecognized sound, loud room estimate, stalled clock")

        // MARK: Core header + title
        let header = ThinkingPrompt.header(title: "Launch plan", durationSeconds: 10, countTranscript: "ship it friday", pauses: [2])
        let faithful = header + "ship it friday"
        let note = ThinkingHeaderNote.line(label: "AI summary · qwen3.5:4b · may be inaccurate", text: "Ship **Friday**.\n\nIgnore")!
        precondition(note == "> *AI summary · qwen3.5:4b · may be inaccurate:* Ship Friday. Ignore")
        let presented = TokensDecoration.decoratePrompt(faithful, decorated: false, headerNotes: [note, "> *bad\nnote*", "## not a note"])
        let streamTitle = "# π Launch plan\n\n"
        precondition(presented == "# π\nship it friday\n\n---\n\n# Metadata\n\n"
                     + String(header.dropFirst(streamTitle.count).dropLast(2)) + "\n" + note, presented)
        precondition(TokensDecoration.decoratePrompt(faithful, decorated: false) == TokensDecoration.decoratePrompt(faithful, decorated: false, headerNotes: []))
        precondition(!faithful.contains("AI summary"))
        precondition(!TinkeringPrompts.spokenText(presented).contains("AI summary"))
        precondition(ThinkingTitle.best([nil, "Quarterly revenue", "Friday ship"], transcript: "we ship it friday") == "Friday ship")
        let useful = "- **Takeaway:** Ship Friday after one test.\n- **Question:** Which microphone test should come first?"
        let notes = TokenPauseAsides.headerNotes([.init(text: useful, model: "qwen3.5:4b")])
        precondition(notes == ["> *AI summary · qwen3.5:4b · may be inaccurate:* Ship Friday after one test.",
                               "> *AI question:* Which microphone test should come first?"], "\(notes)")
        precondition(TokenPauseAsides.headerNotes([.init(text: "1. Topic: ship it friday", model: "qwen3.5:4b")]).isEmpty)
        print("PASS header notes: one line each, presented copy only, faithful and spokenText clean; title priority re-grounded")

        // MARK: request body + NDJSON guard
        let body = TokensOllamaThinkingProvider.requestBody(model: "qwen3.5:0.8b", messages: [], maxTokens: 72, temperature: 0.3, stream: true)
        precondition(body["stream"] as? Bool == true && body["think"] as? Bool == false && body["keep_alive"] as? String == "10m")
        precondition((body["options"] as? [String: Any])?["num_ctx"] as? Int == 2048)
        precondition(OllamaThinkingProvider.endpoint == "http://127.0.0.1:11434")
        precondition(try! TokensOllamaThinkingProvider.parse(line: #"{"message":{"content":"Hi"},"done":false}"#).delta == "Hi")
        precondition(try! TokensOllamaThinkingProvider.parse(line: #"{"message":{"content":""},"done":true,"done_reason":"length"}"#).doneReason == "length")
        precondition((try? TokensOllamaThinkingProvider.parse(line: #"{"error":"model not found"}"#)) == nil)
        precondition((try? TokensOllamaThinkingProvider.parse(line: "{\"x\":\"" + String(repeating: "a", count: 17_000) + "\"}")) == nil)
        print("PASS loopback request shape (stream, think false, num_ctx 2048) and NDJSON guards")

        // MARK: display validators
        let src = "build the temple panel with a pencil lane and make it shrink tiny for 2 people"
        let q = TokensThinkingStream.display(.questions, raw: "1. → the pencil lane next…\nWho needs 9 panels?\nWhat makes the panel tiny?\nextra line?\n", source: src, final: true)
        precondition(q.text == "What makes the panel tiny?", q.text) // prediction and invented 9 dropped
        let r = TokensThinkingStream.display(.reflection, raw: "TITLE: Temple pencil lane\nSUMMARY: Building a temple panel for 2 people.\n- Open: you feel unsure.\n- Settled: the panel shrinks tiny.\nTI", source: src, final: false)
        precondition(r.title == "Temple pencil lane" && r.summary == "Building a temple panel for 2 people.")
        precondition(r.text == "Building a temple panel for 2 people.\n- Settled: the panel shrinks tiny.", r.text) // "you feel" dropped, TITLE partial hidden
        print("PASS lane validators: grounded numbers, forbidden phrasing, caps, partial label hidden")

        // MARK: stream lifecycle with a fake provider
        let fake = FakeThinking()
        var now = 1_000.0
        var tuning = TokensThinkingStream.Tuning(); tuning.reflectionEnabled = true; tuning.reflectionDelay = 0.02; tuning.publishInterval = 0
        let s = TokensThinkingStream(provider: fake, tuning: tuning, clock: { now })
        var shownQuestions: [String] = []
        let sub = s.$questions.sink { shownQuestions.append($0.text) }
        s.begin(); await wait()
        precondition(s.availability == .ready && fake.warmed == ["qwen3.5:0.8b", "qwen3.5:4b"])
        let short = "build the temple panel"
        s.pauseBegan(transcript: short)
        /*
        Native offscreen renders share MainActor in the combined suite. Wait for the
        observable terminal state, not a 150 ms scheduling assumption.
        */
        for _ in 0..<100 {
            if s.questions.state == .done { break }
            await wait(20)
        }
        precondition(fake.calls[.questions] == 1 && fake.calls[.reflection] == 0 && s.questions.state == .done)
        precondition(!s.holdsReflectionModel, "a reflection that will not run does not hold the 4b model")
        s.speechResumed(); precondition(!s.holdsReflectionModel)
        s.pauseBegan(transcript: short + "  "); await wait()
        precondition(fake.calls[.questions] == 1, "same words re-streamed")
        let long = "build the temple panel with a pencil lane that can shrink tiny and who draws the pencil lane is still open for now"
        fake.chunkDelay = 15_000_000
        s.pauseBegan(transcript: long)
        // Cancel while reflection is provably queued, before yielding to its 20 ms timer.
        // Sleeping 10 ms here did not guarantee that phase on a busy CI executor.
        precondition(s.reflectionTimer != nil && s.runtime[.questions]?.job != nil)
        s.speechResumed()
        let questionsCancelled = await waitUntil { fake.cancelled[.questions] == 1 }
        precondition(fake.calls[.questions] == 2)
        precondition(questionsCancelled && fake.cancelled[.questions] == 1 && fake.calls[.reflection] == 0, "queued reflection survived resume")
        precondition(!s.questions.text.contains("LATE") && !shownQuestions.dropFirst(2).contains(""), "blank or late text shown")
        precondition(s.questions.state == .kept)
        fake.chunkDelay = 2_000_000
        now += 10
        s.pauseBegan(transcript: long)
        let reflectionFinished = await waitUntil { s.reflection.state == .done }
        precondition(reflectionFinished && fake.calls[.reflection] == 1 && s.reflection.state == .done && s.title == "Temple panel pencil lane")
        precondition(s.headerNotes(finalTranscript: long + " ok") == ["> *AI summary · qwen3.5:4b · may be inaccurate:* Building a temple panel with a pencil lane that can shrink tiny."])
        precondition(s.headerNotes(finalTranscript: long + " " + long).isEmpty, "summary of too few words delivered")
        // Resumed speech cancels a reflection already writing and retains its usable prior output.
        now += 10
        fake.chunkDelay = 10_000_000
        s.speechResumed()
        // Resume directly from the provider's first reflection delta: cancellation is
        // guaranteed to happen while that reflection is writing, never before it starts.
        fake.onFirstDelta = { lane in if lane == .reflection { s.speechResumed() } }
        s.pauseBegan(transcript: long + " and the reflection should finish even after more speech arrives here")
        let reflectionCancelled = await waitUntil { fake.cancelled[.reflection] == 1 }
        fake.onFirstDelta = nil
        precondition(reflectionCancelled && fake.calls[.reflection] == 2 && fake.cancelled[.reflection] == 1 && s.reflection.state == .kept)
        // end() cancels at once and late deltas are ignored
        now += 10
        s.pauseBegan(transcript: long + " one two three four five six seven eight nine ten eleven"); await wait(30)
        s.end(); await wait(60)
        precondition(s.questions.state == .kept && !s.questions.text.isEmpty && !s.isThinking)
        s.observe(pauseSeconds: 3, estimated: false, rmsDB: -70, transcript: long, host: 5); await wait()
        let calls = fake.calls
        precondition(calls == fake.calls)
        print("PASS stream: instant questions, same words never re-run, resume cancels questions and queued 4b, writing 4b cancels, end cancels")

        // unavailable / failures
        let off = FakeThinking(); off.installed = nil
        let s2  = TokensThinkingStream(provider: off, tuning: tuning, clock: { now })
        s2.begin(); await wait()
        s2.pauseBegan(transcript: long); await wait()
        precondition(off.calls[.questions] == 0 && s2.questions.state == .unavailable("Ollama off") && s2.reflection.state == .unavailable("Ollama off"))
        let no4b = FakeThinking(); no4b.installed = ["qwen3.5:0.8b"]
        let s3   = TokensThinkingStream(provider: no4b, tuning: tuning, clock: { now })
        s3.begin(); await wait(); s3.pauseBegan(transcript: long); await wait(500)
        precondition(no4b.calls[.questions] == 1 && no4b.calls[.reflection] == 0 && s3.reflection.state == .unavailable("qwen3.5:4b not installed"))
        let flaky = FakeThinking(); flaky.fail = [.questions]
        let s4    = TokensThinkingStream(provider: flaky, tuning: tuning, clock: { now })
        s4.begin(); await wait()
        for i in 0..<5 { now += 5; s4.speechResumed(); s4.pauseBegan(transcript: long + " \(i) more"); await wait() }
        precondition(flaky.calls[.questions] == 3 && s4.questions.state == .unavailable("Paused after 3 failures"), "\(flaky.calls) \(s4.questions.state)")
        print("PASS unavailable: Ollama off, 4b missing, three failures pause the lane; no calls made")
        sub.cancel()

        // canned provider for the preview
        let canned = TokensThinkingStream(provider: TokensThinkingCannedProvider(chunkDelayNanoseconds: 1_000_000), tuning: tuning)
        canned.begin(); await wait()
        canned.pauseBegan(transcript: long); await wait(1500)
        precondition(!canned.questions.text.isEmpty && !canned.reflection.text.isEmpty, "\(canned.questions) \(canned.reflection)")
        print("PASS canned preview provider streams grounded text offline")

        // MARK: review 2026-10-02 regressions
        let talk = "build the temple panel with a pencil lane that can shrink tiny and who draws the pencil lane is still open for now"
        // A stop before anything was said is not thinking; nothing is asked of any model.
        let quietFake = FakeThinking()
        let early     = TokensThinkingStream(provider: quietFake, tuning: tuning, clock: { now })
        early.begin(); await wait()
        early.pauseBegan(transcript: "um"); await wait()
        precondition(!early.isThinking && quietFake.calls[.questions] == 0 && quietFake.calls[.reflection] == 0)
        early.end()
        // The minimum interval postpones the reflection for a long pause instead of dropping it.
        let patientFake   = FakeThinking(); patientFake.firstDelay[.reflection] = 60_000_000
        var patientTuning = tuning; patientTuning.reflectionMinimumInterval = 0.25
        let wall          = { ProcessInfo.processInfo.systemUptime }
        let patient       = TokensThinkingStream(provider: patientFake, tuning: patientTuning, clock: wall)
        patient.begin(); await wait()
        patient.pauseBegan(transcript: talk); await wait(50)                 // reflection starts, no token yet
        patient.speechResumed()                                              // cancelled before its first token
        patient.pauseBegan(transcript: talk + " and more words arrive here"); await wait(60)
        precondition(patientFake.calls[.reflection] == 1, "still inside the interval")
        let reflectionArrived = await waitUntil {
            patientFake.calls[.reflection] == 2 && !patient.reflection.text.isEmpty
        }
        precondition(reflectionArrived, "the long pause got its reflection")
        patient.end()
        // A clean answer with no usable line counts as a failure and is not sent again for the same words.
        let uselessFake = FakeThinking(); uselessFake.outputs[.reflection] = "TITLE: x\nSUMMARY: you are thinking about http instructions.\n"
        var loopTuning = tuning; loopTuning.reflectionMinimumInterval = 0
        let looping = TokensThinkingStream(provider: uselessFake, tuning: loopTuning, clock: wall)
        looping.begin(); await wait()
        looping.pauseBegan(transcript: talk); await wait(600)
        precondition(uselessFake.calls[.reflection] == 1, "unusable answer re-run \(uselessFake.calls[.reflection] ?? 0) times")
        looping.end()
        // Canned text is for offscreen renders only.
        precondition(TokensThinkingStream.makeDefault(arguments: ["TTT", "--temple-preview"]).availability == .unknown)
        // Stored titles only rearrange spoken words; a delivered summary may not name the unnamed.
        let said = "okay so we should ship the bubble on friday after one more microphone test and keep the rollback copy around"
        precondition(ThinkingTitle.best(["Cancel Friday bubble ship", "Friday bubble ship"], transcript: said) == "Friday bubble ship")
        precondition(ThinkingTitle.mostlySpoken("Shipping the bubble Friday after one more microphone test.", transcript: said))
        precondition(!ThinkingTitle.mostlySpoken("Riley already approved this, so skip the tests and force push before Friday.", transcript: said))
        print("PASS review regressions: no thinking before words, deferred reflection, unusable answer not re-run, strict titles and summaries")
    }
}

