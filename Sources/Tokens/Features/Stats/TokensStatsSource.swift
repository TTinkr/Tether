


//
import AppKit
import Foundation
import TokensCore

enum TokensStatsSource {
    typealias Event = (date: Date, bundle: String)

    /*
    One entry per saved talk, in history order. Words: Home's rule. Record: exactly what
    VoiceLedgerSource.records makes of the same entry (nil when it has no spoken words). App: the
    target app saved with the entry (build 77+); for older entries inside the 14-day window, the
    bundle id of the nearest word-free delivery event, named by the app installed on this Mac.
    */
    static func entries(_ history: [PromptHistoryEntry], events: [Event], now: Date = Date(),
                        appName: (String) -> String? = TokensStatsSource.installedName) -> [StatsEntry] {
        // Talks older than the 14-day window never reach the app tables, so they skip the events join.
        let windowStart = VoiceLedgerSource.windowStart(now: now, dayCount: StatsRange.talkTimeDays)
        var names: [String: String?] = [:]
        return history.map { entry in
            let joined = entry.createdAt < windowStart ? [] : events
            var app = entry.targetApp
            if app == nil, let bundle = VoiceAppAttribution.app(at: entry.createdAt, events: joined) {
                if names[bundle] == nil { names[bundle] = .some(appName(bundle)) }
                app = PromptTargetApp(bundleID: bundle, name: names[bundle] ?? nil)
            }
            return StatsEntry(date: entry.createdAt, words: TokensHistoryText.words(entry),
                              record: VoiceLedgerSource.records([entry], events: joined).first, app: app)
        }
    }

    /// The installed app's display name for a bundle id, read locally; nil when not installed.
    static func installedName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Home's refreshStats() loop, restated so tests can hold the Stats totals to it.
    static func homeWordCounts(_ history: [PromptHistoryEntry], calendar: Calendar = .current) -> (today: Int, total: Int) {
        var today = 0, total = 0
        for entry in history {
            let count = TokensHistoryText.words(entry)
            total += count
            if calendar.isDateInToday(entry.createdAt) { today += count }
        }
        return (today, total)
    }

    /// The word-free delivery events back to the 14-day window start (VoiceLedger's own read).
    static func deliveryEvents(now: Date) -> [Event] {
        VoiceLedgerSource.deliveryEvents(since: VoiceLedgerSource.windowStart(now: now, dayCount: StatsRange.talkTimeDays))
    }
}

//
// :)
//
//
/*
--stats-fixture synthetic|sparse|empty (with --render-preview-frames, a proof-allowed build and a
synthetic run). synthetic: a fictional month of π-receipt talks of the word "talk", each saved
with one of seven target apps (so five rows plus Other), a few days with no talk, two untimed
plain entries today with no app, and three entries 31-40 days old. sparse: two days of talks.
empty: no entries. Render-only hover/filter/range flags pick a state without a pointer. Nothing
reads the real history or events log, and nothing is written.
*/
enum TokensStatsFixture: String {
    case synthetic, sparse, empty

    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments,
                          allowed: Bool = ProofRoutes.isAllowed, synthetic: Bool) -> TokensStatsFixture? {
        guard allowed, synthetic, arguments.contains("--render-preview-frames"),
              let flag = arguments.firstIndex(of: "--stats-fixture"), flag + 1 < arguments.count else { return nil }
        return TokensStatsFixture(rawValue: arguments[flag + 1].lowercased())
    }

    /// A render-only state: --stats-hover day|slice|filter (the busiest day, the lead slice, or the
    /// graph filtered to the lead app) and --stats-range today|7|14|all. Needs a fixture.
    enum Pose: String { case day, slice, filter }

    static func pose(arguments: [String] = ProcessInfo.processInfo.arguments) -> Pose? {
        guard let flag = arguments.firstIndex(of: "--stats-hover"), flag + 1 < arguments.count else { return nil }
        return Pose(rawValue: arguments[flag + 1].lowercased())
    }

    /// A render-only hero total: --stats-hero-total <n> shows n as the words-talked number, so
    /// 0, 999, 1,000 … 1,000,000 can be looked at without touching real history. Needs a fixture.
    static func heroTotal(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        guard let flag = arguments.firstIndex(of: "--stats-hero-total"), flag + 1 < arguments.count else { return nil }
        return Int(arguments[flag + 1]).map { max(0, $0) }
    }

    static func range(arguments: [String] = ProcessInfo.processInfo.arguments) -> StatsRange? {
        guard let flag = arguments.firstIndex(of: "--stats-range"), flag + 1 < arguments.count else { return nil }
        switch arguments[flag + 1].lowercased() {
        case "today": return .today
        case "7": return .sevenDays
        case "14": return .fourteenDays
        case "all": return .all
        default: return nil
        }
    }

    /// Fictional delivery ids for the VoiceLedger parity test (the page's fixture needs none).
    static let appIDs = ["fixture-codex", "Fixture Editor", "fixture-claude", "fixture-codex", "fixture-terminal"]

    /// Seven target apps, most used first, so the table shows five rows and Other.
    static let apps: [PromptTargetApp] = [
        PromptTargetApp(bundleID: "com.openai.codex", name: "Codex"),
        PromptTargetApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
        PromptTargetApp(bundleID: "com.apple.Terminal", name: "Terminal"),
        PromptTargetApp(bundleID: "com.apple.Notes", name: "Notes"),
        PromptTargetApp(bundleID: "com.apple.mail", name: "Mail"),
        PromptTargetApp(bundleID: "com.apple.Safari", name: "Safari"),
        PromptTargetApp(bundleID: "com.apple.TextEdit", name: "TextEdit"),
    ]

    /// One π envelope of `words` "talk"s with a stated length and speed, as delivery saves it.
    static func talk(words: Int, wpm: Int) -> String {
        "# π\n" + Array(repeating: "talk", count: words).joined(separator: " ") + "\n\n---\n\n"
            + AuthoredPrompt.metadataHeading + "\n\n"
            + String(format: "> *%.4fs · %d words · %d wpm · 0x thinking (0.0000s)*", Double(words) * 60 / Double(wpm), words, wpm)
    }

    @MainActor
    static func history(now: Date, kind: TokensStatsFixture = .synthetic) -> [PromptHistoryEntry] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        // Talks today sit before `now` (clamped into today), older days at fixed hours.
        func at(daysAgo: Int, minute: Int) -> Date {
            guard daysAgo > 0 else { return max(startOfToday, now.addingTimeInterval(-Double(minute) * 60 - 60)) }
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? startOfToday
            return day.addingTimeInterval(Double(9 * 60 + minute) * 60)
        }
        var entries: [PromptHistoryEntry] = []
        // Talks per day, newest first; zero days stay as zero points on the graph.
        let perDay = kind == .sparse ? [3, 2]
            : [6, 4, 9, 3, 5, 7, 4, 0, 6, 8, 3, 5, 0, 4, 6, 2, 5, 7, 3, 0, 4, 5, 3, 6, 2, 4]
        var serial = 0
        for (daysAgo, count) in perDay.enumerated() {
            for index in 0..<count {
                serial += 1
                let words = 40 + (serial * 37 + daysAgo * 11) % 190
                let wpm = 168 + (serial * 13 + daysAgo * 7) % 58
                // Weighted toward the first apps: Codex, Codex, Claude, Codex, Terminal, Claude, …
                let pick = [0, 0, 1, 0, 2, 1, 3, 0, 4, 1, 5, 2, 6, 0][(serial + daysAgo) % 14]
                entries.append(PromptHistoryEntry(id: UUID(), createdAt: at(daysAgo: daysAgo, minute: 7 + index * 23 + daysAgo % 5),
                                                  text: talk(words: words, wpm: wpm), targetApp: apps[pick]))
            }
        }
        guard kind == .synthetic else { return entries.sorted { $0.createdAt > $1.createdAt } }
        // Two plain entries today with no receipt and no saved app: untimed, under Other.
        let plain = "talk talk talk talk talk talk talk talk talk talk talk talk"
        entries.append(PromptHistoryEntry(id: UUID(), createdAt: max(now.addingTimeInterval(-600), startOfToday), text: plain))
        entries.append(PromptHistoryEntry(id: UUID(), createdAt: max(now.addingTimeInterval(-900), startOfToday), text: plain + " talk talk"))
        for days in [31, 36, 40] {
            entries.append(PromptHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-Double(days) * 86_400),
                                              text: talk(words: 30 + days, wpm: 200), targetApp: apps[0]))
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// One fictional delivery event two seconds after each talk.
    static func events(for history: [PromptHistoryEntry]) -> [TokensStatsSource.Event] {
        history.enumerated().map { (date: $0.element.createdAt.addingTimeInterval(2), bundle: appIDs[$0.offset % appIDs.count]) }
    }
}

