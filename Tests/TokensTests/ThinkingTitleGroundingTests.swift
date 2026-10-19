


//
/*
ThinkingTitleGroundingTests.swift
Owns: the case-sensitive name guard over case-insensitive spoken vocabulary.
Never: treats generated titles or summaries as a replacement for spoken text.
See: Thinking/ThinkingText.swift; Transcript/TranscriptFormatting.swift.
*/


import Testing
@testable import Tokens


struct ThinkingTitleGroundingTests {
    @Test func titlesCannotInventShortNamesNegationOrNumbers() {
        let spoken = "ship planning on Friday"
        #expect(!ThinkingTitle.everyWordSpoken("Sam ship planning", transcript: spoken))
        #expect(!ThinkingTitle.everyWordSpoken("Not ship planning", transcript: spoken))
        #expect(!ThinkingTitle.everyWordSpoken("Ship planning 2", transcript: spoken))
        #expect(ThinkingTitle.everyWordSpoken("Ship planning", transcript: spoken))
        #expect(ThinkingTitle.everyWordSpoken("AI UI", transcript: "AI UI"))
    }

    @Test func rejectsInventedNameEvenWhenMostWordsMatch() {
        #expect(!ThinkingTitle.mostlySpoken("Talk with Johnathan about lamps",
                                           transcript: "talk with John about lamps"))
        #expect(ThinkingTitle.mostlySpoken("Talk with John about lamps",
                                          transcript: "talk with john about lamps"))
    }

    @Test func casePreservingTokensKeepTheExistingBoundaries() {
        #expect(LexicalFidelity.casePreservingWords(in: "John’s plan: 2.5!")
                == ["John's", "plan", "2", "5"])
        #expect(LexicalFidelity.words(in: "John’s plan: 2.5!")
                == ["john's", "plan", "2", "5"])
    }
}

