


import AppKit
import Testing
import TokensCore
@testable import Tokens

@Suite("Bubble picker and wordmark on paper rules")
struct BubblePlacementPickerTests {
    /// The same steps TokensSheetZoom walks through, as rendered cell sizes.
    static let zoomSteps: [CGFloat] = [0.75, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5]

    private func onRule(_ value: CGFloat, _ cell: CGFloat) -> Bool {
        abs(value / cell - (value / cell).rounded()) < 0.000_1
    }

    @Test func screenDeckAndCaptionAreWholeCellsAtEveryZoomStep() {
        for zoom in Self.zoomSteps {
            let cell = TokensUI.paperCell * zoom
            let g = TokensBubblePickerGeometry(cell: cell)
            for edge in [g.screen.minX, g.screen.maxX, g.screen.minY, g.screen.maxY, g.base.minY] {
                #expect(onRule(edge, cell), "zoom \(zoom): \(edge) is not a whole cell")
            }
            #expect(abs(g.screen.width - 3 * cell) < 0.001 && abs(g.screen.height - 2 * cell) < 0.001)
            #expect(g.base.width == g.screen.width)
            #expect(g.base.minX == g.screen.minX)
            #expect(g.base.maxX == g.screen.maxX)
            #expect(g.base.minY == g.screen.maxY)
        }
    }

    @Test func pillsMirrorTheBubbleAndNeverTouchTheBorder() {
        for zoom in Self.zoomSteps {
            let cell = TokensUI.paperCell * zoom
            let g = TokensBubblePickerGeometry(cell: cell)
            for slot in TokensBubblePickerGeometry.slots {
                let pill = g.pill(slot)
                let vertical = slot == .left || slot == .right
                #expect(vertical ? pill.height > pill.width : pill.width > pill.height)
                // One-point outline plus visible paper: the pill stays well inside the screen.
                let gap = min(pill.minX - g.screen.minX, g.screen.maxX - pill.maxX,
                              pill.minY - g.screen.minY, g.screen.maxY - pill.maxY)
                #expect(gap >= 0.15 * cell - 0.001 && gap > 2)
                #expect(g.hitArea(slot).contains(pill))
            }
            #expect(g.pill(.custom) == g.pill(.bottom))
        }
    }

    @Test func clickAreasPartitionTheScreenWithoutOverlap() {
        for zoom in Self.zoomSteps {
            let cell = TokensUI.paperCell * zoom
            let g = TokensBubblePickerGeometry(cell: cell)
            let areas = TokensBubblePickerGeometry.slots.map(g.hitArea)
            for (i, a) in areas.enumerated() {
                #expect(g.screen.contains(a))
                for b in areas[(i + 1)...] {
                    let overlap = a.intersection(b)
                    #expect(overlap.isNull || overlap.width * overlap.height < 0.000_1)
                }
            }
            let covered = areas.reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(covered - g.screen.width * g.screen.height) < 0.01)
            for slot in TokensBubblePickerGeometry.slots {
                let a = g.hitArea(slot)
                let along = slot == .left || slot == .right ? a.height : a.width
                let across = slot == .left || slot == .right ? a.width : a.height
                #expect(along >= 0.9 * cell - 0.001 && across >= 0.6 * cell - 0.001)
            }
        }
    }

    @Test func fullDeckStaysInsideItsFrameAtEveryZoomStep() {
        for zoom in Self.zoomSteps {
            let cell = TokensUI.paperCell * zoom
            let g = TokensBubblePickerGeometry(cell: cell)
            for minX in stride(from: 100.0, through: 400.0, by: 7.25) {
                for width in [g.minimumWidth, 4 * cell, 4 * cell + 13, 9 * cell + 3.5] {
                    let maxX = minX + width
                    for side in [TokensBubblePickerGeometry.Side.leading, .trailing] {
                        let x = g.screenMinX(frameMinX: minX, frameMaxX: maxX, side: side)
                        #expect(x + g.base.minX >= minX - 0.01)
                        #expect(x + g.base.maxX + 1 <= maxX + 0.01)
                        let firstRule = ceil((minX + g.horizontalInset - 0.01) / cell) * cell
                        let lastRule = floor((maxX - g.horizontalInset - g.screen.width + 0.01) / cell) * cell
                        if firstRule <= lastRule { #expect(onRule(x, cell)) }
                    }
                }
            }
            #expect(g.titleGap >= cell / 4)
            #expect(onRule(cell + g.titleGap + g.captionBaseline, cell))
            #expect(cell + g.titleGap + g.height == 4 * cell)
        }
    }

    @Test func arrowsSlotsCaptionsAndLabelsMapToTheFourEdges() {
        #expect(TokensBubblePickerGeometry.slots == [.top, .right, .bottom, .left])
        #expect(Set(TokensBubblePickerGeometry.slots) == Set(BubblePlacement.presets))
        #expect(TokensBubblePickerGeometry.placement(for: .up) == .top)
        #expect(TokensBubblePickerGeometry.placement(for: .down) == .bottom)
        #expect(TokensBubblePickerGeometry.placement(for: .left) == .left)
        #expect(TokensBubblePickerGeometry.placement(for: .right) == .right)
        #expect(TokensBubblePickerGeometry.caption(.bottom) == "Bottom of the screen")
        #expect(TokensBubblePickerGeometry.caption(.custom) == "Bottom of the screen")
        let captions = TokensBubblePickerGeometry.slots.map(TokensBubblePickerGeometry.caption)
        #expect(Set(captions).count == 4)
        #expect(TokensBubblePickerGeometry.slots.map(TokensBubblePickerGeometry.accessibilityLabel)
                == ["Bubble position Top", "Bubble position Right", "Bubble position Bottom", "Bubble position Left"])
        // Ordinary launches never pick up the offscreen proof overrides.
        #expect(TokensBubblePickerPreview.placement == nil && TokensBubblePickerPreview.hovered == nil)
        #expect(!TokensBubblePickerPreview.disabled)
    }

    @Test func wordmarkLettersRestOnTheSlotRule() {
        for (sidebar, compact, rows) in [(CGFloat(168), false, 2), (168, true, 1), (112, true, 1), (112, false, 2)] {
            for dev in [false, true] {
                let rule = TokensWordmarkRule(sidebarWidth: sidebar, compact: compact, dev: dev)
                #expect(rule.rows == rows)
                #expect(abs(rule.top + rule.baseline - CGFloat(rows) * TokensUI.paperCell) < 0.001)
                #expect(rule.top > 0 && rule.width + 2 * TokensWordmarkRule.leading + (dev ? 28 : 0) <= sidebar)
                #expect(rule.slotHeight(updateNotice: true) - rule.slotHeight(updateNotice: false) == TokensUI.paperCell)
            }
        }
        #expect(TokensWordmarkRule(sidebarWidth: 168, compact: false).width == 120)
        #expect(TokensWordmarkRule(sidebarWidth: 168, compact: true).width == 92)
    }

    /// Re-measures the bundled artwork: the o, k, e and s strokes must end on the declared row.
    @Test func wordmarkRestRowMatchesTheArtwork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/Release/WaveIdentity/tokens-wordmark.png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(rep.pixelsWide == 1877 && rep.pixelsHigh == 838)
        func lowestInk(_ columns: ClosedRange<Int>) -> Int {
            var lowest = 0
            for x in columns {
                for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1)
                where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    lowest = max(lowest, y)
                    break
                }
            }
            return lowest
        }
        // Column ranges of o, k, e and s in the 1877-pixel master.
        for letters in [580...780, 840...1040, 1061...1230, 1460...1609] {
            #expect(abs(CGFloat(lowestInk(letters)) - TokensWordmarkRule.restRow) <= 4)
        }
    }

    /// The picker never makes a sound: no beep or sound call anywhere in its source.
    @Test func pickerSourceHasNoSound() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Design/BubblePlacementPicker.swift"),
                                encoding: .utf8)
        for word in ["NSSound", "NSBeep", "beep(", "AudioServicesPlay"] { #expect(!source.contains(word)) }
    }

    // The fixed mini screen Settings draws (DESIGN.md §6.5, 2026-10-13).

    @Test func miniScreenIs72By46WithPillsInsideTheirOwnClickAreas() {
        let size = TokensBubbleMiniScreen.size
        #expect(size == CGSize(width: 72, height: 46))
        #expect(TokensBubbleMiniScreen.radius == 6)
        let screen = CGRect(origin: .zero, size: size)
        for slot in TokensBubblePickerGeometry.slots {
            let pill = TokensBubbleMiniScreen.pill(slot)
            let vertical = slot == .left || slot == .right
            #expect(vertical ? pill.height > pill.width : pill.width > pill.height)
            // Clear of the one-point edge on every side, and inside its own click area.
            let gap = min(pill.minX, screen.maxX - pill.maxX, pill.minY, screen.maxY - pill.maxY)
            #expect(gap >= 4)
            #expect(TokensBubbleMiniScreen.hitArea(slot).contains(pill))
        }
        #expect(TokensBubbleMiniScreen.pill(.custom) == TokensBubbleMiniScreen.pill(.bottom))
        #expect(TokensBubbleMiniScreen.hitArea(.custom) == TokensBubbleMiniScreen.hitArea(.bottom))
    }

    @Test func miniScreenClickAreasPartitionTheScreenWithoutOverlap() {
        let screen = CGRect(origin: .zero, size: TokensBubbleMiniScreen.size)
        let areas = TokensBubblePickerGeometry.slots.map(TokensBubbleMiniScreen.hitArea)
        for (i, a) in areas.enumerated() {
            #expect(screen.contains(a))
            for b in areas[(i + 1)...] {
                let overlap = a.intersection(b)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.000_1)
            }
            // Large enough to hit: at least 18 points across and 23 along.
            #expect(min(a.width, a.height) >= 18 && max(a.width, a.height) >= 23)
        }
        let covered = areas.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(covered - screen.width * screen.height) < 0.01)
    }

    @Test func miniScreenPillsAreInkLevelsNeverRed() throws {
        typealias Mini = TokensBubbleMiniScreen
        #expect(Mini.pillAlpha(selected: true, hovered: false, pressed: false, enabled: true) == 1)
        #expect(Mini.pillAlpha(selected: false, hovered: false, pressed: false, enabled: true) == 0.25)
        #expect(Mini.pillAlpha(selected: false, hovered: true, pressed: false, enabled: true) == 0.5)
        #expect(Mini.pillAlpha(selected: false, hovered: false, pressed: true, enabled: true) == 0.5)
        // Locked while finishing: every pill steps down, the chosen one still the brightest.
        let lockedSelected = Mini.pillAlpha(selected: true, hovered: true, pressed: false, enabled: false)
        let lockedIdle = Mini.pillAlpha(selected: false, hovered: true, pressed: false, enabled: false)
        #expect(lockedSelected < 0.5 && lockedIdle < lockedSelected)
        // No red anywhere in the picker, and no whole-control opacity fade for the locked state.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Design/BubblePlacementPicker.swift"),
                                encoding: .utf8)
        for word in ["TokensUI.red", "TokensInk.red", ".opacity(enabled ? 1 : 0.4)"] { #expect(!source.contains(word)) }
    }
}

/*
The talk-key page and its keyboard (DESIGN.md §6.6): the five recommended keys in order,
when the full keyboard opens by itself, the whole-unit keyboard rows, the keyboard's fit in the
narrowest column with every legend whole, and the keep-mic-on value.
*/
@Suite("Talk-key page and Settings values")
struct ShortcutPageLayoutTests {
    @Test func recommendedKeysAreTheFiveInSpecOrder() {
        #expect(TokensShortcutPicker.recommended.map(\.keyCode) == [58, 61, 54, 59, 63])
        #expect(TokensShortcutPicker.recommended.map(TokensShortcutPicker.legend)
                == ["Option", "Option", "Command", "Control", "Fn"])
    }

    @Test func fullKeyboardOpensForAnUnlistedKeyOrTheProofFlagOnly() {
        let flags = ["Tokens", "--render-preview-frames", "--public-preview-all-keys"]
        #expect(!TokensShortcutPicker.opensExpanded(keyCode: 58, arguments: ["Tokens"], allowed: true))
        #expect(TokensShortcutPicker.opensExpanded(keyCode: 96, arguments: ["Tokens"], allowed: false))
        #expect(TokensShortcutPicker.opensExpanded(keyCode: 58, arguments: flags, allowed: true))
        // The flag needs a proof-allowed build and a frame render.
        #expect(!TokensShortcutPicker.opensExpanded(keyCode: 58, arguments: flags, allowed: false))
        #expect(!TokensShortcutPicker.opensExpanded(keyCode: 58, arguments: ["Tokens", "--public-preview-all-keys"],
                                                    allowed: true))
        // Ordinary test launches never pick it up.
        #expect(!TokensShortcutPicker.opensExpanded(keyCode: 58))
    }

    @Test func keyboardRowsAreEqualWholeUnitsAndDrawEveryKeyOnce() {
        #expect(ShortcutKeyboard.compactRowWidths == Array(repeating: 30, count: 6))
        // No key narrower than a letter key (two half-units).
        #expect(ShortcutKeyboard.compactNarrowestKey >= 2)
        let codes = ShortcutKeyboard.compactKeyCodes
        #expect(codes.count == Set(codes).count)
        #expect(Set(codes) == Set(ShortcutKeyboard.drawnKeyCodes))
        for shortcut in TokensShortcutPicker.recommended { #expect(codes.contains(shortcut.keyCode)) }
    }

    /*
    DESIGN.md §4.4 and §7: the open keyboard must not widen the page past its right rule. Its
    smallest step plus the panel's 16-point padding on each side (§6.6) has to fit the page column
    at every window width the app allows and every zoom step, computed the way TokensHome does
    (rail outside the zoom). The narrowest is 760 × 520 at 150%: 336 points, where the old
    smallest step (11) was 327 + 32 = 359.
    */
    @Test func smallestKeyboardFitsTheNarrowestPageColumn() {
        let padding: CGFloat = 2 * 16
        #expect(ShortcutKeyboard.compactWidth(unit: 11) == 327)
        #expect(ShortcutKeyboard.compactWidth(unit: ShortcutKeyboard.compactMinimumUnit) == 297)
        #expect(TokensColumn.layout(sheetWidth: 688 / 1.5).width == 336)
        var narrowest = CGFloat.infinity
        for window in stride(from: CGFloat(760), through: 1800, by: 1) {
            for zoom in BubblePlacementPickerTests.zoomSteps {
                let column = TokensColumn.layout(sheetWidth: (window - TokensRail.width(sheetWidth: window)) / zoom).width
                narrowest = min(narrowest, column)
                #expect(ShortcutKeyboard.compactWidth(unit: ShortcutKeyboard.compactMinimumUnit) + padding <= column,
                        "keyboard wider than the column at \(window) wide, zoom \(zoom)")
            }
        }
        #expect(narrowest == 336)
        // The old smallest step does not fit there, which is why the page widened.
        #expect(ShortcutKeyboard.compactWidth(unit: 11) + padding > narrowest)
    }

    /*
    At the smallest step every worded legend (11-point medium, TokensType.micro) must fit its key
    once shrunk to the legend floor, or it shows an ellipsis. "⌥ right" is the tightest: 27 points
    at 10. Measured with AppKit's system font, which SwiftUI's Text uses.
    */
    @Test func everyLegendFitsItsKeyAtTheSmallestStep() {
        let unit = ShortcutKeyboard.compactMinimumUnit
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let legends = ShortcutKeyboard.compactLegendWidths
        #expect(legends.count == ShortcutKeyboard.compactKeyCodes.count - 5)    // Return and four arrows are symbols
        for (legend, units) in legends {
            let natural = ceil((legend as NSString).size(withAttributes: [.font: font]).width)
            let key = CGFloat(units) * unit - ShortcutKeyboard.compactGap(unit: unit)
            #expect(natural * ShortcutKeyboard.legendMinimumScale <= key, "\(legend): \(natural) in \(key)")
            // Only "⌥ right" needs to go below 70%; every other legend keeps its old size.
            if legend != "⌥ right" { #expect(natural * 0.7 <= key, "\(legend): \(natural) in \(key)") }
        }
        let right = ceil(("⌥ right" as NSString).size(withAttributes: [.font: font]).width)
        #expect(right * 0.7 > 3 * unit - ShortcutKeyboard.compactGap(unit: unit))
    }

    @Test func keycapsUseInkForTheChosenKeyAndNeverRed() throws {
        let chosen = ShortcutKeycapStyle.look(selected: true, reserved: false, modifier: true, enabled: true, hovered: false)
        #expect(chosen.fill == TokensUI.ink && chosen.legend == TokensUI.card)
        let reserved = ShortcutKeycapStyle.look(selected: false, reserved: true, modifier: true, enabled: false, hovered: true)
        #expect(reserved.fill == .clear && reserved.legend == TokensUI.secondary)
        let modifier = ShortcutKeycapStyle.look(selected: false, reserved: false, modifier: true, enabled: true, hovered: false)
        #expect(modifier.legend == TokensUI.ink)
        let letter = ShortcutKeycapStyle.look(selected: false, reserved: false, modifier: false, enabled: true, hovered: false)
        #expect(letter.legend == TokensUI.secondary)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Features/Home/ShortcutKeyboard.swift"),
                                encoding: .utf8)
        for word in ["TokensUI.red", "redChip", "redFill", ".shadow("] { #expect(!source.contains(word)) }
    }

    @Test func keepMicValueOnlyShowsStatusThatSaysMoreThanTheSwitch() {
        #expect(TokensHome.keepMicValue(status: "Background listening off", enabled: false) == nil)
        #expect(TokensHome.keepMicValue(status: "Listening · on this Mac", enabled: true) == nil)
        #expect(TokensHome.keepMicValue(status: "Microphone live · on this Mac", enabled: true) == nil)
        #expect(TokensHome.keepMicValue(status: "Connecting microphone…", enabled: true) == "Connecting microphone…")
        #expect(TokensHome.keepMicValue(status: "Connecting microphone…", enabled: false) == nil)
    }
}

