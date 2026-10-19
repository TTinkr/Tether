
import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// Records what a parent sees of its one child: height and first text baseline.
private final class RowProbe {
    var height: CGFloat = -1
    var first: CGFloat = -1
}

private struct RowProbeLayout: Layout {
    let probe: RowProbe
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let dimensions = view.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        probe.height = dimensions.height
        probe.first = dimensions[.firstTextBaseline]
        return CGSize(width: dimensions.width, height: dimensions.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

@Suite("History rows")
struct HistoryRowTests {
    @MainActor private func measure(_ view: some View, width: CGFloat = 480) -> RowProbe {
        let probe = RowProbe()
        let host = NSHostingView(rootView: RowProbeLayout(probe: probe) { view }.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return probe
    }

    /// Build 76: the hover highlight overlapped the next row. Rows are now whole grid
    /// squares, so a row's fill and click area end on the grid line where the next row starts.
    @Test func rowsAreWholeSquaresSoNothingOverlaps() {
        let cell = TokensUI.paperCell
        #expect(TokensHistoryCellLayout.height(content: 21) == cell)          // one 17-point line
        #expect(TokensHistoryCellLayout.height(content: 67) == 2 * cell)      // three lines
        #expect(TokensHistoryCellLayout.height(content: 66) == 2 * cell)      // two lines + Show more
        for content: CGFloat in [0, 13, 21, 44, 67, 90, 140, 400] {
            let height = TokensHistoryCellLayout.height(content: content)
            #expect(height.truncatingRemainder(dividingBy: cell) == 0)
            #expect((height - content) / 2 >= TokensHistoryCellLayout.minimumPadding)
        }
    }

    /// Measured rows: one line is one square, a long row with Show more is two, content centred.
    @MainActor @Test func measuredRowsFillWholeSquares() {
        let one = measure(TokensHistoryCellLayout {
            Text("Keep every word.").font(TokensHistoryRow.textFont)
        })
        #expect(one.height == 56)
        #expect(one.first > 28 && one.first < 42)     // centred, not on the bottom rule
        let long = measure(TokensHistoryCellLayout {
            VStack(alignment: .leading, spacing: 6) {
                Text("Draft a reply to the design thread: Thursday works for me, but I'd like to move the "
                     + "review to the afternoon so the prototype has one more pass with the real copy in place.")
                    .font(TokensHistoryRow.textFont).lineLimit(2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Show more").font(TokensType.caption)
            }
        }, width: 320)
        #expect(long.height == 112)
        let stack = measure(VStack(spacing: 0) {
            TokensHistoryCellLayout { Text("Today").font(TokensType.captionStrong) }
            TokensHistoryCellLayout { Text("Keep every word.").font(TokensHistoryRow.textFont) }
        })
        #expect(stack.height == 112)
    }

    // MARK: Build 81 lines and pitch

    /// RGBA bytes of the pixel column at x = 2 in an offscreen render, one entry per pixel row.
    @MainActor private func column(_ view: some View, scale: CGFloat) throws -> [[UInt8]] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        // Bitmap rows run top to bottom in memory, as the view does.
        return (0..<height).map { row in Array(bytes[(row * width + 2) * 4 ..< (row * width + 2) * 4 + 4]) }
    }

    /// One header square with its hairline, then a second square (filled or not), at a zoom.
    @MainActor private func twoSquares(zoom: CGFloat, filled: Bool? = nil) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 8, height: 56)
                .overlay(alignment: .bottom) { TokensHistoryDivider() }
            Group {
                if let filled {
                    TokensHistoryRowFill(filled: filled, focused: false)
                } else {
                    Color.clear
                }
            }
            .frame(width: 8, height: 56)
            .overlay(alignment: .bottom) { TokensHistoryDivider() }
        }
        .environment(\.tokensSheetZoom, zoom)
    }

    /// The grid fills each rule from y to y + 1 / zoom (TokensSheetGrid). A row's hairline must fill
    /// exactly that: one screen pixel on the rule, none above it (it used to sit 1 point above the
    /// rule, a doubled line), at 1x, at 150% and on a 2x screen.
    @MainActor @Test func theHairlineLiesExactlyOnTheGridRule() throws {
        for (zoom, scale) in [(CGFloat(1), CGFloat(1)), (1.5, 1.5), (1, 2), (2, 2)] {
            let pixels = try column(twoSquares(zoom: zoom), scale: scale)
            let rule = Int((56 * scale).rounded())
            let thickness = Int((scale / zoom).rounded())   // 1 / zoom points in pixels
            #expect(TokensHistoryDivider.weight(zoom: zoom) == 1 / zoom)
            for row in rule ..< rule + thickness {
                #expect(pixels[row][3] == 255, "zoom \(zoom) scale \(scale): rule pixel \(row)")
            }
            #expect(pixels[rule - 1][3] == 0, "zoom \(zoom) scale \(scale): line above the rule")
            #expect(pixels[rule + thickness][3] == 0, "zoom \(zoom) scale \(scale): line below the rule")
        }
    }

    /// The hover fill starts under the hairline above its row and runs to the row's bottom edge,
    /// where the row's own hairline hangs outside it: neither line is tinted.
    @MainActor @Test func theHoverFillNeverTintsAHairline() throws {
        for (zoom, scale) in [(CGFloat(1), CGFloat(1)), (1.5, 1.5), (1, 2)] {
            let plain = try column(twoSquares(zoom: zoom, filled: false), scale: scale)
            let filled = try column(twoSquares(zoom: zoom, filled: true), scale: scale)
            let rule = Int((56 * scale).rounded())
            let line = Int((scale / zoom).rounded())
            let bottom = Int((112 * scale).rounded())
            for row in rule ..< rule + line {
                #expect(filled[row] == plain[row], "zoom \(zoom): the hairline above is tinted")
            }
            #expect(filled[rule + line][3] > 0, "zoom \(zoom): the fill starts right under the hairline")
            #expect(filled[bottom - 1][3] > 0, "zoom \(zoom): the fill reaches the row's bottom edge")
            #expect(plain[rule + line][3] == 0)
        }
    }

    /// Lines of a taller row sit on the 28-point pitch from the content's first baseline. No rule
    /// inside the row may run through a line's letters (from cap height down to the baseline).
    @Test func noRuleCrossesAWrappedLine() {
        let cell = TokensUI.paperCell, pitch = TokensUI.halfCell
        // One square: centred, exactly as build 77.
        #expect(TokensHistoryCellLayout.top(content: 20, firstBaseline: 16, height: cell) == 18)
        for (first, lastDescent) in [(CGFloat(16), CGFloat(4)), (16.2, 3.6), (16, 5)] {
            for lines in 2...9 {
                let content = first + pitch * CGFloat(lines - 1) + lastDescent
                let height = TokensHistoryCellLayout.height(content: content)
                let top = TokensHistoryCellLayout.top(content: content, firstBaseline: first, height: height)
                // The first line rests no higher than the half-rule, and 12 points stay clear below.
                #expect(top + first >= pitch - 0.01, "\(lines) lines")
                #expect(height - top - content >= TokensHistoryCellLayout.minimumPadding, "\(lines) lines")
                for line in 0..<lines {
                    let baseline = top + first + pitch * CGFloat(line)
                    for rule in stride(from: cell, to: height, by: cell) {
                        #expect(!(rule > baseline - 13 && rule < baseline - 0.5),
                                "\(lines) lines: rule \(rule) crosses the line at \(baseline)")
                    }
                }
            }
        }
    }

    /// Measured like a History row: the time, then two lines and Show more on the 28-point pitch.
    /// The row stays two squares, and its lines sit on rule, rule and half-rule (28 / 56 / 84), so
    /// the rule inside the row is the second line's baseline (it ran through its letters).
    @MainActor @Test func measuredLongRowKeepsItsLinesOffTheRule() {
        let long = "Draft a reply to the design thread: Thursday works for me, but I'd like to move the "
            + "review to the afternoon so the prototype has one more pass with the real copy in place."
        func row(lines: Int, toggle: Bool) -> some View {
            TokensHistoryCellLayout {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("12:06 PM").font(TokensType.caption).frame(width: 64, alignment: .leading)
                    TokensPitchStack {
                        Text(long).font(TokensHistoryRow.textFont).lineLimit(lines)
                            .tokensReadingPitch(size: TokensHistoryRow.textSize)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if toggle { Text("Show more").font(TokensType.caption) }
                    }
                }
            }
        }
        let showMore = measure(row(lines: 2, toggle: true), width: 320)
        #expect(showMore.height == 112)
        #expect(abs(showMore.first - 28) < 0.5)
        let three = measure(row(lines: 3, toggle: false), width: 320)
        #expect(three.height == 112)
        #expect(abs(three.first - 28) < 0.5)
        // Two lines alone stay centred: the rule passes in the gap between them.
        let two = measure(row(lines: 2, toggle: false), width: 320)
        #expect(two.height == 112)
        #expect(two.first + 4 < 56 && two.first + 28 - 13 > 56)
    }

    @Test func showMoreOnlyWhenThereIsMore() {
        #expect(!TokensHistoryRowLayout.showsToggle(previewLines: 3, expanded: false, truncated: false, typedNote: false))
        #expect(TokensHistoryRowLayout.showsToggle(previewLines: 3, expanded: false, truncated: true, typedNote: false))
        #expect(TokensHistoryRowLayout.showsToggle(previewLines: 3, expanded: false, truncated: false, typedNote: true))
        #expect(TokensHistoryRowLayout.showsToggle(previewLines: 3, expanded: true, truncated: false, typedNote: false))
        // Home's Recent is one line per talk and never opens in place.
        #expect(!TokensHistoryRowLayout.showsToggle(previewLines: 1, expanded: false, truncated: true, typedNote: true))
    }

    @Test func rowSpeaksAsCopyDictation() {
        #expect(TokensHistoryRow.accessibilityLabel == "Copy words")
    }

    /// The new fixtures need --render-preview-frames in a proof-allowed build.
    @Test func newFixturesStayRenderOnly() {
        let args = ["Tokens", "--render-preview-frames", "/tmp/x", "--history-preview-full", "--history-preview-hover"]
        for name in ["--history-preview-full", "--history-preview-hover"] {
            #expect(TokensHistoryPreview.flag(name, arguments: args, allowed: true))
            #expect(!TokensHistoryPreview.flag(name, arguments: args, allowed: false))
            #expect(!TokensHistoryPreview.flag(name, arguments: args.filter { $0 != "--render-preview-frames" },
                                               allowed: true))
        }
    }

    /// The History fixture spans several days, newest first, with long talks at the top.
    @Test func fullFixtureSpansDaysNewestFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 0, minute: 30))!
        let history = TokensHistoryPreview.history(now: now, calendar: calendar)
        #expect(history.count == TokensHistoryPreview.fictionalTalks.count)
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt })
        #expect(TokensHistoryCard.groups(history, now: now, calendar: calendar).count >= 3)
        #expect(calendar.isDate(history[0].createdAt, inSameDayAs: now))
        #expect(TokensHistoryText.preview(history[0]).count > 200)
    }
}
