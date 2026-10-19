


//
/*
ScriptedThinking.swift
Tokens · Tests

Owns: the deterministic thinking provider and timed-word fixture
Never: changes the assertion order or weakens checks.
See: ThinkingTests+FormatterLifecycle.swift; ThinkingTests+PausePlacement.swift.
*/


import Foundation
import Testing
@testable import Tokens


/// Scripted provider: deterministic answers, optional delay, call counting.
final class ScriptedThinking: ThinkingProvider, @unchecked Sendable {
    var model: String? = "test-model"
    var delay: UInt64 = 20_000_000
    var formatCalls = 0
    var titleCalls = 0
    var transform: (String) -> String = { "✨ " + $0.prefix(1).uppercased() + $0.dropFirst() + "." }
    var titleText = "Launch plan"
    func resolveModel() async -> String? { model }
    func format(_ paragraph: String, model: String) async throws -> String {
        formatCalls += 1
        // Deliberately ignores cancellation, like a slow local runtime.
        try? await Task.sleep(nanoseconds: delay)
        return transform(paragraph)
    }
    func title(for transcript: String, model: String) async throws -> String {
        titleCalls += 1
        try? await Task.sleep(nanoseconds: delay)
        return titleText
    }
}

func timed(_ text: String, starts: [Double], length: Double = 0.2) -> [TimedWord] {
    zip(text.split(separator: " "), starts).map {
        TimedWord(text: String($0), start: $1, end: $1 + length, isFinal: true)
    }
}

