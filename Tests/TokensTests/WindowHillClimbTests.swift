


import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// Records what a parent sees of its one child: height and both text baselines.
private final class LineProbe {
    var height: CGFloat = -1
    var first: CGFloat = -1
    var last: CGFloat = -1
}

private struct LineProbeLayout: Layout {
    let probe: LineProbe
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let dimensions = view.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        probe.height = dimensions.height
        probe.first = dimensions[.firstTextBaseline]
        probe.last = dimensions[.lastTextBaseline]
        return CGSize(width: dimensions.width, height: dimensions.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

@Suite("Window hill-climb rules")
struct WindowHillClimbTests {
    @MainActor private func measure(_ view: some View, width: CGFloat = 320) -> LineProbe {
        let probe = LineProbe()
        let host = NSHostingView(rootView: LineProbeLayout(probe: probe) { view }.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return probe
    }

    /// §2.4: the Update offer is the rail's optional second red mark.
    @Test func updateOfferQuietsWhenThePageHasItsRedAction() {
        // A page with its own red action (Home blocked, Settings with Accessibility off).
        #expect(TokensRailRed.updateIsQuiet(pageShowsBlocker: true, wide: true, homeSelected: true))
        #expect(TokensRailRed.updateIsQuiet(pageShowsBlocker: true, wide: false, homeSelected: false))
        // Ready Home, wide rail: selected Home + Update = 2.
        #expect(!TokensRailRed.updateIsQuiet(pageShowsBlocker: false, wide: true, homeSelected: true))
        // Icon rail: the update icon sits right above the selected Home icon, so it is quiet there.
        #expect(TokensRailRed.updateIsQuiet(pageShowsBlocker: false, wide: false, homeSelected: true))
        #expect(!TokensRailRed.updateIsQuiet(pageShowsBlocker: false, wide: false, homeSelected: false))
        // History blocked with an update: selected History + Update; the status dot is secondary.
        #expect(TokensRailRed.blockedDotIsQuiet(updateShown: true))
        #expect(!TokensRailRed.blockedDotIsQuiet(updateShown: false))
        // History's storage error is the page's own red status: the rail's dot steps back.
        #expect(TokensRailRed.blockedDotIsQuiet(updateShown: false, pageShowsRedStatus: true))
    }

    /// Home's heading sits on rule 2 at every sheet size (no empty band).
    @Test func homesHeroAlwaysStartsOnRuleTwo() {
        for height: CGFloat in [520 / 1.5, 720 / 1.5, 520, 720, 900, 1_200] {
            #expect(TokensHomeHeroStart.liftsHero(sheetHeight: height))
        }
    }

    /// Recent fills the sheet: the rows whose baselines land above the resting edge, 3 to 8.
    @Test func recentShowsTheRowsTheSheetHolds() {
        // Build 81: 5, not 6. The build-80 Speech model line moved the first row to rule 8, and
        // the old 6 left the sixth row hidden (but clickable) under the bottom edge.
        #expect(TokensHomeLayout.recentRows(sheetHeight: 720) == 5)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 900) == 8)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 520) == 3)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 720 / 1.5) == 3)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 2_000) == 8)
        // Row 5 at 720 ends on rule 12 (672), 48 above the edge; descenders fit.
        #expect(CGFloat(TokensHomeLayout.firstRowRule + 4) * TokensUI.paperCell
                <= 720 - TokensRestingEdgeMask.below)
    }

    /// Home starts at every other page's left edge (no sideways jump between pages), then runs
    /// up to 14 squares on the rules with at least a square of margin.
    @Test func homeColumnWidensOnTheRules() {
        for (sheet, leading, width): (CGFloat, CGFloat, CGFloat) in
            [(824, 112, 616), (1_224, 280, 784), (688, 56, 560), (824 / 1.5, 56, 392)] {
            let column = TokensHomeLayout.column(sheetWidth: sheet)
            #expect(column.leading == leading)
            #expect(column.leading == TokensColumn.layout(sheetWidth: sheet).leading)
            #expect(column.width == width)
            #expect(column.leading.truncatingRemainder(dividingBy: TokensUI.paperCell) == 0)
            #expect(column.leading >= TokensUI.paperCell)
            #expect(column.leading + column.width <= sheet - TokensUI.halfCell)
        }
    }

    /// The Dictionary intro wraps at the 28-point pitch and the count line follows 28 lower, so
    /// the block ends on a whole square with no blank square after it.
    @MainActor @Test func pitchStackPutsTheCountRightUnderTheIntro() {
        #expect(TokensPitchStack.tops(firstBaselines: [12, 10], lastBaselines: [40, 10], pitch: 28) == [0, 58])
        let two = measure(TokensPitchStack {
            Text("Names and terms\nshould spell your way.").font(TokensType.body).tokensReadingPitch()
            Text("18 terms · Edit as text").font(TokensType.caption)
        }.tokensOnRule())
        #expect(abs(two.first - 56) < 0.01)
        #expect(abs(two.last - 112) < 0.01)
        #expect(two.height == 112)
        let one = measure(TokensPitchStack {
            Text("Names and terms").font(TokensType.body)
            Text("18 terms").font(TokensType.caption)
        }.tokensOnRule())
        #expect(abs(one.last - 84) < 0.01)
        #expect(one.height == 112)
    }

    /// A resting page never shows the next line's ascenders at the bottom edge, and never cuts a
    /// line (or a control centred on it) whose descenders fit.
    @Test func restingEdgeCutsOnlyPartialLines() {
        // 1040 x 720 at 100%: the slot is 608 tall; its last whole rule is 560 (sheet 672).
        let cut = TokensRestingEdgeMask.cut(height: 608)
        #expect(cut == 573)
        #expect(cut < 616 - 11)     // the next rule's ascenders stay hidden
        #expect(cut >= 560 + 13)    // a 36-point field on the last rule is whole
        // 1040 x 720 at 150%: slot 368; a line on the half-rule 364 (sheet 476) would sit at
        // the fold without the line above it, so it is hidden with them.
        #expect(TokensRestingEdgeMask.cut(height: 368) < 364 - 10)
        // Short lifted Home (slot 291): nothing visible is cut.
        let shortSlotHeight: CGFloat = 520 / 1.5 - 56
        #expect(TokensRestingEdgeMask.cut(height: shortSlotHeight) == shortSlotHeight)
    }

    /// Fixtures need --render-preview-frames in a proof-allowed build; nothing else turns them on.
    @Test func fixturesStayRenderOnly() {
        let args = ["Tokens", "--render-preview-frames", "/tmp/x", "--home-preview-blocker", "Relaunch",
                    "--history-preview-copied"]
        #expect(TokensHomePreview.value(after: "--home-preview-blocker", arguments: args, allowed: true) == "relaunch")
        #expect(TokensHomePreview.value(after: "--home-preview-blocker", arguments: args, allowed: false) == nil)
        let noRender = args.filter { $0 != "--render-preview-frames" }
        #expect(TokensHomePreview.value(after: "--home-preview-blocker", arguments: noRender, allowed: true) == nil)
        #expect(TokensHomePreview.value(after: "--home-preview-live", arguments: args, allowed: true) == nil)
        #expect(TokensHistoryPreview.flag("--history-preview-copied", arguments: args, allowed: true))
        #expect(!TokensHistoryPreview.flag("--history-preview-copied", arguments: args, allowed: false))
        #expect(!TokensHistoryPreview.flag("--history-preview-copied", arguments: noRender, allowed: true))
        #expect(!TokensHistoryPreview.flag("--history-preview-empty", arguments: args, allowed: true))
        // TOK-QA-005: the live-block detail fixture is render-only too.
        let live = ["Tokens", "--render-preview-frames", "/tmp/x", "--home-preview-live", "finishing",
                    "--home-preview-live-detail", "kept"]
        #expect(TokensHomePreview.value(after: "--home-preview-live-detail", arguments: live, allowed: true) == "kept")
        #expect(TokensHomePreview.value(after: "--home-preview-live-detail", arguments: live, allowed: false) == nil)
        #expect(TokensHomePreview.value(after: "--home-preview-live-detail",
                                        arguments: live.filter { $0 != "--render-preview-frames" }, allowed: true) == nil)
    }
}

