


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension TokensHome {

    // MARK: History

    /// One saved talk as a row; a click copies it, and long talks open in place (Show more).
    func historyRow(_ entry: PromptHistoryEntry, lines: Int = 3) -> some View {
        TokensHistoryRow(entry: entry, model: model, previewLines: lines)
    }

    /*
    One of three views, checked in order: a history storage error (with Retry, and Preserve & reset
    when recovery is needed), an empty history, or the search line over the grouped list. The
    first line is rule 3, under the title; after a blank square, day groups start on rule 4
    (on the smallest zoomed sheet the blank square is left out: TokensFieldClearance).
    */
    var historyPage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if !model.historyStorageError.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TokensStatusDot(color: TokensUI.red)
                        Text(model.historyStorageError)
                            .font(TokensType.body)
                            .foregroundStyle(TokensUI.ink2)
                            .lineLimit(3)
                            .tokensReadingPitch()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tokensOnRule()
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button { model.retryPromptHistoryStorage() } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TokensQuietButtonStyle(size: .regular))
                        .tokensControlOnBaseline()
                        if model.historyRecoveryRequired {
                            Button { model.recoverPromptHistoryStorage() } label: {
                                Label("Preserve & reset", systemImage: "externaldrive")
                            }
                            .buttonStyle(TokensQuietButtonStyle(size: .regular))
                            .tokensControlOnBaseline()
                        }
                    }
                    .tokensOnRule()
                } else if model.promptHistory.isEmpty {
                    Text("Nothing yet. What you say will show up here.")
                        .font(TokensType.body)
                        .foregroundStyle(TokensUI.secondary)
                        .tokensReadingPitch()
                        .fixedSize(horizontal: false, vertical: true)
                        .tokensOnRule()
                    if !model.historyStorageNotice.isEmpty {
                        Text(model.historyStorageNotice)
                            .font(TokensType.caption)
                            .foregroundStyle(TokensUI.secondary)
                            .tokensReadingPitch(size: 13)
                            .fixedSize(horizontal: false, vertical: true)
                            .tokensOnRule()
                    }
                } else {
                    historySearchLine
                    if matchingHistory.isEmpty {
                        Text("No matches.")
                            .font(TokensType.body)
                            .foregroundStyle(TokensUI.secondary)
                            .tokensOnRule()
                    } else {
                        // A blank square keeps "Today" clear of the field hanging below rule 3,
                        // as on the Dictionary, so the day groups start on rule 4 (build 81).
                        TokensFieldClearance()
                        TokensHistoryCard(entries: matchingHistory, model: model, previewLines: 3, lazy: true)
                            .accessibilityLabel("Everything you said")
                    }
                }
            }
            .tokensPageColumn()
        }
        .tokensRuledScroll()
        .tokensRestingEdge()
        .modifier(TokensHistoryPreviewFixtures(model: model, apply: applyHistoryPreviewFixtures))
    }

    /*
    Render-only History fixtures (TokensHistoryPreview) applied to this synthetic run's
    in-memory model. Synthetic runs never write history (TalkModel+History), and nothing here
    touches the clipboard: "Copied" is drawn by setting the feedback key alone. It is re-applied
    when the preview script replaces the history or its own copy mark, and assigns only on a
    difference, so it settles.
    */
    func applyHistoryPreviewFixtures() {
        guard model.isSyntheticRun, TokensHistoryPreview.any else { return }
        if TokensHistoryPreview.full, !TokensHistoryPreview.empty, !TokensHistoryPreview.error,
           model.promptHistory.first?.text != TokensHistoryPreview.fictionalTalks[0].text {
            model.promptHistory = TokensHistoryPreview.history(now: Date())
        }
        if (TokensHistoryPreview.empty || TokensHistoryPreview.error), !model.promptHistory.isEmpty {
            model.promptHistory = []
        }
        if TokensHistoryPreview.error, model.historyStorageError.isEmpty {
            model.historyStorageError = "History could not be loaded. Original preserved."
            model.historyRecoveryRequired = true
        }
        if TokensHistoryPreview.empty, model.historyStorageNotice.isEmpty {
            model.historyStorageNotice = "History cleared."
        }
        if TokensHistoryPreview.copied, let first = model.promptHistory.first,
           model.copyFeedbackKey != first.id.uuidString {
            model.copyFeedbackKey = first.id.uuidString
        }
    }

    /*
    Rule 3: the search field across the column minus 44, then a 32 × 32 quiet "…" menu whose
    one item, Clear history…, opens the existing confirmation. Everything listed is kept on this
    Mac only; this is the one way to delete it, and it waits while recovery is required.
    */
    private var historySearchLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TokensHistorySearchField(query: $historyQuery, count: model.promptHistory.count)
                .frame(maxWidth: .infinity)
                .tokensControlOnBaseline()
            Menu {
                Button("Clear history…") { confirmingClearHistory = true }
                    .disabled(model.historyRecoveryRequired)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(TokensHistoryMenuButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.historyRecoveryRequired)
            .help("More")
            .accessibilityLabel("History actions")
            .tokensControlOnBaseline()
        }
        .tokensOnRule()
        .alert("Clear all history?", isPresented: $confirmingClearHistory) {
            Button("Clear History", role: .destructive) { model.clearPromptHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything you said is deleted from this Mac. This cannot be undone.")
        }
    }

//
// :)
//
//
    /*
    With a blank search, every talk. Otherwise the talks whose shown words (or typed note) contain
    the search words, a locale-aware match that ignores case and accents (TalkModel.historyMatches,
    build 81: it used to search the saved markup, tags and metadata included).
    */
    private var matchingHistory: [PromptHistoryEntry] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.promptHistory }
        return model.promptHistory.filter { TalkModel.historyMatches($0, query: query) }
    }

    /*
    One saved talk. Rule 3: its date and word count, with a quiet Copy button at the end of the
    line. From rule 4: the full selectable text at the 28-point pitch, straight on the sheet. If
    the talk has since been removed, a short message instead.
    */
    func promptPage(_ id: UUID) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let entry = model.promptHistory.first(where: { $0.id == id }) {
                    let copied = model.copyFeedbackKey == entry.id.uuidString
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
                             + " · \(TokensHistoryText.words(entry).formatted()) words")
                            .font(TokensType.caption)
                            .foregroundStyle(TokensUI.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Button { model.copyPromptHistoryEntry(entry) } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(TokensQuietButtonStyle(size: .regular))
                        .fixedSize()
                        .tokensControlOnBaseline()
                        .accessibilityLabel("Copy words")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tokensOnRule()
                    Text(model.historyPresentation(entry))
                        .font(TokensType.body)
                        .foregroundStyle(TokensUI.ink)
                        .tokensReadingPitch()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Full text")
                        .tokensOnRule()
                        .tokensCopyFeedback(active: copied, revision: model.copyFeedbackRevision)
                } else {
                    Text("These words are no longer saved.")
                        .font(TokensType.body)
                        .foregroundStyle(TokensUI.secondary)
                        .tokensOnRule()
                }
            }
            .tokensPageColumn()
        }
        .tokensRuledScroll()
        .tokensRestingEdge()
        .modifier(TokensHistoryPreviewFixtures(model: model, apply: applyHistoryPreviewFixtures))
    }
}

/*
Render-only History fixtures (DESIGN.md §8.3), so the changed states can be looked at before
they ship. Each needs --render-preview-frames in a proof-allowed build on a synthetic run, and
none writes preferences, consent, history or the clipboard.
  --history-preview-full       nine fictional talks over four days, the newest two long
                               (History only; Home uses --home-preview-history full)
  --history-preview-expanded   the list's first row opens in place (Show less under the words)
  --history-preview-hover      the list's first row draws as if the pointer were over it
  --history-preview-copied     the first dictation shows "Copied" (rows and the detail page)
  --history-preview-empty      no dictations, with the storage notice
  --history-preview-error      the storage error with Retry and Preserve & reset
*/
enum TokensHistoryPreview {
    static func flag(_ name: String, arguments: [String] = ProcessInfo.processInfo.arguments,
                     allowed: Bool = ProofRoutes.isAllowed) -> Bool {
        allowed && arguments.contains("--render-preview-frames") && arguments.contains(name)
    }
    static let full = flag("--history-preview-full")
    static let expanded = flag("--history-preview-expanded")
    static let hover = flag("--history-preview-hover")
    static let copied = flag("--history-preview-copied")
    static let empty = flag("--history-preview-empty")
    static let error = flag("--history-preview-error")
    static var any: Bool { full || copied || empty || error }

    /// Fictional talks for --history-preview-full: (words, minutes ago), newest first.
    static let fictionalTalks: [(text: String, minutesAgo: Double)] = [
        ("Draft a reply to the design thread: Thursday works for me, but I'd like to move the review to the "
         + "afternoon so the prototype has one more pass. Bring the two layouts we liked, the calmer list and "
         + "the denser one, and we'll pick with the real copy in place rather than the placeholder text.", 3),
        ("Notes for the planning call. First, the export folder keeps its old name for a week so nobody's "
         + "links break. Second, the settings page needs one more look at the smallest window size. Third, "
         + "ask whether the reading list should sit under the heading or beside it.", 21),
        ("Keep every recognized word, including the correction I just made.", 48),
        ("Make the tiny recording capsule feel immediate and calm.", 95),
        ("Green notebook, blue pencil, and the margin notes from Tuesday's review.", 1_500),
        ("Move the reading list under the heading and keep the links as they are.", 1_620),
        ("Add a note that the café order is ready at noon.", 2_950),
        ("Check the spacing on the settings page at the smallest window size.", 4_400),
        ("Summarize the three open questions before the planning call.", 4_480),
    ]

    /// Today's talks squeeze into the time since midnight, so a render just after 00:00 still has them.
    static func history(now: Date, calendar: Calendar = .current) -> [PromptHistoryEntry] {
        let elapsed = now.timeIntervalSince(calendar.startOfDay(for: now))
        let todaySpan = (fictionalTalks.map(\.minutesAgo).filter { $0 < 120 }.max() ?? 1) * 60 + 60
        return fictionalTalks.map { talk in
            let ago = talk.minutesAgo < 120 ? talk.minutesAgo * 60 * min(1, elapsed / todaySpan) : talk.minutesAgo * 60
            return PromptHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-ago), text: talk.text)
        }
    }
}

/// Applies the History fixtures on appear and again whenever the history or the copy mark
/// changes. Without a fixture flag the apply call returns at once.
struct TokensHistoryPreviewFixtures: ViewModifier {
    @ObservedObject var model: TalkModel
    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: apply)
            .onChange(of: model.promptHistory.count) { _, _ in apply() }
            .onChange(of: model.copyFeedbackKey) { _, _ in apply() }
    }
}

/*
Scrolled pages rest with every visible line whole (DESIGN.md §4.3). The page's content is cut
just under the lowest rule whose descenders fit in the page slot, leaving 13 points for controls
centred on that line (a 36-point field ends 13 below its baseline). So the next line's ascenders
never show as a sliver at the window's bottom edge, and a Show more line at the half-rule never
shows at the fold without its words. The slot starts on a rule, so its local
56-point lines are the sheet's rules. Only the content is masked: the graph squares behind it
run to the edge. The mask measures itself (a Canvas); no GeometryReader is tied to scroll content.
*/
struct TokensRestingEdgeMask: View {
    // Plain constants and maths, usable from the geometry callback off the main actor.
    nonisolated static let descender: CGFloat = 4
    nonisolated static let below: CGFloat = 13
    /// The page slot's own coordinate space, named by tokensRestingEdge() for rows to measure in.
    nonisolated static let space = "tokens.resting-edge.slot"

    /// Where visible content ends inside a slot `height` tall.
    nonisolated static func cut(height: CGFloat) -> CGFloat {
        let pitch = TokensUI.paperCell
        let line = floor(max(0, height - descender) / pitch) * pitch
        return min(height, line + below)
    }

    /*
    Whether a row whose top is `rowTop` and height `rowHeight` in a slot `slotHeight` tall sits
    under the resting edge. Any row whose first half-square is cut does: at rest that is the row
    straddling the edge, whose top 13 points look like blank paper. Rows centre their lines in
    whole squares (TokensHistoryCellLayout), not on the rules the cut assumes, so a row of one or
    two squares that does not fit whole above the cut is under the edge too; otherwise a
    two-square row resting on its middle rule showed its second line sliced at the window's
    bottom (History at 760 × 520, build 81). A taller, open row whose first half-square still
    shows stays, because its first words are on screen.
    */
    nonisolated static func hides(rowTop: CGFloat, rowHeight: CGFloat = TokensUI.paperCell,
                                  slotHeight: CGFloat) -> Bool {
        let edge = cut(height: slotHeight)
        if rowTop + TokensUI.halfCell > edge { return true }
        return rowHeight <= 2 * TokensUI.paperCell
            && rowTop + rowHeight - TokensHistoryCellLayout.minimumPadding > edge
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.cut(height: size.height))),
                         with: .color(.black))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Hides a partial line at the bottom of a page slot (TokensRestingEdgeMask), and names the
    /// slot so the rows inside can tell when they sit under that edge (tokensQuietUnderRestingEdge).
    func tokensRestingEdge() -> some View {
        coordinateSpace(.named(TokensRestingEdgeMask.space))
            .mask { TokensRestingEdgeMask() }
    }

    /*
    The mask only hides; it does not stop clicks. So a row hidden under the resting edge still
    copied a talk you could not see, or removed a Dictionary term, from blank-looking paper at the
    window's bottom (build 81). A row under the edge is not drawn and takes no clicks, hover or
    tooltip: no sliced line, and no stray strip of a row's wash (the Dictionary's just-added mark
    at 1440 × 900). Scrolling still works there, because the scroll view itself still takes the
    wheel. Outside a page slot (no tokensRestingEdge) nothing changes.
    */
    func tokensQuietUnderRestingEdge() -> some View { modifier(TokensRestingEdgeGate()) }
}

/*
Hides a row and turns its clicks off while TokensRestingEdgeMask.hides says it is under the
edge. The drawing is dropped by a visual effect, computed from the row's place in the slot
while it draws, so no frame shows the row before it is hidden; it changes drawing only, never
layout. Clicks follow onGeometryChange, which only ever flips a Bool here. Nothing in the
layout depends on either (no GeometryReader, DESIGN.md §8.1).
*/
struct TokensRestingEdgeGate: ViewModifier {
    @State private var underEdge = false

    func body(content: Content) -> some View {
        content
            .visualEffect { effect, proxy in effect.opacity(Self.underEdge(proxy) ? 0 : 1) }
            .allowsHitTesting(!underEdge)
            .onGeometryChange(for: Bool.self) { Self.underEdge($0) } action: { underEdge = $0 }
    }

    /// Whether the row measured by `proxy` is under its slot's resting edge (false outside a slot).
    nonisolated static func underEdge(_ proxy: GeometryProxy) -> Bool {
        guard let slot = proxy.bounds(of: .named(TokensRestingEdgeMask.space)) else { return false }
        // The slot's bounds in this row's own coordinates: its top is minus the row's top.
        return TokensRestingEdgeMask.hides(rowTop: -slot.minY, rowHeight: proxy.size.height,
                                           slotHeight: slot.height)
    }
}

/*
The blank square between a field and the centred rows listed under it: History's search line
and the Dictionary's add field (the Dictionary's since build 77). A 36-point field hangs 13
points below its rule into the next square, so a row centred there sat about 10 points under
the field and read as its caption ("Today" on History, build 81). On a sheet too short to show
a first row after the blank square (760 × 520 at 150%), the square is left out, so the page
shows a row rather than empty paper; the Dictionary then starts its first row's wash under
the field.
*/
struct TokensFieldClearance: View {
    @Environment(\.tokensSheetSize) private var sheet

    /*
    With the blank square, the first row ends five squares into the page slot (which starts on
    rule 2): History's search line, the blank square, "Today" and a row of up to two squares; or
    the Dictionary's intro (up to two squares), the add field, the blank square and one term.
    */
    nonisolated static let squaresToFirstRow: CGFloat = 5

    /// Whether a sheet `sheetHeight` tall keeps the blank square: that first row still ends above
    /// the resting edge (TokensRestingEdgeMask.cut).
    nonisolated static func shows(sheetHeight: CGFloat) -> Bool {
        let slot = sheetHeight - 2 * TokensUI.paperCell
        return TokensRestingEdgeMask.cut(height: slot) >= squaresToFirstRow * TokensUI.paperCell
    }

    var body: some View {
        if Self.shows(sheetHeight: sheet.height) { TokensRuleSpacer(cells: 1) }
    }
}

//
// :)
//
//
/*
Saved talks on the sheet (build 77). History groups them by day: a semibold
secondary day label ("Today", "Yesterday", "Oct 10") on its own square with a hairline under it,
then that day's rows, each with a hairline under it. Home's Recent passes at most eight entries
ungrouped, and each row names its day instead. The name is kept from the card era for the
cross-lane contract; there is no card.

Every header and row is a whole number of grid squares (TokensHistoryCellLayout), its content
centred in them, and its hairline drawn on the grid line at its bottom edge. So a row's hover
fill and click area are exactly its own squares: they meet the next row at the hairline and
never cover it or the row beyond.
*/
struct TokensHistoryCard: View {
    let entries: [PromptHistoryEntry]
    @ObservedObject var model: TalkModel
    var previewLines = 2
    var lazy = false
    var grouped = true

    struct DayGroup: Identifiable {
        let day: Date
        let label: String
        let entries: [PromptHistoryEntry]
        var id: Date { day }
    }

    /// Consecutive entries on the same calendar day form one group; history order is kept.
    static func groups(_ entries: [PromptHistoryEntry], now: Date = Date(),
                       calendar: Calendar = .current) -> [DayGroup] {
        var result: [DayGroup] = []
        var current: [PromptHistoryEntry] = []
        var currentDay: Date?
        func flush() {
            guard let day = currentDay, !current.isEmpty else { return }
            result.append(DayGroup(day: day, label: dayLabel(day, now: now, calendar: calendar), entries: current))
        }
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if day != currentDay { flush(); current = []; currentDay = day }
            current.append(entry)
        }
        flush()
        return result
    }

    static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            return day.formatted(.dateTime.month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { content }
            } else {
                VStack(alignment: .leading, spacing: 0) { content }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if grouped {
            ForEach(Self.groups(entries)) { group in
                TokensHistoryCellLayout {
                    Text(group.label)
                        .font(TokensType.captionStrong)
                        .foregroundStyle(TokensUI.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottom) { TokensHistoryDivider() }
                .accessibilityAddTraits(.isHeader)
                ForEach(group.entries, id: \.id) { entry in row(entry, showsDay: false) }
            }
        } else {
            ForEach(entries, id: \.id) { entry in row(entry, showsDay: true) }
        }
    }

    /// Render-only fixtures (hover, open) apply to the list's first row only.
    private func row(_ entry: PromptHistoryEntry, showsDay: Bool) -> some View {
        TokensHistoryRow(entry: entry, model: model, previewLines: previewLines,
                         showsDay: showsDay, proofRow: entry.id == entries.first?.id)
    }
}

/*
The hairline on the grid line at the bottom edge of a header or row, used as
`.overlay(alignment: .bottom)`. It hangs from that edge at the grid's own weight, so it covers
exactly what TokensSheetGrid fills for the rule there (y to y + 1 / zoom) and the two read as one
line (DESIGN.md §4.1), like the hero's TokensHairline on its rule. It used to fill the point
above the rule: a doubled two-tone line with a step where the column ended (build 81).
*/
struct TokensHistoryDivider: View {
    @Environment(\.tokensSheetZoom) private var zoom

    /// The sheet grid's line weight: one screen point at any zoom.
    static func weight(zoom: CGFloat) -> CGFloat { 1 / max(zoom, 0.01) }

    var body: some View {
        Rectangle().fill(TokensUI.divider).frame(height: Self.weight(zoom: zoom))
            .alignmentGuide(.bottom) { $0[.top] }   // its top edge on the row's bottom edge
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/*
A header or row as whole grid squares with its content centred in them: the height is the
content plus at least `minimumPadding` above and below, rounded up to 56-point squares. A
one-line row is one square (about 17 points clear above and below 17-point text); two or three
lines, or two lines and Show more, are two squares.
*/
struct TokensHistoryCellLayout: Layout {
    static let minimumPadding: CGFloat = 12

    static func height(content: CGFloat, cell: CGFloat = TokensUI.paperCell) -> CGFloat {
        max(cell, ceil((content + 2 * minimumPadding) / cell) * cell)
    }

    /*
    The content's top in a cell `height` tall, its lines on the 28-point pitch from
    `firstBaseline`. One square: centred (build 77). Taller cells have a rule inside them, and
    centring an odd number of lines puts the middle line's letters on it (build 81: the rule ran
    through "but I'd like to move the review"). So the block lifts, by under half a pitch, until
    its baselines sit on the rules and half-rules; an even number of lines stays centred, with the
    rule passing between two lines. No rule crosses a line (DESIGN.md R2, R4).
    */
    static func top(content: CGFloat, firstBaseline: CGFloat, height: CGFloat,
                    cell: CGFloat = TokensUI.paperCell) -> CGFloat {
        let centred = (height - content) / 2
        guard height > cell + 0.5 else { return centred }
        let pitch = cell / 2
        let belowRule = (centred + firstBaseline).truncatingRemainder(dividingBy: pitch)
        return belowRule < pitch / 2 && centred - belowRule >= 0 ? centred - belowRule : centred
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: Self.height(content: size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let content = view.dimensions(in: ProposedViewSize(width: bounds.width, height: nil))
        let top = Self.top(content: content.height, firstBaseline: content[.firstTextBaseline],
                           height: bounds.height)
        view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top),
                   proposal: ProposedViewSize(width: bounds.width, height: content.height))
    }
}

/*
One saved talk: the time in a fixed left column (secondary), the words (17-point ink, wrapping)
and a quiet copy icon at the right edge. Clicking anywhere in the row copies the whole dictation
at once (TalkModel.copyPromptHistoryEntry); Return or Space on a focused row does the same, and
VoiceOver reads it as a "Copy words" button. For 1.6 seconds the icon becomes a red check
and "Copied". Hover only adds a faint fill inside the row's own squares; nothing moves or grows.

Long talks show two lines and a quiet "Show more" under them; it opens the whole text in place,
with "Show less" under it, and never copies (the words take no clicks, so a click reaches either
the link or the row). Talks that fit in three lines show them all. Home's Recent passes one line
and never expands.
*/
struct TokensHistoryRow: View {
    let entry: PromptHistoryEntry
    @ObservedObject var model: TalkModel
    var previewLines = 3
    /// Home's Recent: say "Yesterday" or "Oct 10" in the time column for older talks.
    var showsDay = false
    /// The list's first row: render-only hover and open fixtures apply here.
    var proofRow = false
    @State private var expanded = false
    @State private var previewWidth: CGFloat = 0
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.tokensSheetSize) private var sheet

    /// A faint row fill on hover or keyboard focus (DESIGN.md §2.3 sheet rows: ink 4%).
    static var hoverFill: Color { TokensInk.primary.color.opacity(0.04) }
    static let wideColumn: CGFloat = 480
    static let accessibilityLabel = "Copy words"
    static let textSize: CGFloat = 17
    static var textFont: Font { .system(size: textSize) }

    private var preview: String { TokensHistoryText.preview(entry) }
    private var copied: Bool { model.copyFeedbackKey == entry.id.uuidString }
    private var previewIsTruncated: Bool {
        TokensHistoryRowLayout.isTruncated(preview, width: previewWidth, lineLimit: previewLines,
                                           size: Self.textSize)
    }
    /// Typed notes are omitted by the spoken preview but must remain reachable.
    private var hasTypedNote: Bool { entry.authored?.typed.isEmpty == false }
    private var showsToggle: Bool {
        TokensHistoryRowLayout.showsToggle(previewLines: previewLines, expanded: expanded,
                                           truncated: previewIsTruncated, typedNote: hasTypedNote)
    }
    private var proofHover: Bool { proofRow && model.isSyntheticRun && TokensHistoryPreview.hover }
    private var filled: Bool { hovering || focused || proofHover }
    private var wide: Bool { TokensColumn.layout(sheetWidth: sheet.width).width >= Self.wideColumn }

    private var timeText: String {
        let calendar = Calendar.current
        if showsDay, !calendar.isDateInToday(entry.createdAt) {
            return TokensHistoryCard.dayLabel(calendar.startOfDay(for: entry.createdAt))
        }
        return entry.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private func copy() { model.copyPromptHistoryEntry(entry) }

    var body: some View {
        TokensHistoryCellLayout {
            HStack(alignment: .firstTextBaseline, spacing: wide ? 16 : 10) {
                time.frame(width: wide ? 72 : 64, alignment: .leading)
                words
                status
            }
        }
        .background {
            // The row's own squares take the click; the fill is TokensHistoryRowFill.
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: copy)
                TokensHistoryRowFill(filled: filled, focused: focused)
            }
            .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { TokensHistoryDivider() }
        .animation(.easeOut(duration: 0.12), value: filled)
        .onHover { hovering = $0 }
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.return, .space]) { _ in
            copy()
            return .handled
        }
        .help("Click to copy")
        // Hidden under the page's bottom edge, the row takes no click, hover or tooltip (build 81).
        .tokensQuietUnderRestingEdge()
        .accessibilityElement(children: .contain)
        .onAppear {
            // Render-only fixture: the list's first row opens in place.
            if proofRow, model.isSyntheticRun, TokensHistoryPreview.expanded { expanded = true }
        }
    }

    /// The time, or a red "Copied" in its place in a narrow column (where the icon stands alone).
    private var time: some View {
        let showsCopied = copied && !wide
        return Text(showsCopied ? "Copied" : timeText)
            .font(TokensType.caption)
            .foregroundStyle(showsCopied ? TokensUI.red : TokensUI.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /*
    The words, then Show more / Show less under them, every line on the 28-point reading pitch
    (DESIGN.md R2): the words wrap at it, and the link's baseline is one pitch under their last
    line (TokensPitchStack), so TokensHistoryCellLayout can keep a rule off every line (build 81;
    the 23-point pitch put a rule through a line). The words never take a click (the row does),
    and they carry the row's VoiceOver button: label "Copy words", value the time and words (or
    "Copied"), identifier tokens.history.copy.<id>.
    */
    private var words: some View {
        TokensPitchStack {
            Group {
                if expanded {
                    Text(model.historyPresentation(entry))
                        .font(Self.textFont)
                        .foregroundStyle(TokensUI.ink)
                        .tokensReadingPitch(size: Self.textSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("tokens.history.full.\(entry.id.uuidString)")
                } else {
                    Text(preview)
                        .font(Self.textFont)
                        .foregroundStyle(TokensUI.ink)
                        .lineLimit(showsToggle ? previewLines - 1 : previewLines)
                        .truncationMode(.tail)
                        .tokensReadingPitch(size: Self.textSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            // Measure the offered width, not a character count or screen width, so
                            // narrowing, zooming and Recent's line limit all update Show more.
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { previewWidth = geometry.size.width }
                                    .onChange(of: geometry.size.width) { _, width in previewWidth = width }
                            }
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel)
            .accessibilityValue(copied ? "Copied" : "\(timeText). \(expanded ? model.historyPresentation(entry) : preview)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { copy() }
            .accessibilityIdentifier("tokens.history.copy.\(entry.id.uuidString)")
            if showsToggle { toggle }
        }
    }

    /// Opens or closes the whole text in place; never copies, navigates or scrolls.
    private var toggle: some View {
        Button {
            expanded.toggle()
        } label: {
            Text(expanded ? "Show less" : "Show more")
                .font(TokensType.caption)
        }
        .buttonStyle(TokensLinkButtonStyle(tone: .quiet))
        .fixedSize()
        .help(expanded ? "Show less" : "Show all of it")
        .accessibilityLabel(expanded ? "Show less" : "Show all")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("tokens.history.expand.\(entry.id.uuidString)")
    }

    /// A quiet copy icon at the right edge; a red check and "Copied" while the feedback lasts.
    private var status: some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .firstTextBaseline)) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 13))
                .foregroundStyle(filled ? TokensUI.ink2 : TokensUI.secondary)
                .opacity(copied ? 0 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                if wide { Text("Copied").font(TokensType.caption) }
            }
            .foregroundStyle(TokensUI.red)
            .opacity(copied ? 1 : 0)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: wide ? 64 : 20, alignment: .trailing)
        .animation(.easeOut(duration: 0.15), value: copied)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/*
A history row's hover or focus fill: exactly the row's own squares, square-cornered, its sides on
the same grid lines as the hairlines (build 77: the old fill ran 12 points past the row,
off the grid, with rounded corners). The hairline above the row (the row or day header before
it) hangs into the row's top 1 / zoom points, so the fill starts just under it and runs to the
row's bottom edge, where the row's own hairline hangs just outside. It never tints either line
(build 81).
*/
struct TokensHistoryRowFill: View {
    let filled: Bool
    let focused: Bool
    @Environment(\.tokensSheetZoom) private var zoom

    var body: some View {
        Rectangle()
            .fill(filled ? TokensHistoryRow.hoverFill : Color.clear)
            .overlay {
                if focused {
                    Rectangle().strokeBorder(TokensUI.controlEdge, lineWidth: 1.5)
                }
            }
            .padding(.top, TokensHistoryDivider.weight(zoom: zoom))
            .allowsHitTesting(false)
    }
}

/*
History's search field (DESIGN.md §5.11): a magnifier, then the field on the raised surface,
36 tall, with a 1.5-point edge while focused. The placeholder is drawn by Tokens in secondary,
because macOS draws a field's own prompt as bright as typed text; typed text keeps the scheme's
label colour. The clear button appears once something is typed.
*/
struct TokensHistorySearchField: View {
    @Binding var query: String
    let count: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(TokensUI.secondary)
                .accessibilityHidden(true)
            TextField("", text: $query)
                .focused($focused)
                .tokensFieldPlaceholder("Search what you said", empty: query.isEmpty)
                .accessibilityLabel("Search what you said")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(TokensUI.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .tokensFieldSurface(focused: focused)
    }
}

/// The 32 × 32 quiet square behind History's "…" menu: raised fill and control edge, ink glyph;
/// pressed shows the chip-hover fill; disabled is the neutral disabled look.
struct TokensHistoryMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .foregroundStyle(enabled ? TokensUI.ink : TokensUI.secondary)
                .frame(width: 32, height: 32)
                .background(enabled ? (configuration.isPressed ? TokensUI.chipHover : TokensUI.raised)
                                    : TokensUI.disabledFill, in: shape)
                .overlay {
                    shape.strokeBorder(enabled ? TokensUI.controlEdge : TokensInk.primary.color.opacity(0.14),
                                       lineWidth: 1)
                }
                .contentShape(shape)
        }
    }
}


/// Counts wrapped lines at the row's system font (17 in History rows); asking for one extra line is enough to
/// detect truncation without laying out an entire long transcript.
enum TokensHistoryRowLayout {
    /*
    Whether a row shows Show more / Show less. Rows that may open (more than one preview line) show
    it while open, when the words run past `previewLines`, or when a typed note is hidden from the
    spoken preview. Showing it costs one preview line, so a long row stays two squares.
    */
    static func showsToggle(previewLines: Int, expanded: Bool, truncated: Bool, typedNote: Bool) -> Bool {
        previewLines > 1 && (expanded || truncated || typedNote)
    }

    static func isTruncated(_ text: String, width: CGFloat, lineLimit: Int, size: CGFloat = 15) -> Bool {
        guard width.isFinite, width > 0, lineLimit > 0, !text.isEmpty else { return false }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lineLimit + 1
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines = 0
        var index = 0
        while index < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            lines += 1
            if lines > lineLimit { return true }
            index = NSMaxRange(range)
        }
        return false
    }
}

/// Shares the paragraph's Core Text typesetter, font and minimum-width rule. Asking for one
/// extra line is enough to detect truncation without laying out an entire long transcript.
/// Kept for its tests; History rows now use `TokensHistoryRowLayout` at the system font.
enum TokensHistoryPreviewLayout {
    static func isTruncated(_ text: String, width: CGFloat, lineLimit: Int, size: CGFloat = 15) -> Bool {
        guard width.isFinite, width > 0, lineLimit > 0 else { return false }
        return TokensTypesetter.lines(text, size: size, ink: .primary,
            width: max(width, TokensUI.module), limit: lineLimit + 1).count > lineLimit
    }
}

/// A full-height, selectable native text view with no inner scroll view. Its measured baseline
/// and fixed line height keep every line on the sheet without changing any saved bytes.
/// Still used by the recovery window (Features/Bubble/RecoveryWindow.swift) and its tests.
struct TokensInlineHistoryText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.layoutManager?.usesFontLeading = false
        view.selectedTextAttributes = [.backgroundColor: TokensInk.secondary.nsColor.withAlphaComponent(0.2)]
        view.setAccessibilityLabel("Full saved text")
        update(view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { update(view) }
    }

    private func update(_ view: NSTextView) {
        view.string = text
        view.textStorage?.setAttributes(Self.attributes, range: NSRange(location: 0, length: (text as NSString).length))
        view.textContainerInset = NSSize(width: 0, height: Self.baselineInset)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(TokensUI.module, proposal.width ?? 400)
        return Self.measuredSize(text, width: width)
    }

    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = TokensUI.paperCell
        paragraph.maximumLineHeight = TokensUI.paperCell
        var result = TokensTypesetter.attributes(size: 15, ink: .primary)
        result[.paragraphStyle] = paragraph
        return result
    }

    private static func layout(_ text: String, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: attributes)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.usesFontLeading = false
        layout.ensureLayout(for: container)
        return (storage, layout, container)
    }

    static var baselineInset: CGFloat {
        let (storage, layout, _) = layout("Ag", width: 400)
        return withExtendedLifetime(storage) {
            let baseline = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
                + layout.location(forGlyphAt: 0).y
            return max(0, TokensUI.paperCell - baseline)
        }
    }

    static func measuredSize(_ text: String, width: CGFloat) -> CGSize {
        let (storage, layout, container) = layout(text, width: width)
        return withExtendedLifetime(storage) {
            let used = max(layout.usedRect(for: container).height, layout.extraLineFragmentRect.maxY)
            // Reserve complete rows plus bottom descender clearance, without an internal scroller.
            let height = ceil((baselineInset + used) / TokensUI.paperCell) * TokensUI.paperCell
            return CGSize(width: width, height: max(TokensUI.paperCell, height))
        }
    }
}
