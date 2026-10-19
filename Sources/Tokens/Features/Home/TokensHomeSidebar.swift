


//
import AVFoundation
import AppKit
import Combine
import Speech
import TokensCore
import SwiftUI


/// Rail measurements from DESIGN.md §5.1, in window points (the rail is never zoomed).
enum TokensRail {
    static let wideWidth: CGFloat = 216
    static let iconWidth: CGFloat = 72
    /// The window width at which the rail shows labels.
    static let wideThreshold: CGFloat = 900
    /// Row hit area: 40 tall, radius 8, 8 in from the rail's edges, centred 5 above the label's baseline.
    static let rowHeight: CGFloat = 40
    static let rowRadius: CGFloat = 8
    static let outerInset: CGFloat = 8
    /// The label baseline inside a row: 25 below the row's top (rowHeight / 2 + 5).
    static let rowBaseline: CGFloat = 25
    /// Label baselines are 56 apart (Home 168, History 224, Dictionary 280, Stats 336, Models 392), so rows are 16 apart.
    static let rowPitch: CGFloat = 56
    static let firstBaseline: CGFloat = 168
    /// Wide rail x positions: wordmark, status and Dev lines 24; icon column 28 (20 wide); labels 60.
    static let textX: CGFloat = 24
    static let iconX: CGFloat = 28
    static let iconColumn: CGFloat = 20
    static let labelX: CGFloat = 60
    /// The selected page's 2.5 × 20 red bar: x = 12 wide, x = 6 compact.
    static let barX: CGFloat = 12
    static let compactBarX: CGFloat = 6
    /// The wordmark is 132 wide with its letters resting on y = 112; "Update" sits 28 lower.
    static let wordmarkWidth: CGFloat = 132
    static let letterLine: CGFloat = 112
    static let updateLine: CGFloat = 28
    /// The compact rail's mark: 28 points, centred at (36, 96).
    static let markSize: CGFloat = 28
    static let markCentre: CGFloat = 96
    /// Settings' label baseline above the window bottom: 28, or 64 with the Dev line under it.
    static func settingsBaseline(dev: Bool) -> CGFloat { dev ? 64 : 28 }
    /// The status line's baseline sits this far above Settings' baseline.
    static let statusAboveSettings: CGFloat = 44
    /// The compact Settings icon centre sits 40 above the window bottom.
    static let compactSettingsCentre: CGFloat = 40
    /// Height of the clear title-bar strip the sheet runs under (the window buttons sit there).
    static let titleBar: CGFloat = 28

    static func width(sheetWidth: CGFloat) -> CGFloat { sheetWidth >= wideThreshold ? wideWidth : iconWidth }

    /// Top of the first row's hit area: 143, or 171 while an update is offered.
    static func rowsTop(updateNotice: Bool) -> CGFloat {
        firstBaseline - rowBaseline + (updateNotice ? updateLine : 0)
    }
    /// The slot under the last row: Settings' row ends 15 below its baseline, then 13 (Release),
    /// 49 (the Dev line's slot) or 20 (compact) to the window bottom.
    static func settingsBottom(wide: Bool, dev: Bool) -> CGFloat {
        wide ? settingsBaseline(dev: dev) - (rowHeight - rowBaseline) : compactSettingsCentre - rowHeight / 2
    }
    /// The status slot ends at Settings' row top; its baseline sits 19 above that edge.
    static let statusSlot: CGFloat = 36
    static var statusBaseline: CGFloat { statusSlot - (statusAboveSettings - rowBaseline) }
}

extension TokensHome {

    /// The clear strip above the header when the sheet runs under the title bar.
    var titleBarInset: CGFloat { coversTitleBar ? TokensRail.titleBar : 0 }

    // MARK: Frame

    /*
    When the column fits, it takes the whole height and its flexible space pushes the status
    line and Settings to the bottom. Only a window too short for the column scrolls it. The
    scroll content is never tied to a GeometryReader height: that tie left Settings floating
    at zoomed small sizes and, in Release builds, rendered the first-run page empty.
    */
    func sidebar(width: CGFloat) -> some View {
        let wide = width >= TokensRail.wideWidth
        return ViewThatFits(in: .vertical) {
            sidebarColumn(width: width, wide: wide)
                .frame(maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical, showsIndicators: false) {
                sidebarColumn(width: width, wide: wide)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /*
    Fixed slots from the top (wordmark, then rows 16 apart) and from the bottom (status, Settings,
    then the Dev line or a margin), with one Spacer between. Every height is a whole window
    point, so each label lands on its spec baseline at any window height.
    */
    private func sidebarColumn(width: CGFloat, wide: Bool) -> some View {
        let dev = DevChannel.isActive && wide
        let quietUpdate = TokensRailRed.updateIsQuiet(pageShowsBlocker: pageShowsBlocker, wide: wide,
                                                      homeSelected: section == .home && detail != .firstRun)
        return VStack(alignment: .leading, spacing: 0) {
            // Brand and update action have separate rows, so progress never distorts the logo.
            TokensSidebarLogo(updater: model.updater, appName: appName, wide: wide, titleBarInset: titleBarInset,
                              quietUpdate: quietUpdate)
            VStack(spacing: TokensRail.rowPitch - TokensRail.rowHeight) {
                ForEach([Section.home, .history, .dictionary, .stats, .models], id: \.self) { item in railRow(item, wide: wide) }
            }
            Spacer(minLength: 16)
            statusBlock(wide: wide)
            railRow(.settings, wide: wide)
            if dev {
                // The Dev line's baseline is 29 below Settings' row, so it lands on H − 20.
                DevMergeRow()
                    .tokensRailLine(height: TokensRail.settingsBottom(wide: true, dev: true), baseline: 29)
                    .padding(.leading, TokensRail.textX - TokensRail.outerInset)
            } else {
                Color.clear.frame(height: TokensRail.settingsBottom(wide: wide, dev: false))
            }
        }
        .padding(.horizontal, TokensRail.outerInset)
        .frame(width: width, alignment: .leading)
    }

    private func railRow(_ item: Section, wide: Bool) -> some View {
        let selected = section == item && detail != .firstRun
        return TokensRailRow(title: item.rawValue, symbol: item.symbol, selected: selected, wide: wide) { select(item) }
    }

    /// Not Ready: setup or a permission is unfinished (Ready when --public-preview-ready forces
    /// it; a render-only --home-preview-blocker fixture counts as blocked). Home's hero uses the
    /// same checks for its "Almost ready" state.
    var setupBlocked: Bool {
        if TokensHomePreview.blocker(model) != nil { return true }
        return !TokensPreview.forcesReady && (TalkModel.tokensFirstRunPending || !model.shortcutAccessGranted
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || (SpeechEngineChoice.appleSpeechNeeded(setupPending: TalkModel.tokensSetupInProgress)
                && SFSpeechRecognizer.authorizationStatus() != .authorized))
    }

    /*
    True while the page in view already names the blocker with its own red action: Home's hero
    ("Almost ready" and its red button), or Settings' Accessibility row while Accessibility is
    off ("Open Settings", the same check TokensHomeSettings uses). The rail then hides "Setup
    unfinished" and quiets the Update offer, so the screen keeps to two red elements (§2.4).
    */
    var pageShowsBlocker: Bool {
        guard detail == nil else { return false }
        switch section {
        case .home:       return setupBlocked && shownLive == nil
        case .settings:   return !model.shortcutAccessGranted && !TokensPreview.forcesReady
        default:          return false
        }
    }

    /*
    One quiet line above Settings, only when something is not Ready: "Setup unfinished" (a button
    that opens Home), "Listening" (red dot) or "Finishing" (secondary dot). The line hides as
    "Setup unfinished" on a page that already shows the blocker (pageShowsBlocker). The icon rail
    draws one glyph instead (dot, red mic.fill, secondary mic). The microphone name and the full
    status stay in the tooltip and the accessibility label.
    */
    @ViewBuilder
    func statusBlock(wide: Bool) -> some View {
        let live = shownLive
        if live != nil || (setupBlocked && !pageShowsBlocker) {
            TokensRailStatus(kind: live == .finishing ? .finishing : live == .listening ? .listening : .blocked,
                             updater: model.updater,
                             pageShowsRedStatus: detail == nil && section == .history
                                && !model.historyStorageError.isEmpty,
                             wide: wide,
                             device: model.effectiveInputDeviceName) { select(.home) }
        }
    }
}

/*
The rail's red budget (DESIGN.md §2.4: at most two red elements per screen, live capture
exempt). The selected row is always one. The Update offer is the rail's optional second, so it
drops to ink2 when the page already has its red action, and on the icon rail while the selected
Home icon sits right under it (no red cluster). While the offer shows, or while the page shows its
own red status dot (History's storage error), a blocked status dot is secondary rather than a
third red mark.
*/
enum TokensRailRed {
    static func updateIsQuiet(pageShowsBlocker: Bool, wide: Bool, homeSelected: Bool) -> Bool {
        pageShowsBlocker || (!wide && homeSelected)
    }
    static func blockedDotIsQuiet(updateShown: Bool, pageShowsRedStatus: Bool = false) -> Bool {
        updateShown || pageShowsRedStatus
    }
}

/*
The status line itself. Wide: the 6-point dot centred in the rows' 20-point icon column and the
13-point words on the label column (x = 60), so the line reads as part of the row grid. "Setup
unfinished" is a button: its words go from ink2 to ink on hover, like the other text actions.
*/
struct TokensRailStatus: View {
    enum Kind { case blocked, listening, finishing }
    let kind: Kind
    @ObservedObject var updater: Updater
    /// The page already shows a red status dot of its own (History's storage error).
    var pageShowsRedStatus = false
    let wide: Bool
    let device: String
    let openHome: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        switch kind {
        case .blocked:   return "Setup unfinished"
        case .listening: return "Listening"
        case .finishing: return "Finishing"
        }
    }

    private var dot: Color {
        switch kind {
        case .finishing: return TokensUI.secondary
        case .listening: return TokensUI.red
        case .blocked:
            return TokensRailRed.blockedDotIsQuiet(updateShown: updater.showsUpdateNotice,
                                                   pageShowsRedStatus: pageShowsRedStatus) ? TokensUI.secondary : TokensUI.red
        }
    }

    private var words: Color {
        switch kind {
        case .finishing: return TokensUI.secondary
        case .listening: return TokensUI.ink2
        case .blocked:   return hovered ? TokensUI.ink : TokensUI.ink2
        }
    }

    var body: some View {
        let line = Group {
            if wide {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    TokensStatusDot(color: dot)
                        .frame(width: TokensRail.iconColumn)
                    Text(title)
                        .font(TokensType.caption)
                        .foregroundStyle(words)
                        .lineLimit(1)
                        .padding(.leading, TokensRail.labelX - TokensRail.iconX - TokensRail.iconColumn)
                }
                .tokensRailLine(height: TokensRail.statusSlot, baseline: TokensRail.statusBaseline)
                .padding(.leading, TokensRail.iconX - TokensRail.outerInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Group {
                    if kind == .blocked {
                        Circle().frame(width: 6, height: 6)
                    } else {
                        Image(systemName: kind == .finishing ? "mic" : "mic.fill").font(.system(size: 14))
                    }
                }
                .foregroundStyle(dot)
                // Centred 44 above the Settings icon's centre.
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .padding(.bottom, TokensRail.statusSlot - 24)
            }
        }
        .contentShape(Rectangle())
        .help(title + " · " + device)
        if kind == .blocked {
            Button(action: openHome) { line }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .animation(TokensUI.fade(reduceMotion), value: hovered)
                .accessibilityLabel(title + ". Microphone: " + device)
                .accessibilityHint("Opens Home, which shows what to finish.")
        } else {
            line
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title + ". Microphone: " + device)
        }
    }
}

/// One rail row (DESIGN.md §5.1): a 40-tall hit area, radius 8. A 15-point regular icon in a
/// 20-point column at x = 28, the 14-point label at x = 60 on its baseline. Unselected rows are
/// ink2; hover is ink on a 6% ink wash; the selected row is red with a 2.5 × 20 red bar.
/// The icon rail keeps the tooltip and the accessibility label.
struct TokensRailRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let wide: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: TokensRail.iconColumn, height: TokensRail.rowHeight)
                    .frame(maxWidth: wide ? nil : .infinity)
                    .padding(.leading, wide ? TokensRail.iconX - TokensRail.outerInset : 0)
                if wide {
                    Text(title)
                        .font(selected ? TokensType.label : .system(size: 14, weight: .regular))
                        .lineLimit(1)
                        .tokensRailLine(height: TokensRail.rowHeight, baseline: TokensRail.rowBaseline)
                        .padding(.leading, TokensRail.labelX - TokensRail.outerInset)
                }
            }
            .foregroundStyle(selected ? TokensUI.red : hovered ? TokensUI.ink : TokensUI.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: TokensRail.rowHeight)
            .background(hovered && !selected ? TokensUI.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: TokensRail.rowRadius, style: .continuous))
            // Approved board: the chosen page is marked by a slim red bar near the rail's edge.
            .overlay(alignment: .leading) {
                Capsule().fill(TokensUI.red)
                    .frame(width: 2.5, height: 20)
                    .offset(x: (wide ? TokensRail.barX : TokensRail.compactBarX) - TokensRail.outerInset)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: TokensRail.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(TokensUI.fade(reduceMotion), value: hovered)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Places its child so the child's first text baseline lands `baseline` points below the top of
/// a box `height` tall. The rail is not on the sheet's grid, so it pins each label to an exact
/// window point this way instead of using tokensOnRule.
struct TokensRailLine: Layout {
    let height: CGFloat
    let baseline: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return CGSize(width: 0, height: height) }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let offered = ProposedViewSize(width: bounds.width, height: nil)
        let first = view.dimensions(in: offered)[.firstTextBaseline]
        view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + baseline - first), proposal: offered)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .firstTextBaseline || guide == .lastTextBaseline ? baseline : nil
    }
}

extension View {
    /// Pins this view's first text baseline `baseline` points below the top of a `height` box.
    func tokensRailLine(height: CGFloat, baseline: CGFloat) -> some View {
        TokensRailLine(height: height, baseline: baseline) { self }
    }
}

//
// :)
//
//
/*
Measured once from Resources/Release/WaveIdentity/tokens-wordmark.png (1877 x 838; the Dev copy
is identical). TokensBrandWordmark shows the centred 1348 x 553 window of it, which starts at
image row 142.5. The bottoms of the o, k, e and s strokes are at rows 642-648, so the letters
rest on row 645: (645 - 142.5) / 1348 of the drawn width below the wordmark's top. The T stem
and the n's last stroke reach a few rows lower, like handwriting crossing the line.
*/
/// Where the wordmark's letters rest, and which rule they rest on in each sidebar layout.
struct TokensWordmarkRule: Equatable {
    static let restRow: CGFloat = 645
    static let baselineFraction: CGFloat = (restRow - 142.5) / 1348
    /// Leading inset shared with the page names below it.
    static let leading: CGFloat = 16

    let sidebarWidth: CGFloat
    let compact: Bool
    var dev = false

    /// Drawn width: 120 in the regular sidebar, 92 compact, and never wider than the column
    /// allows (leaving room for the small DEV word on the same rule in Dev builds).
    var width: CGFloat { min(compact ? 92 : 120, sidebarWidth - 2 * Self.leading - (dev ? 28 : 0)) }
    /// Distance from the wordmark's top edge to its letter bottoms.
    var baseline: CGFloat { width * Self.baselineFraction }
    /// The rule the letters rest on: rule 2 regular (clear of the window buttons), rule 1 compact.
    var rows: Int { compact ? 1 : 2 }
    /// With an update known, "Update" takes the next rule and the slot grows by one row.
    func slotHeight(updateNotice: Bool) -> CGFloat { CGFloat(rows + (updateNotice ? 1 : 0)) * TokensUI.paperCell }
    /// The wordmark's top edge inside the slot.
    var top: CGFloat { CGFloat(rows) * TokensUI.paperCell - baseline }
}

/*
The slot at the top of the rail, exactly as tall as the space above the first row (143, or 171
with an update offer). The wide rail shows the wordmark alone, 132 wide at x = 24 with its letters
on y = 112, whatever the title-bar inset; "Update" sits on y = 140 below it. The icon rail shows
the 28-point logo π (TokensBrandMark) centred at (36, 96) and, when an update is offered, an icon under it. The
offer is red unless `quietUpdate` (TokensRailRed) asks for ink2; its tooltip and id never change.
*/
struct TokensSidebarLogo: View {
    @ObservedObject var updater: Updater
    let appName: String
    let wide: Bool
    let titleBarInset: CGFloat
    var quietUpdate = false

    /// Drawn width of the wordmark artwork: the T stands about 34 points above the letters' line.
    static let wordmarkWidth: CGFloat = TokensRail.wordmarkWidth
    /// The window y the wordmark's letters rest on.
    static let letterLine: CGFloat = TokensRail.letterLine

    var body: some View {
        Group {
            if wide {
                let letters = Self.wordmarkWidth * TokensWordmarkRule.baselineFraction
                TokensLogoUpdate(updater: updater, appName: appName, width: Self.wordmarkWidth, quiet: quietUpdate)
                    .padding(.leading, TokensRail.textX - TokensRail.outerInset)
                    .padding(.top, Self.letterLine - letters)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    TokensBrandMark(size: TokensRail.markSize)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(appName)
                    if updater.showsUpdateNotice {
                        Button { updater.actOnUpdateNotice() } label: {
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(quietUpdate ? TokensUI.ink2 : TokensUI.red)
                                .frame(width: 34, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!updater.canActOnUpdateNotice)
                        .accessibilityLabel("\(appName): Update")
                        .accessibilityValue(updater.updateNoticeDetail)
                        .help(updater.canRetryRestart ? updater.label : updater.updateNoticeDetail)
                        .accessibilityIdentifier("tokens.update.notice")
                    }
                }
                .padding(.top, TokensRail.markCentre - TokensRail.markSize / 2)
                .frame(maxWidth: .infinity)
            }
        }
        // The icon rail keeps its rows still; the wide rail moves them down 28 for "Update".
        .frame(height: TokensRail.rowsTop(updateNotice: wide && updater.showsUpdateNotice), alignment: .top)
    }
}

/// The logo's π (LogoPi, the app icon's own drawing), in ink: the compact rail's mark and set-up's.
/// Build 82: it was the handwritten "Tk" image; Tokens' mark is the π.
struct TokensBrandMark: View {
    let size: CGFloat

    var body: some View {
        let line = max(1.5, size * 0.09)
        let drawn = LogoPi.size(inkHeight: size * 0.62, lineWidth: line)
        LogoPi()
            .stroke(TokensUI.ink, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            .frame(width: drawn.width, height: drawn.height)
            .frame(width: size, height: size)
            .accessibilityLabel("Tokens")
    }
}

/*
The wordmark stands alone and visually stable: no channel word beside it (the rail's Dev line is
the only channel mark). An update offer has its own labelled action whose baseline sits 28 below
the letters' line; neither the ring nor a status label can overlap the artwork.
*/
struct TokensLogoUpdate: View {
    @ObservedObject var updater: Updater
    let appName: String
    let width: CGFloat
    /// Ink2 instead of red while the page already shows its one red action (TokensRailRed).
    var quiet = false

    /// The wordmark is framed to its letter bottoms (TokensWordmarkRule's measured artwork row),
    /// so the row below is measured from the handwriting's line.
    private var baseline: CGFloat { width * TokensWordmarkRule.baselineFraction }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TokensBrandWordmark(width: width)
                .frame(height: baseline, alignment: .top)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appName)
            if updater.showsUpdateNotice {
                Button { updater.actOnUpdateNotice() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(updater.canRetryRestart ? "Restart Tokens" : updater.busy ? "Updating…" : "Update")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(quiet ? TokensUI.ink2 : TokensUI.red)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!updater.canActOnUpdateNotice)
                .accessibilityLabel("\(appName): Update")
                .accessibilityValue(updater.updateNoticeDetail)
                .help(updater.canRetryRestart ? updater.label : updater.updateNoticeDetail)
                .accessibilityIdentifier("tokens.update.notice")
                .tokensRailLine(height: TokensRail.updateLine, baseline: TokensRail.updateLine)
            }
        }
    }
}

/// The red pen's ring stretched to fit a word: a teacher circling a wrong answer. Same wobble
/// source as FirstRunRing, so a seed always draws the same oval.
struct TokensPenEllipse: Shape {
    var seed = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 36, sweep = 2 * CGFloat.pi * 1.06, start = -CGFloat.pi * 0.62
        var points: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps), angle = start + sweep * t
            let wobble = (TokensPencil.unit(seed, i) - 0.5) * 2
            let drift = t > 0.9 ? (t - 0.9) * 18 : 0
            points.append(CGPoint(x: rect.midX + (rect.width / 2 + wobble + drift) * cos(angle),
                                  y: rect.midY + (rect.height / 2 + wobble * 0.6 + drift * 0.4) * sin(angle)))
        }
        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

