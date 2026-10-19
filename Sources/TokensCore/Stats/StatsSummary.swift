


//
import Foundation

/// The page's range control, in display order. Day ranges end at the next local midnight.
public enum StatsRange: String, CaseIterable, Sendable {
    case today, sevenDays, fourteenDays, all

    /// VoiceLedger's window; talk time and the speed figures never reach further back.
    public static let talkTimeDays = 14

    public var label: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .fourteenDays: "14 days"
        case .all: "All"
        }
    }

    /// Calendar days covered, today included; nil for All.
    public var dayCount: Int? {
        switch self {
        case .today: 1
        case .sevenDays: 7
        case .fourteenDays: 14
        case .all: nil
        }
    }

    /// Local midnight `dayCount − 1` days before today; nil for All (no lower bound).
    public func start(now: Date, calendar: Calendar) -> Date? {
        guard let dayCount else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
    }
}

/// One saved history entry as the page needs it. There is deliberately no text field.
public struct StatsEntry: Equatable, Sendable {
    public var date: Date
    /// Home's word rule (spoken part only), computed by the app from the same entry.
    public var words: Int
    /// VoiceLedger's reading of the same entry; nil when it has no spoken words.
    public var record: VoiceRecord?
    /// The app the talk went to, saved locally with the entry (or joined from delivery events); nil when unknown.
    public var app: PromptTargetApp?

    public init(date: Date, words: Int, record: VoiceRecord?, app: PromptTargetApp? = nil) {
        self.date = date; self.words = words; self.record = record; self.app = app
    }

    /// Stated capture seconds, or nil when untimed (missing, non-finite or negative).
    public var talkSeconds: Double? {
        guard let seconds = record?.seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

//
// :)
//
//
/// The three numbers at the top of the page, and what the talk-time note needs to say.
public struct StatsTotals: Equatable, Sendable {
    public var dictations: Int
    public var words: Int
    /// Sum of stated seconds in the talk window; nil when no entry there was timed.
    public var talkSeconds: Double?
    public var timed: Int
    /// Dictations in the talk window without a usable receipt; excluded from talkSeconds.
    public var untimed: Int
    /// True when the range reaches further back than the 14-day talk window (All).
    public var talkTimeClipped: Bool

    public init(dictations: Int = 0, words: Int = 0, talkSeconds: Double? = nil, timed: Int = 0,
                untimed: Int = 0, talkTimeClipped: Bool = false) {
        self.dictations = dictations; self.words = words; self.talkSeconds = talkSeconds
        self.timed = timed; self.untimed = untimed; self.talkTimeClipped = talkTimeClipped
    }
}

/// Totals for one range plus the 14-day VoiceLedger (sparkline and both tables).
public struct StatsSummary: Equatable, Sendable {
    public var range: StatsRange
    public var totals: StatsTotals
    public var ledger: VoiceLedger
    /// No saved entries at all: the page shows its one-line empty state.
    public var isEmpty: Bool

    /*
    One pass over the entries. Range: [start, next local midnight), or everything for All, the
    same as Home's "today" and "all time". Talk window: the later of the range start and the
    14-day start, up to the same midnight. The ledger always covers the 14 days and ignores range.
    */
    public static func build(_ entries: [StatsEntry], range: StatsRange, now: Date,
                             calendar: Calendar = .current) -> StatsSummary {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let start = range.start(now: now, calendar: calendar)
        let talkFloor = StatsRange.fourteenDays.start(now: now, calendar: calendar) ?? today
        let talkStart = max(start ?? talkFloor, talkFloor)
        var totals = StatsTotals(talkTimeClipped: start.map { $0 < talkFloor } ?? true)
        var seconds = 0.0
        for entry in entries {
            if let start, entry.date < start || entry.date >= end { continue }
            totals.dictations += 1
            totals.words += entry.words
            guard entry.date >= talkStart, entry.date < end else { continue }
            if let stated = entry.talkSeconds {
                totals.timed += 1
                seconds += stated
            } else {
                totals.untimed += 1
            }
        }
        totals.talkSeconds = totals.timed > 0 ? seconds : nil
        let ledger = VoiceLedger.build(entries.compactMap(\.record), now: now, calendar: calendar,
                                       dayCount: StatsRange.talkTimeDays)
        return StatsSummary(range: range, totals: totals, ledger: ledger, isEmpty: entries.isEmpty)
    }

    /// "—" when untimed; else whole seconds as 45s, 12m 05s, or 3h 07m.
    public static func talkTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
        return String(format: "%dh %02dm", whole / 3_600, (whole % 3_600) / 60)
    }
}

