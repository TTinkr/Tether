


//
import Foundation
import Testing
@testable import Tokens

@MainActor final class TableFixture: TokenPauseProvider {
    nonisolated var structuredWorkspace: Bool { true }
    var output = ""
    func resolveModel() async -> String? { "fixture" }
    func stream(transcript: String, model: String, timeout: TimeInterval, onDelta: @escaping @MainActor (String) -> Void) async throws {
        onDelta(output)
    }
}
@Suite(.serialized) struct TinkeringHistoryTests {
    @Test @MainActor static func run() async {
        let provider = TableFixture()
        var now      = 0.0
        let subject  = TokenPauseAsides(provider: provider, clock: { now })
        subject.begin()
        for index in 1...5 {
            let source      = "Train for \(index) seconds. Compare the errors."
            provider.output = "ROW: constraint|Train for \(index) seconds|⏱️\nROW: goal|Compare the errors|📊"
            subject.observe(pauseSeconds: nil, transcript: source)
            try? await Task.sleep(nanoseconds: 30_000_000)
            precondition(subject.workspaceSource == source)
            precondition(subject.recentWorkspaceResponses.count == min(index, 3))
            precondition(subject.recentWorkspaceResponses.first?.source == source)
            now += 5
        }
        let retained    = subject.recentWorkspaceResponses
        provider.output = "ROW: detail|Invented unsupported text|💩"
        subject.observe(pauseSeconds: nil, transcript: "Unrelated words")
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(subject.recentWorkspaceResponses == retained)
        precondition(subject.stop().count == 1, "History must not multiply delivery appendices")
        subject.discard()
        precondition(subject.recentWorkspaceResponses.isEmpty && subject.workspaceSource.isEmpty)

        /*
        Live model context is intentionally capped; visible source follows
        the same bounded suffix and an early quote cannot be grounded.
        */
        let longProvider    = TableFixture()
        let longSubject     = TokenPauseAsides(provider: longProvider, clock: { 0 })
        let longSource      = "Alpha signal " + String(repeating: " filler", count: 200)
        longProvider.output = "ROW: goal|Alpha signal|📡"
        longSubject.begin()
        longSubject.observe(pauseSeconds: nil, transcript: longSource)
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(longSubject.workspaceSource == String(longSource.suffix(900)))
        precondition(longSubject.recentWorkspaceResponses.isEmpty,
                     "quote outside the bounded live context must not be retained")
        print("PASS bounded3 newest-first history, original source grounding, invalid response retention, one delivery cache, discard privacy reset")
    }
}

