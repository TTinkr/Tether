


//
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct StagedPromptTests {
    @Test static func run() {
        precondition(!StagedPrompt.allowsDirectInsertion(bundleIdentifier: "com.openai.codex"))
        precondition(!StagedPrompt.allowsDirectInsertion(bundleIdentifier: "com.google.Chrome"))
        precondition(!StagedPrompt.allowsDirectInsertion(bundleIdentifier: nil))
        precondition(StagedPrompt.allowsDirectInsertion(bundleIdentifier: "com.apple.TextEdit"))

        let body   = "Alpha beta gamma delta epsilon zeta eta theta iota kappa. Tail finishes here."
        let chunks = StagedPrompt.chunks(stableText: body)
        precondition(chunks.count == 4)
        precondition(body.hasPrefix(chunks.joined()))
        let final     = StagedPrompt.render(body: body, duration: 3)
        let committed = StagedPrompt.snapshotHeader(body: body, duration: 3) + chunks.joined()
        let tail      = StagedPrompt.remainder(final: final, committed: committed)!
        precondition(committed + tail == final)
        precondition(final.hasSuffix(body))
        let frozen = StagedPrompt.snapshotHeader(body: "one two", duration: 3)
        precondition(StagedPrompt.render(body: body, duration: 4, frozenHeader: frozen).hasPrefix(frozen))
        precondition(StagedPrompt.remainder(final: final, committed: StagedPrompt.header + "Wrong ") == nil)
        precondition(StagedPrompt.chunks(stableText: "unfinished words with no sentence end").isEmpty)
        precondition(StagedPrompt.chunks(stableText: "talk characters A B C end talk characters.").isEmpty)
        precondition(StagedPrompt.chunks(stableText: "one two three four.").isEmpty)
        precondition(StagedPrompt.stablePrefix("one  two\nthree tail", wordCount: 3) == "one  two\nthree ")
        precondition(StagedPrompt.stablePrefix(body, wordCount: 0).isEmpty)
        let unicode = "👩🏽‍💻 café é go forward now."
        precondition(unicode.hasPrefix(StagedPrompt.chunks(stableText: unicode).joined()))
        for count in 0...20 {
            let prefix = StagedPrompt.stablePrefix(body, wordCount: count)
            precondition(body.hasPrefix(prefix))
            precondition(StagedPrompt.chunks(stableText: prefix).count <= 4)
        }
        print("PASS staged header/flow/tail reconstruction, immutable-prefix rejection, finalized-only flow, TC/TN bypass, whitespace and graphemes")
    }
}

