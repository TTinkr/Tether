
import AppKit
import SwiftUI
import Testing
@testable import Tokens

struct PasteMarkerGeometryTests {
    // One 1440×900 primary screen with a 25-point menu bar.
    let visible = [CGRect(x: 0, y: 0, width: 1440, height: 875)]
    let size = CGSize(width: 110, height: 22)

    @Test func sitsJustAboveTheCaretWithItsLeftEdgeOnIt() throws {
        // AX caret 600 points from the top of the screen.
        let caret = CGRect(x: 400, y: 600, width: 0, height: 18)
        let origin = try #require(PasteMarkerGeometry.origin(anchor: caret, size: size, primaryHeight: 900, visibleFrames: visible))
        #expect(origin.x == 398)
        #expect(origin.y == 900 - 600 + PasteMarkerGeometry.gap)
    }

    @Test func dropsBelowACaretAtTheTopAndStaysOnScreen() throws {
        let top = CGRect(x: 1430, y: 30, width: 0, height: 18)
        let origin = try #require(PasteMarkerGeometry.origin(anchor: top, size: size, primaryHeight: 900, visibleFrames: visible))
        #expect(origin.y + size.height <= 875)
        #expect(origin.y < 900 - 30 - 18)
        #expect(origin.x + size.width <= 1440)
    }

    @Test func refusesEmptyOrOffscreenAnchors() {
        #expect(PasteMarkerGeometry.origin(anchor: .zero, size: size, primaryHeight: 900, visibleFrames: visible) == nil)
        #expect(PasteMarkerGeometry.origin(anchor: CGRect(x: 5000, y: 5000, width: 0, height: 18), size: size,
                                           primaryHeight: 900, visibleFrames: visible) == nil)
    }

    @Test func ignoresJitter() {
        let a = CGRect(x: 10, y: 10, width: 300, height: 60)
        #expect(!PasteMarkerGeometry.shouldMove(from: a, to: a.offsetBy(dx: 2, dy: 1)))
        #expect(PasteMarkerGeometry.shouldMove(from: a, to: a.offsetBy(dx: 20, dy: 0)))
        #expect(PasteMarkerGeometry.shouldMove(from: a, to: CGRect(x: 10, y: 10, width: 300, height: 80)))
        #expect(PasteMarkerGeometry.shouldMove(from: nil, to: a))
    }

    @Test func cornersHugAComposerWithRoomForTheLabel() throws {
        // A 600x80 composer whose top edge is 700 points below the top of the screen.
        let field = CGRect(x: 300, y: 700, width: 600, height: 80)
        let frame = try #require(PasteMarkerGeometry.cueFrame(field: field, primaryHeight: 900, visibleFrames: visible))
        let m = PasteMarkerGeometry.margin, o = PasteMarkerGeometry.outset
        #expect(frame.minX == 300 - o - m.width)
        #expect(frame.width == 600 + 2 * (o + m.width))
        #expect(frame.maxY == 900 - 700 + o + m.height)
        #expect(frame.height == 80 + 2 * (o + m.height))
    }

    @Test func aWholeDocumentPaneGetsNoCorners() {
        // An editor pane filling most of the screen is not a composer.
        #expect(PasteMarkerGeometry.cueFrame(field: CGRect(x: 0, y: 60, width: 1400, height: 780),
                                             primaryHeight: 900, visibleFrames: visible) == nil)
        #expect(PasteMarkerGeometry.cueFrame(field: CGRect(x: 0, y: 60, width: 20, height: 10),
                                             primaryHeight: 900, visibleFrames: visible) == nil)
        #expect(PasteMarkerGeometry.cueFrame(field: CGRect(x: 4000, y: 60, width: 300, height: 40),
                                             primaryHeight: 900, visibleFrames: visible) == nil)
    }

    @Test func defaultsOnAndRemembersOff() {
        let suite = "paste-marker-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Build 83: the pointer ring is its own switch; both start on and turn off separately.
        #expect(PasteCursorRingPreference.load(defaults))
        PasteCursorRingPreference.save(false, defaults)
        #expect(!PasteCursorRingPreference.load(defaults) && PasteMarkerPreference.load(defaults))
        PasteCursorRingPreference.save(true, defaults)
        #expect(PasteMarkerPreference.load(defaults))
        PasteMarkerPreference.save(false, defaults)
        #expect(!PasteMarkerPreference.load(defaults))
    }
}

/*
Renders at an exact pixel density. A Retina Mac gives every offscreen window a 2x backing, so
without this a "1x" proof would only be a shrunken Retina frame; overriding the window's scale
makes SwiftUI rasterise the text and dots at 1x (a plain display), 2x (Retina) or 8x (zoom).
*/
final class PasteMarkerRenderWindow: NSWindow {
    var scale: CGFloat = 2
    override var backingScaleFactor: CGFloat { scale }
}

@MainActor enum PasteMarkerPNG {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// `crop` is in the view's own top-left coordinates; nil renders the whole view.
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat, dark: Bool, crop: CGRect? = nil) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = PasteMarkerRenderWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                             backing: .buffered, defer: false)
        window.scale = scale
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        var rect = crop ?? host.bounds
        if let crop, !host.isFlipped { rect.origin.y = size.height - crop.maxY }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((rect.width * scale).rounded()),
                                                pixelsHigh: Int((rect.height * scale).rounded()), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = rect.size
        host.cacheDisplay(in: rect, to: rep)
        return rep
    }

    static func png(_ rep: NSBitmapImageRep) throws -> Data {
        try #require(rep.representation(using: .png, properties: [:]))
    }

    static func write(_ data: Data, _ name: String) throws {
        guard let out = outputDirectory else { return }
        try data.write(to: out.appendingPathComponent(name))
    }

    /// The bounds (points, top-left) of every pixel inside `region` more opaque than `minAlpha`, or nil if none.
    static func inkBounds(_ rep: NSBitmapImageRep, in region: CGRect, minAlpha: Double) -> CGRect? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        guard let data = rep.bitmapData else { return nil }
        let x0 = max(0, Int(region.minX * scale)), x1 = min(rep.pixelsWide, Int(region.maxX * scale))
        let y0 = max(0, Int(region.minY * scale)), y1 = min(rep.pixelsHigh, Int(region.maxY * scale))
        var b = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in y0..<y1 { for x in x0..<x1 where Double(data[y * rep.bytesPerRow + x * rep.samplesPerPixel + 3]) / 255 > minAlpha {
            b = (min(b.minX, x), min(b.minY, y), max(b.maxX, x), max(b.maxY, y))
        } }
        guard b.maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(b.minX) / scale, y: CGFloat(b.minY) / scale,
                      width: CGFloat(b.maxX + 1 - b.minX) / scale, height: CGFloat(b.maxY + 1 - b.minY) / scale)
    }

    struct Ink: Codable { var minX: Double, minY: Double, maxX: Double, maxY: Double }
    /// What a zoom crop measured, in points from the crop's top-left.
    struct LabelMeasure: Codable {
        var pi: Ink
        var capLetter: Ink
        /// Positive: π's ink top is below the cap line. Negative: above it.
        var piTopMinusCapLine: Double
        /// Positive: π's ink bottom is below the baseline.
        var piBottomMinusBaseline: Double
    }

    /*
    Finds the coral π mark and the first capital of the key name inside `band` (points, top-left)
    of an 8x zoom crop. Coral is red well above green and blue; key-name ink is neutral and far from
    the local background. The capital ("L" of Left Option) gives the cap line and the baseline.
    */
    static func measureLabel(_ rep: NSBitmapImageRep, band: CGRect) -> LabelMeasure? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        guard let data = rep.bitmapData else { return nil }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let p = data + y * bpr + x * spp
            return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
        }
        let x0 = max(0, Int(band.minX * scale)), x1 = min(rep.pixelsWide, Int(band.maxX * scale))
        let y0 = max(0, Int(band.minY * scale)), y1 = min(rep.pixelsHigh, Int(band.maxY * scale))
        let bg = rgb(x0, y0)
        let bgLum = 0.2126 * bg.0 + 0.7152 * bg.1 + 0.0722 * bg.2
        func coral(_ c: (Double, Double, Double)) -> Bool { c.0 - c.1 > 0.2 && c.0 - c.2 > 0.2 }
        func neutralInk(_ c: (Double, Double, Double)) -> Bool {
            let lum = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
            return abs(c.0 - c.1) < 0.08 && abs(c.1 - c.2) < 0.08 && abs(lum - bgLum) > 0.22
        }
        // Build 79: π and key name share the coral, so π is the first run of inked columns and the
        // capital is the next run after the gap between them (neutral ink still counts for older looks).
        func inked(_ x: Int) -> Bool { (y0..<y1).contains { coral(rgb(x, $0)) || neutralInk(rgb(x, $0)) } }
        guard let piStart = (x0..<x1).first(where: inked) else { return nil }
        guard let piEnd = (piStart..<x1).first(where: { !inked($0) }) else { return nil }
        guard let start = (piEnd..<x1).first(where: inked) else { return nil }
        let end = min(x1, start + Int(3.2 * scale))
        var cap = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in y0..<y1 { for x in start..<end where coral(rgb(x, y)) || neutralInk(rgb(x, y)) {
            cap = (min(cap.minX, x), min(cap.minY, y), max(cap.maxX, x), max(cap.maxY, y))
        } }
        guard cap.maxX >= 0 else { return nil }
        // π only above the corner's dotted arm, which stands just below the label in the same columns.
        let piRows = y0..<min(y1, cap.maxY + 1 + Int(0.5 * scale))
        var pi = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in piRows { for x in piStart..<piEnd where coral(rgb(x, y)) {
            pi = (min(pi.minX, x), min(pi.minY, y), max(pi.maxX, x), max(pi.maxY, y))
        } }
        guard pi.maxX >= 0, pi.maxX + 1 < x1 else { return nil }
        guard cap.maxX >= 0 else { return nil }
        func ink(_ b: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> Ink {
            Ink(minX: Double(b.minX) / scale, minY: Double(b.minY) / scale,
                maxX: Double(b.maxX + 1) / scale, maxY: Double(b.maxY + 1) / scale)
        }
        let p = ink(pi), l = ink(cap)
        return LabelMeasure(pi: p, capLetter: l, piTopMinusCapLine: p.minY - l.minY, piBottomMinusBaseline: p.maxY - l.maxY)
    }

    /// The zoom crop with its measured guides: blue cap line and baseline, pink box around π.
    static func guides(_ rep: NSBitmapImageRep, _ m: LabelMeasure) throws -> Data {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let copy = try #require(rep.copy() as? NSBitmapImageRep)
        copy.size = NSSize(width: copy.pixelsWide, height: copy.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: copy))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let height = CGFloat(copy.pixelsHigh)
        // Pixels, flipped to a top-left origin.
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSRect {
            NSRect(x: CGFloat(x), y: height - CGFloat(y) - CGFloat(h), width: CGFloat(w), height: CGFloat(h))
        }
        NSColor.systemBlue.withAlphaComponent(0.75).setFill()
        rect(0, m.capLetter.minY * scale - 1, Double(copy.pixelsWide), 2).fill()
        rect(0, m.capLetter.maxY * scale - 1, Double(copy.pixelsWide), 2).fill()
        NSColor.systemPink.setStroke()
        let box = NSBezierPath(rect: rect(m.pi.minX * scale, m.pi.minY * scale,
                                          (m.pi.maxX - m.pi.minX) * scale, (m.pi.maxY - m.pi.minY) * scale))
        box.lineWidth = 2
        box.stroke()
        context.flushGraphics()
        return try png(copy)
    }
}

/// A fictional composer with a visible caret: before the placeholder when empty, after the last word when filled.
struct PasteMarkerRenderHost: View {
    static let size = CGSize(width: 560, height: 180)
    /// The composer's frame in the host.
    static let composer = CGRect(x: 32, y: 32, width: 480, height: 110)
    /// The top-left corner at 8x: the label, the dotted arm below it, the caret and the placeholder start.
    static let zoomCrop = CGRect(x: 16, y: 8, width: 96, height: 56)
    /// Where the label can be inside the zoom crop: above the first dot of the top-left arm and the placeholder.
    static let labelBand = CGRect(x: 0, y: 0, width: 96, height: 18.5)

    let filled: Bool
    /// The marker's own appearance (the system's); nil follows the composer's.
    var markerScheme: ColorScheme?

    private var caret: some View {
        Rectangle().fill(Color.primary).frame(width: 1, height: 16)
    }

    var body: some View {
        let cueInset = PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.width
        let cueTop = PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.height
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if filled {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep the next step simple,")
                            HStack(spacing: 1) { Text("then show the result."); caret }
                        }
                        .foregroundStyle(Color.primary)
                    } else {
                        HStack(spacing: 0) { caret; Text("Write a message…").foregroundStyle(Color.secondary) }
                    }
                }
                .font(.system(size: 13))
                .padding(.top, 14).padding(.leading, 16)
                Spacer()
                HStack {
                    Image(systemName: "plus").padding(8).background(Circle().fill(Color.primary.opacity(0.07)))
                    Spacer()
                    Image(systemName: "arrow.up").padding(8).background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .padding(10)
            }
            .frame(width: Self.composer.width, height: Self.composer.height)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            // The real overlay panel sits outset by the cue margin around the box.
            Group {
                if let markerScheme {
                    PasteMarkerView(shortcutName: "Left Option").environment(\.colorScheme, markerScheme)
                } else {
                    PasteMarkerView(shortcutName: "Left Option")
                }
            }
            .frame(width: Self.composer.width + 2 * cueInset, height: Self.composer.height + 2 * cueTop)
            .offset(x: -cueInset, y: -cueTop)
        }
        .padding(.top, Self.composer.minY).padding(.leading, Self.composer.minX)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@Suite(.serialized) @MainActor struct PasteMarkerRenderTests {
    @Test func rendersAtActualScaleInLightAndDark() throws {
        for dark in [false, true] { for filled in [false, true] { for scale in [CGFloat(1), 2] {
            let host = PasteMarkerRenderHost(filled: filled).preferredColorScheme(dark ? .dark : .light)
            let rep = try PasteMarkerPNG.render(host, size: PasteMarkerRenderHost.size, scale: scale, dark: dark)
            #expect(rep.pixelsWide == Int(PasteMarkerRenderHost.size.width * scale))
            let data = try PasteMarkerPNG.png(rep)
            #expect(data.count > 1000)
            try PasteMarkerPNG.write(data, "cue-\(dark ? "dark" : "light")-\(filled ? "filled" : "empty")@\(Int(scale))x.png")
        } } }
    }

    /*
    Build 81: a one-line composer (the AX text element of an empty Claude or Codex composer is a
    single line, about 22 points tall). The side arms used to be a third of the height, four or
    five dots per corner; now each end is a bracket whose dots run the box's whole height.
    */
    @Test func oneLineComposerGetsWholeBrackets() throws {
        let field = CGSize(width: 600, height: 22)
        let cue = CGSize(width: field.width + 2 * PasteMarkerGeometry.outset, height: field.height + 2 * PasteMarkerGeometry.outset)
        #expect(CornerCues.arms(CGRect(origin: .zero, size: cue)).down >= cue.height / 2)
        #expect(CornerCues.arms(CGRect(origin: .zero, size: cue)).across == CornerCues.armLength)
        #expect(CornerCues.arms(CGRect(x: 0, y: 0, width: 400, height: 120)) == (CornerCues.armLength, CornerCues.armLength))
        let panel = CGSize(width: cue.width + 2 * PasteMarkerGeometry.margin.width, height: cue.height + 2 * PasteMarkerGeometry.margin.height)
        let size = CGSize(width: panel.width + 40, height: panel.height + 40)
        for dark in [false, true] {
            let view = ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: field.width + 40, height: field.height + 28)
                    .offset(x: 20 + PasteMarkerGeometry.margin.width - 16, y: 20 + PasteMarkerGeometry.margin.height - 10)
                PasteMarkerView(shortcutName: "Left Option")
                    .frame(width: panel.width, height: panel.height)
                    .offset(x: 20, y: 20)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light)
            let rep = try PasteMarkerPNG.render(view, size: size, scale: 2, dark: dark)
            try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), "cue-oneline-\(dark ? "dark" : "light")@2x.png")
            // The left bracket: coral dots from the top line to the bottom line of the cue.
            let left = CGRect(x: 20 + PasteMarkerGeometry.margin.width - 2, y: 20 + PasteMarkerGeometry.margin.height - 2,
                              width: 4, height: cue.height + 4)
            let ink = try #require(PasteMarkerPNG.inkBounds(rep, in: left, minAlpha: 0.5))
            #expect(ink.height >= cue.height - 3, "left bracket covers \(ink.height) of \(cue.height)")
        }
    }

    /// The marker follows the system appearance, which need not match the app underneath it.
    @Test func rendersOverAComposerOfTheOtherAppearance() throws {
        for dark in [false, true] {
            let host = PasteMarkerRenderHost(filled: true, markerScheme: dark ? .light : .dark)
                .preferredColorScheme(dark ? .dark : .light)
            let name = "cue-mismatch-\(dark ? "light-marker-on-dark" : "dark-marker-on-light")"
            let rep = try PasteMarkerPNG.render(host, size: PasteMarkerRenderHost.size, scale: 2, dark: dark)
            try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), name + "@2x.png")
            let zoom = try PasteMarkerPNG.render(host, size: PasteMarkerRenderHost.size, scale: 8, dark: dark,
                                                 crop: PasteMarkerRenderHost.zoomCrop)
            try PasteMarkerPNG.write(try PasteMarkerPNG.png(zoom), name + "-zoom@8x.png")
        }
    }

    @Test func zoomsIntoTheLabelCorner() throws {
        for dark in [false, true] {
            let host = PasteMarkerRenderHost(filled: false).preferredColorScheme(dark ? .dark : .light)
            let rep = try PasteMarkerPNG.render(host, size: PasteMarkerRenderHost.size, scale: 8, dark: dark,
                                                crop: PasteMarkerRenderHost.zoomCrop)
            #expect(rep.pixelsWide == Int(PasteMarkerRenderHost.zoomCrop.width * 8))
            let name = "cue-zoom-\(dark ? "dark" : "light")@8x"
            try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), name + ".png")
            let measure = try #require(PasteMarkerPNG.measureLabel(rep, band: PasteMarkerRenderHost.labelBand))
            try PasteMarkerPNG.write(try PasteMarkerPNG.guides(rep, measure), name + "-guides.png")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try PasteMarkerPNG.write(try encoder.encode(measure), name + "-measure.json")
            // π stands on the key name's baseline and its flat top meets the cap line (two 8x pixels of slack).
            // The π stands 1.2 capitals tall (build 79), so its top rises above the cap line by about 0.2 of a capital.
            let rise = -measure.piTopMinusCapLine, cap = NSFont.systemFont(ofSize: PasteMarkerLabel.keySize, weight: .semibold).capHeight
            #expect(abs(rise - (PasteMarkerLabel.piTall - 1) * cap) <= 0.5, "π rise above cap line: \(rise)")
            #expect(abs(measure.piBottomMinusBaseline) <= 0.25, "π bottom vs baseline: \(measure.piBottomMinusBaseline)")
            // Unboxed: about 1.2 capitals of π, not a 14-point disc.
            #expect(measure.pi.maxY - measure.pi.minY < 13)
        }
    }

    /*
    The label sits wholly above the text box: nothing of it, halo included, enters the box, so it
    can never cover a caret, placeholder or typed words; and its ink stays inside the room the
    screen-edge check reserves for it.
    */
    @Test func labelNeverEntersTheBox() throws {
        let o = PasteMarkerGeometry.outset, m = PasteMarkerGeometry.margin
        let box = CGRect(x: o + m.width, y: o + m.height, width: 320, height: 80)
        let size = CGSize(width: box.width + 2 * box.minX, height: box.height + 2 * box.minY)
        for dark in [false, true] { for name in ["Left Option", "Right Option", "Right Command"] {
            let view = PasteMarkerView(shortcutName: name).environment(\.colorScheme, dark ? .dark : .light)
            let rep = try PasteMarkerPNG.render(view, size: size, scale: 8, dark: dark)
            try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), "label-\(name)-\(dark ? "dark" : "light")@8x.png")
            #expect(PasteMarkerPNG.inkBounds(rep, in: box, minAlpha: 0.02) == nil, "marker ink inside the box")
            let label = try #require(PasteMarkerPNG.inkBounds(rep, in: CGRect(x: 0, y: 0, width: size.width / 2, height: box.minY),
                                                               minAlpha: 0.05))
            #expect(label.minY >= PasteMarkerGeometry.labelTopInset, "label top \(label.minY)")
            #expect(label.minX >= PasteMarkerGeometry.labelLeadingInset)
            #expect(label.width > 40 && label.width < 125, "label width \(label.width)")   // wider since RC5: a larger π and a 4 pt gap
        } }
    }
}

/// The key name adjusts to the background: coral on dark, the quiet grey on light (build 80).
@Suite struct PasteMarkerKeyInkTests {
    @Test func coralOnDarkGreyOnLight() {
        #expect(pasteMarkerKeyInk(.dark) != pasteMarkerKeyInk(.light))
        #expect(NSColor(pasteMarkerKeyInk(.light)).usingColorSpace(.sRGB)!.redComponent < 0.5)
        #expect(NSColor(pasteMarkerKeyInk(.dark)).usingColorSpace(.sRGB)!.redComponent > 0.8)
    }
}

/*
The π beside "Right Option" looked odd and needed to be larger. A comparison sheet
of π styles over light and dark composers (written to TOKENS_FIRSTUSE_RENDER_DIR when set), and
for every style the label stays whole inside the panel's room above the corner.
*/
@Suite(.serialized) @MainActor struct PasteMarkerPiStyleTests {
    static let candidates: [(String, PasteMarkerPiStyle)] = [
        ("build81", .build81),
        ("t14-a80-g4", PasteMarkerPiStyle(tall: 1.4, aspect: 0.8, gap: 4)),
        ("t15-a75-g4", PasteMarkerPiStyle(tall: 1.5, aspect: 0.75, gap: 4)),
        ("t15-a80-g4", PasteMarkerPiStyle(tall: 1.5, aspect: 0.8, gap: 4)),
        ("t15-a90-g4", PasteMarkerPiStyle(tall: 1.5, aspect: 0.9, gap: 4)),
        ("t16-a80-g4", PasteMarkerPiStyle(tall: 1.6, aspect: 0.8, gap: 4)),
    ]
    static let names = ["Right Option", "Left Option", "F5", "Right Command"]

    /// One framed marker's top-left corner over a fictional composer, label above it.
    struct Cell: View {
        let name: String
        let pi: PasteMarkerPiStyle
        let dark: Bool
        static let size = CGSize(width: 200, height: 70)
        var body: some View {
            let inset = PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.width
            let top = PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.height
            ZStack(alignment: .topLeading) {
                (dark ? Color(white: 0.11) : Color(white: 0.96))
                RoundedRectangle(cornerRadius: 12)
                    .fill(dark ? Color(white: 0.19) : Color.white)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .offset(x: inset, y: top)
                PasteMarkerView(shortcutName: name, framed: true, pi: pi)
                    .frame(width: Self.size.width + 2 * inset, height: Self.size.height + 2 * top)
            }
            .frame(width: Self.size.width + 2 * inset, height: Self.size.height + top, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    @Test func everyStyleStaysWholeInsideThePanel() throws {
        let rise = { (pi: PasteMarkerPiStyle) in max(pi.size.height + PasteMarkerLabel.piLine, PasteMarkerLabel.capHeight) + PasteMarkerLabel.haloRoom }
        for (label, pi) in Self.candidates {
            #expect(PasteMarkerGeometry.labelBaseline - rise(pi) >= 0, "\(label) rises past the panel top")
        }
        #expect(PasteMarkerGeometry.labelTopInset >= 0)
        #expect(PasteMarkerLabel.piStyle == .chosen)
        // Larger than build 81 in both directions, and wider apart.
        #expect(PasteMarkerPiStyle.chosen.size.height > PasteMarkerPiStyle.build81.size.height)
        #expect(PasteMarkerPiStyle.chosen.size.width > PasteMarkerPiStyle.build81.size.width)
        #expect(PasteMarkerPiStyle.chosen.gap > PasteMarkerPiStyle.build81.gap)
    }

    @Test func comparisonSheet() throws {
        let rows = VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.candidates, id: \.0) { label, pi in
                HStack(alignment: .top, spacing: 10) {
                    Text(label).font(.system(size: 11, design: .monospaced)).frame(width: 90, alignment: .leading)
                    ForEach(Self.names, id: \.self) { name in
                        VStack(spacing: 4) { Cell(name: name, pi: pi, dark: false); Cell(name: name, pi: pi, dark: true) }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.25))
        let cellWidth = Cell.size.width + 2 * (PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.width)
        let cellHeight = Cell.size.height + PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.height
        let size = CGSize(width: 24 + 100 + CGFloat(Self.names.count) * (cellWidth + 10),
                          height: 24 + CGFloat(Self.candidates.count) * (2 * cellHeight + 14))
        for scale in [1, 2] as [CGFloat] {
            let rep = try PasteMarkerPNG.render(rows, size: size, scale: scale, dark: false)
            #expect(rep.pixelsWide == Int(size.width * scale))
            try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), "pi-sheet@\(Int(scale))x.png")
        }
        // 8x zooms of the label corner for the old and the chosen style, light and dark.
        for (label, pi) in [("build81", PasteMarkerPiStyle.build81), ("chosen", PasteMarkerPiStyle.chosen)] {
            for dark in [false, true] {
                let rep = try PasteMarkerPNG.render(Cell(name: "Right Option", pi: pi, dark: dark), size: CGSize(width: cellWidth, height: cellHeight),
                                                    scale: 8, dark: dark, crop: CGRect(x: 0, y: 0, width: 130, height: 40))
                try PasteMarkerPNG.write(try PasteMarkerPNG.png(rep), "pi-\(label)-\(dark ? "dark" : "light")@8x.png")
            }
        }
    }
}
