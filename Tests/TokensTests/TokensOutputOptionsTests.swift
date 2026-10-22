import Foundation
import Testing
@testable import Tokens

struct TokensOutputOptionsTests {
    @Test func oldAlwaysOnMetadataDoesNotOptIntoNewExtras() throws {
        let suite = "TokensOutputOptionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "TTTMetadataFooterEnabled.v1")
        #expect(!defaults.bool(forKey: TokensOutputOptions.metadataKey))
        #expect(defaults.object(forKey: TokensOutputOptions.characterTagsKey) == nil)
        defaults.set(true, forKey: TokensOutputOptions.metadataKey)
        #expect(defaults.bool(forKey: TokensOutputOptions.metadataKey))
        #expect(defaults.object(forKey: TokensOutputOptions.characterTagsKey) == nil)
    }

    @Test func characterTagsAreOnUntilTurnedOff() throws {
        let suite = "TokensOutputOptionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TokensOutputOptions.characterTags(in: defaults))
        defaults.set(false, forKey: TokensOutputOptions.characterTagsKey)
        #expect(!TokensOutputOptions.characterTags(in: defaults))
        defaults.set(true, forKey: TokensOutputOptions.characterTagsKey)
        #expect(TokensOutputOptions.characterTags(in: defaults))
    }

    @Test func numberTagsHaveTheirOwnSwitchAndInheritAnOldOff() throws {
        let suite = "TokensOutputOptionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TokensOutputOptions.numberTags(in: defaults))
        defaults.set(false, forKey: TokensOutputOptions.characterTagsKey)   // the old shared switch, off
        #expect(!TokensOutputOptions.numberTags(in: defaults))
        defaults.set(true, forKey: TokensOutputOptions.numberTagsKey)
        #expect(TokensOutputOptions.numberTags(in: defaults))
        #expect(!TokensOutputOptions.characterTags(in: defaults))
    }

    @Test func turningLettersOffKeepsNumbersOnAcrossRelaunch() throws {
        let suite = "TokensOutputOptionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Fresh: both on. Letters off must not drag numbers along once read back after relaunch.
        TokensOutputOptions.setCharacterTags(false, in: defaults)
        #expect(!TokensOutputOptions.characterTags(in: defaults))
        #expect(TokensOutputOptions.numberTags(in: defaults))
        TokensOutputOptions.setCharacterTags(true, in: defaults)
        #expect(TokensOutputOptions.numberTags(in: defaults))
        // A legacy shared-switch off still carries to numbers the first time, then they are independent.
        let legacy = try #require(UserDefaults(suiteName: suite + ".legacy"))
        defer { legacy.removePersistentDomain(forName: suite + ".legacy") }
        legacy.set(false, forKey: TokensOutputOptions.characterTagsKey)
        #expect(!TokensOutputOptions.numberTags(in: legacy))
        TokensOutputOptions.setCharacterTags(true, in: legacy)
        #expect(TokensOutputOptions.characterTags(in: legacy) && !TokensOutputOptions.numberTags(in: legacy))
    }

    @Test func eachKindSwitchesAloneAndTagsCarryNoStars() {
        let raw = "Spell R I L E Y then count 1 2 3."
        #expect(TokensOutputOptions.body(raw, characterTags: true, numberTags: true)
                == "Spell <char>RILEY</char> then count <num>123</num>.")
        #expect(TokensOutputOptions.body(raw, characterTags: true, numberTags: false)
                == "Spell <char>RILEY</char> then count 1 2 3.")
        #expect(TokensOutputOptions.body(raw, characterTags: false, numberTags: true)
                == "Spell RILEY then count <num>123</num>.")
        #expect(TokensOutputOptions.body(raw, characterTags: false, numberTags: false)
                == "Spell RILEY then count 1 2 3.")
        // Markdown the speaker wrote stays as written.
        let literal = "Keep *this* and **that** and `R I L E Y`."
        #expect(TokensOutputOptions.body(literal, characterTags: true, numberTags: true) == literal)
    }

    @Test(arguments: [
        ("My name is R I L E Y.", "My name is <char>RILEY</char>."),
        ("My name is R-I-L-E-Y.", "My name is <char>RILEY</char>."),
        ("My name is R. I. L. E. Y.", "My name is <char>RILEY</char>."),
        ("Count 1 2 3 4 5 6 7 8 9 10.", "Count <num>1,2,3,4,5,6,7,8,9,10</num>."),
        ("Count 1, 2, 3, 4, 5, 6, 7, 8, 9, 10.", "Count <num>1,2,3,4,5,6,7,8,9,10</num>."),
        ("Count one two three four five six seven eight nine ten.", "Count <num>1,2,3,4,5,6,7,8,9,10</num>."),
    ])
    func defaultTagsMarkSpelledNamesAndNumberRuns(raw: String, tagged: String) {
        #expect(TokensOutputOptions.body(raw, characterTags: true, numberTags: true) == tagged)
    }

    @Test func cleanTextPreservesCaseNumbersAndLiteralMarkdownWithoutEnvelope() {
        let raw = "Keep NASA and 1234567910.\n# A literal heading\nUse **bold** as written."
        let body = TokensOutputOptions.body(raw, characterTags: false, numberTags: false)
        let parts = TokensOutputOptions.parts(body, metadata: false)
        #expect(parts.text == raw)
        #expect(parts.marker.isEmpty)
        #expect(parts.metadata.isEmpty)
        let plan = parts.revealPlan(spokenWordCount: 16)
        #expect(plan.completeText == raw)
        #expect(plan.marker.isEmpty)
        #expect(plan.metadata.isEmpty)
        #expect(plan.duration < 0.6)
    }

    @Test func extrasCanBeEnabledIndependently() {
        let raw = "My name is R I L E Y."
        for tags in [false, true] {
            for metadata in [false, true] {
                let body = TokensOutputOptions.body(raw, characterTags: tags, numberTags: tags)
                let rendered = metadata ? TokensPrompt.format(body, durationSeconds: 3,
                                                               countTranscript: "My name is RILEY.") : body
                let parts = TokensOutputOptions.parts(rendered, metadata: metadata)
                #expect(parts.text.contains("<char>") == tags)
                // Chill metadata (UX review): one paste, the words then an inline "— π […]".
                let words = tags ? "My name is <char>RILEY</char>." : "My name is RILEY."
                #expect(!parts.text.contains("# Metadata") && parts.marker.isEmpty && parts.metadata.isEmpty)
                #expect(parts.body == (metadata ? words + "\n— π [80 wpm, 3.00s, \(words.count) characters]" : words))
                #expect(parts.revealPlan(spokenWordCount: 4).completeText == parts.text)
            }
        }
    }
}

@Suite struct ChillFooterTests {
    @Test func pausesReadAsThinkingAndStayOutOfTheFooter() {
        let paused = "# π T\n\n> *26.5000s · 102 words · 231 wpm · 2x thinking (3.1400s)*\n\nhello\n*[pause 1.4420]* there"
        #expect(TokensOutputOptions.parts(paused, metadata: true, thinking: true).text
            == "hello\n[thinking 1.44s] there\n— π [231 wpm, 26.50s, 11 characters]")
        let calm = "# π T\n\n> *4.5000s · 1 word · 13 wpm · 0x thinking (0.0000s)*\n\nhello"
        #expect(TokensOutputOptions.parts(calm, metadata: true).text == "hello\n— π [13 wpm, 4.50s, 5 characters]")
    }

    /// Build 88: thinking traces and metadata are separate switches, both off by default.
    @Test func thinkingAndMetadataSwitchSeparately() throws {
        let paused = "# π T\n\n> *26.5000s · 102 words · 231 wpm · 2x thinking (3.1400s)*\n\nhello\n*[pause 1.4420]* there"
        #expect(TokensOutputOptions.parts(paused, metadata: false, thinking: false).text == "hello there")
        #expect(TokensOutputOptions.parts(paused, metadata: false, thinking: true).text == "hello\n[thinking 1.44s] there")
        #expect(TokensOutputOptions.parts(paused, metadata: true, thinking: false).text
            == "hello there\n— π [231 wpm, 26.50s, 11 characters]")
        // Codex review: code keeps its bytes; unplaced and historical markers go with the switch off.
        let code = "# π T\n\n> *2.0000s · 3 words · 90 wpm*\n\nrun `*[pause 1.0000]*` now\n*[pause 1.2000]* ok"
        for thinking in [false, true] {
            let out = TokensOutputOptions.parts(code, metadata: false, thinking: thinking).text
            #expect(out.contains("`*[pause 1.0000]*`") && out.hasSuffix(" ok"), "code keeps its bytes (thinking: \(thinking))")
            #expect(out.contains("[thinking 1.20s]") == thinking && !out.contains("*[pause 1.2000]*"))
        }
        #expect(InlineTalkMarkdown.joiningPauseNotes("run `*[pause 1.0000]*` now\n*[pause 1.2000]* ok")
            == "run `*[pause 1.0000]*` now ok")
        let unplaced = "# π T\n\n> *2.0000s · 3 words · 90 wpm*\n\nhello <thinking duration=\"1.0000s\" placement=\"unplaced\" count=\"2\"/> there"
        #expect(TokensOutputOptions.parts(unplaced, metadata: false).text == "hello there")
        // Plain text (no thinking layout) passes through as before.
        #expect(TokensOutputOptions.parts("just words", metadata: false, thinking: false).text == "just words")
        // Never set: both off.
        let suite = "ThinkingDefault.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(!d.bool(forKey: TokensOutputOptions.thinkingKey) && !d.bool(forKey: TokensOutputOptions.metadataKey))
    }
}


@Suite struct NumberTagSpacingTests {
    @Test func singleDigitRunsJoinAndLongerNumbersTakeCommas() {
        #expect(TokensOutputOptions.tags(in: "*<num>1 2 3 4 5 6 7</num>*", characters: true, numbers: true) == "<num>1234567</num>")
        #expect(TokensOutputOptions.tags(in: "*<num>9 10 11</num>*", characters: true, numbers: true) == "<num>9,10,11</num>")
        #expect(TokensOutputOptions.tags(in: "*<num>1 2 3</num>*", characters: true, numbers: false) == "1 2 3")
    }

    // Build 89 hard rule: no words, no paste.
    @Test func generatedTextAloneIsNotWords() {
        for empty in ["", "   ", "\n\n", ".", "…", "*[pause 2.1400]*", "[thinking 2.14s]", " *[pause 0.9000]* . "] {
            #expect(!TokensOutputOptions.hasWords(empty), "\(empty.debugDescription) should not paste")
        }
        for spoken in ["hello", "5", "12345", "a", "Hmm.", "こんにちは", "*[pause 2.1400]* okay"] {
            #expect(TokensOutputOptions.hasWords(spoken), "\(spoken.debugDescription) should paste")
        }
    }

    // The no-words check runs before anything a silent talk could leave behind (build 88 pasted a lone footer).
    @Test func silentTalkStopsBeforeFooterHistoryRecoveryAndPaste() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delivery = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Talk/TalkModel+Delivery.swift"), encoding: .utf8)
        let guardAt = try #require(delivery.range(of: "guard TokensOutputOptions.hasWords(spokenText) || !(stagedCommitted ?? \"\").isEmpty else {")).lowerBound
        for later in ["TokensOutputOptions.parts(faithful", "recordPromptHistory(authored", "retainForRecovery(payload",
                      "checkpointTranscript(rawPayload", "lastTranscriptForCopy  = payload"] {
            let at = try #require(delivery.range(of: later), "missing \(later)").lowerBound
            #expect(guardAt < at, "\(later) runs before the no-words check")
        }
    }
}
