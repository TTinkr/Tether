


//
import Foundation

/// The five target-app buckets the ledger shows, in display order.
public enum VoiceApp: String, CaseIterable, Sendable, Codable {
    case codex, claude, cursor, terminal, other

    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .terminal: "Terminal"
        case .other: "Other"
        }
    }

    /*
    Matches a bundle id or an app name, case-insensitively. Cursor ships under a ToDesktop id
    (com.todesktop.230313mzl4w4u92), so that prefix counts as Cursor. Unknown or missing → Other.
    */
    public static func classify(_ app: String?) -> VoiceApp {
        guard let app = app?.lowercased(), !app.isEmpty else { return .other }
        if app.contains("codex") || app.contains("openai") { return .codex }
        if app.contains("claude") || app.contains("anthropic") { return .claude }
        if app.contains("cursor") || app.hasPrefix("com.todesktop.") { return .cursor }
        let terminals = ["com.apple.terminal", "terminal", "iterm", "ghostty", "warp", "kitty", "alacritty", "wezterm"]
        if terminals.contains(where: { app == $0 || app.contains($0) }) { return .terminal }
        return .other
    }
}

/// One saved talk reduced to numbers. There is deliberately no text field.
public struct VoiceRecord: Equatable, Sendable {
    public var date: Date
    public var app: VoiceApp
    public var words: Int
    /// Stated talk length; nil when the saved text carried no receipt.
    public var seconds: Double?
    /// Stated words per minute; nil when untimed.
    public var wpm: Int?
    public var pauseCount: Int
    /// Longest placed pause in seconds; unplaced pauses have no individual length.
    public var longestPause: Double?

    public init(date: Date, app: VoiceApp, words: Int, seconds: Double? = nil, wpm: Int? = nil,
                pauseCount: Int = 0, longestPause: Double? = nil) {
        self.date = date; self.app = app; self.words = words; self.seconds = seconds
        self.wpm = wpm; self.pauseCount = pauseCount; self.longestPause = longestPause
    }

    /*
    π envelope first (any of its three layouts), then the legacy receipt footer
    "⟨π\n…\n42 characters · 8 words · 3.1s · 155 wpm ⟩", then plain text counted with the
    writers' word rule. Empty talks return nil so they never count as a talk.
    */
    public static func parse(text: String, date: Date, app: String?) -> VoiceRecord? {
        let bucket = VoiceApp.classify(app)
        if let envelope = PiEnvelope.parse(text) {
            let placed = envelope.pauses.map(\.seconds)
            let counted = envelope.stats?.pauseCount ?? (placed.count + envelope.unplacedPauseCount)
            let words = envelope.stats?.words ?? PiEnvelope.wordCount(of: envelope.spokenText)
            guard words > 0 else { return nil }
            return VoiceRecord(date: date, app: bucket, words: words, seconds: envelope.stats?.seconds,
                               wpm: envelope.stats?.wpm, pauseCount: counted, longestPause: placed.max())
        }
        if let receipt = legacyReceipt(text) {
            guard receipt.words > 0 else { return nil }
            return VoiceRecord(date: date, app: bucket, words: receipt.words, seconds: receipt.seconds, wpm: receipt.wpm)
        }
        let words = PiEnvelope.wordCount(of: PiEnvelope.spokenText(of: text))
        guard words > 0 else { return nil }
        return VoiceRecord(date: date, app: bucket, words: words)
    }

    /// The full-form Receipt.swift footer; the short form ("3.1s · 155 wpm") has no word count.
    static func legacyReceipt(_ text: String) -> (words: Int, seconds: Double, wpm: Int)? {
        let pattern = #"\n\s*\d+ characters? · (\d+) words? · (\d+(?:\.\d+)?)s · (\d+) wpm\s*⟩\s*$"#
        guard text.hasPrefix("⟨π\n"),
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let words = group(1).flatMap(Int.init), let seconds = group(2).flatMap(Double.init),
              let wpm = group(3).flatMap(Int.init) else { return nil }
        return (words, seconds, wpm)
    }
}

/*
Joins a talk to the target app from word-free delivery events (time, bundle id). The nearest
event within `window` seconds wins; none → nil, which the ledger shows as Other.
*/
public enum VoiceAppAttribution {
    public static func app(at date: Date, events: [(date: Date, bundle: String)], window: TimeInterval = 90) -> String? {
        events.filter { abs($0.date.timeIntervalSince(date)) <= window }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.bundle
    }

    /// Reads `delivery_preflight bundle=<id>` lines from Diagnostics' events.log text.
    public static func events(fromLog log: String) -> [(date: Date, bundle: String)] {
        let formatter = ISO8601DateFormatter()
        return log.split(separator: "\n").compactMap { line in
            guard line.contains(" delivery_preflight bundle="),
                  let space = line.firstIndex(of: " "),
                  let date = formatter.date(from: String(line[..<space])),
                  let start = line.range(of: " delivery_preflight bundle=")?.upperBound else { return nil }
            let bundle = line[start...].prefix { !$0.isWhitespace }
            return bundle.isEmpty || bundle == "unknown" ? nil : (date, String(bundle))
        }
    }
}

//
// :)
//
//
/// One table row: a day or an app. Speed columns are nil when no talk in the row was timed.
public struct VoiceLedgerRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var talks: Int
    public var words: Int
    public var medianWPM: Int?
    /// Share (0…1) of timed talks above `VoiceLedger.fastWPM`.
    public var fastShare: Double?
    public var pausesPer100Words: Double?
    public var longestPause: Double?

    public init(id: String, label: String, talks: Int = 0, words: Int = 0, medianWPM: Int? = nil,
                fastShare: Double? = nil, pausesPer100Words: Double? = nil, longestPause: Double? = nil) {
        self.id = id; self.label = label; self.talks = talks; self.words = words; self.medianWPM = medianWPM
        self.fastShare = fastShare; self.pausesPer100Words = pausesPer100Words; self.longestPause = longestPause
    }

    /// Aggregates any set of records into one row.
    public static func summarize(_ records: [VoiceRecord], id: String, label: String) -> VoiceLedgerRow {
        let timed = records.compactMap(\.wpm)
        let words = records.reduce(0) { $0 + $1.words }
        let pauses = records.reduce(0) { $0 + $1.pauseCount }
        return VoiceLedgerRow(
            id: id, label: label, talks: records.count, words: words,
            medianWPM: VoiceLedger.median(timed),
            fastShare: timed.isEmpty ? nil : Double(timed.filter { $0 > VoiceLedger.fastWPM }.count) / Double(timed.count),
            pausesPer100Words: words > 0 ? Double(pauses) * 100 / Double(words) : nil,
            longestPause: records.compactMap(\.longestPause).max())
    }
}

/// Fourteen day rows (oldest first), one row per app, a total and a streak.
public struct VoiceLedger: Equatable, Sendable {
    public static let fastWPM = 220
    public var days: [VoiceLedgerRow]
    public var dayStarts: [Date]
    public var apps: [VoiceLedgerRow]
    public var total: VoiceLedgerRow
    /// Consecutive days with at least one talk, ending today (or yesterday if today is still empty).
    public var streak: Int

    /*
    Only records inside the window feed the tables; the streak looks back through every record.
    Apps with no talks in the window are dropped, except that an all-empty ledger keeps none.
    */
    public static func build(_ records: [VoiceRecord], now: Date, calendar: Calendar = .current, dayCount: Int = 14) -> VoiceLedger {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        let label = DateFormatter()
        label.calendar = calendar; label.timeZone = calendar.timeZone
        label.locale = Locale(identifier: "en_US_POSIX"); label.dateFormat = "EEE d MMM"
        let days = starts.map { start in
            VoiceLedgerRow.summarize(byDay[start] ?? [], id: ISO8601DateFormatter().string(from: start),
                                     label: label.string(from: start))
        }
        let windowed = starts.first.map { first in records.filter { $0.date >= first && $0.date < (calendar.date(byAdding: .day, value: 1, to: today) ?? now) } } ?? []
        let apps = VoiceApp.allCases.map { app in
            VoiceLedgerRow.summarize(windowed.filter { $0.app == app }, id: app.rawValue, label: app.label)
        }.filter { $0.talks > 0 }
        return VoiceLedger(days: days, dayStarts: starts, apps: apps,
                           total: .summarize(windowed, id: "total", label: "All apps"),
                           streak: streak(Set(byDay.keys), today: today, calendar: calendar))
    }

    static func streak(_ active: Set<Date>, today: Date, calendar: Calendar) -> Int {
        var day = active.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var count = 0
        while active.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Median; with an even count it is the mean of the two middle values, rounded; nil when empty.
    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? Int((Double(sorted[mid - 1] + sorted[mid]) / 2).rounded()) : sorted[mid]
    }
}

