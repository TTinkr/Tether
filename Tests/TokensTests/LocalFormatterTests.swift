


//
import Foundation
import Testing
@testable import Tokens

struct EchoFormatter: FormattingProvider {
    func format(_ text: String) async throws -> String {
        try await Task.sleep(nanoseconds: 50_000_000)
        return text + "."
    }
}
struct SlowFormatter: FormattingProvider {
    func format(_ text: String) async throws -> String {
        // Intentionally ignores cancellation to simulate a slow provider.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return text + "."
    }
}
@Suite(.serialized) struct LocalFormatterTests {
    @Test @MainActor static func run() async throws {
        let cases = [
            "um I want to go to the store and then no wait I want to stay here",
            "we should test Codex first then test Claude Code next I think that is useful",
            "this is the first point this is the second point we need more paragraphs",
            "I I think like this is important um keep all of my words",
            "talk characters C LA U D end talk characters is how I spell it"
        ]
        precondition(!LocalFormattingPolicy.accepts(raw: "um I I think", proposal: "I think."))
        precondition(LocalFormattingPolicy.accepts(raw: "um I I think", proposal: "Um, I, I think."))
        // Real local-model failure: punctuation is not permission to drop fillers.
        let correction = "I want to meet at six no wait I meant seven um keep both times"
        precondition(!LocalFormattingPolicy.accepts(raw: correction,
            proposal: "I want to meet at six. No, wait. I meant seven. Keep both times."))
        precondition(LocalFormattingPolicy.accepts(raw: correction,
            proposal: "I want to meet at six—no wait I meant seven. Um keep both times."))
        let amounts = "there is $23 but wire $90 there is a pending transfer"
        precondition(LocalFormattingPolicy.accepts(raw: amounts,
            proposal: "There is $23, but wire $90. There is a pending transfer."))
        precondition(!LocalFormattingPolicy.accepts(raw: amounts,
            proposal: "There is $23, but wire $900. There is a pending transfer."))
        print("PASS punctuation boundaries preserve fillers, corrections and amounts")
        for raw in cases {
            let chunks = LocalFormattingPolicy.chunks(raw)
            precondition(LexicalFidelity.preservesWords(raw: raw, formatted: chunks.joined(separator: "\n\n")))
        }
        precondition(LocalFormattingPolicy.chunks("One. Two. Three.") == ["One. Two.", "Three."])
        let suite    = "TTTFormatterTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalFormatter.preferenceKey)
        let formatter  = LocalFormatter(provider: EchoFormatter(), defaults: defaults)
        let exactWords = "um keep these exact words"
        formatter.ingest(exactWords)
        for _ in 0..<20 where formatter.rendered(exactWords) == exactWords {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(formatter.rendered(exactWords) == "um keep these exact words.")
        precondition(formatter.rendered("um keep these changed words") == "um keep these changed words")
        formatter.ingest("old session must not appear")
        formatter.reset()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        precondition(formatter.rendered("old session must not appear") == "old session must not appear")
        formatter.setEnabled(false)
        precondition(formatter.rendered("untouched  spacing") == "untouched  spacing")
        precondition(!LocalFormattingPolicy.accepts(raw: "one two three four five six seven eight", proposal: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight"))
        if CommandLine.arguments.contains("--catalog") {
            formatter.refreshModels()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            precondition(!formatter.availableModels.isEmpty)
            let choice = formatter.availableModels.first { $0 != formatter.selectedModel }!
            formatter.selectModel(choice)
            precondition(formatter.selectedModel == choice)
            precondition(defaults.string(forKey: "TTTLocalModel.v1") == choice)
            formatter.selectModel("not-an-installed-model")
            precondition(formatter.selectedModel == choice)
            print("PASS installed model catalog and persisted selection; invalid choice ignored")
        }
        defaults.set(true, forKey: LocalFormatter.preferenceKey)
        let slow        = LocalFormatter(provider: SlowFormatter(), defaults: defaults)
        var completions = 0
        let started     = Date()
        slow.finishWithin(0.1, raw: "um preserve this sentence") { completions += 1 }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(completions == 1 && Date().timeIntervalSince(started) < 0.5)
        precondition(slow.rendered("um preserve this sentence") == "um preserve this sentence")
        slow.finishWithin(1, raw: "turning off while refining") { completions += 1 }
        slow.setEnabled(false)
        precondition(completions == 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(completions == 2)
        defaults.set(true, forKey: LocalFormatter.preferenceKey)
        let quick            = LocalFormatter(provider: EchoFormatter(), defaults: defaults)
        var quickCompletions = 0
        quick.finishWithin(0.5, raw: "keep all these words") { quickCompletions += 1 }
        let quickDeadline = ProcessInfo.processInfo.systemUptime + 2
        while quickCompletions == 0 && ProcessInfo.processInfo.systemUptime < quickDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(quickCompletions == 1)
        precondition(quick.rendered("keep all these words") == "keep all these words.")
        let otherName = "TTTTelepathyTests-" + UUID().uuidString
        let other     = UserDefaults(suiteName: otherName)!
        defer { other.removePersistentDomain(forName: otherName) }
        other.set(true, forKey: LocalFormatter.preferenceKey)
        other.set("test-model", forKey: "TTTLocalModel.v1")
        quick.switchPreferences(to: other, allowModel: true)
        precondition(quick.enabled && quick.selectedModel == "test-model")
        precondition(quick.rendered("keep all these words") == "keep all these words")
        quick.setEnabled(false)
        precondition(!other.bool(forKey: LocalFormatter.preferenceKey))
        precondition(defaults.bool(forKey: LocalFormatter.preferenceKey))
        quick.switchPreferences(to: defaults, allowModel: false)
        precondition(!quick.enabled && defaults.bool(forKey: LocalFormatter.preferenceKey))
        print("PASS independent product model preferences; cache reset and Tokens model exclusion")
        print("PASS final deadline, late inference ignored, toggle-off completion exactly once")
        guard CommandLine.arguments.contains("--live") else { print("PASS local formatter policy, exact cache, cancellation and off mode"); return }
        for raw in cases {
            let start = Date()
            do {
                let proposed = try await OllamaFormatter().format(raw)
                let accepted = LocalFormattingPolicy.accepts(raw: raw, proposal: proposed)
                let data = try JSONSerialization.data(withJSONObject: ["raw":raw,"proposed":proposed,"accepted":accepted,"seconds":Date().timeIntervalSince(start)],options:[.sortedKeys])
                print(String(decoding:data,as:UTF8.self))
            } catch { print("inference_failed \(error)") }
        }
    }
}

