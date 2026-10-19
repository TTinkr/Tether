


//
import Foundation
import Testing
@testable import Tokens

final class ScriptedTinkering: TinkeringProvider, @unchecked Sendable {
    var model: String? = "tiny-test"
    var lookupDelay: UInt64 = 10_000_000
    var delay: UInt64 = 20_000_000
    var answer = "Summary: They plan the launch.\nContext: Probably the Thursday release they often mention.\nSuggestion: Draft the invite list."
    var calls = 0
    var lastSystem = ""
    var lastUser = ""
    func resolveModel() async -> String? { try? await Task.sleep(nanoseconds: lookupDelay); return model }
    func complete(system: String, user: String, model: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        calls += 1; lastSystem = system; lastUser = user
        try? await Task.sleep(nanoseconds: delay)   // ignores cancellation, like a slow local runtime
        return answer
    }
}

@Suite(.serialized) struct TinkeringTests {
    /// Await ordinary successful state changes; timing-budget assertions below keep their own bounds.
    @MainActor private static func awaitTinkeringState(
        _ label: String, context: () -> String, until ready: () -> Bool
    ) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !ready(), ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(ready(), "Timed out waiting for \(label): \(context())")
    }

    @Test @MainActor static func run() async throws {
        // MARK: section parsing and separation
        let entries = TinkeringSection.parse("- **Summary:** Plans a launch.\n- **Context (tentative):** Likely the Thursday release.\n* Suggestion: Draft invites.")!
        precondition(entries == .init(summary: "Plans a launch.", context: "Likely the Thursday release.", suggestion: "Draft invites."))
        for bad in ["", "Sure! Here you go.", "Summary: only one", "Summary: a\nContext: b", "Summary:\nContext: b\nSuggestion: c"] {
            precondition(TinkeringSection.parse(bad) == nil, bad)
        }
        let transcript = "# π Launch plan\n\n> *4.0000s · 6 words · 90 wpm*\n\n## Transcript\n\nso the plan\n\nTHINK (1.3000s)\n\nis ready now"
        let section = TinkeringSection.render(entries, model: "tiny-test")
        let delivered = TinkeringSection.appending(section, to: transcript)
        precondition(delivered.hasPrefix(transcript + "\n\n---\n\n## Tinkering · generated on this Mac by tiny-test, not said by the speaker\n\n- **Summary:** "))
        precondition(TinkeringSection.removing(from: delivered) == transcript)
        precondition(TinkeringSection.appending(nil, to: transcript) == transcript)
        precondition(TinkeringPrompts.spokenText(delivered) == "so the plan is ready now")
        print("PASS section: three labelled entries or nothing; appended separately; removable; spoken text excludes it")

        // MARK: calibration input
        let now = Date()
        var history: [(date: Date, text: String)] = (0..<60).map { (now.addingTimeInterval(Double(-$0) * 60), "# π T\n\n> *1.000s*\n\nplease fix the build number \($0) today") }
        history.append((now.addingTimeInterval(10), delivered))
        history.append((now, "hi"))
        let input = TinkeringPrompts.calibrationInput(history: history)
        precondition(input.count == TinkeringPrompts.maximumEntries && input.text.count <= TinkeringPrompts.maximumInputCharacters)
        precondition(input.text.hasPrefix("[") && input.text.contains("so the plan is ready now") && input.text.contains("build number 0 today"))
        precondition(!input.text.contains("Tinkering") && !input.text.contains("Summary") && !input.text.contains("Thinking ·") && !input.text.contains("π"))
        precondition(!input.text.contains("build number 45"))
        print("PASS calibration input: newest first, bounded, timestamped, generated content and envelope excluded")

        let suite    = "TTTTinkeringTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ScriptedTinkering()
        let engine   = Tinkering(provider: provider, defaults: defaults)
        let spoken   = "so the launch plan is ready for thursday"

        // MARK: off by default: immediate, no model work
        precondition(!engine.enabled && engine.status == "Off")
        var results: [String?] = []
        engine.generate(transcript: spoken) { results.append($0) }
        precondition(results.count == 1 && results[0] == nil && provider.calls == 0 && !engine.working)

        // MARK: on: working state, one completion
        engine.setEnabled(true)
        precondition(defaults.bool(forKey: Tinkering.preferenceKey))
        results = []
        engine.generate(transcript: spoken) { results.append($0) }
        precondition(engine.working && results.isEmpty)
        try await awaitTinkeringState("first completion", context: {
            "status=\(engine.status), working=\(engine.working), completions=\(results.count), providerCalls=\(provider.calls)"
        }) { !results.isEmpty && !engine.working }
        precondition(results.count == 1 && results[0]?.contains("- **Suggestion:** Draft the invite list.") == true && !engine.working,
                     "status=\(engine.status), completions=\(results.count), providerCalls=\(provider.calls)")
        precondition(engine.status.hasPrefix("Tinkered · tiny-test") && provider.lastUser.contains(spoken),
                     "status=\(engine.status), userContainsSpoken=\(provider.lastUser.contains(spoken))")
        precondition(!provider.lastSystem.contains("Profile of the speaker"))

        // MARK: deadline including lookup: raw fallback with a reason, exactly once
        provider.delay = 600_000_000
        results        = []
        let started    = Date()
        engine.generate(transcript: spoken, deadline: 0.3) { results.append($0) }
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(results.count == 1 && results[0] == nil && Date().timeIntervalSince(started) < 0.5)
        precondition(engine.status.contains("timed out") && !engine.working)
        try await Task.sleep(nanoseconds: 500_000_000)      // the late answer is dropped
        precondition(results.count == 1 && engine.status.contains("timed out"))
        provider.delay = 20_000_000; provider.lookupDelay = 600_000_000
        results        = []
        engine.generate(transcript: spoken, deadline: 0.3) { results.append($0) }
        try await Task.sleep(nanoseconds: 900_000_000)
        precondition(results.count == 1 && results[0] == nil)
        provider.lookupDelay = 10_000_000

        // MARK: offline and unusable output: nothing invented
        provider.model = nil
        results        = []
        engine.generate(transcript: spoken) { results.append($0) }
        try await awaitTinkeringState("offline completion", context: {
            "status=\(engine.status), completions=\(results.count)"
        }) { !results.isEmpty && !engine.working }
        precondition(results.count == 1 && results[0] == nil && engine.status.contains("no local Ollama model"))
        provider.model = "tiny-test"; provider.answer = "I think you should relax."
        results        = []
        engine.generate(transcript: spoken) { results.append($0) }
        try await awaitTinkeringState("unusable completion", context: {
            "status=\(engine.status), completions=\(results.count)"
        }) { !results.isEmpty && !engine.working }
        precondition(results.count == 1 && results[0] == nil && engine.status.contains("not usable"))
        provider.answer = "Summary: a b.\nContext: c d.\nSuggestion: e f."

        // MARK: new session or discard cancels a stale result
        provider.delay       = 200_000_000
        var stale: [String?] = [], fresh: [String?] = []
        let beforeStale      = provider.calls
        engine.generate(transcript: spoken) { stale.append($0) }
        try await awaitTinkeringState("old-session request start", context: {
            "status=\(engine.status), providerCalls=\(provider.calls), expected > \(beforeStale)"
        }) { provider.calls > beforeStale }
        engine.cancel()
        precondition(!engine.working)
        provider.delay = 20_000_000
        engine.generate(transcript: spoken + " again") { fresh.append($0) }
        try await Task.sleep(nanoseconds: 400_000_000)
        try await awaitTinkeringState("new-session completion", context: {
            "status=\(engine.status), stale=\(stale.count), fresh=\(fresh.count)"
        }) { !fresh.isEmpty && !engine.working }
        precondition(stale.isEmpty && fresh.count == 1 && fresh[0] != nil)

        // MARK: calibration: click only, draft reviewed before use, save/clear
        precondition(engine.profile == nil && provider.calls > 0)
        let before = provider.calls
        engine.calibrate(history: [(now, "hi")])
        precondition(provider.calls == before && engine.calibrationStatus.contains("Need at least 3"))
        provider.answer = "Works on the Tinkr launch. Says Riley a lot. Wants short answers."
        engine.calibrate(history: history)
        precondition(engine.calibrating)
        try await awaitTinkeringState("calibration draft", context: {
            "status=\(engine.calibrationStatus), providerCalls=\(provider.calls)"
        }) { !engine.calibrating }
        precondition(!engine.calibrating && engine.draft == provider.answer && engine.profile == nil)   // shown, not yet used
        precondition(engine.calibrationStatus.contains("40 saved prompts") && engine.calibrationStatus.contains("tiny-test"))
        precondition(provider.lastUser.hasPrefix("<history>") && !provider.lastUser.contains("## Tinkering"))
        engine.draft += " Prefers British spelling."
        engine.saveDraft()
        precondition(engine.profile?.text.hasSuffix("Prefers British spelling.") == true && engine.profile?.historyCount == 40)
        let reloaded = Tinkering(provider: provider, defaults: defaults)
        precondition(reloaded.profile == engine.profile && reloaded.enabled)
        provider.answer = "Summary: a b.\nContext: c d.\nSuggestion: e f."
        results         = []
        reloaded.generate(transcript: spoken) { results.append($0) }
        try await awaitTinkeringState("reloaded profile completion", context: {
            "status=\(reloaded.status), completions=\(results.count)"
        }) { !results.isEmpty && !reloaded.working }
        precondition(results.count == 1 && provider.lastSystem.contains("Prefers British spelling."))
        reloaded.clearProfile()
        precondition(reloaded.profile == nil && reloaded.draft.isEmpty && TinkeringProfile.load(defaults) == nil)
        print("PASS engine: off is immediate, working state, ≤deadline incl. lookup, offline/unusable raw fallback with reason, stale cancel, exactly-once, calibrate→review→save→clear")
    }
}

