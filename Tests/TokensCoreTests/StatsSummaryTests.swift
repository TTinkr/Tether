


//
import Foundation
import Testing
import TokensCore

struct StatsSummaryTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // 2026-10-13 18:00 UTC; local midnight is 2026-10-13 00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_914_400)
    static let midnight = utc.startOfDay(for: now)
    static func at(_ seconds: TimeInterval) -> Date { midnight.addingTimeInterval(seconds) }

    static func timed(_ date: Date, words: Int = 10, seconds: Double? = 4, app: VoiceApp = .codex) -> StatsEntry {
        StatsEntry(date: date, words: words,
                   record: VoiceRecord(date: date, app: app, words: words, seconds: seconds, wpm: seconds.map { _ in 150 }))
    }

    static func build(_ entries: [StatsEntry], _ range: StatsRange) -> StatsSummary {
        StatsSummary.build(entries, range: range, now: now, calendar: utc)
    }

    @Test func emptyHistoryIsEmptyWithNoTalkTime() {
        for range in StatsRange.allCases {
            let summary = Self.build([], range)
            #expect(summary.isEmpty)
            #expect(summary.totals == StatsTotals(talkTimeClipped: range == .all))
            #expect(summary.totals.talkSeconds == nil)
            #expect(summary.ledger.total.talks == 0)
        }
        #expect(StatsSummary.talkTime(nil) == "—")
    }

    @Test func rangeStartsAtLocalMidnight() {
        let entries = [
            Self.timed(Self.at(0)),                  // today 00:00:00, in Today
            Self.timed(Self.at(-1)),                 // yesterday 23:59:59, not in Today
            Self.timed(Self.at(-6 * 86_400)),        // first moment of the 7-day range
            Self.timed(Self.at(-6 * 86_400 - 1)),    // one second before it
            Self.timed(Self.at(-13 * 86_400)),       // first moment of the 14-day range
            Self.timed(Self.at(-13 * 86_400 - 1)),   // one second before it
            Self.timed(Self.at(86_400)),             // tomorrow 00:00 (clock skew): outside every day range
        ]
        #expect(Self.build(entries, .today).totals.dictations == 1)
        #expect(Self.build(entries, .sevenDays).totals.dictations == 3)
        #expect(Self.build(entries, .fourteenDays).totals.dictations == 5)
        #expect(Self.build(entries, .all).totals.dictations == 7)
        #expect(StatsRange.today.start(now: Self.now, calendar: Self.utc) == Self.midnight)
        #expect(StatsRange.all.start(now: Self.now, calendar: Self.utc) == nil)
    }

    @Test func untimedEntriesCountButAddNoSeconds() throws {
        let entries = [
            Self.timed(Self.at(60), words: 12, seconds: 6.4),
            Self.timed(Self.at(120), words: 5, seconds: nil),            // receipt without seconds
            StatsEntry(date: Self.at(180), words: 0, record: nil),       // typed-only / no spoken words
            Self.timed(Self.at(240), words: 3, seconds: .nan),           // malformed duration
            Self.timed(Self.at(300), words: 3, seconds: -2),
        ]
        let totals = Self.build(entries, .today).totals
        #expect(totals.dictations == 5)
        #expect(totals.words == 23)   // 12 + 5 + 0 + 3 + 3
        #expect(totals.timed == 1 && totals.untimed == 4)
        #expect(try #require(totals.talkSeconds) == 6.4)
        // Only untimed entries: talk time is unknown, never zero.
        #expect(Self.build(Array(entries.dropFirst()), .today).totals.talkSeconds == nil)
    }

    @Test func talkTimeNeverReachesPastFourteenDays() throws {
        let entries = [
            Self.timed(Self.at(60), words: 10, seconds: 30),
            Self.timed(Self.at(-13 * 86_400), words: 10, seconds: 30),
            Self.timed(Self.at(-20 * 86_400), words: 50, seconds: 300),
            StatsEntry(date: Self.at(-40 * 86_400), words: 7, record: nil),
        ]
        let all = Self.build(entries, .all).totals
        #expect(all.dictations == 4 && all.words == 77)
        #expect(try #require(all.talkSeconds) == 60)
        #expect(all.talkTimeClipped)
        // The 40-day-old untimed entry is outside the talk window, so it is not reported as untimed.
        #expect(all.timed == 2 && all.untimed == 0)
        let fourteen = Self.build(entries, .fourteenDays).totals
        #expect(!fourteen.talkTimeClipped && fourteen.talkSeconds == 60 && fourteen.dictations == 2)
        #expect(!Self.build(entries, .today).totals.talkTimeClipped)
    }

    @Test func ledgerIgnoresTheRangeAndKeepsFourteenDays() {
        let entries = [Self.timed(Self.at(60), app: .claude), Self.timed(Self.at(-3 * 86_400), app: .terminal),
                       Self.timed(Self.at(-30 * 86_400), app: .cursor)]
        let today = Self.build(entries, .today)
        #expect(today.ledger == Self.build(entries, .all).ledger)
        #expect(today.ledger.days.count == 14)
        #expect(today.ledger.total.talks == 2)
        #expect(today.ledger.apps.map(\.id) == ["claude", "terminal"])
    }

    @Test func talkTimeFormatting() {
        #expect(StatsSummary.talkTime(0) == "0s")
        #expect(StatsSummary.talkTime(44.6) == "45s")
        #expect(StatsSummary.talkTime(59.6) == "1m 00s")
        #expect(StatsSummary.talkTime(725) == "12m 05s")
        #expect(StatsSummary.talkTime(3_599.4) == "59m 59s")
        #expect(StatsSummary.talkTime(11_220) == "3h 07m")
        #expect(StatsSummary.talkTime(-1) == "—")
        #expect(StatsSummary.talkTime(.infinity) == "—")
    }

    @Test func veryLargeHistoryIsOnePass() throws {
        // 200,000 talks over ~2 years, every 5 minutes; half timed at 3 s.
        let count = 200_000
        let entries = (0..<count).map { index -> StatsEntry in
            let date = Self.now.addingTimeInterval(-Double(index) * 300)
            return index.isMultiple(of: 2) ? Self.timed(date, words: 4, seconds: 3)
                : StatsEntry(date: date, words: 4, record: nil)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let summary = Self.build(entries, .all)
        let elapsed = clock.now - started
        #expect(summary.totals.dictations == count)
        #expect(summary.totals.words == count * 4)
        // 18:00 today back to midnight 13 days ago: 13 × 288 + 216 talks + the one at exactly 18:00.
        let window = 13 * 288 + 216 + 1
        #expect(summary.totals.timed + summary.totals.untimed == window)
        #expect(try #require(summary.totals.talkSeconds) == Double(summary.totals.timed) * 3)
        #expect(elapsed < .seconds(10))
    }
}

