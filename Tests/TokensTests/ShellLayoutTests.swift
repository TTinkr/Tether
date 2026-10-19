


import AppKit
import Testing
@testable import Tokens

@Suite("Window shell: rail, proof sizes, View menu")
struct ShellLayoutTests {
    @Test func railShowsLabelsFromNineHundredLogicalPoints() {
        #expect(TokensRail.width(sheetWidth: 1040) == 216)
        #expect(TokensRail.width(sheetWidth: 900) == 216)
        #expect(TokensRail.width(sheetWidth: 899) == 72)
        // A 693-point width is the icon rail. The shell passes the physical window width and the
        // rail is outside the zoom, so 1040 at 150% keeps the labelled rail.
        #expect(TokensRail.width(sheetWidth: 1040 / 1.5) == 72)
        #expect(TokensRail.width(sheetWidth: 760) == 72)
    }

    /// DESIGN.md §4.4 and §7: both column edges on vertical rules, one column on every page.
    @Test func pageColumnLandsOnVerticalRules() {
        func column(_ width: CGFloat) -> [CGFloat] {
            let layout = TokensColumn.layout(sheetWidth: width)
            return [layout.leading, layout.width]
        }
        #expect(column(824) == [112, 616])          // 1040 × 720
        #expect(column(688) == [56, 560])           // 760 × 520
        #expect(column(1224) == [280, 616])         // 1440 × 900
        #expect(column(824 / 1.5) == [56, 392])     // 1040 at 150%: 549.33
        #expect(column(688 / 1.5) == [56, 336])     // 760 at 150%: 458.67
        for width in stride(from: 300.0, through: 1600.0, by: 7.25) {
            let layout = TokensColumn.layout(sheetWidth: width)
            #expect(layout.leading.truncatingRemainder(dividingBy: 56) == 0)
            #expect(layout.width.truncatingRemainder(dividingBy: 56) == 0)
            #expect(layout.width <= 616 && layout.width >= 224)
        }
        // Scroll content ends one square plus the slot remainder below its last row.
        #expect(TokensColumn.bottomPadding(sheetHeight: 720) == 104)        // 56 + 608 mod 56
        #expect(TokensColumn.bottomPadding(sheetHeight: 720 / 1.5) == 88)    // 56 + 368 mod 56
    }

    @Test func zoomKeysAcceptCommandOrControl() {
        for modifiers: NSEvent.ModifierFlags in [.command, .control] {
            #expect(TokensSheetZoom.action(characters: "+", modifiers: modifiers) == 1)
            #expect(TokensSheetZoom.action(characters: "=", modifiers: modifiers) == 1)
            #expect(TokensSheetZoom.action(characters: "-", modifiers: modifiers) == -1)
            #expect(TokensSheetZoom.action(characters: "0", modifiers: modifiers) == 0)
        }
        for characters in ["+", "=", "-", "0"] {
            #expect(TokensSheetZoom.action(characters: characters, modifiers: .option) == nil)
            #expect(TokensSheetZoom.action(characters: characters, modifiers: [.control, .option]) == nil)
        }
    }

    /// DESIGN.md §2.3: Chalkboard's derived surfaces are opaque blends of ink over the sheet.
    @Test func derivedChalkColoursMatchTheSpec() {
        let sheet: UInt32 = 0x1E2321, ink: UInt32 = 0xE9ECE6
        #expect(TokensUI.opaqueHex(0.82, over: sheet, ink: ink) == 0xC4C8C3)   // ink2
        #expect(TokensUI.opaqueHex(0.06, over: sheet, ink: ink) == 0x2A2F2D)   // raised
        #expect(TokensUI.opaqueHex(0.08, over: sheet, ink: ink) == 0x2E3331)   // chip
        #expect(TokensUI.opaqueHex(0.12, over: sheet, ink: ink) == 0x363B39)   // chipHover, divider
        #expect(TokensUI.opaqueHex(0.14, over: sheet, ink: ink) == 0x3A3F3D)   // selected
        #expect(TokensUI.opaqueHex(0.05, over: sheet, ink: ink) == 0x282D2B)   // disabledFill
        #expect(TokensUI.opaqueHex(0.10, over: 0xCC4339, ink: 0x000000) == 0xB83C33)   // pressed primary
        #expect(TokensTheme.chalkboard.palette.seam == 0x111413)
        #expect(TokensTheme.paper.palette.seam == 0xE4E2DC)
    }

    @Test func readyPreviewNeedsARenderAndAProofBuild() {
        let render = ["Tokens", "--render-preview-frames", "/tmp/x", "--public-preview-ready"]
        #expect(TokensPreview.forcesReady(arguments: render, allowed: true))
        #expect(!TokensPreview.forcesReady(arguments: render, allowed: false))
        #expect(!TokensPreview.forcesReady(arguments: ["Tokens", "--public-preview-ready"], allowed: true))
        #expect(!TokensPreview.forcesReady(arguments: ["Tokens", "--render-preview-frames", "/tmp/x"], allowed: true))
    }

    @Test func previewSizeFlagParsesAndRespectsTheMinimum() {
        let base = ["Tokens", "--render-preview-frames", "/tmp/x"]
        #expect(AppDelegate.publicPreviewSize(base + ["--public-preview-size", "1440x900"]) == NSSize(width: 1440, height: 900))
        #expect(AppDelegate.publicPreviewSize(base + ["--public-preview-size", "100X100"]) == AppDelegate.publicMinimumSize)
        #expect(AppDelegate.publicPreviewSize(base + ["--public-preview-size", "wide"]) == nil)
        #expect(AppDelegate.publicPreviewSize(base) == nil)
        // Without a proof render the flag is ignored.
        #expect(AppDelegate.publicPreviewSize(["Tokens", "--public-preview-size", "1440x900"]) == nil)
        #expect(AppDelegate.publicDefaultSize == NSSize(width: 1040, height: 720))
        #expect(AppDelegate.publicMinimumSize == NSSize(width: 760, height: 576))
    }

    /*
    Build 82: the rail's column, as TokensHomeSidebar lays it out (logo slot, five rows 16 apart,
    the Spacer's 16-point minimum, the status slot, Settings' row and the slot under it), fits the
    smallest window in every state, so the rail never falls back to scrolling and Settings stays at
    the bottom (independent review, 2026-10-17: six rows overflowed the 520-point window).
    */
    @Test func railFitsTheSmallestWindowInEveryState() {
        let rows = 5 * TokensRail.rowHeight + 4 * (TokensRail.rowPitch - TokensRail.rowHeight)
        for wide in [true, false] { for dev in [false, true] where wide || !dev {
            for update in [false, true] { for status in [false, true] {
                let column = TokensRail.rowsTop(updateNotice: update) + rows + 16
                    + (status ? TokensRail.statusSlot : 0) + TokensRail.rowHeight
                    + TokensRail.settingsBottom(wide: wide, dev: dev)
                #expect(column <= AppDelegate.publicMinimumSize.height,
                        "wide \(wide) dev \(dev) update \(update) status \(status): \(column) > \(AppDelegate.publicMinimumSize.height)")
            } }
        } }
    }

    @MainActor @Test func viewMenuGetsZoomItemsOnceBeforeWindow() throws {
        let main = NSMenu(title: "Main")
        for title in ["Tokens", "Edit", "Window", "Help"] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = NSMenu(title: title)
            main.addItem(holder)
        }
        let view = try #require(TokensViewMenu.addItems(to: main))
        TokensViewMenu.addItems(to: main)
        #expect(main.items.map(\.title) == ["Tokens", "Edit", "View", "Window", "Help"])
        let zoom = view.items.filter { $0.action != nil }
        #expect(zoom.map(\.title) == ["Actual Size", "Zoom In", "Zoom In", "Zoom Out"])
        #expect(zoom.map(\.keyEquivalent) == ["0", "+", "=", "-"])
        #expect(zoom.allSatisfy { $0.keyEquivalentModifierMask == .command })
        #expect(zoom.filter(\.isHidden).map(\.keyEquivalent) == ["="])
        #expect(zoom.first { $0.isHidden }?.allowsKeyEquivalentWhenHidden == true)
        // With no Tokens window in front, the items are disabled rather than acting elsewhere.
        #expect(zoom.allSatisfy { !TokensViewMenu.shared.validateMenuItem($0) })
    }
}

