


//
/*
CoreTests+KeyboardAndNotation.swift
Tokens · Tests

Owns: chords, literal commands and character/number notation
Never: changes the assertion order or weakens checks.
See: CoreTests.swift (ordered suite entry point).
*/


import Foundation
import Testing
@testable import Tokens


extension CoreTests {
    static func keyboardAndNotation() throws -> CharacterTalkRendering {

        var chord = ArrowChordDetector(maximumInterval: 0.11)
        precondition(chord.keyDown(keyCode: 124, timestamp: 1.00) == nil)
        precondition(chord.keyDown(keyCode: 123, timestamp: 1.06) == .toggle)
        precondition(chord.keyDown(keyCode: 123, timestamp: 1.07, isRepeat: true) == nil)
        chord.keyUp(keyCode: 123)
        chord.keyUp(keyCode: 124)

        // True overlap works in the opposite physical order.
        precondition(chord.keyDown(keyCode: 123, timestamp: 2.00) == nil)
        precondition(chord.keyDown(keyCode: 124, timestamp: 2.03) == .toggle)
        chord.keyUp(keyCode: 123)
        chord.keyUp(keyCode: 124)

        // A slow navigation sequence, a modified chord, and intervening input do not fire.
        precondition(chord.keyDown(keyCode: 124, timestamp: 3.00) == nil)
        chord.keyUp(keyCode: 124)
        precondition(chord.keyDown(keyCode: 123, timestamp: 3.20) == nil)
        chord.keyUp(keyCode: 123)
        precondition(chord.keyDown(keyCode: 124, timestamp: 4.00, hasDisallowedModifiers: true) == nil)
        precondition(chord.keyDown(keyCode: 10, timestamp: 4.02) == nil)
        precondition(chord.keyDown(keyCode: 123, timestamp: 4.04) == nil)
        chord.keyUp(keyCode: 123)

        for literal in ["Ship the smallest thing, tune out", "Make it real. Take off!", "Bye", "Bye-bye Tinkr Pi", "we should take off tomorrow", "the command is copy talk", "Please say Tinkr close", "\"copy talk\"", "“Tinkr minimize”"] {
            precondition(FinishCommandParser.trailingCommand(in: literal) == nil)
            precondition(VoiceCommandParser.standaloneCommand(in: literal) == nil)
        }
        precondition(VoiceCommandParser.standaloneCommand(in: "Copy talk.") == .copyTalk)
        precondition(VoiceCommandParser.standaloneCommand(in: "Tinkr full screen!") == .fullScreen)
        precondition(VoiceCommandParser.standaloneCommand(in: "Tinkr clothes") == nil)
        precondition(VoiceCommandParser.standaloneCommand(in: "Tinker minimize.") == .minimize)
        precondition(VoiceCommandParser.standaloneCommand(in: "I like to tinker") == nil)
        for candidate in Candidate.benchmarkClasses {
            precondition(VoiceCommandParser.standaloneCommand(in: "Tinkr \(candidate.displayName).") == .labSound(candidate))
            precondition(VoiceCommandParser.standaloneCommand(in: "Tinker \(candidate.displayName)!") == .labSound(candidate))
            precondition(VoiceCommandParser.standaloneCommand(in: "Tinker, \(candidate.displayName).") == .labSound(candidate))
            precondition(VoiceCommandParser.standaloneCommand(in: "I said Tinkr \(candidate.displayName)") == nil)
            precondition(VoiceCommandParser.standaloneCommand(in: "\"Tinkr \(candidate.displayName)\"") == nil)
            precondition(FinishCommandParser.trailingCommand(in: "Tinkr \(candidate.displayName)") == nil)
        }
        precondition(VoiceCommandParser.standaloneCommand(in: "Tinkr laugh then paste") == nil)
        precondition(VoiceCommandParser.standaloneCommand(in: "copy talk then continue") == nil)
        precondition(FinishCommandParser.trailingCommand(in: "Tinkr paste") == FinishMatch(payload: "", command: .finish))
        var utterances = CommandUtteranceTracker()
        precondition(utterances.consume("Um six no wait actually seven.")?.text == "Um six no wait actually seven.")
        precondition(utterances.consume("Um six no wait actually seven. Copy talk.") == CommandUtterance(text: "Copy talk.", precedingTranscript: "Um six no wait actually seven."))
        precondition(utterances.consume("Um six no wait actually seven. Copy talk.") == nil)
        precondition(utterances.consume("Um six, no, wait, actually seven. Tinkr close.") == nil)
        let raw = "um i i think six no wait actually seven"
        precondition(LexicalFidelity.preservesWords(raw: raw, formatted: "Um, I—I think six; no, wait: actually seven."))
        precondition(!LexicalFidelity.preservesWords(raw: raw, formatted: "I think seven."))
        precondition(LexicalFidelity.acceptedText(raw: raw, proposed: "I think seven.") == raw)
        precondition(!LexicalFidelity.preservesWords(raw: "do not", formatted: "don't"))
        precondition(!LexicalFidelity.preservesWords(raw: "x is 1.25", formatted: "x is 125"))

        let automaticCharacters = CharacterTalk.render("My name is R I L E Y.")
        precondition(automaticCharacters.displayText == "My name is ⟦TC⟧RILEY⟦/TC⟧.")
        precondition(automaticCharacters.deliveryText == "My name is RILEY.")
        precondition(automaticCharacters.markdownText == "My name is *<char>RILEY</char>*.")
        precondition(automaticCharacters.hasCharacterSpan && !automaticCharacters.isCharacterModeActive)
        let explicitCharacters = CharacterTalk.render(
            "Use talk characters C L A U D E end talk characters with Codex."
        )
        precondition(explicitCharacters.displayText == "Use ⟦TC⟧CLAUDE⟦/TC⟧ with Codex.")
        precondition(explicitCharacters.deliveryText == "Use CLAUDE with Codex.")
        precondition(explicitCharacters.markdownText == "Use *<char>CLAUDE</char>* with Codex.")
        let shortCommandCharacters = CharacterTalk.render("TC C L A U D E end TC")
        precondition(shortCommandCharacters.displayText == "⟦TC⟧CLAUDE⟦/TC⟧")
        precondition(shortCommandCharacters.deliveryText == "CLAUDE")
        let activeCharacters = CharacterTalk.render("talk characters T I N K R")
        precondition(activeCharacters.displayText == "⟦TC⟧TINKR")
        precondition(activeCharacters.deliveryText == "TINKR")
        precondition(activeCharacters.markdownText == "*<char>TINKR</char>*")
        precondition(activeCharacters.isCharacterModeActive)
        let ordinaryAcronym = CharacterTalk.render("TC protocols use API and SDK.")
        precondition(ordinaryAcronym.displayText == "TC protocols use API and SDK.")
        precondition(ordinaryAcronym.deliveryText == ordinaryAcronym.displayText)
        print("PASS: Character Talk marks explicit or isolated spelling spans and strips controls from delivery")

        let talkedNumbers = CharacterTalk.render(
            "Count one, two, three, four, five, six, seven, eight, nine, ten right now."
        )
        let digits = "1 2 3 4 5 6 7 8 9 10"
        precondition(talkedNumbers.displayText == "Count ⟦TN⟧\(digits)⟦/TN⟧ right now.")
        precondition(talkedNumbers.deliveryText == "Count \(digits) right now.")
        precondition(talkedNumbers.markdownText == "Count *<num>\(digits)</num>* right now.")
        precondition(talkedNumbers.hasNumberSpan && !talkedNumbers.hasCharacterSpan && talkedNumbers.hasProtectedSpan)
        let digitRun = CharacterTalk.render("Use 1 2 3 now.")
        precondition(digitRun.markdownText == "Use *<num>1 2 3</num>* now.")
        for ordinary in ["I need one or two versions.", "Say one two and stop.", "Version 2.5 ships at seven."] {
            let rendered = CharacterTalk.render(ordinary)
            precondition(rendered.markdownText == ordinary && !rendered.hasProtectedSpan)
        }
        let combinedNotation = CharacterTalk.render("Spell R I L E Y then count one two three.")
        precondition(combinedNotation.markdownText == "Spell *<char>RILEY</char>* then count *<num>1 2 3</num>*.")
        precondition(combinedNotation.hasCharacterSpan && combinedNotation.hasNumberSpan)
        let explicitCharacterDigits = CharacterTalk.render("talk characters 1 2 3 end talk characters")
        precondition(explicitCharacterDigits.markdownText == "*<char>123</char>*")
        precondition(explicitCharacterDigits.hasCharacterSpan && !explicitCharacterDigits.hasNumberSpan)
        for literal in ["`one two three`", "```swift\none two three\n```", "[one two three](https://example.com)"] {
            let rendered = CharacterTalk.render(literal)
            precondition(rendered.markdownText == literal && rendered.deliveryText == literal)
        }
        for existing in ["<TN> 1 2 3 </TN>", "⟦TN⟧1 2 3⟦/TN⟧", "<TC> KIMI </TC>"] {
            let rendered = CharacterTalk.render(existing)
            precondition(rendered.markdownText == existing && rendered.deliveryText == existing)
            precondition(rendered.hasProtectedSpan)
        }
        precondition(TalkVocabulary.normalizeRecognizedText("My colleague Quinn sent it.") == "My colleague Quinn sent it.")
        precondition(TalkVocabulary.normalizeRecognizedText("Quen is a model.") == "Qwen is a model.")
        precondition(TalkVocabulary.normalizeRecognizedText("Quinn and Kimi are machine learning models.")
                     == "Qwen and K I M I are machine learning models.")
        print("PASS: Talked Numbers emits TN digits for 3+ token runs, preserves ordinary prose, and coexists with TC")

        precondition(RightOptionMode.tap.action(pressed: true, capturing: false, finalizing: false) == .begin)
        precondition(RightOptionMode.tap.action(pressed: false, capturing: true, finalizing: false) == .ignore)
        precondition(RightOptionMode.tap.action(pressed: true, capturing: true, finalizing: false) == .finish)
        precondition(RightOptionMode.tap.action(pressed: true, capturing: false, finalizing: true) == .ignore)
        precondition(RightOptionMode.hold.action(pressed: false, capturing: true, finalizing: false) == .finish)
        precondition(RightOptionMode.hold.action(pressed: false, capturing: false, finalizing: false) == .ignore)
        print("PASS: hold/tap routing; tap releases ignored; finalization guarded")
        // The formatting group verifies this exact rendering, as the original test did.
        return automaticCharacters
    }
}

