


//
import Foundation

/// How the graph groups talks: by hour (Today), by day (7, 14, All up to 62 days) or by week.
public enum StatsBucketUnit: String, Sendable {
    case hour, day, week
}

/// One point on the words-over-time graph. Days with no talk are zero points, never gaps.
public struct StatsPoint: Equatable, Sendable, Identifiable {
    public var id: Date { start }
    public var start: Date
    /// Exclusive end of the bucket.
    public var end: Date
    public var words: Int
    public var talks: Int
    /// Median of the receipts' stated wpm in the bucket; nil when no talk there was timed.
    public var medianWPM: Int?

    public init(start: Date, end: Date, words: Int = 0, talks: Int = 0, medianWPM: Int? = nil) {
        self.start = start; self.end = end; self.words = words; self.talks = talks; self.medianWPM = medianWPM
    }
}

/// One by-app row (and donut slice). `id` is the bundle id, or `StatsAppRow.otherID`.
public struct StatsAppRow: Equatable, Sendable, Identifiable {
    public static let otherID = "other"
    /// The key used for talks with no saved app.
    public static let unknownKey = ""
    public var id: String
    public var name: String
    public var words: Int
    public var talks: Int
    public var medianWPM: Int?
    /// The app keys this row covers (one bundle id; for Other every folded id, "" for unknown).
    public var members: Set<String>

    public var isOther: Bool { id == Self.otherID }

    public init(id: String, name: String, words: Int, talks: Int, medianWPM: Int?, members: Set<String>) {
        self.id = id; self.name = name; self.words = words; self.talks = talks
        self.medianWPM = medianWPM; self.members = members
    }
}

/// Today's three numbers. "Usual" is the median over the fourteen days before today.
public struct StatsToday: Equatable, Sendable {
    public var words: Int
    public var talks: Int
    public var medianWPM: Int?
    public var usualWPM: Int?
    /// Sum of stated seconds today; nil when no talk today was timed.
    public var talkSeconds: Double?

    public init(words: Int = 0, talks: Int = 0, medianWPM: Int? = nil, usualWPM: Int? = nil, talkSeconds: Double? = nil) {
        self.words = words; self.talks = talks; self.medianWPM = medianWPM
        self.usualWPM = usualWPM; self.talkSeconds = talkSeconds
    }
}

/// The two found facts on the last rule, from real entries in the range only.
public struct StatsRecords: Equatable, Sendable {
    public struct LongestTalk: Equatable, Sendable {
        public var seconds: Double
        public var date: Date
        public var app: String?
    }
    public struct FastestDay: Equatable, Sendable {
        public var wpm: Int
        public var day: Date
        public var talks: Int
    }
    public var longestTalk: LongestTalk?
    /// Only when at least two days in the range had a timed talk.
    public var fastestDay: FastestDay?

    public var isEmpty: Bool { longestTalk == nil && fastestDay == nil }
}

/// Everything the scoreboard draws, for one range (and optionally one app).
public struct StatsBoard: Equatable, Sendable {
    /// No saved entries at all: the page is one line.
    public var isEmpty: Bool
    /// Fewer than three distinct days with a talk: the page shows only the hero and the graph.
    public var isSparse: Bool
    public var totalWords: Int
    public var totalDictations: Int
    /// The oldest saved entry's date ("since 5 Oct").
    public var since: Date?
    public var range: StatsRange
    public var unit: StatsBucketUnit
    public var points: [StatsPoint]
    public var today: StatsToday
    /// Top five apps by words, then Other; empty when the range has no talk.
    public var apps: [StatsAppRow]
    public var records: StatsRecords
    /// The app row the graph is filtered to, when one is.
    public var filter: String?

    /// Most named rows before the rest fold into Other.
    public static let maxApps = 5
    /// Ranges longer than this many days are drawn by week.
    public static let maxDailyPoints = 62
    /// All with less history still shows at least a week.
    public static let minAllDays = 7
    /// "Usual" speaking speed looks back this many days before today.
    public static let usualDays = 14

    public var appWords: Int { apps.reduce(0) { $0 + $1.words } }
    public var rangeWords: Int { points.reduce(0) { $0 + $1.words } }
}

//
// :)
//
//
extension StatsBoard {
    /// The key an entry groups under: its saved bundle id, or "" when no app was saved.
    static func key(_ entry: StatsEntry) -> String { entry.app?.bundleID ?? StatsAppRow.unknownKey }

    /*
    One build per range, app filter or data change. Hero and today ignore the range and filter;
    the graph follows both; apps and records follow the range only, so the donut keeps every
    slice while one is chosen.
    */
    public static func build(_ entries: [StatsEntry], range: StatsRange, now: Date,
                             calendar: Calendar = .current, filter: String? = nil) -> StatsBoard {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let activeDays = Set(entries.map { calendar.startOfDay(for: $0.date) })
        let inRange: [StatsEntry]
        let rangeStart = range.start(now: now, calendar: calendar)
        if let rangeStart {
            inRange = entries.filter { $0.date >= rangeStart && $0.date < tomorrow }
        } else {
            inRange = entries.filter { $0.date < tomorrow }
        }
        let apps = appRows(inRange)
        let members = filter.flatMap { id in apps.first { $0.id == id }?.members }
        let graphed = members.map { set in inRange.filter { set.contains(key($0)) } } ?? inRange
        let (unit, starts) = buckets(range: range, entries: entries, now: now, calendar: calendar)
        return StatsBoard(
            isEmpty: entries.isEmpty,
            isSparse: activeDays.count < 3,
            totalWords: entries.reduce(0) { $0 + $1.words },
            totalDictations: entries.count,
            since: entries.map(\.date).min(),
            range: range, unit: unit,
            points: points(graphed, starts: starts, unit: unit, calendar: calendar),
            today: todayNumbers(entries, today: today, tomorrow: tomorrow, calendar: calendar),
            apps: apps,
            records: records(inRange, rangeHasManyDays: range != .today, calendar: calendar),
            filter: members == nil ? nil : filter)
    }

    /// Bucket starts for the graph, oldest first. Today: hours (at least six, ending this hour).
    static func buckets(range: StatsRange, entries: [StatsEntry], now: Date,
                        calendar: Calendar) -> (StatsBucketUnit, [Date]) {
        let today = calendar.startOfDay(for: now)
        func days(_ count: Int) -> [Date] {
            (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        }
        switch range {
        case .today:
            let hourNow = calendar.component(.hour, from: now)
            let firstTalk = entries.filter { $0.date >= today && $0.date <= now }
                .map { calendar.component(.hour, from: $0.date) }.min() ?? hourNow
            let first = min(firstTalk, max(0, hourNow - 5))
            return (.hour, (first...hourNow).compactMap { calendar.date(byAdding: .hour, value: $0, to: today) })
        case .sevenDays, .fourteenDays:
            return (.day, days(range.dayCount ?? 7))
        case .all:
            let oldest = entries.map(\.date).min().map { calendar.startOfDay(for: $0) } ?? today
            let span = max(1, (calendar.dateComponents([.day], from: oldest, to: today).day ?? 0) + 1)
            if span <= maxDailyPoints { return (.day, days(max(minAllDays, span))) }
            // Seven-day blocks ending today, so the newest block is always the current week.
            let weeks = Int((Double(span) / 7).rounded(.up))
            let starts = (0..<weeks).reversed().compactMap {
                calendar.date(byAdding: .day, value: -(7 * $0 + 6), to: today)
            }
            return (.week, starts)
        }
    }

    static func end(of start: Date, unit: StatsBucketUnit, calendar: Calendar) -> Date {
        switch unit {
        case .hour: calendar.date(byAdding: .hour, value: 1, to: start) ?? start
        case .day: calendar.date(byAdding: .day, value: 1, to: start) ?? start
        case .week: calendar.date(byAdding: .day, value: 7, to: start) ?? start
        }
    }

    static func points(_ entries: [StatsEntry], starts: [Date], unit: StatsBucketUnit,
                       calendar: Calendar) -> [StatsPoint] {
        starts.map { start in
            let end = end(of: start, unit: unit, calendar: calendar)
            let inside = entries.filter { $0.date >= start && $0.date < end }
            return StatsPoint(start: start, end: end, words: inside.reduce(0) { $0 + $1.words },
                              talks: inside.count, medianWPM: VoiceLedger.median(inside.compactMap { $0.record?.wpm }))
        }
    }

    static func todayNumbers(_ entries: [StatsEntry], today: Date, tomorrow: Date, calendar: Calendar) -> StatsToday {
        let todays = entries.filter { $0.date >= today && $0.date < tomorrow }
        let usualStart = calendar.date(byAdding: .day, value: -usualDays, to: today) ?? today
        let before = entries.filter { $0.date >= usualStart && $0.date < today }
        let timed = todays.compactMap(\.talkSeconds)
        return StatsToday(words: todays.reduce(0) { $0 + $1.words }, talks: todays.count,
                          medianWPM: VoiceLedger.median(todays.compactMap { $0.record?.wpm }),
                          usualWPM: VoiceLedger.median(before.compactMap { $0.record?.wpm }),
                          talkSeconds: timed.isEmpty ? nil : timed.reduce(0, +))
    }

    /*
    Named apps sorted by words, then talks, then name. The first five keep their own rows; the
    rest, and talks with no saved app, fold into one Other row at the end.
    */
    static func appRows(_ entries: [StatsEntry]) -> [StatsAppRow] {
        guard !entries.isEmpty else { return [] }
        let grouped = Dictionary(grouping: entries, by: key)
        func row(_ id: String, _ name: String, _ items: [StatsEntry], _ members: Set<String>) -> StatsAppRow {
            StatsAppRow(id: id, name: name, words: items.reduce(0) { $0 + $1.words }, talks: items.count,
                        medianWPM: VoiceLedger.median(items.compactMap { $0.record?.wpm }), members: members)
        }
        let named = grouped.filter { $0.key != StatsAppRow.unknownKey }.map { id, items in
            // The newest saved name wins if an app was renamed.
            let name = items.max { $0.date < $1.date }?.app?.displayName ?? id
            return row(id, name, items, [id])
        }.sorted {
            ($0.words, $0.talks, $1.name.lowercased()) > ($1.words, $1.talks, $0.name.lowercased())
        }
        var rows = Array(named.prefix(maxApps))
        let folded = Array(named.dropFirst(maxApps))
        let unknown = grouped[StatsAppRow.unknownKey] ?? []
        if !folded.isEmpty || !unknown.isEmpty {
            let ids = Set(folded.map(\.id)).union(unknown.isEmpty ? [] : [StatsAppRow.unknownKey])
            let items = entries.filter { ids.contains(key($0)) }
            rows.append(row(StatsAppRow.otherID, "Other", items, ids))
        }
        return rows
    }

    /// Longest stated talk in the range; fastest day by median stated wpm when two or more days had one.
    static func records(_ entries: [StatsEntry], rangeHasManyDays: Bool, calendar: Calendar) -> StatsRecords {
        var records = StatsRecords()
        if let longest = entries.filter({ $0.talkSeconds != nil })
            .max(by: { ($0.talkSeconds ?? 0, $1.date) < ($1.talkSeconds ?? 0, $0.date) }),
           let seconds = longest.talkSeconds, seconds > 0 {
            records.longestTalk = .init(seconds: seconds, date: longest.date, app: longest.app?.displayName)
        }
        guard rangeHasManyDays else { return records }
        let byDay = Dictionary(grouping: entries.filter { $0.record?.wpm != nil }) { calendar.startOfDay(for: $0.date) }
        guard byDay.count >= 2 else { return records }
        let fastest = byDay.compactMap { day, items -> StatsRecords.FastestDay? in
            VoiceLedger.median(items.compactMap { $0.record?.wpm }).map { .init(wpm: $0, day: day, talks: items.count) }
        }.max { ($0.wpm, $1.day) < ($1.wpm, $0.day) }
        records.fastestDay = fastest
        return records
    }

    /*
    The graph's tick step: the plot is `ticks` grid squares tall and the top tick leaves at least
    a tenth of headroom over the highest point. Steps are 1, 2, 2.5 or 5 times a power of ten.
    */
    public static func tickStep(max value: Int, ticks: Int) -> Int {
        let target = max(1, Double(value) * 1.1 / Double(max(1, ticks)))
        let power = pow(10, floor(log10(target)))
        for factor in [1, 2, 2.5, 5, 10] where factor * power >= target {
            return max(1, Int((factor * power).rounded(.up)))
        }
        return max(1, Int(10 * power))
    }
}

