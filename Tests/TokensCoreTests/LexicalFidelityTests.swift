


//
/*
LexicalFidelityTests — corrections must keep every word
Owns: synthetic examples for repetition, order and contraction preservation.
Never: use private recordings or model-generated test expectations.
*/


import XCTest
@testable import TokensCore

final class LexicalFidelityTests: XCTestCase {
    func testPunctuationAndCasingPreserveEveryWordIncludingRepetitions() {
        let raw       = "um I I think six no wait actually seven"
        let formatted = "Um, I—I think six; no, wait: actually seven."

        XCTAssertTrue(LexicalFidelity.preservesWords(raw: raw, formatted: formatted))
        XCTAssertEqual(
            LexicalFidelity.words(in: formatted),
            ["um", "i", "i", "think", "six", "no", "wait", "actually", "seven"]
        )
    }

    func testRejectsDeletionReorderingAndContractionChanges() {
        XCTAssertFalse(LexicalFidelity.preservesWords(raw: "first second", formatted: "second first"))
        XCTAssertFalse(LexicalFidelity.preservesWords(raw: "I I agree", formatted: "I agree"))
        XCTAssertFalse(LexicalFidelity.preservesWords(raw: "do not", formatted: "don't"))
        XCTAssertEqual(
            LexicalFidelity.acceptedText(raw: "first second", proposed: "second first"),
            "first second"
        )
    }
}

