


import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// Records what a parent sees of its one child: height and both text baselines.
private final class RuleProbe {
    var height: CGFloat = -1
    var first: CGFloat = -1
    var last: CGFloat = -1
}

private struct RuleProbeLayout: Layout {
    let probe: RuleProbe
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

@Suite("Paper baseline and zoom geometry")
struct PaperAlignmentTests {
    @Test func forwardSnapPreservesSpaceAndRulePhase() {
        for origin in stride(from: -200.0, through: 800.0, by: 0.5) {
            let inset = TokensPaperGeometry.leadingSpace(origin: origin)
            #expect(inset >= 0 && inset < TokensUI.paperCell)
            let rule = (origin + inset) / TokensUI.paperCell
            #expect(abs(rule - rule.rounded()) < 0.0001)
        }
    }

    @Test func sheetZoomBoundsAndResetShortcuts() {
        #expect(TokensSheetZoom.changed(1, by: 1) == 1.1)
        #expect(TokensSheetZoom.changed(1, by: -1) == 0.9)
        #expect(TokensSheetZoom.changed(0.75, by: -1) == 0.75)
        #expect(TokensSheetZoom.changed(0.75, by: 1) == 0.8)
        #expect(TokensSheetZoom.changed(1.5, by: 1) == 1.5)
        #expect(TokensSheetZoom.action(characters: "+", modifiers: [.command, .shift]) == 1)
        #expect(TokensSheetZoom.action(characters: "=", modifiers: .control) == 1)
        #expect(TokensSheetZoom.action(characters: "-", modifiers: .command) == -1)
        #expect(TokensSheetZoom.action(characters: "0", modifiers: .control) == 0)
        #expect(TokensSheetZoom.action(characters: "=", modifiers: [.command, .control]) == nil)
        #expect(TokensSheetZoom.action(characters: "=", modifiers: []) == nil)
        #expect(TokensSheetZoom.action(characters: "=", modifiers: [.command, .option]) == nil)
    }

    @MainActor private func measure(_ view: some View, width: CGFloat = 320) -> RuleProbe {
        let probe = RuleProbe()
        let host = NSHostingView(rootView: RuleProbeLayout(probe: probe) { view }.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return probe
    }

    @MainActor @Test func oneLineSitsOnTheFirstRule() {
        let line = measure(Text("Ready when you are").font(.system(size: 15)).tokensOnRule())
        #expect(line.height == 56)
        #expect(abs(line.first - 56) < 0.01)
        let title = measure(Text("History").font(TokensType.title).tokensOnRule())
        #expect(title.height == 56 && abs(title.first - 56) < 0.01)
        // Taller than a square: the 44-point headline still rests on the first rule.
        let display = measure(Text("Ready").font(TokensType.display).tokensOnRule())
        #expect(display.height == 56 && abs(display.first - 56) < 0.01)
    }

    @MainActor @Test func threeWrappedLinesFillTwoSquaresAtHalfSquarePitch() {
        let text = Text("First line\nSecond line\nThird line").font(.system(size: 15))
            .tokensReadingPitch(size: 15)
            .tokensOnRule()
        let block = measure(text)
        #expect(block.height == 112)
        #expect(abs(block.first - 56) < 0.01)
        #expect(abs(block.last - 112) < 0.01)
        #expect((9...11).contains(TokensType.lineSpacing(size: 15)))
        // Every reading size keeps the exact pitch: lines on a rule or exactly half-way.
        for size: CGFloat in [13, 15, 17] {
            let two = measure(Text("First\nSecond").font(.system(size: size)).tokensReadingPitch(size: size))
            #expect(abs(two.last - two.first - 28) < 0.01, "pitch at \(size) pt")
        }
    }

    @Test func mixedLabelStaysOneSquareButASecondLineDoesNot() {
        // A label whose last guide is 2 points low ("See all ›") is still one line.
        #expect(TokensOnRuleLayout.placement(firstBaseline: 15, lastBaseline: 17, cell: 56).height == 56)
        // Two lines of 11-point text (14-point pitch) take two squares.
        #expect(TokensOnRuleLayout.placement(firstBaseline: 11, lastBaseline: 25, cell: 56).height == 112)
        // A first baseline below one square moves to the next rule.
        let tall = TokensOnRuleLayout.placement(firstBaseline: 60, lastBaseline: 60, cell: 56)
        #expect(tall.offset == 52 && tall.height == 112)
    }

    @MainActor @Test func ruleSpacerAndHairlineKeepWholeSquares() {
        #expect(measure(TokensRuleSpacer(cells: 2)).height == 112)
        // A hairline's baseline is its top edge, so on a rule it covers the grid line.
        let line = measure(TokensHairline(strong: true).tokensOnRule())
        #expect(line.height == 56 && abs(line.first - 56) < 0.01)
    }

    @Test func paperParagraphUsesVisibleRulePitch() {
        #expect(TokensParagraphLayout.pitch(13, paperText: true) == 56)
        #expect(TokensParagraphLayout.pitch(27, paperText: true) == 56)
        #expect(TokensParagraphLayout.pitch(13) == 24)
    }
}

