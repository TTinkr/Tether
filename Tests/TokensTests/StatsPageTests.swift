


//
import Foundation
import Testing
@testable import Tokens
import TokensCore

@MainActor
@Suite struct StatsPageTests {
    /// The one shared fixture: the same history the synthetic render shows.
    static func fixture(now: Date) -> (history: [PromptHistoryEntry], events: [TokensStatsSource.Event]) {
        let history = TokensStatsFixture.history(now: now)
        return (history, TokensStatsFixture.events(for: history))
    }

    @Test func totalsEqualHomeCaptionAndVoiceLedger() throws {
        let now = Date()
        let (history, events) = Self.fixture(now: now)
        let entries = TokensStatsSource.entries(history, events: events)
        let home = TokensStatsSource.homeWordCounts(history)
        let today = StatsSummary.build(entries, range: .today, now: now)
        let all = StatsSummary.build(entries, range: .all, now: now)
        let fourteen = StatsSummary.build(entries, range: .fourteenDays, now: now)

        // Home: "N words today" and the tooltip's "N words all time · N dictations".
        #expect(home.today > 0 && home.total > home.today)
        #expect(today.totals.words == home.today)
        #expect(all.totals.words == home.total)
        #expect(all.totals.dictations == history.count)
        // Home's Today line reads Stats' own "Today" range (no events: talk time needs none).
        let line = TokensHomeToday.summary(history: history, wordsTotal: home.total, now: now)
        #expect(line.words == today.totals.words)
        #expect(line.dictations == today.totals.dictations)
        #expect(line.talkSeconds == today.totals.talkSeconds)

        // VoiceLedger ("Your voice"), built exactly as its window builds it.
        let records = VoiceLedgerSource.records(history, events: events)
        let ledger = VoiceLedger.build(records, now: now)
        #expect(fourteen.ledger == ledger)
        #expect(fourteen.totals.dictations == ledger.total.talks)
        #expect(fourteen.totals.words == ledger.total.words)
        let window = try #require(StatsRange.fourteenDays.start(now: now, calendar: .current))
        let seconds = records.filter { $0.date >= window && $0.date <= now }.compactMap(\.seconds).reduce(0, +)
        #expect(try #require(fourteen.totals.talkSeconds) == seconds)
        #expect(fourteen.totals.untimed == 2)   // the two plain entries today
        // Entries older than the 14-day window (the three 20–40 days old, plus any fixture day that
        // falls before the window's local-midnight start when the test runs just after midnight)
        // count under All but add no talk time.
        let older = history.filter { $0.createdAt < window }.count
        #expect(older >= 3)
        #expect(all.totals.dictations == fourteen.totals.dictations + older)
        #expect(all.totals.talkSeconds == fourteen.totals.talkSeconds && all.totals.talkTimeClipped)
    }

    @Test func appAttributionFallsBackToOther() throws {
        let now = Date()
        let entry = PromptHistoryEntry(id: UUID(), createdAt: now, text: "four plain spoken words")
        func app(_ events: [TokensStatsSource.Event]) throws -> VoiceApp {
            try #require(TokensStatsSource.entries([entry], events: events, appName: { _ in nil }).first?.record).app
        }
        #expect(try app([]) == .other)
        #expect(try app([(now.addingTimeInterval(2), "Fixture Editor")]) == .other)
        #expect(try app([(now.addingTimeInterval(2), "fixture-codex")]) == .codex)
        #expect(try app([(now.addingTimeInterval(91), "com.openai.codex")]) == .other)
        // A typed-only entry still counts as a dictation, with no record and no words.
        let empty = TokensStatsSource.entries([PromptHistoryEntry(id: UUID(), createdAt: now, text: "  ")], events: [])
        #expect(empty.count == 1 && empty[0].record == nil && empty[0].words == 0 && empty[0].app == nil)
    }

    @Test func savedTargetAppWinsOverTheEventsJoin() throws {
        let now = Date()
        let saved = PromptTargetApp(bundleID: "com.openai.codex", name: "Codex")
        let events: [TokensStatsSource.Event] = [(now.addingTimeInterval(2), "com.apple.Terminal")]
        let withApp = PromptHistoryEntry(id: UUID(), createdAt: now, text: "four plain spoken words", targetApp: saved)
        let without = PromptHistoryEntry(id: UUID(), createdAt: now, text: "four plain spoken words")
        var asked: [String] = []
        let entries = TokensStatsSource.entries([withApp, without], events: events, now: now,
                                                appName: { asked.append($0); return "Terminal" })
        #expect(entries[0].app == saved)
        #expect(entries[1].app == PromptTargetApp(bundleID: "com.apple.Terminal", name: "Terminal"))
        #expect(asked == ["com.apple.Terminal"])
        // Older than the 14-day window: no events join, so no app.
        let old = PromptHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-20 * 86_400), text: "four plain spoken words")
        #expect(TokensStatsSource.entries([old], events: [(old.createdAt, "com.apple.Terminal")], now: now).first?.app == nil)
    }

    /// TOK-QA-003: each range segment has its own spoken name, and none is the bare number.
    @Test func rangeSegmentsSayTheirOwnNames() {
        let spoken = StatsRange.allCases.map(TokensStatsCopy.rangeSpoken)
        #expect(Set(spoken).count == StatsRange.allCases.count)
        #expect(spoken.allSatisfy { Int($0) == nil && $0 != "Range" })
    }

    @Test func entriesCarryNoText() {
        let entry = StatsEntry(date: Date(), words: 3, record: nil)
        // The app is an id and a name, never a word of the talk.
        #expect(Mirror(reflecting: entry).children.compactMap(\.label) == ["date", "words", "record", "app"])
        let record = VoiceRecord(date: Date(), app: .other, words: 3)
        #expect(!Mirror(reflecting: record).children.contains { $0.value is String })
    }

    @Test func fixtureNeedsARenderProof() {
        let render = ["Tokens", "--render-preview-frames", "/tmp/x", "--stats-fixture", "synthetic"]
        #expect(TokensStatsFixture.requested(arguments: render, allowed: true, synthetic: true) == .synthetic)
        #expect(TokensStatsFixture.requested(arguments: render, allowed: false, synthetic: true) == nil)
        #expect(TokensStatsFixture.requested(arguments: render, allowed: true, synthetic: false) == nil)
        #expect(TokensStatsFixture.requested(arguments: ["Tokens", "--stats-fixture", "synthetic"],
                                             allowed: true, synthetic: true) == nil)
        #expect(TokensStatsFixture.requested(arguments: ["Tokens", "--render-preview-frames", "/x", "--stats-fixture", "EMPTY"],
                                             allowed: true, synthetic: true) == .empty)
        #expect(TokensStatsFixture.requested(arguments: ["Tokens", "--render-preview-frames", "/x", "--stats-fixture", "sparse"],
                                             allowed: true, synthetic: true) == .sparse)
        #expect(TokensStatsFixture.requested(arguments: ["Tokens", "--render-preview-frames", "/x", "--stats-fixture", "real"],
                                             allowed: true, synthetic: true) == nil)
        #expect(TokensStatsFixture.requested(arguments: ["Tokens", "--render-preview-frames", "/x", "--stats-fixture"],
                                             allowed: true, synthetic: true) == nil)
        #expect(TokensStatsFixture.pose(arguments: ["--stats-hover", "Slice"]) == .slice)
        #expect(TokensStatsFixture.range(arguments: ["--stats-range", "14"]) == .fourteenDays)
        #expect(TokensStatsFixture.range(arguments: ["--stats-range", "30"]) == nil)
    }

    /// The synthetic scoreboard fixture shows five apps and Other, and only real-shaped numbers.
    @Test func syntheticFixtureFillsTheScoreboard() throws {
        let now = Date()
        let entries = TokensStatsSource.entries(TokensStatsFixture.history(now: now), events: [], now: now)
        let board = StatsBoard.build(entries, range: .sevenDays, now: now)
        #expect(!board.isEmpty && !board.isSparse)
        #expect(board.apps.count == StatsBoard.maxApps + 1 && board.apps.last?.isOther == true)
        #expect(board.apps.first?.name == "Codex")
        #expect(board.points.count == 7 && board.today.talks > 0 && board.today.medianWPM != nil)
        #expect(board.records.longestTalk != nil && board.records.fastestDay != nil)
        let sparse = TokensStatsSource.entries(TokensStatsFixture.history(now: now, kind: .sparse), events: [], now: now)
        #expect(StatsBoard.build(sparse, range: .sevenDays, now: now).isSparse)
    }

    @Test func copyMatchesTheContract() {
        #expect(TokensStatsCopy.empty == "Your first talk will show up here.")
        #expect(StatsRange.allCases.map(TokensStatsCopy.rangeShort) == ["Today", "7", "14", "All"])
        #expect(StatsRange.allCases.map(TokensStatsCopy.rangePhrase) == ["today", "last 7 days", "last 14 days", "all time"])
        let tiles = TokensStatsCopy.today(StatsToday(words: 760, talks: 4, medianWPM: 208, usualWPM: 198, talkSeconds: 372))
        #expect(tiles.map(\.label) == ["Words today", "Speaking speed", "Talk time today"])
        #expect(tiles.map(\.value) == [760.formatted(), "208", "6m 12s"])
        #expect(tiles[1].unit == "wpm" && tiles[1].note == "usual 198")
        let quiet = TokensStatsCopy.today(StatsToday())
        #expect(quiet.map(\.value) == ["0", "—", "—"])
        // Nothing on the page talks about time saved, streaks or goals.
        let words = (tiles + quiet).flatMap { [$0.label, $0.note ?? "", $0.help] }.joined(separator: " ").lowercased()
        for banned in ["time saved", "streak", "goal", "typing", "faster"] { #expect(!words.contains(banned)) }
    }

    /// Build 82: Models joins the rail after Stats, beside Settings.
    @Test func railOrderPutsStatsAfterDictionaryAndModelsBeforeSettings() {
        #expect(TokensHome.Section.allCases.map(\.rawValue) == ["Home", "History", "Dictionary", "Stats", "Models", "Settings"])
        #expect(StatsRange.allCases.map(\.label) == ["Today", "7 days", "14 days", "All"])
    }
}

