


//
import Foundation
import Testing
@testable import Tokens

/// One fixture row: what was recognized, what should be pasted, and the Markdown form.
/// A nil markdown means "same as delivery" (no number span is expected).
struct NumberTalkCase: Sendable, CustomTestStringConvertible {
    let raw: String
    let delivery: String
    let markdown: String?
    var testDescription: String { raw }
}

@Suite struct NumberTalkDecodeTests {
    /*
    Every spoken number word decodes as itself inside a run of three, and a spoken tens word
    followed by a spoken unit word joins into one number.
    */
    static let decoded: [NumberTalkCase] = [
        // Each of the 28 words (plus "oh") decodes as itself.
        .init(raw: "port nineteen sixty eighty", delivery: "port 19 60 80", markdown: "port *<num>19 60 80</num>*"),
        .init(raw: "four fourteen seventy", delivery: "4 14 70", markdown: "*<num>4 14 70</num>*"),
        .init(raw: "line eighteen ninety nine", delivery: "line 18 99", markdown: "line *<num>18 99</num>*"),
        .init(raw: "zero oh one nineteen", delivery: "0 0 1 19", markdown: "*<num>0 0 1 19</num>*"),
        .init(raw: "two three five", delivery: "2 3 5", markdown: "*<num>2 3 5</num>*"),
        .init(raw: "six seven eight", delivery: "6 7 8", markdown: "*<num>6 7 8</num>*"),
        .init(raw: "nine ten eleven", delivery: "9 10 11", markdown: "*<num>9 10 11</num>*"),
        .init(raw: "twelve thirteen fifteen", delivery: "12 13 15", markdown: "*<num>12 13 15</num>*"),
        .init(raw: "sixteen seventeen eighteen", delivery: "16 17 18", markdown: "*<num>16 17 18</num>*"),
        .init(raw: "thirty forty fifty", delivery: "30 40 50", markdown: "*<num>30 40 50</num>*"),
        .init(raw: "seventy eighty ninety", delivery: "70 80 90", markdown: "*<num>70 80 90</num>*"),
        .init(raw: "ten twenty sixty", delivery: "10 20 60", markdown: "*<num>10 20 60</num>*"),
        // Teens next to units.
        .init(raw: "seven seventeen seven", delivery: "7 17 7", markdown: "*<num>7 17 7</num>*"),
        .init(raw: "sixteen six sixty", delivery: "16 6 60", markdown: "*<num>16 6 60</num>*"),
        .init(raw: "eight eighteen eighty", delivery: "8 18 80", markdown: "*<num>8 18 80</num>*"),
        .init(raw: "nine nineteen ninety", delivery: "9 19 90", markdown: "*<num>9 19 90</num>*"),
        .init(raw: "four fourteen forty", delivery: "4 14 40", markdown: "*<num>4 14 40</num>*"),
        // Tens + unit pairs join.
        .init(raw: "twenty one twenty two", delivery: "21 22", markdown: "*<num>21 22</num>*"),
        .init(raw: "two twenty five", delivery: "2 25", markdown: "*<num>2 25</num>*"),
        .init(raw: "thirty three three", delivery: "33 3", markdown: "*<num>33 3</num>*"),
        .init(raw: "twenty ten two", delivery: "20 10 2", markdown: "*<num>20 10 2</num>*"),
        .init(raw: "sixty ten one", delivery: "60 10 1", markdown: "*<num>60 10 1</num>*"),
        .init(raw: "forty two forty two", delivery: "42 42", markdown: "*<num>42 42</num>*"),
        // Commas are allowed inside a run, but a tens word never joins a unit across one.
        .init(raw: "twenty, one, two", delivery: "20 1 2", markdown: "*<num>20 1 2</num>*"),   // list boundaries kept
        .init(raw: "twenty one, twenty two", delivery: "21 22", markdown: "*<num>21 22</num>*"),
        .init(raw: "forty, two, seven", delivery: "40 2 7", markdown: "*<num>40 2 7</num>*"),
        // Case does not matter.
        .init(raw: "Nineteen Sixty Eighty", delivery: "19 60 80", markdown: "*<num>19 60 80</num>*"),
        // Digit tokens decode as themselves and never join.
        .init(raw: "version 1 2 3", delivery: "version 1 2 3", markdown: "version *<num>1 2 3</num>*"),
        .init(raw: "20 1 2", delivery: "20 1 2", markdown: "*<num>20 1 2</num>*"),
        .init(raw: "twenty 1 2", delivery: "20 1 2", markdown: "*<num>20 1 2</num>*"),
        .init(raw: "Open port eighty eighty then go.", delivery: "Open port eighty eighty then go.", markdown: nil),
        .init(raw: "Ports sixty ninety eighty, then stop.", delivery: "Ports 60 90 80, then stop.",
              markdown: "Ports *<num>60 90 80</num>*, then stop."),
    ]

    /*
    Prose and protected spans that must come out byte-identical in delivery and Markdown.
    */
    static let unchanged: [String] = [
        "twenty 3 Qwen",
        "one of the two",
        "I have two or three ideas",
        "the one thing",
        "nineteen sixty",
        "someone twenty",
        "stone two three",
        "`one two three`",
        "`nineteen sixty eighty`",
        "```swift\nnineteen sixty eighty\n```",
    ]

    @Test(arguments: decoded)
    func spokenNumberDecodesAsSaid(_ row: NumberTalkCase) {
        let rendered = CharacterTalk.render(row.raw)
        #expect(rendered.deliveryText == row.delivery)
        #expect(rendered.markdownText == (row.markdown ?? row.delivery))
        #expect(rendered.hasNumberSpan == (row.markdown != nil))
    }

    @Test(arguments: unchanged)
    func proseAndProtectedSpansStayAsSpoken(_ raw: String) {
        let rendered = CharacterTalk.render(raw)
        #expect(rendered.deliveryText == raw)
        #expect(rendered.markdownText == raw)
    }

    @Test func displayMarkersWrapTheDecodedRun() {
        let rendered = CharacterTalk.render("port nineteen sixty eighty")
        #expect(rendered.displayText.contains(NumberTalk.openMarker + "19 60 80" + NumberTalk.closeMarker))
    }
}

/// Codex integration review 2026-10-13: agent names are opt-in; the default raw path is faithful.
@Suite struct AgentNameFixesGateTests {
    @Test func defaultOffLeavesAgentWordsAsSaid() {
        let said = "send this to codecs in the agent chat and ask cloud code"
        #expect(TalkVocabulary.normalizeRecognizedText(said, agentNameFixes: false) == said)
    }

    @Test func optedInCorrectsOnlyAgentSentences() {
        #expect(TalkVocabulary.normalizeRecognizedText("send this to codecs in the agent chat", agentNameFixes: true)
                == "send this to Codex in the agent chat")
        for literal in ["ask the agent about compression codecs", "this chat has soul",
                        "https://example.com/chat/codecs is the agent link"] {
            #expect(TalkVocabulary.normalizeRecognizedText(literal, agentNameFixes: true) == literal)
        }
    }

    @Test func keyDefaultsToOff() {
        let suite = UserDefaults(suiteName: "AgentNameFixesGateTests.\(UUID().uuidString)")!
        #expect(AgentNameFixes.isEnabled(in: suite) == false)
        suite.set(true, forKey: AgentNameFixes.key)
        #expect(AgentNameFixes.isEnabled(in: suite))
    }
}

