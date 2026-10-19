


import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// What a parent sees of its one child: height and both text baselines.
private final class AccessRuleProbe {
    var height: CGFloat = -1
    var first: CGFloat = -1
    var last: CGFloat = -1
}

private struct AccessRuleProbeLayout: Layout {
    let probe: AccessRuleProbe
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

/// A proof window as firstRunPage lays it out: the logical sheet, the Access column, the branch.
private struct AccessProofShape: CustomStringConvertible {
    let window: CGSize
    let zoom: CGFloat
    var sheet: CGSize { CGSize(width: window.width / zoom, height: window.height / zoom) }
    var column: (leading: CGFloat, width: CGFloat) {
        let rail = TokensRail.width(sheetWidth: sheet.width)
        return TokensColumn.layout(sheetWidth: max(1, sheet.width - rail), maxWidth: TokensSetupLayout.accessColumnMaximum)
    }
    var compact: Bool { sheet.height < TokensSetupLayout.compactBelow }
    var rule: CGFloat { TokensSetupLayout.headlineRule(sheetHeight: sheet.height) }
    var description: String { "\(Int(window.width))x\(Int(window.height))@\(zoom)" }
}

@Suite("Access step on the grid")
struct AccessStepGridTests {
    @MainActor private func measure(_ view: some View, width: CGFloat, compact: Bool = false) -> AccessRuleProbe {
        let probe = AccessRuleProbe()
        let host = NSHostingView(rootView: AccessRuleProbeLayout(probe: probe) { view }
            .frame(width: width)
            .environment(\.tokensSetupCompact, compact))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return probe
    }

    private static let previews = ["accessibility", "microphone", "speech", "prompt", "relaunch",
                                   "orukeet-prompt", "orukeet-microphone", "orukeet-ready"]

    /// The matrix windows (1040 × 720, 760 × 520, 760 × 520 at 150%, 1440 × 900) and two zooms of the default.
    private static let shapes = [AccessProofShape(window: CGSize(width: 1040, height: 720), zoom: 1),
                                 AccessProofShape(window: CGSize(width: 760, height: 520), zoom: 1),
                                 AccessProofShape(window: CGSize(width: 760, height: 520), zoom: 1.5),
                                 AccessProofShape(window: CGSize(width: 1440, height: 900), zoom: 1),
                                 AccessProofShape(window: CGSize(width: 1040, height: 720), zoom: 1.25),
                                 AccessProofShape(window: CGSize(width: 1040, height: 720), zoom: 1.5)]

    /*
    The heart of the review (build 81 RC5): at 760 × 520 and at 150% the line, the advice and every
    reason had gone into tooltips. Here the whole step is measured in every state at every proof
    size and must be exactly as tall as all of its parts measured on their own: the title's
    square, the line, the buttons, the square after 48-point buttons, the advice (under the
    picture, or after the buttons), and "Where things stand" with every row. Leaving any of them
    out at some size makes the step shorter than the sum and fails.
    */
    @MainActor @Test func everyWordIsDrawnInEveryStateAndShape() throws {
        let cell = TokensUI.paperCell
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            for shape in Self.shapes {
                let column = shape.column.width
                let step = measure(TokensFirstRunAccessStep(access: access, inner: column, compact: shape.compact),
                                   width: column, compact: shape.compact)
                let split = TokensFirstRunAccessStep.showsPicture(access, inner: column, compact: shape.compact)
                    ? TokensFirstRunAccessStep.split(inner: column) : nil
                // The single column's words keep the page measure; its buttons and rows the whole column.
                let words = split?.actions ?? min(column, TokensFirstRunAccessStep.measure)
                let line = measure(TokensFirstRunAccessStep.lead(TokensFirstRunAccessStep.statusLine(access, appName: appName)),
                                   width: words).height
                let buttons = measure(FirstRunAccessButtons(access: access, fixedWidth: split != nil, compact: shape.compact),
                                      width: split?.actions ?? column, compact: shape.compact).height
                let after = TokensFirstRunAccessStep.squaresAfterActions(compact: shape.compact) * cell
                let advice = TokensFirstRunAccessStep.advice(access, appName: appName).map {
                    measure(TokensFirstRunAccessStep.note($0), width: split?.picture ?? min(column, TokensFirstRunAccessStep.measure)).height
                } ?? 0
                let rows = measure(FirstRunPermissionRows(access: access), width: column).height
                let top = split.map { max(cell + line + buttons + after,
                                          TokensFirstRunAccessStep.pictureSquares(width: $0.picture) * cell + advice) }
                    ?? cell + line + buttons + after + advice
                #expect(line >= cell && buttons >= cell && rows >= 2 * cell, "\(name) at \(shape)")
                #expect(abs(step.height - (top + rows)) < 0.01, "\(name) at \(shape): \(step.height) vs \(top + rows)")
                #expect(step.height.truncatingRemainder(dividingBy: cell) == 0, "\(name) at \(shape)")
                #expect(abs(step.first - cell) < 0.01, "\(name) at \(shape): the title stands on the step's first rule")
            }
            // Only the relaunch and the ready state go without advice; their line says it all.
            #expect((TokensFirstRunAccessStep.advice(access, appName: appName) == nil) == (name == "relaunch" || name == "orukeet-ready"))
        }
    }

    /// Each permission row shows its reason under its name on the 28-point pitch, in whole squares,
    /// at every column width the step uses (the reason was the row's tooltip in short windows).
    @MainActor @Test func everyRowShowsItsReasonUnderItsName() throws {
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            for permission in TokensFirstRunAccessStep.permissions(access) {
                for width: CGFloat in [280, 350, 504, 560, 672, 712] {
                    let row = measure(FirstRunPermissionRow(permission: permission), width: width)
                    #expect(row.height.truncatingRemainder(dividingBy: TokensUI.paperCell) == 0, "\(permission.name) at \(width)")
                    #expect(abs(row.first - TokensUI.halfCell) < 0.01, "\(permission.name) at \(width): name on the half-rule")
                    let steps = (row.last - row.first) / TokensUI.halfCell
                    #expect(steps >= 1 - 0.01 && abs(steps - steps.rounded()) < 0.01,
                            "\(permission.name) at \(width): the reason stands under the name (\(row.last - row.first))")
                    #expect(row.last <= row.height + 0.01)
                }
                // In the default column every reason is one line: one square per permission.
                let wide = measure(FirstRunPermissionRow(permission: permission), width: 672)
                #expect(wide.height == TokensUI.paperCell && abs(wide.last - TokensUI.paperCell) < 0.01)
            }
        }
    }

    /// "Where things stand" is drawn in every state and every width, on the rows' first rule.
    @MainActor @Test func theLabelStandsOverTheRowsInEveryState() throws {
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            let count = CGFloat(TokensFirstRunAccessStep.permissions(access).count)
            for shape in Self.shapes {
                let rows = measure(FirstRunPermissionRows(access: access), width: shape.column.width)
                #expect(abs(rows.first - TokensUI.paperCell) < 0.01, "\(name) at \(shape)")
                #expect(rows.height >= (1 + count) * TokensUI.paperCell, "\(name) at \(shape)")
            }
            #expect(TokensFirstRunAccessStep.guidance(access, appName: "Tokens").contains(TokensFirstRunAccessStep.eyebrow))
        }
    }

    /*
    No tooltip holds words the page does not draw: the step's only tooltip is Continue's, and its
    words end the ready state's line, drawn over the button. The reasons, the advice and the
    line are not in any .help or spoken-only hint, and the density variants that moved them there
    are gone from the step and its caller.
    */
    @Test func noWordIsLeftToATooltip() throws {
        let step = try String(contentsOf: Self.source("Sources/Tokens/Features/Home/TokensFirstRunAccessStep.swift"), encoding: .utf8)
        let view = String(step[try #require(step.range(of: "struct TokensFirstRunAccessStep: View {")).upperBound...])
        let helps = view.components(separatedBy: ".help(").dropFirst().map { $0.prefix(while: { $0 != ")" }) }
        #expect(helps == ["TokensFirstRunAccessStep.continueNote"])
        #expect(!view.contains(".accessibilityHint("))
        for gone in ["snug", "Density", "tight", "packed", "showsInstruction"] { #expect(!view.contains(gone), "\(gone)") }
        let ready = try #require(FirstRunAccessSnapshot.preview("orukeet-ready"))
        #expect(TokensFirstRunAccessStep.statusLine(ready, appName: "Tokens").hasSuffix(TokensFirstRunAccessStep.continueNote))

        let shell = try String(contentsOf: Self.source("Sources/Tokens/Features/Home/TokensHomeFirstRun.swift"), encoding: .utf8)
        let stage = String(shell[try #require(shell.range(of: "private func accessStage(")).lowerBound...].prefix(2400))
        #expect(!stage.contains(".help(") && !stage.contains("snug"))
    }

    /// Step 2's title is the same 28-point regular headline as Terms and Done, one line on its rule.
    @MainActor @Test func titleIsTheSetupHeadline() throws {
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            // 280: the compact column at 760 × 520 and 150%; the 28-point line scales rather than wraps.
            let line = measure(TokensSetupTitle(text: TokensFirstRunAccessStep.stepTitle(access)).tokensOnRule(), width: 280)
            #expect(line.height == TokensUI.paperCell && abs(line.first - 56) < 0.01 && abs(line.last - 56) < 0.01)
        }
        // A 28-point line box is about 34 tall; the old 16-point medium section was about 19.
        #expect(measure(TokensSetupTitle(text: "Allow Accessibility"), width: 672).height > 30)
        let source = try String(contentsOf: Self.source("Sources/Tokens/Features/Home/TokensFirstRunAccessStep.swift"), encoding: .utf8)
        #expect(source.contains("TokensSetupTitle(text: title)"))
        #expect(!source.contains("TokensType.section"))
        #expect(!source.contains("TokensHairline("))
    }

    /// The line (17 point) and the advice (13 point) wrap on the 28-point pitch and fill whole
    /// squares, so what follows them lands back on a rule.
    @MainActor @Test func wordsWrapOnTheHalfSquarePitch() throws {
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            var blocks = [TokensFirstRunAccessStep.lead(TokensFirstRunAccessStep.statusLine(access, appName: "Tokens Dev"))]
                .map { AnyView($0) }
            if let advice = TokensFirstRunAccessStep.advice(access, appName: "Tokens Dev") {
                blocks.append(AnyView(TokensFirstRunAccessStep.note(advice)))
            }
            for block in blocks {
                for width: CGFloat in [224, 256, 280, 312, 392, 504, 560, 672] {
                    let text = measure(block, width: width)
                    #expect(abs(text.first - 56) < 0.01, "\(name) at \(width)")
                    #expect(text.height.truncatingRemainder(dividingBy: TokensUI.paperCell) == 0, "\(name) at \(width)")
                    let steps = (text.last - text.first) / 28
                    #expect(abs(steps - steps.rounded()) < 0.01, "\(name) at \(width): \(text.last - text.first)")
                    #expect(text.last <= text.height + 0.01)
                }
            }
        }
    }

    /*
    Half a square of paper under the last button before the next words (it was 4.5 points at
    760 × 520 at 150%): a 48-point button hangs about 19 under its rule, so the next line goes a
    square further down; a 36-point one hangs about 13 and the next rule already clears it. The
    next words' height is the 13-point font's whole ascender, more than any letter reaches.
    */
    @MainActor @Test func halfASquareUnderTheLastButton() {
        let ascender = NSFont.systemFont(ofSize: 13).ascender
        for compact in [false, true] {
            let button = measure(FirstRunActionButton("Skip for now") {}, width: 300, compact: compact)
            let hang = button.height - button.first
            #expect(hang > 10 && hang < 22, "hang \(hang)")
            let next = (1 + TokensFirstRunAccessStep.squaresAfterActions(compact: compact)) * TokensUI.paperCell
            #expect(next - hang - ascender >= TokensUI.halfCell, "compact \(compact): \(next - hang - ascender)")
        }
    }

    /// The default window holds every state, with a square of paper to spare under the last row
    /// (the Speech Recognition row used to reach the window's bottom); so does 1440 × 900.
    @MainActor @Test func theDefaultWindowHoldsEveryState() throws {
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            for shape in [Self.shapes[0], Self.shapes[3]] {
                let column = shape.column.width
                let step = measure(TokensFirstRunAccessStep(access: access, inner: column, compact: shape.compact), width: column)
                let bottom = (shape.rule - 1) * TokensUI.paperCell + step.height
                #expect(bottom + TokensUI.paperCell <= shape.sheet.height, "\(name) at \(shape): last row ends at \(bottom)")
            }
        }
    }

    /// Too tall for the sheet, the step scrolls: the Accessibility state does at 760 × 520 and at
    /// 150%, and the scroll's end rests on whole squares at any sheet height.
    @MainActor @Test func shortWindowsScrollOnWholeSquares() throws {
        let access = try #require(FirstRunAccessSnapshot.preview("accessibility"))
        for shape in [Self.shapes[1], Self.shapes[2]] {
            let column = shape.column.width
            let step = measure(TokensFirstRunAccessStep(access: access, inner: column, compact: shape.compact),
                               width: column, compact: shape.compact)
            let still = (shape.rule - 1) * TokensUI.paperCell + step.height + TokensUI.halfCell
            #expect(still > shape.sheet.height, "\(shape)")
        }
        for height: CGFloat in [520 / 1.5, 480, 520, 576, 720, 900] {
            let bottom = TokensFirstRunAccessStep.scrollBottom(sheetHeight: height)
            #expect(bottom >= TokensUI.paperCell && bottom < 2 * TokensUI.paperCell)
            for squares: CGFloat in [7, 12, 16] {
                let range = squares * TokensUI.paperCell + bottom - height
                #expect(abs(range / TokensUI.paperCell - (range / TokensUI.paperCell).rounded()) < 0.001, "\(height)")
            }
        }
    }

    /// At rest, what the window's bottom edge would cut is hidden whole: the 36-point button on
    /// the last rule at 760 × 520 at 150%, and the row whose square passes 760 × 520's edge; and
    /// at the scroll's end, what has begun to pass the top edge (no header covers it).
    @Test func whatTheEdgeWouldCutIsHiddenWhole() {
        let short: CGFloat = 520 / 1.5
        let hang: CGFloat = 12.65, top: CGFloat = 36 - hang
        #expect(FirstRunWholeAtRest.hides(top: 6 * 56 - top, height: 36, slotHeight: short))
        #expect(!FirstRunWholeAtRest.hides(top: 5 * 56 - top, height: 36, slotHeight: short))
        #expect(!FirstRunWholeAtRest.hides(top: 5 * 56, height: 56, slotHeight: short))
        #expect(FirstRunWholeAtRest.hides(top: 6 * 56, height: 56, slotHeight: short))
        #expect(!FirstRunWholeAtRest.hides(top: 8 * 56, height: 56, slotHeight: 520))
        #expect(FirstRunWholeAtRest.hides(top: 9 * 56, height: 56, slotHeight: 520))
        #expect(FirstRunWholeAtRest.hides(top: -top, height: 36, slotHeight: short))
        #expect(FirstRunWholeAtRest.hides(top: -56, height: 56, slotHeight: 520))
        #expect(!FirstRunWholeAtRest.hides(top: 0, height: 56, slotHeight: 520))
    }

    /// Beside the picture: the paired actions where the column has room (the default window),
    /// three stacked at 760 × 520, and no picture in a narrower column or the short window.
    @Test func columnSplitsBetweenActionsAndPicture() {
        #expect(TokensFirstRunAccessStep.split(inner: 672)! == (392, 256))
        #expect(TokensFirstRunAccessStep.split(inner: 712)! == (392, 296))
        #expect(TokensFirstRunAccessStep.split(inner: 560)! == (312, 224))
        #expect(TokensFirstRunAccessStep.split(inner: 504) == nil)
        #expect(TokensFirstRunAccessStep.split(inner: 280) == nil)
        // The advice's capitals stand at least 12 points under the picture.
        for width: CGFloat in [200, 224, 256, 296, 340] {
            let rule = (TokensFirstRunAccessStep.pictureSquares(width: width) + 1) * TokensUI.paperCell
            let clear = rule - NSFont.systemFont(ofSize: 13).capHeight - (TokensUI.halfCell + AccessGuideAnimation.height(for: width))
            #expect(clear >= 12 && clear < 12 + TokensUI.paperCell, "\(width): \(clear)")
        }
    }

    private static func source(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    /// The set-up copy calls the thing you press "the key" (the Accessibility row, the Done step);
    /// "Reconnect the shortcut" and "the shortcut connection" are gone.
    @Test func accessCopySaysKey() throws {
        for name in Self.previews {
            let access = try #require(FirstRunAccessSnapshot.preview(name))
            for line in TokensFirstRunAccessStep.guidance(access, appName: "Tokens") {
                #expect(!line.lowercased().contains("shortcut"), "\(name): \(line)")
            }
        }
        let relaunch = try #require(FirstRunAccessSnapshot.preview("relaunch"))
        #expect(TokensFirstRunAccessStep.statusLine(relaunch, appName: "Tokens Dev").contains("Relaunch Tokens Dev so the key works"))
        #expect(TokensFirstRunAccessStep.stepTitle(relaunch) == "Relaunch to finish")
    }

    /// A column wider than the page column (Access, 712) keeps the page column's leading edge and
    /// grows only to the right; every other width is laid out exactly as before.
    @Test func wideColumnKeepsThePageLeadingEdge() {
        func before(_ sheet: CGFloat, _ maxWidth: CGFloat) -> (leading: CGFloat, width: CGFloat) {
            let width = min(maxWidth, max(4 * 56, floor((sheet - 112) / 56) * 56))
            var leading = max(56, (((sheet - width) / 2) / 56).rounded() * 56)
            if leading + width > sheet - 28 { leading = 56 }
            return (leading, width)
        }
        #expect(TokensColumn.layout(sheetWidth: 824, maxWidth: 712) == (112, 672))
        #expect(TokensColumn.layout(sheetWidth: 1224, maxWidth: 712) == (280, 712))
        #expect(TokensColumn.layout(sheetWidth: 688, maxWidth: 712) == (56, 560))
        for sheet in stride(from: CGFloat(300), through: 1600, by: 7.25) {
            let page = TokensColumn.layout(sheetWidth: sheet)
            let wide = TokensColumn.layout(sheetWidth: sheet, maxWidth: TokensSetupLayout.accessColumnMaximum)
            #expect(wide.leading == page.leading, "sheet \(sheet)")
            #expect(wide.width >= page.width && wide.width <= TokensSetupLayout.accessColumnMaximum)
            #expect(wide.leading + wide.width <= max(sheet - TokensUI.halfCell, page.leading + page.width))
            for maxWidth: CGFloat in [616, 560, 392] {
                #expect(TokensColumn.layout(sheetWidth: sheet, maxWidth: maxWidth) == before(sheet, maxWidth), "sheet \(sheet)")
            }
        }
    }

    /// Terms, Access and Done start at one x at every proof window and zoom, so nothing jumps
    /// sideways between steps (DESIGN.md §6.7). At 1040 × 720 Access used to start a square left.
    @Test func setupStepsShareOneLeadingEdge() {
        for shape in Self.shapes {
            let rail = TokensRail.width(sheetWidth: shape.sheet.width)
            let terms = TokensColumn.layout(sheetWidth: max(1, shape.sheet.width - rail), maxWidth: TokensSetupLayout.columnMaximum)
            #expect(shape.column.leading == terms.leading, "\(shape)")
        }
    }
}

