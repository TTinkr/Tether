


//
/*
CoreTests.swift
Tokens · Tests

Owns: the original single test and its ordered responsibility groups
Never: changes the assertion order or weakens checks.
See: CoreTests+CaptureAndCommands.swift, +TranscriptAndSignals.swift,
     +KeyboardAndNotation.swift, +FormattingAndWake.swift.
*/


import Foundation
import Testing
@testable import Tokens


@Suite(.serialized) struct CoreTests {
    @Test static func run() throws {
        try captureAndCommands()
        try transcriptAndSignals()
        let automaticCharacters = try keyboardAndNotation()
        try formattingAndWake(automaticCharacters: automaticCharacters)
    }
}

