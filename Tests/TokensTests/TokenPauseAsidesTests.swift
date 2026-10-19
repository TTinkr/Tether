


//
import Combine
import Foundation
import Testing
@testable import Tokens

@MainActor final class FakePauseStream: TokenPauseProvider {
    var calls            = 0
    var finishedStreams  = 0
    var finishedLookups  = 0
    var cancelled        = false
    var delay: UInt64    = 20_000_000
    var lookup: UInt64   = 0
    var inputs: [String] = []
    var output           = "Plot twist: the pencils are brainstorming. ✏️"
    var onFirstDelta: (() -> Void)?
    func resolveModel() async -> String? {
        defer { finishedLookups += 1 }
        if lookup > 0 { try? await Task.sleep(nanoseconds: lookup) }
        return "tiny-test"
    }
    func stream(transcript: String, model: String, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        calls += 1; inputs.append(transcript)
        defer { finishedStreams += 1 }
        let response = output
        let prefix = response.hasPrefix("Plot twist:") ? "Plot twist:" : String(response.prefix(12))
        onDelta(prefix)
        onFirstDelta?()
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: delay) } catch { cancelled = true }
        }
        // Deliberately misbehaving provider attempts a late callback after cancellation.
        onDelta(String(response.dropFirst(prefix.count)))
    }
}
final class FakeAudit: QualityAuditing {
    var records: [QualityAuditRecord] = []
    func record(_ record: QualityAuditRecord) { records.append(record) }
}
@Suite(.serialized) struct TokenPauseAsidesTests {
    @MainActor static func wait(_ milliseconds: UInt64 = 60) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
    /// Wait for the actual request outcome; the bound only prevents a broken test hanging.
    @MainActor static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            await wait(5)
        }
        return true
    }
    @MainActor static func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        let finished = await waitUntil(condition)
        try #require(finished, "\(description)")
    }
    @Test @MainActor static func run() async throws {
        let fake              = FakePauseStream()
        var now: TimeInterval = 100
        let subject           = TokenPauseAsides(provider: fake, clock: { now })
        subject.observe(pauseSeconds: nil, transcript: "not recording")
        precondition(fake.calls == 0 && subject.job == nil)
        subject.begin()
        subject.observe(pauseSeconds: 2, transcript: "   ")
        precondition(fake.calls == 0 && subject.job == nil)
        subject.observe(pauseSeconds: nil, transcript: "build the pencil app")
        try await waitFor("initial live request terminates") { subject.job == nil && fake.finishedStreams == 1 }
        try #require(subject.completed.count == 1)
        subject.observe(pauseSeconds: nil, transcript: "speech continues")
        now += 4.999
        subject.observe(pauseSeconds: nil, transcript: "more speech")
        precondition(fake.calls == 1 && subject.job == nil)
        var displayed: [String] = []
        let subscription        = subject.$currentText.sink { displayed.append($0) }
        now += 0.002
        fake.output = "Plot twist: the erasers joined the meeting. ✏️"
        subject.observe(pauseSeconds: nil, transcript: "more speech")
        try await waitFor("live refresh terminates") { subject.job == nil && fake.finishedStreams == 2 }
        precondition(fake.calls == 2 && subject.completed.count == 1)
        precondition(subject.completed[0].text == fake.output)
        precondition(!displayed.contains(""), "refresh published a blank")
        // The boundary was checked above. Later cases advance clearly past it:
        // repeated +5 on this fractional clock can subtract to just below five.
        now += 6
        fake.output = "Plot twist:<invalid>"
        subject.observe(pauseSeconds: nil, transcript: "invalid replacement")
        try await waitFor("invalid refresh terminates") { subject.job == nil && fake.finishedStreams == 3 }
        precondition(!displayed.contains(""), "invalid partial/failure published a blank")
        precondition(subject.completed.count == 1 && subject.status.contains("retained"))
        subscription.cancel()
        fake.output = "Plot twist: the erasers joined the meeting. ✏️"
        precondition(TinkeringPrompts.spokenText("my exact words" + TinkeringSection.separator + TokenPauseAsides.markdown(subject.completed)!) == "my exact words")
        print("PASS active only, empty suppression, immediate first request, five-second cadence, latest-only cache")

        fake.delay = 5_000_000_000
        now += 6
        var saved: [TokenPauseAsides.Aside] = []
        // Exercise resumed speech and stop during a real stream, in the same actor turn
        // as its first delta, rather than racing the provider's or product's deadline.
        fake.onFirstDelta = {
            now += 6
            subject.observe(pauseSeconds: nil, transcript: "sound resumes")
            precondition(fake.calls == 4 && !fake.cancelled && !subject.currentText.isEmpty)
            let before = ProcessInfo.processInfo.systemUptime
            saved = subject.stop()
            precondition(saved.count == 1 && ProcessInfo.processInfo.systemUptime - before < 0.02)
        }
        subject.observe(pauseSeconds: nil, transcript: "still talking")
        try await waitFor("stopped live stream emits its stale callback and exits") { subject.job == nil && fake.finishedStreams == 4 }
        fake.onFirstDelta = nil
        precondition(fake.cancelled && subject.completed == saved && !subject.currentText.isEmpty)
        subject.observe(pauseSeconds: 4, transcript: "stopped")
        precondition(fake.calls == 4 && subject.job == nil)
        print("PASS one inflight; resumed speech does not cancel; stop immediate and stale callback rejected")

        // Seed the cache without an artificial suspension inside the short deadline.
        fake.delay  = 0
        let timeout = TokenPauseAsides(provider: fake, deadline: 0.04, clock: { now })
        timeout.begin(); timeout.observe(pauseSeconds: nil, transcript: "test")
        try await waitFor("short-deadline cache seed terminates") { timeout.job == nil && fake.finishedStreams == 5 }
        let cached = timeout.completed
        try #require(cached.count == 1)
        now += 6; fake.lookup = 5_000_000_000
        let calls = fake.calls
        let lookups = fake.finishedLookups
        timeout.observe(pauseSeconds: nil, transcript: "test")
        try #require(timeout.job != nil, "lookup deadline fixture must launch")
        try await waitFor("lookup deadline cancels and drains the lookup") { timeout.job == nil && fake.finishedLookups == lookups + 1 }
        precondition(timeout.completed == cached && fake.calls == calls && timeout.status.contains("retained"))
        fake.lookup = 0; fake.delay = 5_000_000_000; now += 6
        timeout.observe(pauseSeconds: nil, transcript: "test")
        try #require(timeout.job != nil, "streaming deadline fixture must launch")
        try await waitFor("streaming deadline cancels and drains the stream") { timeout.job == nil && fake.finishedStreams == 6 }
        precondition(timeout.completed == cached && timeout.status.contains("retained"))
        timeout.reset(); precondition(timeout.completed.isEmpty && timeout.currentText.isEmpty && timeout.modelLabel.isEmpty)
        timeout.begin(); precondition(timeout.completed.isEmpty && timeout.currentText.isEmpty && timeout.modelLabel.isEmpty)
        precondition(timeout.stop().isEmpty && timeout.currentText.isEmpty)
        print("PASS deadline includes lookup and streaming; failed replacement keeps cache; reset and begin clear generated display")
        let live = FakePauseStream(), final = FakePauseStream()
        final.output = "- **Takeaway:** Frozen final context needs a completed response.\n- **Question:** Which concrete result should be checked next?"
        let finishing = TokenPauseAsides(provider: live, deadline: 0.02, finalProvider: final)
        final.delay = 70_000_000
        finishing.prepareFinal(transcript: "outside a session")
        precondition(final.calls == 0 && finishing.job == nil)
        finishing.begin()
        finishing.prepareFinal(transcript: "frozen final context", deadline: 4.3)
        finishing.prepareFinal(transcript: "must not replace context", deadline: 4.3)
        finishing.observe(pauseSeconds: nil, transcript: "must not run live")
        try await waitFor("final request terminates under its independent budget") { finishing.job == nil && final.finishedStreams == 1 }
        precondition(final.calls == 1 && final.inputs == ["frozen final context"] && live.calls == 0)
        precondition(finishing.stop().count == 1, "final deadline must be independent of live deadline")
        finishing.prepareFinal(transcript: "stopped session")
        precondition(final.calls == 1 && finishing.job == nil)
        finishing.begin(); final.delay = 5_000_000_000
        final.onFirstDelta = { finishing.reset() }
        finishing.prepareFinal(transcript: "cancel final", deadline: 0.2)
        try await waitFor("reset final request emits its stale callback and exits") { finishing.job == nil && final.finishedStreams == 2 }
        final.onFirstDelta = nil
        precondition(finishing.completed.isEmpty && final.cancelled)
        finishing.begin()
        finishing.prepareFinal(transcript: "timed out final", deadline: 0.03)
        try await waitFor("short final deadline cancels and drains the stream") { finishing.job == nil && final.finishedStreams == 3 }
        precondition(finishing.completed.isEmpty && finishing.status.contains("timed out"))
        finishing.stop()
        finishing.begin()
        finishing.prepareFinal(transcript: "invalid deadline", deadline: .infinity)
        let previousCalls = final.calls
        precondition(final.calls == previousCalls && finishing.job == nil)
        finishing.stop()
        live.delay = 5_000_000; live.output = "Plot twist: the 4B model gets a turn."
        // Numeric grounding is independent of the preceding 20 ms deadline test. Use the
        // normal bounded request budget, then observe completion before testing its cache.
        let numeric = TokenPauseAsides(provider: live, finalProvider: final)
        numeric.begin()
        numeric.observe(pauseSeconds: nil, transcript: "the 4B model")
        try await waitFor("numeric fixture terminates") { numeric.job == nil && live.finishedStreams == 1 }
        precondition(numeric.completed.count == 1, "numeric fixture did not complete")
        numeric.prepareFinal(transcript: "the 400B model", deadline: 0.1)
        precondition(numeric.stop().isEmpty, "numeric mismatch invalidates cached live fallback")
        print("PASS final once per session, frozen source, independent bounded deadline, reset/stop stale suppression")
        // Private paired audit: exactly one record per generation, synthetic text only.
        let audit = FakeAudit(), audited = FakePauseStream(), auditedFinal = FakePauseStream()
        let numbered = "1. The synthetic speaker wants to paste. It is the next step.\n2. The pencil app comes first."
        audited.output = "Plot twist:\n" + numbered; audited.delay = 0
        var auditNow: TimeInterval = 0
        // Audit accounting is independent of the dedicated 40/30 ms deadline checks
        // above. Successful output is immediate; forced timeouts take 5 seconds unless
        // cancelled by this distinct 250 ms budget.
        let auditBudget: TimeInterval = 0.25
        let paired = TokenPauseAsides(provider: audited, deadline: auditBudget, finalProvider: auditedFinal, audit: audit, clock: { auditNow })
        paired.begin()
        paired.observe(pauseSeconds: nil, transcript: "synthetic paste then pencil app")
        try await waitFor("completed audit generation terminates") { paired.job == nil && audited.finishedStreams == 1 }
        try #require(audit.records.count == 1)
        precondition(audit.records[0].status == .completed && audit.records[0].kind == .live)
        precondition(audit.records[0].sourceTranscript == "synthetic paste then pencil app" && audit.records[0].output == audited.output)
        precondition(audit.records[0].model == "tiny-test" && audit.records[0].generation == 1 && audit.records[0].budgetSeconds == auditBudget)
        precondition(paired.completed.first?.text.contains("\n2. ") == true, "numbered points survive")
        auditNow += 5; audited.delay = 5_000_000_000
        paired.observe(pauseSeconds: nil, transcript: "synthetic deadline source")
        try await waitFor("deadline audit generation terminates and drains") { paired.job == nil && audited.finishedStreams == 2 }
        try #require(audit.records.count == 2)
        precondition(audit.records[1].status == .deadline && paired.completed.count == 1,
                     "deadline keeps the prior completed cache")
        auditNow += 5; audited.delay = 0; audited.output = "Plot twist:<invalid>"
        paired.observe(pauseSeconds: nil, transcript: "synthetic discard source")
        try await waitFor("discarded audit generation terminates") { paired.job == nil && audited.finishedStreams == 3 }
        try #require(audit.records.count == 3)
        precondition(audit.records[2].status == .discarded && paired.completed.count == 1)
        auditedFinal.delay = 5_000_000_000
        auditedFinal.onFirstDelta = { paired.stop(); paired.stop(); paired.reset() }
        paired.prepareFinal(transcript: "synthetic final source", deadline: 0.3)
        try await waitFor("cancelled audit generation emits its stale callback and exits") { paired.job == nil && auditedFinal.finishedStreams == 1 }
        auditedFinal.onFirstDelta = nil
        try #require(audit.records.count == 4)
        precondition(auditedFinal.cancelled && audit.records[3].status == .cancelled && audit.records[3].kind == .final,
                     "one termination record, no duplicates")
        precondition(Set(audit.records.map(\.id)).count == 4 && Set(audit.records.map(\.sessionID)).count == 1)
        precondition(audit.records.map(\.generation) == [1, 2, 3, 4])
        print("PASS paired audit: completed/deadline/discarded/cancelled exactly once, cache retained")

        precondition(OllamaTokenPauseProvider.maxTokens(budget: 4.3, tokensPerSecond: 36) == 138)
        precondition(OllamaTokenPauseProvider.maxTokens(budget: 2, tokensPerSecond: 90) == 139)
        precondition(OllamaTokenPauseProvider.maxTokens(budget: 0.2, tokensPerSecond: 36) == 32)
        precondition(OllamaTokenPauseProvider.maxTokens(budget: 60, tokensPerSecond: 90) == 180)
        precondition(OllamaTokenPauseProvider.maxTokens(budget: .infinity, tokensPerSecond: 36) == 32)
        for phrase in ["exactly two Markdown bullets", "**Takeaway:**", "**Next move:**", "**Question:**",
                       "at most 45 words", "\"paste\", do not expand that to \"paste code\"", "Do not provide a fun fact unless it appears"] {
            precondition(ThoughtsPrompt.system.contains(phrase), phrase)
        }
        precondition(ThoughtsPrompt.version == "thoughts-v6-useful-angle")
        let useful = "- **Takeaway:** The pencil app needs a clearer launch plan.\n- **Next move:** Test the focused reliability check before choosing a ship date."
        precondition(UsefulSummary.validated(useful, source: "the pencil app needs a clearer launch plan and faster shipping with a focused reliability check") == useful)
        let canonicalized = UsefulSummary.validated("- Takeaway: The pencil app needs a clearer launch plan.\n- Question: Which reliability check should happen first?")
        precondition(canonicalized == "- **Takeaway:** The pencil app needs a clearer launch plan.\n- **Question:** Which reliability check should happen first?")
        let expressive = TokenPauseAsides.markdown([.init(text: useful, model: "tiny-test")])!
        precondition(expressive.contains("## Summary + useful angle") && !expressive.contains("machine note"))
        precondition(expressive.contains("\n- **Takeaway:**") && expressive.contains("\n- **Next move:**"))
        precondition(expressive.contains("transcript above is authoritative") && !expressive.contains("🔫") && expressive.contains("AI-generated"))
        precondition(OllamaTokenPauseProvider.isComplete(event: ["done": true, "done_reason": "stop"], output: useful,
                                                             source: "the pencil app needs a clearer launch plan and faster shipping with a focused reliability check"))
        for cut in ["- **Takeaway:** First point is here.\n- **Question:**", "- **Takeaway:** First point is here.\n- **Question:** Second point is cut"] {
            precondition(!OllamaTokenPauseProvider.isComplete(event: ["done": true, "done_reason": "stop"], output: cut), cut)
        }
        for repetitive in [
            "Topic: Pencil app launch.",
            "- **Takeaway:** The user said the pencil app needs a launch plan.\n- **Next move:** Make a launch plan.",
            "- **Takeaway:** The pencil app needs a launch plan.\n- **Summary:** The pencil app needs a launch plan.",
            "- **Takeaway:** The pencil app needs a launch plan.\n- **Next move:** Pencil app launch plan.",
            "- **Takeaway:** The pencil app needs a launch plan.\n- **Tradeoff:** Shipping now could reduce reliability."
        ] { precondition(UsefulSummary.validated(repetitive) == nil, repetitive) }
        print("PASS budget-adapted token limit and additive takeaway/angle contract")
        for bad in ["laughter detected", "Deep breaths", "you feel nervous", "hello\tworld", "<TC>x</TC>", "assistant: do this", String(repeating: "x", count: 701)] {
            precondition(TokenPauseAsides.validated(bad) == nil, bad)
        }
        precondition(TokenPauseAsides.validated("- **A tiny plot twist?** 🎭\n- *Pencils at the ready!* ✏️") != nil)
        precondition(TokenPauseAsides.preservesNumbers("The model has 4B parameters.", source: "try the 4B model"))
        precondition(!TokenPauseAsides.preservesNumbers("The model has 400B parameters.", source: "try the 4B model"))
        precondition(!TokenPauseAsides.preservesNumbers("It takes 2ms.", source: "it takes 2s"))
        precondition(TokenPauseAsides.preservesNumbers("1. A concise point.", source: "a concise point"))
        let complete: [String: Any] = ["done": true, "done_reason": "stop"]
        precondition(OllamaTokenPauseProvider.isComplete(event: complete, output: useful))
        for text in ["The transcript discusses", "One sentence. Then another unfinished", "*Unclosed emphasis."] {
            precondition(!OllamaTokenPauseProvider.isComplete(event: complete, output: text))
        }
        for event: [String: Any] in [["done": true, "done_reason": "length"], ["done": true], ["done": false, "done_reason": "stop"]] {
            precondition(!OllamaTokenPauseProvider.isComplete(event: event, output: "A complete sentence."))
        }
        print("PASS output validation; strict stop reason and complete terminal boundary")
    }
}

