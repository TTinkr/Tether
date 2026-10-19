


//
import Foundation
import Testing
@testable import Tokens

/// One replay row. `expected_raw` is the default route (metadata off, character tags off);
/// `expected_tagged` is the character-tags route. `pause` switches both to the pause route.
struct TalkReplayCase: Decodable, Sendable {
    struct Pause: Decodable, Sendable {
        /// Recognizer start time of each whitespace word; each word lasts 0.2 s.
        let starts: [Double]
        /// Measured silences as [start, end] seconds.
        let pauses: [[Double]]
    }
    let id: String
    let category: String
    let input: String
    let expectedRaw: String
    let expectedTagged: String?
    let pause: Pause?
    let expectedFail: Bool?
    let reason: String?
    let note: String?
    /// The case runs with the opt-in "Fix Agent Names" setting on (AgentNameFixes); default off.
    var agentNameFixes: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, category, input, pause, reason, note
        case expectedRaw = "expected_raw", expectedTagged = "expected_tagged", expectedFail = "expected_fail"
        case agentNameFixes = "agent_name_fixes"
    }
    var isExpectedFail: Bool { expectedFail ?? false }
    var fixesAgentNames: Bool { agentNameFixes ?? false }
}

struct TalkReplayFixture: Decodable, Sendable {
    let version: Int
    let cases: [TalkReplayCase]
}

struct TalkReplayFloors: Decodable, Sendable {
    let version: Int
    let measured: String
    let rule: String?
    /// Minimum passing cases per category.
    let floors: [String: Int]
}

//
// :)
//
//
/*
The same calls delivery makes, in the same order. Default route: TalkModel+Delivery brands the
trimmed payload, renderTranscript (Tokens) renders the body, and TokensOutputOptions.parts with
metadata off returns it unchanged. Pause route: TalkModel.thinkingPayload's body step.
*/
enum TalkReplayPipeline {
    static func deliver(_ input: String, characterTags: Bool, agentNameFixes: Bool = false) -> String {
        let canonical = TalkVocabulary.normalizeRecognizedText(input.trimmingCharacters(in: .whitespacesAndNewlines),
                                                               agentNameFixes: agentNameFixes)
        let body = TokensOutputOptions.body(canonical, characterTags: characterTags, numberTags: characterTags)
        return TokensOutputOptions.parts(body, metadata: false).text
    }

    static func deliver(_ input: String, pause: TalkReplayCase.Pause, characterTags: Bool,
                        agentNameFixes: Bool = false) -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = zip(raw.split(whereSeparator: { $0.isWhitespace }), pause.starts).map {
            TimedWord(text: String($0), start: $1, end: $1 + 0.2, isFinal: true)
        }
        let pauses = pause.pauses.map { ThinkingPause(start: $0[0], end: $0[1]) }
        let render: (String) -> String = {
            TokensOutputOptions.body(TalkVocabulary.normalizeRecognizedText($0, agentNameFixes: agentNameFixes),
                                     characterTags: characterTags, numberTags: characterTags)
        }
        let outputBody = render(raw)
        let placement = ThinkingComposer.placement(raw: raw, words: words, pauses: pauses)
        let composed = ThinkingComposer.body(placement.segments, unplaced: placement.unplaced, paragraphs: render)
        guard LexicalFidelity.preservesWords(raw: outputBody,
                                             formatted: ThinkingComposer.removingAnnotations(composed)) else {
            return [outputBody, ThinkingComposer.unplacedSummary(pauses.map(\.duration))]
                .compactMap { $0 }.joined(separator: "\n\n")
        }
        return TokensOutputOptions.parts(composed, metadata: false).text
    }

    /// True when every expectation the case declares matches.
    static func passes(_ row: TalkReplayCase) -> Bool {
        let fixes = row.fixesAgentNames
        let raw = row.pause.map { deliver(row.input, pause: $0, characterTags: false, agentNameFixes: fixes) }
            ?? deliver(row.input, characterTags: false, agentNameFixes: fixes)
        guard raw == row.expectedRaw else { return false }
        guard let tagged = row.expectedTagged else { return true }
        return (row.pause.map { deliver(row.input, pause: $0, characterTags: true, agentNameFixes: fixes) }
            ?? deliver(row.input, characterTags: true, agentNameFixes: fixes)) == tagged
    }
}

//
// :)
//
//
struct TalkReplayScore {
    let category: String
    let total: Int
    let passed: Int
    /// Minimum passing count; the rate is for reading only.
    let floor: Int?
    var rate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    var holdsFloor: Bool { floor.map { passed >= $0 } ?? false }
    var aboveFloor: Bool { floor.map { passed > $0 } ?? false }
}

enum TalkReplayScoreboard {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func load() throws -> (TalkReplayFixture, TalkReplayFloors) {
        let decoder = JSONDecoder()
        let fixture = try decoder.decode(TalkReplayFixture.self,
                                         from: Data(contentsOf: fixtures.appendingPathComponent("talk-replay.json")))
        let floors = try decoder.decode(TalkReplayFloors.self,
                                        from: Data(contentsOf: fixtures.appendingPathComponent("talk-replay-floors.json")))
        return (fixture, floors)
    }

    static func scores(_ cases: [TalkReplayCase], results: [String: Bool], floors: [String: Int]) -> [TalkReplayScore] {
        var order: [String] = []
        for row in cases where !order.contains(row.category) { order.append(row.category) }
        return order.map { category in
            let rows = cases.filter { $0.category == category }
            return TalkReplayScore(category: category, total: rows.count,
                                   passed: rows.filter { results[$0.id] == true }.count, floor: floors[category])
        }
    }

    /// Markdown only: ids, categories, counts and the fixture's own reasons. No transcript words.
    static func markdown(_ scores: [TalkReplayScore], cases: [TalkReplayCase], results: [String: Bool],
                         commit: String?) -> String {
        func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
        var lines = ["# Talk replay scoreboard", ""]
        if let commit { lines.append("Commit: `\(commit)`  ") }
        let passed = scores.map(\.passed).reduce(0, +), total = scores.map(\.total).reduce(0, +)
        lines += ["Cases: \(total) · passing: \(passed) · expected_fail: \(cases.filter(\.isExpectedFail).count)", "",
                  "Floor = minimum passing cases (never decreases). Rate is for reading only.", "",
                  "| Category | Cases | Pass | Rate | Floor | Status |", "|---|---:|---:|---:|---:|---|"]
        for score in scores {
            let status = !score.holdsFloor ? "BELOW FLOOR" : score.aboveFloor ? "above floor (raise it)" : "holds"
            lines.append("| \(score.category) | \(score.total) | \(score.passed) | \(percent(score.rate)) | "
                         + "\(score.floor.map(String.init) ?? "none") | \(status) |")
        }
        let regressions = cases.filter { !$0.isExpectedFail && results[$0.id] != true }
        let fixed = cases.filter { $0.isExpectedFail && results[$0.id] == true }
        let targets = cases.filter { $0.isExpectedFail && results[$0.id] != true }
        if !regressions.isEmpty {
            lines += ["", "## Regressions (must pass)", ""] + regressions.map { "- `\($0.id)` (\($0.category))" }
        }
        if !fixed.isEmpty {
            lines += ["", "## Now passing: drop expected_fail and raise the floor", ""] + fixed.map { "- `\($0.id)`" }
        }
        lines += ["", "## Next hill-climb targets (expected_fail)", "", "| Case | Category | Reason |", "|---|---|---|"]
        lines += targets.map { "| `\($0.id)` | \($0.category) | \($0.reason ?? "") |" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ text: String) throws {
        guard let out = ProcessInfo.processInfo.environment["TOKENS_REPLAY_OUT"], !out.isEmpty else { return }
        var url = URL(fileURLWithPath: out)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: out, isDirectory: &isDirectory), isDirectory.boolValue {
            url = url.appendingPathComponent("talk-replay-scoreboard.md")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

@Suite struct TalkReplayScoreboardTests {
    @Test func fixtureIsWellFormed() throws {
        let (fixture, floors) = try TalkReplayScoreboard.load()
        #expect(fixture.cases.count >= 60)
        #expect(Set(fixture.cases.map(\.id)).count == fixture.cases.count, "case ids must be unique")
        let categories = Set(fixture.cases.map(\.category))
        #expect(categories == Set(floors.floors.keys), "every category needs a floor and every floor a category")
        for (category, floor) in floors.floors {
            let total = fixture.cases.filter { $0.category == category }.count
            #expect(floor >= 0 && floor <= total, "\(category) floor \(floor) must be within 0...\(total)")
        }
        for row in fixture.cases where row.isExpectedFail {
            #expect(!(row.reason ?? "").isEmpty, "expected_fail case \(row.id) needs a reason")
        }
        for row in fixture.cases {
            if let pause = row.pause {
                #expect(pause.starts.isEmpty || pause.starts.count == row.input.split(whereSeparator: { $0.isWhitespace }).count,
                        "pause starts must give one time per word in \(row.id)")
                #expect(pause.pauses.allSatisfy { $0.count == 2 && $0[1] > $0[0] }, "pauses are [start, end] in \(row.id)")
            }
        }
    }

    @Test func categoriesHoldTheirFloors() throws {
        let (fixture, floors) = try TalkReplayScoreboard.load()
        var results: [String: Bool] = [:]
        for row in fixture.cases { results[row.id] = TalkReplayPipeline.passes(row) }
        let scores = TalkReplayScoreboard.scores(fixture.cases, results: results, floors: floors.floors)
        let commit = ProcessInfo.processInfo.environment["TOKENS_REPLAY_COMMIT"]
        try TalkReplayScoreboard.write(TalkReplayScoreboard.markdown(scores, cases: fixture.cases,
                                                                     results: results, commit: commit))
        for score in scores {
            #expect(score.holdsFloor, "\(score.category) at \(score.passed)/\(score.total) is below its floor of \(score.floor ?? 0) passing")
        }
        for row in fixture.cases where !row.isExpectedFail && results[row.id] != true {
            let fixes = row.fixesAgentNames
            let actual = row.pause.map { TalkReplayPipeline.deliver(row.input, pause: $0, characterTags: false, agentNameFixes: fixes) }
                ?? TalkReplayPipeline.deliver(row.input, characterTags: false, agentNameFixes: fixes)
            Issue.record("replay case \(row.id) (\(row.category)) regressed; default route gave: \(actual.debugDescription)")
        }
    }

    /// The hill-climb loop must be able to add a known failure without lowering any floor.
    @Test func addingAnExpectedFailTargetKeepsTheFloor() throws {
        let (fixture, floors) = try TalkReplayScoreboard.load()
        var results: [String: Bool] = [:]
        for row in fixture.cases { results[row.id] = TalkReplayPipeline.passes(row) }
        let baseline = TalkReplayScoreboard.scores(fixture.cases, results: results, floors: floors.floors)
        for category in floors.floors.keys {
            let before = baseline.first { $0.category == category }
            let target = TalkReplayCase(id: "synthetic-target-\(category)", category: category, input: "x",
                                        expectedRaw: "y", expectedTagged: nil, pause: nil, expectedFail: true,
                                        reason: "synthetic", note: nil)
            var widened = results
            widened[target.id] = false
            let score = TalkReplayScoreboard.scores(fixture.cases + [target], results: widened, floors: floors.floors)
                .first { $0.category == category }
            #expect(score?.passed == before?.passed && score?.holdsFloor == before?.holdsFloor,
                    "adding one expected_fail target to \(category) must not change its floor verdict")
        }
    }
}

