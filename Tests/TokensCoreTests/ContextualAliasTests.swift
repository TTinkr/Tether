


//
import Foundation
import Testing
@testable import TokensCore

/// Small deterministic generator so the window fuzz is reproducible.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct AliasCase: Sendable, CustomTestStringConvertible {
    let heard: String
    let expected: String
    var testDescription: String { heard }
}

@Suite struct ContextualAliasTests {
    /// Misheard agent prompts that must be fixed.
    static let fixes: [AliasCase] = [
        .init(heard: "consult cloud code agent on the taste here", expected: "consult Claude Code agent on the taste here"),
        .init(heard: "send that to codecs in this session", expected: "send that to Codex in this session"),
        .init(heard: "open a cloud code session for the worktree", expected: "open a Claude Code session for the worktree"),
        .init(heard: "Cloud Code with opus should review it", expected: "Claude Code with opus should review it"),
        .init(heard: "ask the cloud code agent to run the tests", expected: "ask the Claude Code agent to run the tests"),
        .init(heard: "cloud  code in the terminal is faster", expected: "Claude Code in the terminal is faster"),
        .init(heard: "let the harness route it to cloud code", expected: "let the harness route it to Claude Code"),
        .init(heard: "codecs exec can take the bounded read", expected: "Codex exec can take the bounded read"),
        .init(heard: "steer the codecs thread with the new plan", expected: "steer the Codex thread with the new plan"),
        .init(heard: "give it to Codecs on gpt", expected: "give it to Codex on gpt"),
        .init(heard: "the codecs cli should own packaging", expected: "the Codex cli should own packaging"),
        .init(heard: "spin up a codecs session in a new worktree", expected: "spin up a Codex session in a new worktree"),
        .init(heard: "cloud code and codecs both read the worktree", expected: "Claude Code and Codex both read the worktree"),
        .init(heard: "first line here.\nask cloud code agent now", expected: "first line here.\nask Claude Code agent now"),
        .init(heard: "codecs chat, then soul music", expected: "Codex chat, then soul music"),
    ]

    /// Phrases that must come out byte-identical (hard zero tolerance).
    static let keep: [String] = [
        // Codex integration review 2026-10-13: links, paths and literal meanings stay as said.
        "https://example.com/chat/codecs is the agent link",
        "open www.example.com/codecs in the agent chat",
        "the agent wrote ~/work/codecs/notes.md in this session",
        "check src/chat/soul.md with the gpt model",
        "mail codecs@example.com from the agent chat",
        "ask the agent about compression codecs",
        "this chat has soul",
        "with the gpt model, open soul.md",
        "ask the agent to open codecs.swift",
        "audio codecs for the mp3",
        "soul music all night",
        "the brand soul",
        "cloud code storage bucket",
        "video codecs matter",
        "searching my soul",
        "ask the agent about `cloud code` inside backticks",
        "```\ncloud code agent\n```",
        "the codecs in ffmpeg for this chat",
        "which codecs does the encoder support in this session",
        "soul food with the agent team",
        "my soul mate wants a chat",
        "cloud code on aws for the agent",
        "the cloud code azure session",
        "a soulful agent session",
        "cloud code is a phrase I like",
        "codecs are hard",
        "the soul of the product",
        "cloud coder agent",
        "soulmate chat",
        "the agent. cloud code for the bucket",
        "gpt agents. My soul is tired",
        "opus audio codecs in the chat",
        "<num>soul gpt</num>",
        // Soul needs a model word; chat, session and agent are in nearly every prompt.
        "put your soul into this session",
        "the soul of this chat",
        "start a new soul chat for the integration",
        "the agent has no soul",
    ]

    @Test(arguments: fixes)
    func misheardAgentNameIsFixed(_ row: AliasCase) {
        #expect(ContextualAlias.apply(row.heard) == row.expected)
    }

    @Test(arguments: keep)
    func ordinaryPhraseIsByteIdentical(_ phrase: String) {
        #expect(ContextualAlias.apply(phrase) == phrase)
    }

    @Test func emptyRulesChangeNothing() {
        #expect(ContextualAlias.apply("consult cloud code agent", rules: []) == "consult cloud code agent")
    }

    @Test func customRulesStillApply() {
        let rule = ContextualAliasRule(heard: #"tinker"#, written: "tinkr", requiresNearby: ["app"], blockedBy: ["toy"])
        #expect(ContextualAlias.apply("open the tinker app", rules: [rule]) == "open the tinkr app")
        #expect(ContextualAlias.apply("a tinker toy app", rules: [rule]) == "a tinker toy app")
    }

    /// The bounded outward scan must give the same window as splitting the whole string.
    @Test func boundedWindowMatchesWholeStringSplit() {
        var generator = SplitMix(seed: 0x70_6B_E7)
        let pieces = ["soul", "codecs", "cloud code", "gpt", "music", "agent", ".", "!", "?", "\n",
                      "\r\n", "é", "e\u{301}", "👨‍👩‍👧", "🇺🇸", "model", "word", "  ", ", "]
        for _ in 0 ..< 2_000 {
            let count = Int(generator.next() % 120)
            var text = ""
            for _ in 0 ..< count {
                text += pieces[Int(generator.next() % UInt64(pieces.count))]
                text += generator.next() % 3 == 0 ? "" : " "
            }
            let source = text as NSString
            guard source.length > 0 else { continue }
            let a = Int(generator.next() % UInt64(source.length))
            let b = min(source.length, a + Int(generator.next() % 8))
            let range = NSRange(location: a, length: b - a)
            #expect(ContextualAlias.sentenceWindow(around: range, in: source) == Self.referenceWindow(around: range, in: source))
        }
    }

    /// A long run of words with no stop and an emoji-dense run both reach 96 characters.
    @Test func longRunsKeepNinetySixCharacters() {
        let filler = String(repeating: "word ", count: 80)
        let emoji = String(repeating: "👨‍👩‍👧", count: 120)
        for text in [filler + "soul" + filler, emoji + " soul " + emoji] {
            let source = text as NSString
            let range = source.range(of: "soul")
            #expect(ContextualAlias.sentenceWindow(around: range, in: source) == Self.referenceWindow(around: range, in: source))
        }
    }

    /// Dense input stays linear: 200 K characters of matches with no sentence breaks.
    @Test func longTokensWithoutSpacesStayLinear() {
        // Unanchored protected alternatives backtracked on long runs.
        for run in [String(repeating: "a", count: 50_000), String(repeating: "a@", count: 10_000),
                    String(repeating: "a-", count: 10_000), String(repeating: "a.", count: 10_000)] {
            let text = run + " codecs agent"
            let started = ContinuousClock.now
            let out = ContextualAlias.apply(text)
            #expect(ContinuousClock.now - started < .seconds(2))   // was 160 s+ for the 50k run
            #expect(out.hasSuffix(" Codex agent"))
        }
    }

    @Test func denseLongInputCompletes() {
        let text = String(repeating: "codecs agent ", count: 16_000)
        let fixed = ContextualAlias.apply(text)
        #expect(fixed == String(repeating: "Codex agent ", count: 16_000))
    }

    /// Text cut after a finished sentence brands the same as the full text, so a sentence-bounded
    /// stable prefix (the staged path) is always a prefix of the branded final.
    @Test func sentenceBoundedPrefixAgreesWithFinal() {
        let finals = [
            "send that to codecs. then soul for luna reads",
            "ask cloud code agent now. the codecs thread can wait",
            "soul music first. then codecs in this session",
        ]
        for final in finals {
            guard let cut = final.firstIndex(of: ".") else { continue }
            let prefix = String(final[...cut])
            #expect(ContextualAlias.apply(final).hasPrefix(ContextualAlias.apply(prefix)))
        }
    }

    static func referenceWindow(around range: NSRange, in source: NSString) -> String {
        let before = source.substring(to: range.location)
        let after  = source.substring(from: NSMaxRange(range))
        let stops  = CharacterSet(charactersIn: ".!?\n")
        let left   = before.components(separatedBy: stops).last ?? ""
        let right  = after.components(separatedBy: stops).first ?? ""
        return String(left.suffix(96)) + " " + String(right.prefix(96))
    }

    @Test func exactlyTwoRulesShip() {
        #expect(ContextualAlias.rules.map(\.written) == ["Claude Code", "Codex"])
    }
}

