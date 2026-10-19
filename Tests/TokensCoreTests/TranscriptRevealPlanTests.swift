import Foundation
import Testing
@testable import TokensCore

struct TranscriptRevealPlanTests {
    private func plan(_ body: String, words: Int = 1) -> TranscriptRevealPlan {
        .init(marker: "", body: body, metadata: "", spokenWordCount: words)
    }
    @Test func approvedEquationGoldenFrontiers() {
        let value = plan(String(repeating: "a", count: 372))
        // Independently evaluated approved polynomial at exact checkpoints.
        for (time, expected) in [(0.0, 0.0), (0.05, 4.275), (0.1, 9.9),
                                 (0.2, 36.31111111111111), (0.3, 134.7888888888889), (0.4, 372.0)] {
            #expect(abs(value.position(at: time) - expected) < 1e-9)
        }
        #expect(value.duration == 0.4)
        #expect(value.visibleBodyCount(at: 0.05) == 4)
        #expect(value.visibleBodyCount(at: 0.1) == 9)
        #expect(!value.hasSeparateOpening)
        #expect(value.openingCharacters == 0)
    }
    @Test func firstHundredMillisecondsAreIndependentOfLengthAndWords() {
        for count in [72, 372, 2500, 100_000] {
            let value = plan(String(repeating: "x", count: count), words: count)
            #expect(value.visibleBodyCount(at: 0) == 0)
            #expect(value.visibleBodyCount(at: 0.01) == 0)
            #expect(value.visibleBodyCount(at: 0.02) == 1)
            #expect(value.visibleBodyCount(at: 0.1) == 9)
            #expect(value.duration == 0.4)
            #expect(value.visibleBodyCount(at: 0.4) == count)
        }
    }
    @Test func whitespaceAndUnicodeMapToExactLiteralPrefixes() {
        let body = " \t👩🏽‍💻\n\ne\u{301} café\r\n🇳🇿  "
        let value = plan(body)
        let graphemes = Array(body)
        #expect(value.nonWhitespaceCount == 7)
        var previous = ""
        for frame in 0...400 {
            let visible = value.visibleText(at: Double(frame) / 1000)
            let prefix = String(graphemes.prefix(value.visibleBodyCount(at: Double(frame) / 1000)))
            #expect(visible.utf8.elementsEqual(prefix.utf8))
            #expect(visible.utf8.starts(with: previous.utf8))
            previous = visible
        }
        #expect(value.visibleText(at: 0.02).utf8.elementsEqual(" \t👩🏽‍💻\n\n".utf8))
        #expect(previous.utf8.elementsEqual(body.utf8))
    }
    @Test func shortEmptyAndWhitespaceOnlyCompleteNaturally() {
        #expect(plan("").duration == 0)
        #expect(plan("").visibleText(at: 0) == "")
        #expect(plan(" \n\t").duration == 0)
        #expect(plan(" \n\t").visibleText(at: 0) == " \n\t")
        for count in [1, 2, 16, 71] {
            let value = plan(String(repeating: "a", count: count))
            #expect(value.duration > 0 && value.duration < 0.4)
            #expect(value.visibleBodyCount(at: value.duration) == count)
            #expect(value.position(at: 0) == 0)
        }
    }
    @Test func entireLongBodyUsesOneMonotoneCurveWithoutCapOrTail() {
        let body = String(repeating: "word\n", count: 2500)
        let value = plan(body)
        var previous = 0
        for frame in 0...400 {
            let visible = value.visibleBodyCount(at: Double(frame) / 1000)
            #expect(visible >= previous && visible <= body.count)
            previous = visible
        }
        #expect(value.visibleBodyCount(at: 0.2) > 72)
        #expect(value.visibleBodyCount(at: 0.399) < body.count)
        #expect(value.visibleBodyCount(at: 0.4) == body.count)
        #expect(value.visibleText(at: 0.4).utf8.elementsEqual(body.utf8))
    }
    @Test func literalAnnotationsDoNotCreateAtomicJumps() {
        let value = plan("<char>RILEY</char> `literal code` [link](example)")
        #expect(value.visibleText(at: 0.02) == "<")
        #expect(value.safeBodyCount(upTo: 3) == 3)
        #expect(value.nextSafeBodyCount(after: 3) == 4)
        #expect(value.safeBodyCount(upTo: Int.max) == value.body.count)
        #expect(value.nextSafeBodyCount(after: Int.max) == value.body.count)
    }
    @Test func authoredEnvelopeAndInvalidClocksRemainExact() {
        let value = TranscriptRevealPlan(marker: "# π\n", body: "hello", metadata: "\nfooter", spokenWordCount: 1000)
        for time in [-1.0, -.infinity, .nan] {
            #expect(value.visibleBodyCount(at: time) == 0)
            #expect(value.visibleText(at: time) == value.marker)
        }
        #expect(value.visibleText(at: .infinity) == value.completeText)
        #expect(value.removingMarker().completeText == "hello\nfooter")
        #expect(value.prependingMarker("start").completeText == "start" + value.completeText)
        #expect(value.duration == plan("hello", words: 1).duration)
    }
}
