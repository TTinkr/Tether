


//
import Foundation

/// How one talk ended, as far as the events can tell.
public enum PasteOutcome: String, Codable, Sendable, CaseIterable {
    /// delivery_verified: the editor read the text back.
    case landed
    /// delivery_unverified, but paste_ack saw the editor change (2026-10-10 rule: counts as landed).
    case landedUnverified
    /// delivery_failed, or unverified with no editor change.
    case missed
    /// Unverified, and the build wrote no paste_ack to tell (older builds): neither landed nor missed.
    case unchecked
    /// Words kept for Copy without a paste attempt (no target, microphone stop, retracted stream).
    case held
    /// Tokens' own window was in front; words stayed in History on purpose.
    case keptInApp
}

/// Counts for one row of the ledger (an app, a route, a day or the whole log).
public struct PasteLedgerCounts: Codable, Sendable, Equatable {
    public var landed = 0
    public var landedUnverified = 0
    public var missed = 0
    public var unchecked = 0
    public var held = 0
    public var keptInApp = 0
    /// held_words_copied after a miss or hold: the person took the words with Copy.
    public var recoveredViaHeldWords = 0
    /// Unconfirmed pastes whose editor already held text (paste_ack_shape before_utf16 > 0).
    public var unconfirmedIntoNonEmptyEditor = 0

    public init() {}

    /// Paste attempts only: landed + landedUnverified + missed + unchecked.
    public var pastes: Int { landed + landedUnverified + missed + unchecked }
    public var landedTotal: Int { landed + landedUnverified }
    /// Landed share of the attempts that can be judged (unchecked left out), 0...1; nil when none.
    public var landRate: Double? {
        let judged = landedTotal + missed
        return judged == 0 ? nil : Double(landedTotal) / Double(judged)
    }

    mutating func add(_ outcome: PasteOutcome) {
        switch outcome {
        case .landed: landed += 1
        case .landedUnverified: landedUnverified += 1
        case .missed: missed += 1
        case .unchecked: unchecked += 1
        case .held: held += 1
        case .keptInApp: keptInApp += 1
        }
    }
}

public struct PasteLedgerDay: Codable, Sendable, Equatable {
    public var day: String
    public var counts: PasteLedgerCounts
}

public struct PasteLedgerApp: Codable, Sendable, Equatable {
    public var bundle: String
    public var name: String
    public var counts: PasteLedgerCounts
}

/// The whole answer. Keys are bundle identifiers, routes and fixed reason codes; never words.
public struct PasteLedger: Codable, Sendable, Equatable {
    public var linesRead = 0
    public var linesParsed = 0
    /// Lines that did not match the event shape (format drift, a multi-line event, a torn write).
    public var linesUnparsed = 0
    /// Well-formed events that do not concern pasting (updater, shortcut, speech...).
    public var otherEvents = 0
    /// Attempts still open at the end of the log (app quit mid-delivery, or the log ends there),
    /// plus attempts dropped because the next talk began before any paste was posted.
    public var unclosedAttempts = 0
    /// Attempts with no terminal delivery_* line, closed from their paste_ack when the next talk began.
    public var inferredFromAck = 0
    public var firstDay: String?
    public var lastDay: String?
    public var overall = PasteLedgerCounts()
    /// Sorted by paste attempts, most first.
    public var apps: [PasteLedgerApp] = []
    /// "single", "staged" (three-step or streamed pieces) and "none" (held / kept in app).
    public var routes: [String: PasteLedgerCounts] = [:]
    /// Exactly seven days ending on `lastDay` (or the supplied day), oldest first.
    public var lastSevenDays: [PasteLedgerDay] = []
    /// The same seven days split into "Claude", "Codex" and "Other", so one editor's regression stands out.
    public var lastSevenDaysByGroup: [String: [PasteLedgerDay]] = [:]
    /// Miss and hold reasons, most first.
    public var failureReasons: [PasteLedgerReason] = []
    /// How many lines of each paste-related event were seen, so a renamed event shows up as a zero.
    public var pasteEventCounts: [String: Int] = [:]
}

public struct PasteLedgerReason: Codable, Sendable, Equatable {
    public var reason: String
    public var count: Int
    public init(reason: String, count: Int) { self.reason = reason; self.count = count }
}

/// One parsed line: time, app process, event name and its key=value fields.
public struct EventLine: Sendable, Equatable {
    public var date: Date
    public var app: String
    public var pid: String
    public var event: String
    public var fields: [String: String]

    /// nil when the line is not "<ISO time> app=<id> pid=<n> <event> [key=value ...]".
    public static func parse(_ line: Substring, formatter: ISO8601DateFormatter) -> EventLine? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[1].hasPrefix("app="), parts[2].hasPrefix("pid="),
              let date = formatter.date(from: String(parts[0])),
              parts[3].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        var fields: [String: String] = [:]
        for token in parts.dropFirst(4) {
            guard let equals = token.firstIndex(of: "=") else { continue }
            fields[String(token[..<equals])] = String(token[token.index(after: equals)...])
        }
        return EventLine(date: date, app: String(parts[1].dropFirst(4)), pid: String(parts[2].dropFirst(4)),
                         event: String(parts[3]), fields: fields)
    }
}


//
/*
One talk's delivery writes, in order: capture_target (at key down), delivery_preflight,
optional staging and three_step_paste lines, paste_ack_shape (unconfirmed only), paste_ack, paste_posted,
then exactly one of delivery_verified / delivery_unverified / delivery_failed, then
recovery_retained for anything held. State is kept per app process (app + pid) because
two builds can write the same log. recovery_retained with a session that no delivery_* line
closed is a hold without a paste (no target, microphone stopped, retracted stream).
*/
public enum PasteLedgerBuilder {
    /// Events that belong to a paste attempt; listed so a renamed event shows as a zero count.
    public static let pasteEvents: Set<String> = [
        "capture_target", "capture_target_unavailable", "delivery_preflight", "staging_gate", "staging_plan",
        "three_step_paste", "staged_delivery_first_write", "continuous_reveal", "speed_of_sound_paste_dispatched",
        "paste_ack_rules", "paste_ack_shape", "paste_ack_diff", "paste_ack", "paste_posted",
        "clipboard_held_for_unacknowledged_paste", "codex_final_reveal_stopped",
        "delivery_verified", "delivery_unverified", "delivery_failed", "delivery_empty", "delivery_kept_in_app",
        "delivery_held", "delivery_return_dispatched", "agent_send_dispatched_unconfirmed", "auto_send_suppressed",
        "recovery_retained", "held_words_shown", "held_words_copied", "held_words_dismissed",
    ]

    private struct Attempt {
        var bundle: String?
        var staged = false
        var ackSeen = false
        var ackVerified = false
        var editorChanged = false
        var nonEmptyEditor = false
    }

    private struct Process {
        var captureBundle: String?
        var attempt: Attempt?
        var closedSessions: [String] = []
        var lastClosed: (bundle: String, route: String)?
        /// delivery_held's fixed reason (editing_thinking_notes, focus_changed_since_key_edge), used when the
        /// next recovery_retained closes the talk as held; cleared when a new talk begins.
        var pendingHoldReason: String?
    }

    /// Builds the ledger. `today` (yyyy-MM-dd in `timeZone`) anchors the seven-day trend; default is the last event's day.
    public static func build<S: Sequence>(lines: S, timeZone: TimeZone = .current, today: String? = nil) -> PasteLedger
    where S.Element: StringProtocol {
        let iso = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var ledger = PasteLedger()
        var processes: [String: Process] = [:]
        var apps: [String: PasteLedgerCounts] = [:]
        var days: [String: PasteLedgerCounts] = [:]
        var groupDays: [String: [String: PasteLedgerCounts]] = [:]
        var reasons: [String: Int] = [:]

        func record(_ outcome: PasteOutcome, bundle: String, route: String, day: String, reason: String?, nonEmpty: Bool) {
            ledger.overall.add(outcome)
            apps[bundle, default: .init()].add(outcome)
            ledger.routes[route, default: .init()].add(outcome)
            days[day, default: .init()].add(outcome)
            groupDays[group(bundle: bundle), default: [:]][day, default: .init()].add(outcome)
            if nonEmpty && outcome != .landed {
                ledger.overall.unconfirmedIntoNonEmptyEditor += 1
                apps[bundle, default: .init()].unconfirmedIntoNonEmptyEditor += 1
                ledger.routes[route, default: .init()].unconfirmedIntoNonEmptyEditor += 1
            }
            if let reason { reasons[reason, default: 0] += 1 }
        }

        for raw in lines {
            // Swift reads "\r\n" as one Character, so a plain "\n" split would merge CRLF lines.
            for piece in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
                let text = Substring(piece)
                guard !text.allSatisfy(\.isWhitespace) else { continue }
                ledger.linesRead += 1
                guard let line = EventLine.parse(text, formatter: iso) else { ledger.linesUnparsed += 1; continue }
                ledger.linesParsed += 1
                let day = dayFormatter.string(from: line.date)
                if ledger.firstDay == nil || day < ledger.firstDay! { ledger.firstDay = day }
                if ledger.lastDay == nil || day > ledger.lastDay! { ledger.lastDay = day }
                guard pasteEvents.contains(line.event) else { ledger.otherEvents += 1; continue }
                ledger.pasteEventCounts[line.event, default: 0] += 1

                let key = line.app + "#" + line.pid
                var process = processes[key] ?? Process()
                let fields = line.fields

                func close(_ outcome: PasteOutcome, reason: String?) {
                    let attempt = process.attempt ?? Attempt()
                    let bundle = attempt.bundle ?? process.captureBundle ?? "unknown"
                    let route = (outcome == .held || outcome == .keptInApp) ? "none" : (attempt.staged ? "staged" : "single")
                    record(outcome, bundle: bundle, route: route, day: day, reason: reason, nonEmpty: attempt.nonEmptyEditor)
                    if let session = fields["session"] {
                        process.closedSessions.append(session)
                        if process.closedSessions.count > 8 { process.closedSessions.removeFirst() }
                    }
                    process.lastClosed = (bundle, route)
                    process.attempt = nil
                }
                func open() { if process.attempt == nil { process.attempt = Attempt() } }

                func closeUnverified() {
                    if process.attempt?.editorChanged == true { close(.landedUnverified, reason: nil) }
                    else if process.attempt?.ackSeen == true { close(.missed, reason: "unverified_no_editor_change") }
                    else { close(.unchecked, reason: nil) }
                }

                switch line.event {
                case "capture_target", "capture_target_unavailable":
                    /*
                    A new talk began. An attempt still open here never logged its delivery_* line
                    (a build that ended on delivery_return_dispatched, or an app quit): close it
                    from its own paste_ack, or count it unclosed when nothing was posted.
                    */
                    if let stale = process.attempt {
                        if stale.ackSeen {
                            ledger.inferredFromAck += 1
                            if stale.ackVerified { close(.landed, reason: nil) } else { closeUnverified() }
                        } else {
                            ledger.unclosedAttempts += 1
                            process.attempt = nil
                        }
                    }
                    process.captureBundle = line.event == "capture_target" ? fields["bundle"] : "none"
                    process.pendingHoldReason = nil
                case "delivery_held":
                    // Only fixed codes (letters, digits, underscore) are kept; anything else becomes held_other.
                    let code = fields["reason"] ?? ""
                    process.pendingHoldReason = !code.isEmpty && code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                        ? code : "held_other"
                case "delivery_preflight":
                    open(); if let bundle = fields["bundle"] { process.attempt?.bundle = bundle }
                case "paste_ack":
                    open()
                    if let bundle = fields["bundle"] { process.attempt?.bundle = bundle }
                    process.attempt?.ackSeen = true
                    if fields["verified"] == "true" { process.attempt?.ackVerified = true }
                    if let changed = fields["changed_ms"], Int(changed) != nil { process.attempt?.editorChanged = true }
                    if let staged = fields["staged"].flatMap(Int.init), staged > 0 { process.attempt?.staged = true }
                case "paste_ack_shape":
                    open()
                    if let before = fields["before_utf16"].flatMap(Int.init), before > 0 { process.attempt?.nonEmptyEditor = true }
                case "three_step_paste":
                    open()
                    if (fields["planned"].flatMap(Int.init) ?? 0) > 1 || fields["stopped"] != nil { process.attempt?.staged = true }
                case "staged_delivery_first_write", "continuous_reveal":
                    open(); process.attempt?.staged = true
                case "staging_gate", "staging_plan", "paste_ack_rules", "paste_ack_diff", "paste_posted",
                     "speed_of_sound_paste_dispatched", "clipboard_held_for_unacknowledged_paste", "codex_final_reveal_stopped":
                    open()
                case "delivery_verified":
                    close(.landed, reason: nil)
                case "delivery_unverified", "agent_send_dispatched_unconfirmed":
                    // Older builds ended an unconfirmed paste whose Return was forwarded with agent_send_dispatched_unconfirmed.
                    closeUnverified()
                case "delivery_failed":
                    close(.missed, reason: fields["reason"] ?? "failed_unknown")
                case "delivery_kept_in_app":
                    process.attempt = process.attempt ?? Attempt()
                    process.attempt?.bundle = "tokens_window"
                    close(.keptInApp, reason: nil)
                case "delivery_empty":
                    process.attempt = nil
                    if let session = fields["session"] { process.closedSessions.append(session) }
                case "recovery_retained":
                    let session = fields["session"] ?? "none"
                    if session != "none", process.closedSessions.contains(session) { break }
                    let pending = process.pendingHoldReason
                    process.pendingHoldReason = nil
                    if process.attempt != nil { close(.missed, reason: "held_mid_delivery") }
                    else if let pending { close(.held, reason: pending) }
                    else if process.captureBundle == nil { close(.held, reason: "held_target_unknown") }
                    else if process.captureBundle == "none" { close(.held, reason: "held_no_target") }
                    else { close(.held, reason: "held_before_paste") }
                case "held_words_copied":
                    if let last = process.lastClosed {
                        ledger.overall.recoveredViaHeldWords += 1
                        apps[last.bundle, default: .init()].recoveredViaHeldWords += 1
                        ledger.routes[last.route, default: .init()].recoveredViaHeldWords += 1
                    }
                default:
                    break
                }
                processes[key] = process
            }
        }

        ledger.unclosedAttempts += processes.values.filter { $0.attempt != nil }.count
        ledger.apps = apps.map { PasteLedgerApp(bundle: $0.key, name: appName(bundle: $0.key), counts: $0.value) }
            .sorted { ($0.counts.pastes, $0.counts.held, $1.bundle) > ($1.counts.pastes, $1.counts.held, $0.bundle) }
        ledger.failureReasons = reasons.map { PasteLedgerReason(reason: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.reason) > ($1.count, $0.reason) }
        if let anchor = today ?? ledger.lastDay, let end = dayFormatter.date(from: anchor) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let window = (0..<7).reversed().compactMap { back in
                calendar.date(byAdding: .day, value: -back, to: end).map(dayFormatter.string(from:))
            }
            ledger.lastSevenDays = window.map { PasteLedgerDay(day: $0, counts: days[$0] ?? .init()) }
            for name in ["Claude", "Codex", "Other"] {
                ledger.lastSevenDaysByGroup[name] = window.map { PasteLedgerDay(day: $0, counts: groupDays[name]?[$0] ?? .init()) }
            }
        }
        return ledger
    }

    /// "Claude", "Codex" or "Other" for the per-group trend.
    public static func group(bundle: String) -> String {
        let name = appName(bundle: bundle)
        return name == "Claude" || name == "Codex" ? name : "Other"
    }

    /// Short names for the editors people commonly talk into; anything else keeps its bundle identifier.
    public static func appName(bundle: String) -> String {
        let names: [String: String] = [
            "com.anthropic.claudefordesktop": "Claude", "com.openai.codex": "Codex",
            "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "com.todesktop.230313mzl4w4u92": "Cursor",
            "com.microsoft.VSCode": "VS Code", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
            "com.apple.Notes": "Notes", "com.apple.TextEdit": "TextEdit", "com.tinkr.testpad": "Test Pad",
            "com.tinyspeck.slackmacgap": "Slack", "com.apple.MobileSMS": "Messages",
            "tokens_window": "Tokens window", "none": "No target", "unknown": "Unknown",
        ]
        return names[bundle] ?? bundle
    }
}


//
extension PasteLedger {
    /// A short Markdown page: per-app table first, then routes, seven days and reasons.
    public func markdown(title: String = "Paste ledger") -> String {
        func rate(_ c: PasteLedgerCounts) -> String { c.landRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "-" }
        func row(_ name: String, _ c: PasteLedgerCounts) -> String {
            "| \(name) | \(c.pastes) | \(c.landed) | \(c.landedUnverified) | \(c.missed) | \(rate(c)) | \(c.unchecked) | \(c.unconfirmedIntoNonEmptyEditor) | \(c.held) | \(c.recoveredViaHeldWords) |"
        }
        let header = "| App | Pastes | Landed (checked) | Landed (editor changed) | Missed | Land rate | No check data | Unconfirmed into non-empty editor | Held, no paste | Copied from held words |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
        var out = ["# \(title)", ""]
        out.append("\(firstDay ?? "-") to \(lastDay ?? "-") · \(linesRead) lines · \(linesUnparsed) unparsed · \(unclosedAttempts) unclosed attempts · \(inferredFromAck) closed from paste_ack")
        out += ["", "## Did it land, per app", "", header]
        out += apps.map { row($0.name, $0.counts) }
        out.append(row("**All**", overall))
        out += ["", "## By route", "", header.replacingOccurrences(of: "| App |", with: "| Route |")]
        out += routes.keys.sorted().map { row($0, routes[$0]!) }
        out += ["", "## Last 7 days", "", "| Day | Landed | Missed | Held | Land rate | |", "|---|---:|---:|---:|---:|---|"]
        let peak = Swift.max(1, lastSevenDays.map { $0.counts.pastes }.max() ?? 1)
        for day in lastSevenDays {
            let c = day.counts
            let bar = String(repeating: "#", count: Int((Double(c.landedTotal) / Double(peak) * 12).rounded()))
                + String(repeating: "x", count: Int((Double(c.missed) / Double(peak) * 12).rounded()))
            out.append("| \(day.day) | \(c.landedTotal) | \(c.missed) | \(c.held) | \(rate(c)) | `\(bar)` |")
        }
        out += ["", "## Last 7 days: Claude, Codex, others (landed / judged)", "",
                "| Day | Claude | Codex | Other |", "|---|---:|---:|---:|"]
        for (index, day) in lastSevenDays.enumerated() {
            let cells = ["Claude", "Codex", "Other"].map { name -> String in
                guard let c = lastSevenDaysByGroup[name]?[index].counts, c.landedTotal + c.missed > 0 else { return "-" }
                return "\(c.landedTotal)/\(c.landedTotal + c.missed)"
            }
            out.append("| \(day.day) | \(cells.joined(separator: " | ")) |")
        }
        out += ["", "## Top reasons it did not land", "", "| Reason | Count |", "|---|---:|"]
        out += failureReasons.prefix(8).map { "| \($0.reason) | \($0.count) |" }
        out += ["", "Landed (editor changed) = paste not read back exactly but the editor changed after Command-V; counted as landed (2026-10-10 rule).",
                "No check data = an older build posted the paste without a paste_ack line; left out of the land rate.",
                "Bars: # landed, x missed. Counts only; no words are read or written."]
        return out.joined(separator: "\n") + "\n"
    }
}

