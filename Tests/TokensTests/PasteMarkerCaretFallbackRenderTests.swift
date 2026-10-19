
import AppKit
import SwiftUI
import Testing
@testable import Tokens

private struct CaretFallbackEdgeFixture: View {
    let field: CGRect
    let caret: CGRect
    let label: CGRect
    let viewport: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(Color.secondary.opacity(0.14)).frame(height: 24)
            Text("Outside the visible screen area")
                .font(.system(size: 9)).foregroundStyle(.secondary).offset(x: 20, y: 6)
            Rectangle().fill(Color.red.opacity(0.5)).frame(height: 1).offset(y: 24)
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.35)))
                .frame(width: field.width, height: field.height)
                .offset(x: field.minX, y: field.minY)
            Text("Fictional composer")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .offset(x: field.minX + 12, y: field.maxY - 20)
            Rectangle().fill(Color.primary).frame(width: 1, height: caret.height)
                .offset(x: caret.minX, y: caret.minY)
            PasteMarkerView(shortcutName: "Left Option", framed: false)
                .frame(width: label.width, height: label.height)
                .offset(x: label.minX, y: label.minY)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
    }
}

@Suite(.serialized) @MainActor struct PasteMarkerCaretFallbackRenderTests {
    /*
    Codex RC4 live QA: a whole-document field (too_big 571x560) logged "cue=0x0" and showed
    nothing. The panel's hosting view has no sizing options, and such a view reports a zero
    fitting size; show() sized the caret label from it. The label is now measured on its own.
    */
    @Test func caretLabelIsNeverZeroSized() throws {
        _ = NSApplication.shared
        let panelLike = NSHostingView(rootView: PasteMarkerView(shortcutName: "Left Option", framed: false))
        panelLike.sizingOptions = []
        // The cause: sized like the panel's view, it reports no size at all.
        #expect(panelLike.fittingSize.width < 1 || panelLike.fittingSize.height < 1)
        for name in ["Left Option", "Right Option", "F5", "Right Command"] {
            let size = PasteMarker.caretLabelSize(shortcutName: name)
            #expect(size.width >= 20 && size.height >= 12, "\(name): \(size)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Features/Bubble/PasteMarker.swift"), encoding: .utf8)
        #expect(source.contains("let size = Self.caretLabelSize(shortcutName: shortcutName)"))
        #expect(!source.contains("hosting?.fittingSize"))
    }

    @Test func rendersVerifiedCaretFallbackAtActualDisplayTopEdges() throws {
        _ = NSApplication.shared
        let screens = NSScreen.screens
        let primary = try #require(screens.first)
        let primaryHeight = primary.frame.maxY
        let labelHost = NSHostingView(rootView: PasteMarkerView(shortcutName: "Left Option", framed: false))
        let labelSize = labelHost.fittingSize
        #expect(labelSize.width > 0 && labelSize.height > 0)

        for (index, screen) in screens.enumerated() {
            // Real visible frame and physical frame, modelling menu-bar and fullscreen edges.
            for (mode, visible) in [("visible", screen.visibleFrame), ("fullscreen", screen.frame)] {
                let field = CGRect(x: visible.minX + 40, y: visible.maxY - 80,
                                   width: min(600, visible.width - 80), height: 80)
                let caret = CGRect(x: field.minX + 12, y: field.maxY - 21, width: 0, height: 18)
                let axField = PasteMarkerGeometry.flip(field, primaryHeight: primaryHeight)
                let axCaret = PasteMarkerGeometry.flip(caret, primaryHeight: primaryHeight)
                #expect(PasteMarkerGeometry.cueFrame(field: axField, primaryHeight: primaryHeight,
                                                     visibleFrames: [visible]) == nil)
                let origin = try #require(PasteMarkerGeometry.origin(anchor: axCaret, size: labelSize,
                    primaryHeight: primaryHeight, visibleFrames: [visible]))
                let label = CGRect(origin: origin, size: labelSize)
                #expect(visible.contains(label))
                #expect(label.maxY < caret.minY)

                // Crop around a fictional composer; the upper 24 points show the excluded area.
                let crop = CGRect(x: field.minX - 20, y: field.minY - 35,
                                  width: field.width + 40, height: field.height + 59)
                func local(_ rect: CGRect) -> CGRect {
                    CGRect(x: rect.minX - crop.minX, y: crop.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
                }
                for scheme in [ColorScheme.light, .dark] {
                    let fixture = CaretFallbackEdgeFixture(field: local(field), caret: local(caret),
                        label: local(label), viewport: crop.size).preferredColorScheme(scheme)
                    let name = "caret-fallback-screen-\(index)-\(mode)-\(scheme == .dark ? "dark" : "light")"
                    // Actual scale on a plain display and on Retina, then an 8x zoom of the label over the caret.
                    for scale in [CGFloat(1), 2] {
                        let rep = try PasteMarkerPNG.render(fixture, size: crop.size, scale: scale, dark: scheme == .dark)
                        let png = try PasteMarkerPNG.png(rep)
                        #expect(png.count > 500)
                        try PasteMarkerPNG.write(png, "\(name)@\(Int(scale))x.png")
                    }
                    let zoom = local(label).union(local(caret)).insetBy(dx: -10, dy: -8)
                        .intersection(CGRect(origin: .zero, size: crop.size))
                    let rep = try PasteMarkerPNG.render(fixture, size: crop.size, scale: 8, dark: scheme == .dark, crop: zoom)
                    try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), "\(name)-zoom@8x.png")
                }
            }
        }
    }
}
