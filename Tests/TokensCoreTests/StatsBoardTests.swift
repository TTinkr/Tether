


//
import Foundation
import Testing
import TokensCore

struct StatsBoardTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // 2026-10-13 18:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_914_400)
    static let midnight = utc.startOfDay(for: now)
    static func day(_ ago: Int, hour: Double = 10) -> Date {
        midnight.addingTimeInterval(-Double(ago) * 86_400 + hour * 3_600)
    }

    static func app(_ id: String) -> PromptTargetApp { PromptTargetApp(bundleID: "com.example.\(id)", name: id) }

    static func entry(_ date: Date, words: Int = 10, wpm: Int? = 150, seconds: Double? = nil,
                      app: PromptTargetApp? = nil) -> StatsEntry {
        let stated = seconds ?? wpm.map { Double(words) * 60 / Double($0) }
        return StatsEntry(date: date, words: words,
                          record: VoiceRecord(date: date, app: .other, words: words, seconds: stated, wpm: wpm), app: app)
    }

    static func build(_ entries: [StatsEntry], _ range: StatsRange, filter: String? = nil) -> StatsBoard {
        StatsBoard.build(entries, range: range, now: now, calendar: utc, filter: filter)
    }

    @Test func emptyHistoryIsOneLine() {
        for range in StatsRange.allCases {
            let board = Self.build([], range)
            #expect(board.isEmpty && board.isSparse)
            #expect(board.totalWords == 0 && board.totalDictations == 0 && board.since == nil)
            #expect(board.apps.isEmpty && board.records.isEmpty)
            #expect(board.points.allSatisfy { $0.words == 0 && $0.talks == 0 })
        }
    }

    @Test func sparseUntilThreeActiveDays() {
        let two = [Self.entry(Self.day(0)), Self.entry(Self.day(0, hour: 11)), Self.entry(Self.day(4))]
        #expect(Self.build(two, .sevenDays).isSparse)
        #expect(!Self.build(two + [Self.entry(Self.day(30))], .sevenDays).isSparse)
    }

    @Test func heroIgnoresTheRange() {
        let entries = [Self.entry(Self.day(0), words: 5), Self.entry(Self.day(9), words: 7), Self.entry(Self.day(40), words: 11)]
        for range in StatsRange.allCases {
            let board = Self.build(entries, range)
            #expect(board.totalWords == 23 && board.totalDictations == 3)
            #expect(board.since == Self.day(40))
        }
        #expect(Self.build(entries, .sevenDays).rangeWords == 5)
        #expect(Self.build(entries, .fourteenDays).rangeWords == 12)
        #expect(Self.build(entries, .all).rangeWords == 23)
    }

    @Test func byAppKeepsFiveAndFoldsTheRestIntoOther() throws {
        // Seven named apps with distinct word totals, plus two talks with no saved app.
        var entries: [StatsEntry] = []
        for (index, words) in [700, 600, 500, 400, 300, 200, 100].enumerated() {
            entries.append(Self.entry(Self.day(1), words: words, wpm: 150 + index, app: Self.app("app\(index)")))
        }
        entries.append(Self.entry(Self.day(0), words: 50, wpm: nil, app: nil))
        entries.append(Self.entry(Self.day(0), words: 25, wpm: nil, app: nil))
        let board = Self.build(entries, .sevenDays)
        #expect(board.apps.map(\.name) == ["app0", "app1", "app2", "app3", "app4", "Other"])
        let other = try #require(board.apps.last)
        #expect(other.isOther && other.id == StatsAppRow.otherID)
        #expect(other.words == 200 + 100 + 50 + 25 && other.talks == 4)
        #expect(other.members == ["com.example.app5", "com.example.app6", StatsAppRow.unknownKey])
        #expect(other.medianWPM == Int((Double(155 + 156) / 2).rounded()))
        #expect(board.appWords == board.rangeWords)
        #expect(board.apps.count <= StatsBoard.maxApps + 1)
    }

    @Test func otherOnlyWhenSomethingFolds() {
        let named = (0..<5).map { Self.entry(Self.day(0), words: 10 * ($0 + 1), app: Self.app("a\($0)")) }
        #expect(!Self.build(named, .today).apps.contains { $0.isOther })
        let withUnknown = Self.build(named + [Self.entry(Self.day(0), app: nil)], .today)
        #expect(withUnknown.apps.last?.isOther == true && withUnknown.apps.last?.members == [StatsAppRow.unknownKey])
        // Ties on words break by talks, then by name.
        let tied = Self.build([Self.entry(Self.day(0), words: 10, app: Self.app("b")),
                               Self.entry(Self.day(0), words: 10, app: Self.app("a"))], .today)
        #expect(tied.apps.map(\.name) == ["a", "b"])
    }

    @Test func rangesBucketByHourDayAndWeek() throws {
        let entries = [Self.entry(Self.day(0, hour: 9.5), words: 4), Self.entry(Self.day(0, hour: 17.2), words: 6),
                       Self.entry(Self.day(3), words: 8)]
        let today = Self.build(entries, .today)
        #expect(today.unit == .hour)
        // From the first talk's hour (9) through this hour (18).
        #expect(today.points.count == 10)
        #expect(today.points.first?.start == Self.day(0, hour: 9) && today.points.last?.start == Self.day(0, hour: 18))
        #expect(today.points.map(\.words).reduce(0, +) == 10)

        let week = Self.build(entries, .sevenDays)
        #expect(week.unit == .day && week.points.count == 7)
        #expect(week.points.last?.start == Self.midnight && week.points.last?.words == 10 && week.points.last?.talks == 2)
        #expect(week.points[3].words == 8)
        #expect(Self.build(entries, .fourteenDays).points.count == 14)

        // All: from the oldest day, at least a week, daily up to 62 days.
        #expect(Self.build(entries, .all).points.count == 7)
        let month = Self.build(entries + [Self.entry(Self.day(40))], .all)
        #expect(month.unit == .day && month.points.count == 41 && month.points.first?.start == Self.day(40, hour: 0))
        let long = Self.build(entries + [Self.entry(Self.day(100), words: 3)], .all)
        #expect(long.unit == .week)
        #expect(long.points.count == 15)   // 101 days → 15 seven-day blocks ending today
        let last = try #require(long.points.last)
        #expect(last.end == Self.utc.date(byAdding: .day, value: 1, to: Self.midnight))
        #expect(long.points.map(\.words).reduce(0, +) == 21)
    }

    @Test func medianSpeedTodayAndUsual() {
        let entries = [
            Self.entry(Self.day(0), wpm: 200), Self.entry(Self.day(0), wpm: 211),       // today: (200+211)/2 = 205.5 → 206
            Self.entry(Self.day(0), wpm: nil),                                              // untimed: counted, no speed
            Self.entry(Self.day(2), wpm: 180), Self.entry(Self.day(5), wpm: 190), Self.entry(Self.day(13), wpm: 230),
            Self.entry(Self.day(15), wpm: 999),                                             // outside the 14 usual days
        ]
        let board = Self.build(entries, .sevenDays)
        #expect(board.today.medianWPM == 206)
        #expect(board.today.usualWPM == 190)
        #expect(board.today.talks == 3 && board.today.words == 30)
        #expect(board.points.last?.medianWPM == 206)
        #expect(board.points[4].medianWPM == 180 && board.points[3].medianWPM == nil)
        let noneToday = Self.build([Self.entry(Self.day(1), wpm: 170)], .sevenDays)
        #expect(noneToday.today.medianWPM == nil && noneToday.today.usualWPM == 170 && noneToday.today.talkSeconds == nil)
    }

    @Test func todayTalkTimeAddsOnlyStatedSeconds() {
        let entries = [Self.entry(Self.day(0), seconds: 30), Self.entry(Self.day(0), wpm: nil, seconds: nil),
                       Self.entry(Self.day(0), seconds: 12.5), Self.entry(Self.day(1), seconds: 100)]
        // The untimed one has no wpm and no seconds; the yesterday one is not today.
        #expect(Self.build(entries, .sevenDays).today.talkSeconds == 42.5)
    }

    @Test func recordsComeFromTheRange() throws {
        let entries = [
            Self.entry(Self.day(0), words: 20, wpm: 200, seconds: 95, app: Self.app("Codex")),
            Self.entry(Self.day(2), words: 20, wpm: 231, seconds: 60),
            Self.entry(Self.day(2), words: 20, wpm: 229, seconds: 40),
            Self.entry(Self.day(10), words: 20, wpm: 260, seconds: 372),
        ]
        let week = Self.build(entries, .sevenDays)
        let longest = try #require(week.records.longestTalk)
        #expect(longest.seconds == 95 && longest.app == "Codex" && longest.date == Self.day(0))
        let fastest = try #require(week.records.fastestDay)
        #expect(fastest.wpm == 230 && fastest.day == Self.day(2, hour: 0) && fastest.talks == 2)
        let fortnight = Self.build(entries, .fourteenDays)
        #expect(fortnight.records.longestTalk?.seconds == 372 && fortnight.records.fastestDay?.wpm == 260)
        // Today never names a fastest day; one timed day is not a record.
        #expect(Self.build(entries, .today).records.fastestDay == nil)
        #expect(Self.build([entries[1], entries[2]], .sevenDays).records.fastestDay == nil)
    }

    @Test func filterNarrowsTheGraphOnly() {
        let entries = [Self.entry(Self.day(0), words: 30, app: Self.app("Codex")),
                       Self.entry(Self.day(0), words: 12, app: Self.app("Mail")),
                       Self.entry(Self.day(1), words: 7, app: nil)]
        let board = Self.build(entries, .sevenDays, filter: "com.example.Codex")
        #expect(board.filter == "com.example.Codex")
        #expect(board.rangeWords == 30)
        #expect(board.apps.map(\.words) == [30, 12, 7])
        #expect(board.totalWords == 49 && board.today.words == 42)
        let other = Self.build(entries, .sevenDays, filter: StatsAppRow.otherID)
        #expect(other.rangeWords == 7)
        #expect(Self.build(entries, .sevenDays, filter: "com.example.Gone").filter == nil)
    }

    @Test func tickStepLeavesHeadroomOnRoundNumbers() {
        #expect(StatsBoard.tickStep(max: 1_240, ticks: 3) == 500)
        #expect(StatsBoard.tickStep(max: 100, ticks: 3) == 50)
        #expect(StatsBoard.tickStep(max: 0, ticks: 3) == 1)
        #expect(StatsBoard.tickStep(max: 9, ticks: 3) == 5)
        for value in [1, 7, 42, 380, 999, 12_480, 250_000] {
            let step = StatsBoard.tickStep(max: value, ticks: 3)
            #expect(Double(step * 3) >= Double(value) * 1.1)
        }
    }
}

