


//
/*
ThinkingTests.swift
Tokens · Tests

Owns: the original single thinking test and ordered responsibility groups
Never: changes the assertion order or weakens checks.
See: ThinkingTests+PresentationAndStaging.swift, +PausePlacement.swift,
     +FormatterLifecycle.swift; ScriptedThinking.swift.
*/


import Foundation
import Testing
@testable import Tokens


@Suite(.serialized) struct ThinkingTests {
    @Test @MainActor static func run() async throws {
        try presentationAndStaging()
        try pausePlacement()
        try await formatterLifecycle()
    }
}

