


//
import AppKit
import SwiftUI
import TokensCore

extension TokensHome {
    /// The Stats rail destination; it reads the history already in memory when it appears.
    var statsPage: some View {
        TokensStatsPage(history: model.promptHistory, synthetic: model.isSyntheticRun)
    }
}

/*
Rules (sheet y, 1040 × 720): title on rule 2 (header); hero number on rule 4 with "words talked"
half a rule above its sub-line; "Words over time" and the range control on rule 5; the graph
fills rules 5-10 (ticks on rules 6-9, day labels half-way below rule 9); today's three numbers
on rule 11 with labels below; "By app" and its table from rule 13; the records on the last rule.
Under three active days only the hero and the graph show; with no saved talk, one line.
*/
struct TokensStatsPage: View {
    let history: [PromptHistoryEntry]
    let synthetic: Bool

    @Environment(\.tokensSheetSize) private var sheet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: StatsRange = .sevenDays
    @State private var entries: [StatsEntry] = []
    @State private var now = Date()
    @State private var loaded = false
    @State private var sample = false
    @State private var board: StatsBoard?
    /// Graph point under the pointer (or scrubbed with the arrow keys).
    @State private var hoveredPoint: Int?
    /// App row/slice under the pointer.
    @State private var hoveredApp: String?
    /// App the graph is filtered to (click a row or slice; click again or Escape clears).
    @State private var filter: String?
    /// 0 → 1 once on arrival: the hero counts up and the graph and donut reveal left to right.
    @State private var arrival: Double = 0
    @State private var heroShown: Double = 0
    /// A render-only pose holds its hover when the pointer (absent in renders) "leaves".
    @State private var pinnedPose = false

    private var column: CGFloat { TokensColumn.layout(sheetWidth: sheet.width).width }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if loaded, let board {
                    if board.isEmpty {
                        Text(TokensStatsCopy.empty)
                            .font(TokensType.body)
                            .foregroundStyle(TokensUI.secondary)
                            .tokensOnRule()
                            .accessibilityIdentifier("tokens.stats.empty")
                    } else {
                        content(board)
                    }
                } else {
                    TokensRuleSpacer(cells: 1)
                }
            }
            .tokensPageColumn()
        }
        .tokensRuledScroll()
        .tokensRestingEdge()
        .background { escapeClearsFilter }
        .accessibilityIdentifier("tokens.stats")
        .task(id: history.count) { await load() }
        // Built once per range, filter or data change, never on every redraw.
        .onChange(of: range) { _, _ in hoveredPoint = nil; rebuild() }
        .onChange(of: filter) { _, _ in rebuild() }
    }

    @ViewBuilder
    private func content(_ board: StatsBoard) -> some View {
        hero(board)
        graphHeader(board)
        TokensStatsChart(points: board.points, unit: board.unit, width: column, arrival: arrival,
                         hovered: Binding(get: { hoveredPoint }, set: { if !pinnedPose { hoveredPoint = $0 } }))
            .background(alignment: .bottom) { rule }
        if !board.isSparse {
            todayRow(board)
                .background(alignment: .bottom) { rule }
            if !board.apps.isEmpty, board.appWords > 0 {
                byApp(board)
            }
            records(board)
        } else if sample {
            sampleLabel.tokensOnRule()
        }
    }

    /*
    The section rule: the `divider` hairline drawn on a sheet rule (DESIGN.md §2.3). Always put it
    behind its block (background, never overlay): text stands on that rule, and a comma's tail or
    a descender must stay whole over it (build 78: the line cut the hero's comma).
    */
    private var rule: some View {
        Rectangle().fill(TokensUI.divider).frame(height: 1).offset(y: 0.5).accessibilityHidden(true)
    }

    /// Escape clears an app filter while one is on.
    @ViewBuilder
    private var escapeClearsFilter: some View {
        if filter != nil {
            Button("Show all apps") { filter = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Data

    /*
    Fixture first (render proofs only), then the history in memory. The word-free events log is
    read off the main thread and only outside synthetic runs. Arrival motion starts once, after
    the first load, and is skipped under Reduce Motion.
    */
    private func load() async {
        let now = Date()
        var sample = false
        let entries: [StatsEntry]
        let fixture = TokensStatsFixture.requested(synthetic: synthetic)
        switch fixture {
        case .synthetic?, .sparse?:
            let kind = fixture ?? .synthetic
            entries = TokensStatsSource.entries(TokensStatsFixture.history(now: now, kind: kind), events: [], now: now)
            sample = true
        case .empty?:
            entries = []
        case nil:
            // Parsing every saved talk and joining it to the events log runs off the main thread.
            let history = self.history
            entries = await Task.detached(priority: .userInitiated) {
                let events = synthetic ? [] : TokensStatsSource.deliveryEvents(now: now)
                return TokensStatsSource.entries(history, events: events, now: now)
            }.value
        }
        let firstLoad = !loaded
        self.now = now
        self.entries = entries
        self.sample = sample
        if firstLoad, fixture != nil, let pinned = TokensStatsFixture.range() { range = pinned }
        rebuild()
        if firstLoad, fixture != nil { pose() }
        loaded = true
        let total = Double(heroTotal(board))
        if firstLoad, !reduceMotion {
            withAnimation(.easeOut(duration: 0.6)) { heroShown = total }
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) { arrival = 1 }
        } else {
            heroShown = total
            arrival = 1
        }
    }

    /// The hero's number: the board's total, or a fixture's --stats-hero-total in a fixture render.
    private func heroTotal(_ board: StatsBoard?) -> Int {
        if TokensStatsFixture.requested(synthetic: synthetic) != nil, let pinned = TokensStatsFixture.heroTotal() { return pinned }
        return board?.totalWords ?? 0
    }

    private func rebuild() {
        board = StatsBoard.build(entries, range: range, now: now, filter: filter)
        if filter != nil, board?.filter == nil { filter = nil }
    }

    /// --stats-hover day|slice|filter: the busiest point, the lead slice, or the lead app's graph.
    private func pose() {
        guard let board, let pose = TokensStatsFixture.pose() else { return }
        switch pose {
        case .day:
            hoveredPoint = board.points.indices.max { board.points[$0].words < board.points[$1].words }
        case .slice:
            hoveredApp = board.apps.first?.id
        case .filter:
            filter = board.apps.first?.id
            rebuild()
        }
        pinnedPose = true
    }

    private func toggleFilter(_ id: String) {
        filter = filter == id ? nil : id
    }
}

//
// :)
//
//
extension TokensStatsPage {
    // MARK: Hero

    /*
    Two squares. The number's baseline is the second rule; "words talked" sits half a square above
    the sub-line, which shares the number's rule. Narrow columns put the words on the next rule.
    */
    @ViewBuilder
    func hero(_ board: StatsBoard) -> some View {
        let size: CGFloat = column < 480 ? 64 : 88
        let words = heroTotal(board)
        let final = words.formatted()
        let width = TokensStatsType.heroWidth(final, size: size)
        let label = Text(words == 1 ? "word talked" : "words talked")
        let since = TokensStatsCopy.since(board)
        let number = ZStack(alignment: .leading) {
            Text(final).hidden()
            StatsCountingNumber(value: heroShown)
        }
        .font(TokensStatsType.hero(size))
        .tracking(-size / 40)
        .foregroundStyle(TokensUI.ink)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(final) \(words == 1 ? "word" : "words") talked, \(since)")
        .help("Every word you've said, counted from talks saved on this Mac. Nothing here is saved or sent.")
        .accessibilityIdentifier("tokens.stats.hero")

        let wide = width + 20 + max(TokensUI.textWidth(since, size: 15),
                                     TokensUI.textWidth("words talked", size: 24) + 4) <= column
        if wide {
            TokensStatsBlock(cells: 2) {
                number.statsBaseline(2 * TokensUI.paperCell)
                label.font(TokensStatsType.heroLabel).foregroundStyle(TokensUI.ink)
                    .statsBaseline(2 * TokensUI.paperCell - TokensUI.halfCell)
                    .padding(.leading, width + 20)
                    .accessibilityHidden(true)
                Text(since).font(TokensType.body).foregroundStyle(TokensUI.secondary)
                    .statsBaseline(2 * TokensUI.paperCell)
                    .padding(.leading, width + 20)
                    .accessibilityHidden(true)
            }
            .lineLimit(1)
            // Behind the number: the rule is its baseline, and the comma's tail (or a descender)
            // must stay whole over it, never be cut by it (build 78).
            .background(alignment: .bottom) { rule }
        } else {
            TokensStatsBlock(cells: 2) { number.statsBaseline(2 * TokensUI.paperCell) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label.font(TokensType.labelLarge).foregroundStyle(TokensUI.ink)
                    Text(since).font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                }
                .tokensOnRule()
                VStack(alignment: .leading, spacing: 0) {
                    label.font(TokensType.labelLarge).foregroundStyle(TokensUI.ink).tokensOnRule()
                    Text(since).font(TokensType.caption).foregroundStyle(TokensUI.secondary).tokensOnRule()
                }
            }
            .lineLimit(1)
            .accessibilityHidden(true)
            .background(alignment: .bottom) { rule }
        }
    }

    // MARK: Graph header

    /// "Words over time" (with the filtered app, if any) and the range control on one rule.
    @ViewBuilder
    func graphHeader(_ board: StatsBoard) -> some View {
        let title = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Words over time").font(TokensStatsType.section).foregroundStyle(TokensUI.ink)
                .accessibilityAddTraits(.isHeader)
            if let id = board.filter, let app = board.apps.first(where: { $0.id == id }) {
                Button { filter = nil } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("· \(app.name)").font(TokensType.body)
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(TokensLinkButtonStyle())
                .help("Show all apps (Escape)")
                .accessibilityLabel("Showing \(app.name) only. Show all apps")
                .accessibilityIdentifier("tokens.stats.filter")
            }
        }
        .lineLimit(1)
        .fixedSize()
        /*
        Each segment says its own range ("Today", "Last 7 days", ...) and has its own identifier;
        the group is "Range". A label on the whole control used to replace every segment's, so all
        four read "Range" (TOK-QA-003, build 80).
        */
        let picker = TokensSegmented(options: StatsRange.allCases.map { ($0, TokensStatsCopy.rangeShort($0)) },
                                     selection: $range,
                                     spoken: { TokensStatsCopy.rangeSpoken($0) },
                                     identifierPrefix: "tokens.stats.range")
            .tokensControlOnBaseline()
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Range")
            .accessibilityIdentifier("tokens.stats.range")
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { title; Spacer(minLength: 16); picker }
                .tokensOnRule()
            VStack(alignment: .leading, spacing: 0) { title.tokensOnRule(); picker.tokensOnRule() }
        }
    }

    // MARK: Today

    /// Words today, speaking speed (with "usual"), talk time: equal columns, number then label.
    @ViewBuilder
    func todayRow(_ board: StatsBoard) -> some View {
        let tiles = TokensStatsCopy.today(board.today)
        let highlight: (Bool) -> Void = { on in
            guard !pinnedPose, board.unit == .day || board.unit == .week else { return }
            hoveredPoint = on ? board.points.indices.last : nil
        }
        if column >= 3 * 150 {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    if index > 0 {
                        Rectangle().fill(TokensUI.divider).frame(width: 1, height: 64)
                            .padding(.top, 28)
                            .padding(.trailing, 24)
                            .accessibilityHidden(true)
                    }
                    TokensStatsTile(tile: tile, onHover: highlight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 2 * TokensUI.paperCell, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    TokensStatsTile(tile: tile, onHover: highlight, inline: true)
                }
            }
        }
    }

    // MARK: By app

    @ViewBuilder
    func byApp(_ board: StatsBoard) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("By app").font(TokensStatsType.section).foregroundStyle(TokensUI.ink)
                .accessibilityAddTraits(.isHeader)
            Text("· \(TokensStatsCopy.rangePhrase(board.range))").font(TokensType.body).foregroundStyle(TokensUI.secondary)
        }
        .lineLimit(1)
        .tokensOnRule()
        .help("Which app each talk went to, saved with the talk on this Mac. Talks with no app saved, and apps after the top five, are under Other.")
        let rows = board.apps
        let cells = CGFloat(rows.count + 1)
        let donutSize = min(168, cells * TokensUI.paperCell - 40)
        let donut = TokensStatsDonut(rows: rows, total: board.appWords, size: donutSize, arrival: arrival,
                                     hovered: Binding(get: { hoveredApp }, set: { if !pinnedPose { hoveredApp = $0 } }),
                                     selected: board.filter, toggle: toggleFilter)
        let table = TokensStatsAppTable(rows: rows, hovered: Binding(get: { hoveredApp }, set: { if !pinnedPose { hoveredApp = $0 } }),
                                        selected: board.filter, toggle: toggleFilter)
        if column >= 168 + 40 + 340 {
            HStack(alignment: .top, spacing: 40) {
                donut.frame(width: donutSize, height: cells * TokensUI.paperCell)
                table
            }
            .background(alignment: .bottom) { rule }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                donut.frame(width: donutSize, height: ceil((donutSize + 24) / TokensUI.paperCell) * TokensUI.paperCell)
                table
            }
            .background(alignment: .bottom) { rule }
        }
    }

    // MARK: Records

    /// "Longest talk · 6m 12s · Thu" and "Fastest day · 231 wpm · Mon"; the sample label trails.
    @ViewBuilder
    func records(_ board: StatsBoard) -> some View {
        let items = TokensStatsCopy.records(board.records, now: now)
        if !items.isEmpty || sample {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Rectangle().fill(TokensUI.divider).frame(width: 1, height: 16)
                                .padding(.horizontal, 20)
                                .tokensControlOnBaseline()
                                .accessibilityHidden(true)
                        }
                        recordText(item)
                    }
                    Spacer(minLength: 16)
                    if sample { sampleLabel }
                }
                .tokensOnRule()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in recordText(item).tokensOnRule() }
                    if sample { sampleLabel.tokensOnRule() }
                }
            }
        }
    }

    private func recordText(_ item: TokensStatsCopy.Record) -> some View {
        (Text(item.label + " · ").foregroundStyle(TokensUI.secondary)
            + Text(item.value).foregroundStyle(TokensUI.ink2)
            + Text(" · " + item.when).foregroundStyle(TokensUI.secondary))
            .font(TokensType.caption.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .help(item.help)
    }

    var sampleLabel: some View {
        Text("Synthetic sample")
            .font(TokensType.caption)
            .foregroundStyle(TokensUI.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("tokens.stats.synthetic")
    }
}

/// Fixed rows of whole squares; children place their own baselines with `statsBaseline`.
struct TokensStatsBlock<Content: View>: View {
    let cells: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: cells * TokensUI.paperCell)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: cells * TokensUI.paperCell, alignment: .top)
    }
}

extension View {
    /// Inside a TokensStatsBlock (or any top-leading stack): first baseline at `y` from the top.
    func statsBaseline(_ y: CGFloat) -> some View {
        alignmentGuide(.top) { $0[.firstTextBaseline] - y }
    }
}

/// The hero's count-up: SwiftUI interpolates `value`, so the digits roll once from zero.
struct StatsCountingNumber: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(Int(value.rounded()).formatted()) }
}

/// One of today's numbers: number on the first rule, label half a square below, note on the next.
struct TokensStatsTile: View {
    let tile: TokensStatsCopy.Tile
    let onHover: (Bool) -> Void
    var inline = false

    var body: some View {
        Group {
            if inline {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    number
                    Text(tile.label).font(TokensType.body).foregroundStyle(TokensUI.secondary)
                    if let note = tile.note { Text("· " + note).font(TokensType.caption).foregroundStyle(TokensUI.secondary) }
                }
                .lineLimit(1)
                .tokensOnRule()
            } else {
                TokensStatsBlock(cells: 2) {
                    number.statsBaseline(TokensUI.paperCell)
                    Text(tile.label).font(TokensType.body).foregroundStyle(TokensUI.secondary)
                        .statsBaseline(TokensUI.paperCell + TokensUI.halfCell)
                    if let note = tile.note {
                        Text(note).font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                            .statsBaseline(2 * TokensUI.paperCell)
                    }
                }
                .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .help(tile.help)
        .accessibilityElement(children: .combine)
    }

    private var number: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(tile.value).font(TokensStatsType.tile)
                .foregroundStyle(tile.value == TokensStatsCopy.none ? TokensUI.faint : TokensUI.ink)
            if let unit = tile.unit {
                Text(unit).font(TokensStatsType.tileUnit).foregroundStyle(TokensUI.ink2)
            }
        }
        .fixedSize()
    }
}

/// The scoreboard's own type, inside DESIGN.md's weights (regular and medium only).
enum TokensStatsType {
    static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
    static let heroLabel = Font.system(size: 24, weight: .medium)
    static let section = Font.system(size: 17, weight: .medium)
    static let tile = Font.system(size: 40, weight: .medium).monospacedDigit()
    static let tileUnit = Font.system(size: 22, weight: .regular)

    /// The hero's final width, so the count-up never moves the words beside it.
    static func heroWidth(_ text: String, size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        return ceil(NSAttributedString(string: text, attributes: [.font: font, .kern: -size / 40]).size().width)
    }
}

//
// :)
//
//
/// Every visible label, kept in one place so tests can verify their contract.
enum TokensStatsCopy {
    static let empty = "Your first talk will show up here."
    static let none = "—"
    static let talkTimeHelp = "Talk time adds up each saved talk's stated length, from the key press to the end of capture. "
        + "It is capture time, not speaking time. Talks saved without a time are left out."

    struct Tile: Equatable {
        var value: String
        var unit: String?
        var label: String
        var note: String?
        var help: String
    }

    struct Record: Equatable {
        var label: String
        var value: String
        var when: String
        var help: String
    }

    static func rangeShort(_ range: StatsRange) -> String {
        switch range {
        case .today: "Today"
        case .sevenDays: "7"
        case .fourteenDays: "14"
        case .all: "All"
        }
    }

    /// The segment's spoken name: the short label alone ("7") says nothing to VoiceOver.
    static func rangeSpoken(_ range: StatsRange) -> String {
        switch range {
        case .today: "Today"
        case .sevenDays: "Last 7 days"
        case .fourteenDays: "Last 14 days"
        case .all: "All time"
        }
    }

    static func rangePhrase(_ range: StatsRange) -> String {
        switch range {
        case .today: "today"
        case .sevenDays: "last 7 days"
        case .fourteenDays: "last 14 days"
        case .all: "all time"
        }
    }

    /// "since 5 Oct · 31 dictations" (the year shows when it is not this year).
    static func since(_ board: StatsBoard, now: Date = Date()) -> String {
        let count = "\(board.totalDictations.formatted()) \(board.totalDictations == 1 ? "talk" : "talks")"
        guard let since = board.since else { return count }
        let sameYear = Calendar.current.isDate(since, equalTo: now, toGranularity: .year)
        return "since \(TokensStatsLabels.format(since, sameYear ? "d MMM" : "d MMM yyyy")) · \(count)"
    }

    /// Words today · Speaking speed (today's median, else the usual one) · Talk time today.
    static func today(_ today: StatsToday) -> [Tile] {
        let words = Tile(value: today.words.formatted(), label: today.words == 1 ? "Word today" : "Words today",
                         help: "\(today.talks.formatted()) \(today.talks == 1 ? "talk" : "talks") today.")
        let speedHelp = "The middle of each talk's stated words per minute. Usual is the last 14 days before today."
        let speed: Tile
        if let median = today.medianWPM {
            speed = Tile(value: median.formatted(), unit: "wpm", label: "Speaking speed",
                         note: today.usualWPM.map { "usual \($0.formatted())" }, help: speedHelp)
        } else if let usual = today.usualWPM {
            speed = Tile(value: usual.formatted(), unit: "wpm", label: "Speaking speed", note: "usual · none timed today", help: speedHelp)
        } else {
            speed = Tile(value: none, label: "Speaking speed", help: speedHelp)
        }
        let time = Tile(value: StatsSummary.talkTime(today.talkSeconds), label: "Talk time today", help: talkTimeHelp)
        return [words, speed, time]
    }

    /// The records line; a day within the last week is named by weekday, older ones by date.
    static func records(_ records: StatsRecords, now: Date) -> [Record] {
        var items: [Record] = []
        if let longest = records.longestTalk {
            let app = longest.app.map { " in \($0)" } ?? ""
            items.append(Record(label: "Longest talk", value: StatsSummary.talkTime(longest.seconds),
                                when: TokensStatsLabels.recent(longest.date, now: now),
                                help: "\(TokensStatsLabels.format(longest.date, "EEE d MMM, h:mm a"))\(app)"))
        }
        if let fastest = records.fastestDay {
            items.append(Record(label: "Fastest day", value: "\(fastest.wpm.formatted()) wpm",
                                when: TokensStatsLabels.recent(fastest.day, now: now),
                                help: "\(TokensStatsLabels.format(fastest.day, "EEE d MMM")) · middle of \(fastest.talks.formatted()) timed \(fastest.talks == 1 ? "talk" : "talks")"))
        }
        return items
    }
}

/// Fixed English date shapes, matching VoiceLedger's day labels ("Thu 9 Oct").
enum TokensStatsLabels {
    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func recent(_ date: Date, now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 99
        return days < 7 ? format(date, "EEE") : format(date, "d MMM")
    }

    /// Axis label for a point: hour ("9am"), weekday for a week or two, else the date.
    static func axis(_ point: StatsPoint, unit: StatsBucketUnit, count: Int) -> String {
        switch unit {
        case .hour: format(point.start, "ha").lowercased()
        case .day: count <= 14 ? format(point.start, "EEE") : format(point.start, "d MMM")
        case .week: format(point.start, "d MMM")
        }
    }

    /// Hover card title: "Thu 9 Oct", "9am", or "1–7 Oct".
    static func long(_ point: StatsPoint, unit: StatsBucketUnit) -> String {
        switch unit {
        case .hour: format(point.start, "ha").lowercased() + "–" + format(point.end, "ha").lowercased()
        case .day: format(point.start, "EEE d MMM")
        case .week:
            format(point.start, "d MMM") + " – " + format(point.end.addingTimeInterval(-1), "d MMM")
        }
    }
}

