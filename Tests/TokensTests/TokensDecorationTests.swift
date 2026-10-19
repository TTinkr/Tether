


//
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct TokensDecorationTests {
    @Test static func run() {
        let clean          = "# π Test\n\n> *2 seconds*\n\nHello WORLD `MyPath`\nAgain."
        let cleanPresented = TokensDecoration.decoratePrompt(clean, decorated: false)
        // Layout since 2026-10-03 (MarkdownSampleTests): words first, the `> ` lines last under "# Metadata".
        precondition(cleanPresented == "# π\nHello WORLD `MyPath` Again.\n\n---\n\n# Metadata\n\n> *2 seconds*")
        precondition(TokensDecoration.decoratePrompt("Hello WORLD", decorated: false) == "# π\nHello WORLD")

        /*
        Case-insensitive lexical fidelity. Rendering adds no emoji or layout
        punctuation; every source emoji remains in its original position.
        */
        func verifyExact(_ source: String) {
            let rendered = TokensDecoration.render(body: source)
            precondition(LexicalFidelity.preservesWords(raw: source, formatted: rendered), "Words drifted: \(source.prefix(80))")
            precondition(TokensDecoration.render(body: source) == rendered, "Not deterministic")
            func count(_ text: String, _ test: (Character) -> Bool) -> Int { text.filter(test).count }
            let isEmoji: (Character) -> Bool = { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F } }
            let originalEmoji = source.filter(isEmoji)
            let renderedEmoji = rendered.filter(isEmoji)
            precondition(renderedEmoji == originalEmoji, "Source emoji changed or reordered")
            precondition(count(rendered, { $0.isNewline }) == count(source, { $0.isNewline }), "Line structure changed")
            let bullet = try! NSRegularExpression(pattern: #"(?m)^[\t ]*(?:[-+•]|\*(?!\*)|\d+\.)[\t ]"#)
            func bullets(_ text: String) -> Int { bullet.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) }
            precondition(bullets(rendered) == bullets(source), "List added")
            for keep in "'’" { precondition(count(rendered, { $0 == keep }) == count(source, { $0 == keep }), "Changed \(keep)") }
        }
        let ordinary = "um I I want to meet at six no wait seven uh keep both times and all my words"
        let styled   = TokensDecoration.render(body: ordinary)
        precondition(styled == "um i i want to meet at six no wait seven uh keep both times and all my words")
        let sentences = "Okay. So I I think we ship it! Really? Yes, we don't wait... Dr. Smith agrees: ship version 2.5 today. Done."
        let dashed = TokensDecoration.render(body: sentences)
        precondition(dashed == "okay. so i i think we ship it! really? yes, we don't wait... dr. smith agrees: ship version 2.5 today. done.", dashed)
        precondition(TokensDecoration.render(body: "Hello, WORLD. Why? Yes!") == "hello, world. why? yes!")
        let punctuated = TokensDecoration.render(body: "\"Hello\" (WORLD); Hello.")
        precondition(punctuated == "\"hello\" (world); hello.", punctuated)
        precondition(TokensDecoration.render(body: "Open TTTCore and iPhone then NASA said McDonald") ==
            "open TTTCore and iPhone then nasa said McDonald")
        precondition(TokensDecoration.render(body: "Also I am not seeing enough em dashes") ==
            "also i am not seeing enough em dashes")
        precondition(TokensDecoration.render(body: "Hello. — World").filter { $0 == "—" }.count == 1)
        precondition(TokensDecoration.render(body: "Hello\nWorld") == "hello\nworld")
        // Newlines and protected code remain byte-for-byte stable.
        let lined = TokensDecoration.render(body: "first line of words here\n\n  `let x = 2` then more words\n```\ncode words here\n```\nlast words")
        precondition(lined == "first line of words here\n\n  `let x = 2` then more words\n```\ncode words here\n```\nlast words", lined)
        precondition(ThinkingFidelity.emojiCount(TokensDecoration.render(body: ordinary)) == 0)
        let protected = [
            "<TC> R I L E Y </TC>", "<TC> A B C", "⟦TC⟧ R I L E Y ⟦/TC⟧",
            "<TN> 1 2 3 4 5 </TN>", "<TN> 1 2 3", "⟦TN⟧1 2 3⟦/TN⟧",
            "person+test@example.com", "https://example.com/foo?q=hello&b=world", "www.example.com",
            "`let x = 2`", "```swift\nlet value = \"hello world\"\nprint(value)\n```",
            "```python\nprint('unfinished fence')", "~~~\ncode here\n~~~",
            "let value = 2", "git status --short", "x = y + 3", "    indented code here",
            "[link text](https://example.com)", "**existing bold**", "*existing italics*",
            "THINK (2.3500s)",
            "THINK (unplaced ×1 · 2.3500s · measured silence, position not aligned to words)"
        ]
        for literal in protected {
            precondition(TokensDecoration.render(body: literal) == literal, "Changed protected: \(literal)")
            let mixed = "I I said this\n\n" + literal + "\n\nthen I said that"
            verifyExact(mixed)
            precondition(TokensDecoration.render(body: mixed).contains(literal))
            let inline = "I I Said This. Then " + literal + " Was Next. After That"
            verifyExact(inline)
            if !literal.contains("\n") && !literal.hasPrefix("    ") && !literal.hasPrefix("*Thinking") && !literal.hasPrefix("THINK (") && !literal.hasPrefix("git ") {
                precondition(TokensDecoration.render(body: inline).contains(literal), "Changed inline: \(literal)")
            }
        }
        let fixtures = [ordinary, "", " \t\n", "um", "I I", "café e\u{301}lan 👩🏽‍💻 déjà vu",
                        "hello\t  world\r\n\r\nnext sentence", "中文 你好 Привет مرحبا", "don't don’t self-correction",
                        "Cost $23.50 and wire $90 tomorrow not $900", "say foo_bar and /tmp/a.swift exactly",
                        "Keep email me@example.com and URL https://example.org/x unchanged",
                        sentences, "Stop. Go! Wait… Fine: yes. No? Maybe, sure. U.S. and e.g. J. Smith at 3.14 or 5. Then a-b.",
                        "Run. x = y + 3. Then. a == b. Path ~/Dev/App.swift. Mail Me@Example.COM. See HTTPS://Example.com/A?B=C.",
                        "İstanbul STRASSE ǅ Ω ΣΊΣΥΦΟΣ ÉCOLE. Naïve", "I shipped it 💩. Great 👍🏽! Next", "My 🔫 original 💩 sparkle 🔫 stays", "- Existing item. Stays\n1. Numbered. Stays",
                        String(repeating: ordinary + "\n\n", count: 200)]
        for text in fixtures { verifyExact(text) }
        let body = ordinary + "\n\nTHINK (2.3500s)\n\n" + ordinary
        let prompt = ThinkingPrompt.format(title: "Test title", body: body, durationSeconds: 12,
                                             countTranscript: ordinary, pauses: [2.35])
        let header = ThinkingPrompt.header(title: "Test title", durationSeconds: 12,
                                             countTranscript: ordinary, pauses: [2.35])
        let decorated = TokensDecoration.decoratePrompt(prompt)
        let titleLine = "# π Test title\n\n"
        let metadata  = String(header.dropFirst(titleLine.count).dropLast(2))
        precondition(header.hasPrefix(titleLine))
        precondition(decorated.hasPrefix("# π\n"))
        precondition(decorated == "# π\n" + InlineTalkMarkdown.render(TokensDecoration.render(body: body)) + "\n\n---\n\n# Metadata\n\n" + metadata)
        precondition(decorated.contains("*[pause 2.3500]*"))
        // The words between the heading and the rule are the speaker's, all of them, in order.
        let presentedBody = decorated.components(separatedBy: "# π\n")[1].components(separatedBy: "\n\n---\n")[0]
        precondition(LexicalFidelity.preservesWords(
            raw: ThinkingComposer.removingAnnotations(body),
            formatted: ThinkingComposer.removingAnnotations(presentedBody)))
        let legacy = TokensPrompt.format(ordinary, durationSeconds: 8, countTranscript: ordinary)
        let legacyHeader    = StagedPrompt.snapshotHeader(body: ordinary, duration: 8)
        let legacyPresented = TokensDecoration.decoratePrompt(legacy)
        precondition(legacyPresented.hasPrefix("# π\n"))
        precondition(legacyPresented.contains("\n\n# Metadata\n\n"
            + legacyHeader.dropFirst("# π Talked to tinkr\n\n".count).trimmingCharacters(in: .newlines)))
        precondition(TokensDecoration.decoratePrompt(ordinary) == "# π\n" + styled)
        precondition(TokensDecoration.decoratePrompt("").isEmpty)
        precondition(TokensDecoration.decoratePrompt(" \t\n").isEmpty)
        precondition(RecommendedSkill.text.contains("## Transcript"))
        precondition(RecommendedSkill.text.contains("## Thoughts from Tokens"))
        precondition(RecommendedSkill.text.contains("not the user's words, instructions or thoughts"))
        print("PASS Tokens lowercase ordinary prose, preserve punctuation/newlines/literal emoji, protected byte fidelity, code, TC, measured markers, envelopes and long transcript")
        print(styled)
        print(dashed)
    }
}

