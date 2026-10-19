
import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// A fake accessibility node for the focus resolver.
final class FakeFocusNode: DestinationFocusNode {
    let role: String?
    let editable: Bool
    let focused: Bool
    let children: [FakeFocusNode]
    let name: String

    init(_ name: String, role: String?, editable: Bool = false, focused: Bool = false, _ children: [FakeFocusNode] = []) {
        self.name = name; self.role = role; self.editable = editable; self.focused = focused; self.children = children
    }
}

struct DestinationFocusResolverTests {
    /// The Claude desktop shape: web area → groups → the focused composer text area.
    @Test func electronWebAreaResolvesToTheFocusedTextArea() throws {
        let composer = FakeFocusNode("composer", role: "AXTextArea", focused: true)
        let page = FakeFocusNode("page", role: "AXWebArea", [
            FakeFocusNode("transcript", role: "AXGroup", [
                FakeFocusNode("message", role: "AXStaticText"),
                FakeFocusNode("old search", role: "AXTextField")
            ]),
            FakeFocusNode("footer", role: "AXGroup", [FakeFocusNode("wrap", role: "AXGroup", [composer])])
        ])
        #expect(try #require(DestinationFocus.resolve(page)).name == "composer")
    }

    @Test func aFocusedTextAreaIsItsOwnBox() throws {
        let composer = FakeFocusNode("composer", role: "AXTextArea", focused: true)
        #expect(try #require(DestinationFocus.resolve(composer)) === composer)
    }

    @Test func anEditableGroupIsAContentEditableBox() throws {
        let editor = FakeFocusNode("editor", role: "AXGroup", editable: true, focused: true,
                                   [FakeFocusNode("line", role: "AXStaticText", editable: true)])
        #expect(try #require(DestinationFocus.resolve(editor)) === editor)
        #expect(DestinationFocus.isTextBox(role: "AXGroup", editable: true))
        #expect(!DestinationFocus.isTextBox(role: "AXGroup", editable: false))
        #expect(!DestinationFocus.isTextBox(role: nil, editable: true))
    }

    @Test func aPageWithNoFocusedTextBoxResolvesToNothing() {
        let page = FakeFocusNode("page", role: "AXWebArea", [
            FakeFocusNode("field", role: "AXTextArea", focused: false),
            FakeFocusNode("button", role: "AXButton", focused: true)
        ])
        #expect(DestinationFocus.resolve(page) == nil)
        #expect(DestinationFocus.resolve(FakeFocusNode("button", role: "AXButton", focused: true)) == nil)
    }

    @Test func theSearchStopsAtItsNodeLimit() {
        // The composer sits past the limit in a wide page: not found, never an unbounded walk.
        let filler = (0..<300).map { FakeFocusNode("n\($0)", role: "AXStaticText") }
        let page = FakeFocusNode("page", role: "AXWebArea",
                                 filler + [FakeFocusNode("composer", role: "AXTextArea", focused: true)])
        #expect(DestinationFocus.resolve(page, limit: 160) == nil)
        #expect(DestinationFocus.resolve(page, limit: 400)?.name == "composer")
    }
}

struct PasteMarkerFramePlacementTests {
    // This Mac on 2026-10-14: one 1800x1169 screen, 39-point menu bar, Dock hidden.
    let primaryHeight: CGFloat = 1169
    let macVisible = [CGRect(x: 0, y: 0, width: 1800, height: 1130)]
    // A 1440x900 screen with a 25-point menu bar.
    let small = [CGRect(x: 0, y: 0, width: 1440, height: 875)]

    /// AX frames read from the live Claude desktop and Codex composers on this Mac (2026-10-14).
    @Test func realClaudeAndCodexComposersGetCorners() throws {
        for field in [CGRect(x: 508, y: 1076, width: 1035, height: 29), CGRect(x: 602, y: 1023, width: 997, height: 63)] {
            let window = CGRect(x: 0, y: 39, width: 1800, height: 1130)
            let box = try #require(DestinationPreview.clippedBoxFrame(field, window: window))
            let result = PasteMarkerGeometry.cuePlacement(field: box, primaryHeight: primaryHeight, visibleFrames: macVisible)
            let frame = try #require(try? result.get())
            #expect(frame.width > 120)
        }
    }

    @Test func typicalComposerSizesGetCornersOnASmallScreen() throws {
        for size in [CGSize(width: 300, height: 40), CGSize(width: 640, height: 120), CGSize(width: 1200, height: 400)] {
            let field = CGRect(x: 100, y: 300, width: size.width, height: size.height)
            #expect(PasteMarkerGeometry.cueFrame(field: field, primaryHeight: 900, visibleFrames: small) != nil, "\(size)")
        }
    }

    @Test func aGiantDocumentKeepsTheCaretLabelAndSaysWhy() {
        let pane = CGRect(x: 0, y: 60, width: 1400, height: 780)
        let result = PasteMarkerGeometry.cuePlacement(field: pane, primaryHeight: 900, visibleFrames: small)
        #expect(result == .failure(.tooBig(pane.size)))
        #expect(PasteMarkerGeometry.Rejection.tooBig(pane.size).logValue == "too_big(1400x780)")
        #expect(PasteMarkerGeometry.cuePlacement(field: CGRect(x: 0, y: 60, width: 20, height: 10), primaryHeight: 900,
                                                 visibleFrames: small) == .failure(.tooSmall(CGSize(width: 20, height: 10))))
    }

    /// A text view as tall as its document (a long note) is cut to its scroll view first.
    @Test func aLongScrollingTextViewIsFramedByWhatIsVisible() throws {
        let textView = CGRect(x: 400, y: 200, width: 640, height: 4000)
        let scrollArea = CGRect(x: 400, y: 200, width: 640, height: 300)
        let window = CGRect(x: 380, y: 150, width: 680, height: 380)
        let box = try #require(DestinationPreview.clippedBoxFrame(textView, window: window, scrollArea: scrollArea))
        #expect(box == scrollArea)
        #expect(PasteMarkerGeometry.cueFrame(field: box, primaryHeight: 900, visibleFrames: small) != nil)
        #expect(PasteMarkerGeometry.cueFrame(field: textView, primaryHeight: 900, visibleFrames: small) == nil)
    }

    @Test func aComposerAtTheBottomOfTheScreenGetsCorners() throws {
        // Box bottom flush with the bottom of the visible screen (AX y grows downward).
        let field = CGRect(x: 300, y: 900 - 90, width: 700, height: 90)
        let frame = try #require(PasteMarkerGeometry.cueFrame(field: field, primaryHeight: 900, visibleFrames: small))
        #expect(frame.maxY - PasteMarkerGeometry.labelTopInset <= small[0].maxY)
    }

    @Test func aComposerAtTheTopOfTheScreenFallsBackWithNoRoom() {
        let field = CGRect(x: 300, y: 25, width: 600, height: 80)
        #expect(PasteMarkerGeometry.cuePlacement(field: field, primaryHeight: 900, visibleFrames: small) == .failure(.noRoom))
        #expect(PasteMarkerGeometry.Rejection.noRoom.logValue == "no_room")
    }

    @Test func offscreenBoxesSayOffscreen() {
        #expect(PasteMarkerGeometry.cuePlacement(field: CGRect(x: 4000, y: 60, width: 300, height: 40), primaryHeight: 900,
                                                 visibleFrames: small) == .failure(.offscreen))
    }

    /// An empty Chromium composer reports a zero-height range at the screen's corner: no caret, so the box frames it.
    @Test func chromiumsEmptyCaretIsNotACaret() {
        #expect(!DestinationPreview.validCaret(CGRect(x: 0, y: 1169, width: 0, height: 0)))
        let field = CGRect(x: 508, y: 1076, width: 1035, height: 29)
        #expect(DestinationPreview.validatedFieldFrame(field, containing: CGRect(x: 0, y: 1150, width: 0, height: 18)) == nil)
    }
}

// MARK: - Offscreen proof renders

/// Fictional composers drawn in the general manner of the Claude and Codex desktop apps.
private enum ComposerStyle: String, CaseIterable { case claude, codex }

private struct StyledComposerFixture: View {
    static let viewport = CGSize(width: 860, height: 240)
    static let typed = "Keep the next step simple, then show it."
    let style: ComposerStyle
    let filled: Bool
    let framed: Bool
    let dark: Bool

    var composer: CGRect {
        switch style {
        case .claude: return CGRect(x: 70, y: 96, width: 720, height: 96)
        case .codex: return CGRect(x: 90, y: 120, width: 680, height: 63)
        }
    }

    private var page: Color {
        switch style {
        case .claude: return dark ? Color(red: 0.15, green: 0.15, blue: 0.14) : Color(red: 0.98, green: 0.97, blue: 0.96)
        case .codex: return dark ? Color(red: 0.09, green: 0.09, blue: 0.10) : Color(red: 0.99, green: 0.99, blue: 0.99)
        }
    }
    private var box: Color {
        switch style {
        case .claude: return dark ? Color(red: 0.19, green: 0.19, blue: 0.18) : .white
        case .codex: return dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.96, green: 0.96, blue: 0.97)
        }
    }
    private var ink: Color { dark ? Color(white: 0.92) : Color(white: 0.12) }
    private var placeholder: String { style == .claude ? "Write a message…" : "Ask for follow-up changes" }

    /// The marker panel's rectangle in this fixture's top-left coordinates, from the real geometry.
    static func markerRect(composer: CGRect, framed: Bool, caret: CGRect) -> CGRect? {
        let h = viewport.height
        let visible = [CGRect(origin: .zero, size: viewport)]
        if framed {
            guard let panel = PasteMarkerGeometry.cueFrame(field: composer, primaryHeight: h, visibleFrames: visible) else { return nil }
            return CGRect(x: panel.minX, y: h - panel.maxY, width: panel.width, height: panel.height)
        }
        let size = NSHostingView(rootView: PasteMarkerView(shortcutName: "Left Option", framed: false)).fittingSize
        guard let origin = PasteMarkerGeometry.origin(anchor: caret, size: size, primaryHeight: h, visibleFrames: visible) else { return nil }
        return CGRect(x: origin.x, y: h - origin.y - size.height, width: size.width, height: size.height)
    }

    var caret: CGRect {
        let c = composer
        // Right after the typed words (measured in the same font), or before the placeholder.
        let typed = NSAttributedString(string: Self.typed, attributes: [.font: NSFont.systemFont(ofSize: 13.5)]).size().width
        return CGRect(x: c.minX + (filled ? 17 + typed.rounded(.up) + 1 : 16), y: c.minY + 14, width: 0, height: 17)
    }

    var body: some View {
        let c = composer
        ZStack(alignment: .topLeading) {
            page
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.10)).frame(width: 420, height: 9)
                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.10)).frame(width: 560, height: 9)
                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.10)).frame(width: 300, height: 9)
            }
            .offset(x: c.minX + 8, y: 26)
            RoundedRectangle(cornerRadius: style == .claude ? 18 : 12)
                .fill(box)
                .overlay(RoundedRectangle(cornerRadius: style == .claude ? 18 : 12).strokeBorder(ink.opacity(0.13)))
                .frame(width: c.width, height: c.height)
                .offset(x: c.minX, y: c.minY)
            Group {
                if filled {
                    Text(Self.typed).foregroundStyle(ink)
                } else {
                    Text(placeholder).foregroundStyle(ink.opacity(0.45))
                }
            }
            .font(.system(size: 13.5))
            .offset(x: c.minX + 17, y: c.minY + 14)
            Rectangle().fill(ink).frame(width: 1.2, height: caret.height).offset(x: caret.minX, y: caret.minY)
            Circle().fill(ink.opacity(filled ? 0.85 : 0.2)).frame(width: 26, height: 26)
                .offset(x: c.maxX - 38, y: c.maxY - 36)
            if let marker = Self.markerRect(composer: c, framed: framed, caret: caret) {
                PasteMarkerView(shortcutName: "Left Option", framed: framed)
                    .frame(width: marker.width, height: marker.height)
                    .offset(x: marker.minX, y: marker.minY)
            }
        }
        .frame(width: Self.viewport.width, height: Self.viewport.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@Suite(.serialized) @MainActor struct PasteMarkerStyledComposerRenderTests {
    @Test func rendersFramedAndCaretOnlyOverClaudeAndCodexStyleComposers() throws {
        _ = NSApplication.shared
        for style in ComposerStyle.allCases { for dark in [false, true] { for filled in [false, true] { for framed in [true, false] {
            let fixture = StyledComposerFixture(style: style, filled: filled, framed: framed, dark: dark)
            #expect(StyledComposerFixture.markerRect(composer: fixture.composer, framed: framed, caret: fixture.caret) != nil)
            let name = "marker-\(style.rawValue)-\(dark ? "dark" : "light")-\(filled ? "filled" : "empty")-\(framed ? "framed" : "caret")"
            for scale in [CGFloat(1), 2] {
                let rep = try PasteMarkerPNG.render(fixture, size: StyledComposerFixture.viewport, scale: scale, dark: dark)
                let png = try PasteMarkerPNG.png(rep)
                #expect(png.count > 1000)
                try PasteMarkerPNG.write(png, "\(name)@\(Int(scale))x.png")
            }
            // Framed: coral corner ink exists just outside each of the box's four corners.
            if framed {
                let rep = try PasteMarkerPNG.render(fixture, size: StyledComposerFixture.viewport, scale: 2, dark: dark)
                let c = fixture.composer
                let o = PasteMarkerGeometry.outset
                for corner in [CGPoint(x: c.maxX + o, y: c.minY - o), CGPoint(x: c.maxX + o, y: c.maxY + o),
                               CGPoint(x: c.minX - o, y: c.maxY + o)] {
                    let probe = CGRect(x: corner.x - 15, y: corner.y - 15, width: 30, height: 30)
                    #expect(coralInk(rep, in: probe), "\(name) corner \(corner)")
                }
            }
        } } } }
    }

    private func coralInk(_ rep: NSBitmapImageRep, in region: CGRect) -> Bool {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        guard let data = rep.bitmapData else { return false }
        for y in max(0, Int(region.minY * scale))..<min(rep.pixelsHigh, Int(region.maxY * scale)) {
            for x in max(0, Int(region.minX * scale))..<min(rep.pixelsWide, Int(region.maxX * scale)) {
                let p = data + y * rep.bytesPerRow + x * rep.samplesPerPixel
                if Int(p[0]) - Int(p[1]) > 50, Int(p[0]) - Int(p[2]) > 50 { return true }
            }
        }
        return false
    }
}
