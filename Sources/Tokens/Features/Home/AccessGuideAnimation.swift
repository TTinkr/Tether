


//
import AppKit
import SwiftUI

/// Which picture the Access step shows. The three lists all live under Privacy & Security;
/// `prompt` is the alert macOS shows the first time an app asks for the microphone.
enum AccessGuidePane: String, CaseIterable {
    case accessibility, microphone, speechRecognition, prompt

    /// The list's title in the drawn settings window.
    var listTitle: String {
        switch self {
        case .accessibility:     return "Accessibility"
        case .microphone:        return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .prompt:            return "Microphone"
        }
    }

    /// The words under the picture. The first-run alert covers both audio permissions only when
    /// the selected engine needs Apple Speech; Orukeet needs the microphone alone.
    func caption(speechRequired: Bool = true) -> String {
        self == .prompt && speechRequired ? "Microphone and Speech Recognition" : listTitle
    }

    /// What the picture shows, for VoiceOver.
    func spokenDescription(appName: String) -> String {
        switch self {
        case .prompt:
            return "Animation: when macOS asks whether \(appName) may use the microphone, click Allow."
        default:
            return "Animation: in System Settings, Privacy & Security, \(listTitle), turn on the switch next to \(appName)."
        }
    }
}

/// One moment of the loop as plain numbers (0…1), so the live loop, the Reduce Motion still and
/// proof frames all draw from the same curve.
struct AccessGuidePose: Equatable {
    /// 0 at the start point, 1 on the switch (or the Allow button).
    var travel: Double = 0
    var pointerOpacity: Double = 0
    /// 0…1…0 while the click is pressed.
    var press: Double = 0
    /// 0 → 1 as the click's ring grows; drawn only strictly between the two.
    var ripple: Double = 0
    /// 0 off → 1 on.
    var on: Double = 0
    /// 1 through the loop; falls to 0 as the picture crossfades back to its start.
    var reset: Double = 1
    /// After the click the pointer eases a little aside so the switch shows.
    var drift: Double = 0
    var checkScale: Double = 0
    var checkOpacity: Double = 0
}

enum AccessGuideTimeline {
    /// One loop, in seconds.
    static let cycle: Double = 5.0
    /// The finished picture (switch on, check shown); Reduce Motion holds here.
    static let still: Double = 3.2

    static func pose(at time: Double) -> AccessGuidePose {
        var t = time.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        let checkIn = span(t, 2.05, 2.45)
        let fadeOut = 1 - span(t, 4.0, 4.4)
        return AccessGuidePose(
            travel: easeInOut(span(t, 0.45, 1.55)),
            pointerOpacity: easeOut(span(t, 0.1, 0.4)) * fadeOut,
            press: sin(span(t, 1.62, 1.86) * .pi),
            ripple: span(t, 1.70, 2.25),
            on: easeOut(span(t, 1.74, 1.98)),
            reset: 1 - span(t, 4.45, 4.75),
            drift: easeInOut(span(t, 2.35, 2.95)),
            checkScale: 0.55 + 0.45 * easeOutBack(checkIn),
            checkOpacity: easeOut(checkIn) * fadeOut)
    }

    static func span(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    /// A small overshoot so the check settles rather than snapping.
    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.2, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

//
// :)
//

/// The looping picture at a given width. Reduce Motion (or a proof pin) draws one still moment.
struct AccessGuideAnimation: View {
    let pane: AccessGuidePane
    let width: CGFloat
    var name: String = appName
    /// False for an engine without Apple Speech (Orukeet): the caption names the microphone only.
    var speechRequired = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    static func height(for width: CGFloat) -> CGFloat {
        (width * AccessGuideScene.base.height / AccessGuideScene.base.width).rounded()
    }

    /// `--access-guide-time SECONDS` pins the loop for offscreen proof frames only.
    static let pinnedTime: Double? = pinned(arguments: ProcessInfo.processInfo.arguments, allowed: ProofRoutes.isAllowed)

    static func pinned(arguments: [String], allowed: Bool) -> Double? {
        guard allowed, arguments.contains("--render-preview-frames"),
              let flag = arguments.firstIndex(of: "--access-guide-time"), flag + 1 < arguments.count,
              let seconds = Double(arguments[flag + 1]), seconds.isFinite else { return nil }
        return seconds
    }

    var body: some View {
        Group {
            if let fixed = Self.pinnedTime ?? (reduceMotion ? AccessGuideTimeline.still : nil) {
                AccessGuideScene(pane: pane, pose: AccessGuideTimeline.pose(at: fixed), name: name,
                                 speechRequired: speechRequired)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    AccessGuideScene(pane: pane,
                                     pose: AccessGuideTimeline.pose(at: context.date.timeIntervalSince(start)),
                                     name: name, speechRequired: speechRequired)
                }
            }
        }
        .frame(width: width, height: Self.height(for: width))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pane.spokenDescription(appName: name))
        .accessibilityAddTraits(.isImage)
    }
}

//
// :)
//

/*
A faithful replica of macOS 26 System Settings (a faithful,
version-labelled replica of the real System Settings; do not invent UI). Geometry, type and
colours are measured from macOS 26.6.2 dark captures (pixels / 2); the light appearance is derived
from them with Apple's standard light system colours and still needs a real light capture.
Inside the window: system colours only, chosen by the Mac's own appearance, never the Tokens theme;
no graph paper, no red. Other apps are unnamed placeholder rows; the only named row is Tokens.
Outside the window, on the theme's board: the caption (the pane) and the provenance label.
Everything is drawn in window points and scaled onto the 320 × 210 board.
*/
/// One frame of the guide. Pure: the same pose and appearance always draw the same picture.
struct AccessGuideScene: View {
    let pane: AccessGuidePane
    let pose: AccessGuidePose
    var name: String = appName
    var speechRequired = true
    /// The Mac's appearance (not the Tokens theme) picks the replica's dark or light colours.
    var dark: Bool = AccessGuideScene.systemIsDark

    static let base = CGSize(width: 320, height: 210)
    /// The replica window in macOS points (System Settings' fixed width, a short height).
    static let windowSize = CGSize(width: 723, height: 420)
    static let windowScale: CGFloat = 316 / 723
    static let windowOrigin = CGPoint(x: 2, y: 3)
    /// The alert, in its own points, and where it sits on the board.
    static let alertSize = CGSize(width: 260, height: 240)
    static let alertScale: CGFloat = 0.66
    static var alertOrigin: CGPoint {
        CGPoint(x: (base.width - alertSize.width * alertScale) / 2, y: 8)
    }

    /// `--access-guide-appearance light|dark` pins the replica for offscreen proof frames only.
    static let pinnedAppearance: Bool? = pinnedDark(arguments: ProcessInfo.processInfo.arguments, allowed: ProofRoutes.isAllowed)

    static func pinnedDark(arguments: [String], allowed: Bool) -> Bool? {
        guard allowed, arguments.contains("--render-preview-frames"),
              let flag = arguments.firstIndex(of: "--access-guide-appearance"), flag + 1 < arguments.count else { return nil }
        switch arguments[flag + 1] { case "dark": return true; case "light": return false; default: return nil }
    }

    /// The system-wide appearance setting, unaffected by the app's own theme.
    static var systemIsDark: Bool {
        pinnedAppearance ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / Self.base.width, size.height / Self.base.height)
            context.scaleBy(x: scale, y: scale)
            Self.draw(&context, pane: pane, pose: pose, name: name, dark: dark, speechRequired: speechRequired)
        }
    }

    // MARK: Layout in window points (measured from the macOS 26.6.2 captures)

    /// The Tokens row's centre in each list.
    static func tokensRowY(_ pane: AccessGuidePane) -> CGFloat {
        switch pane {
        case .accessibility:     return windowSize.height - 36
        case .microphone, .prompt: return 61 + 43 * 4
        case .speechRecognition: return 127 + 43 * 3
        }
    }
    static let switchX: CGFloat = 656.5
    static func switchCenter(_ pane: AccessGuidePane) -> CGPoint { CGPoint(x: switchX + 18, y: tokensRowY(pane) + 0.75) }
    /// The alert's Allow button, in alert points.
    static let allowButton = CGRect(x: 136, y: 190, width: 108, height: 28)

    /// Where the pointer's tip is for this pose, in window (or alert) points.
    static func pointerTip(pane: AccessGuidePane, pose: AccessGuidePose) -> CGPoint {
        let target = pane == .prompt ? CGPoint(x: allowButton.midX - 6, y: allowButton.midY - 2)
                                     : CGPoint(x: switchCenter(pane).x, y: switchCenter(pane).y + 1)
        let start = pane == .prompt ? CGPoint(x: target.x - 120, y: target.y + 40)
                                    : CGPoint(x: target.x - 190, y: target.y + (pane == .accessibility ? -70 : 80))
        let p = CGFloat(pose.travel)
        let arc = -sin(p * .pi) * 24
        let drift = CGFloat(pose.drift)
        return CGPoint(x: start.x + (target.x - start.x) * p + 7 * drift,
                       y: start.y + (target.y - start.y) * p + arc + 9 * drift)
    }

    // MARK: Drawing

    static func draw(_ context: inout GraphicsContext, pane: AccessGuidePane, pose: AccessGuidePose, name: String, dark: Bool,
                     speechRequired: Bool = true) {
        let c = Palette(dark: dark)
        // The board: the theme's paper under a hairline. Outside the window only.
        let board = Path(roundedRect: CGRect(origin: .zero, size: base), cornerRadius: 12, style: .continuous)
        context.fill(board, with: .color(TokensUI.paper))
        context.stroke(board, with: .color(TokensUI.hairline), lineWidth: 1)

        let caption = pane.caption(speechRequired: speechRequired)
        let provenance: String
        if pane == .prompt {
            provenance = "macOS 26 alert \u{00B7} illustration"
            var alert = context
            alert.translateBy(x: alertOrigin.x, y: alertOrigin.y)
            alert.scaleBy(x: alertScale, y: alertScale)
            drawAlert(&alert, pose: pose, name: name, c: c)
            drawPointer(&alert, at: pointerTip(pane: pane, pose: pose), pose: pose)
        } else {
            provenance = "macOS 26 System Settings \u{00B7} illustration"
            var window = context
            window.translateBy(x: windowOrigin.x, y: windowOrigin.y)
            window.scaleBy(x: windowScale, y: windowScale)
            drawWindow(&window, pane: pane, pose: pose, name: name, c: c)
            drawPointer(&window, at: pointerTip(pane: pane, pose: pose), pose: pose)
        }
        let y = base.height - 9.5
        text(&context, caption, size: 8.5, weight: .semibold, TokensUI.ink, at: CGPoint(x: 6, y: y))
        text(&context, provenance, size: 7.5, weight: .regular, TokensUI.secondary, at: CGPoint(x: base.width - 6, y: y), anchor: .trailing)
    }

    /// macOS system colours. Dark: measured. Light: derived (Apple's standard light values).
    struct Palette {
        let frame, content, side, sideEdge, field, group, sep, bar: Color
        let label, label2, label3, title, glyph, glyphOff, plusMinus: Color
        let capsule, capsuleEdge, selection, phTop, phBottom, phBar: Color
        let on, knobOn, off, knobOff, outline, alert: Color
        init(dark: Bool) {
            func hex(_ v: UInt32, _ a: Double = 1) -> Color {
                Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255, opacity: a)
            }
            if dark {
                frame = hex(0x323232); content = hex(0x343434); side = hex(0x252525); sideEdge = hex(0xFFFFFF, 0.07)
                field = hex(0x343434); group = hex(0x3B3B3B); sep = hex(0x444444); bar = hex(0x393939)
                label = hex(0xE4E4E4); label2 = hex(0xA7A7A7); label3 = hex(0x8C8C8C); title = hex(0xE8E8E8)
                glyph = hex(0xDCDCDC); glyphOff = hex(0x7A7A7A); plusMinus = hex(0xBEBEBE)
                capsule = hex(0x383838); capsuleEdge = hex(0xFFFFFF, 0.12); selection = hex(0x2458CA)
                phTop = hex(0x6A6A6A); phBottom = hex(0x595959); phBar = hex(0xFFFFFF, 0.15)
                on = hex(0x387BF5); knobOn = hex(0xE1EBFE); off = hex(0xFFFFFF, 0.14); knobOff = hex(0xDADADA)
                outline = hex(0xFFFFFF, 0.17); alert = hex(0x303030)
            } else {
                frame = hex(0xECECEC); content = hex(0xF2F2F2); side = hex(0xE3E3E3); sideEdge = hex(0x000000, 0.06)
                field = hex(0xD9D9D9); group = hex(0xE8E8E8); sep = hex(0xD3D3D3); bar = hex(0xE4E4E4)
                label = hex(0x262626); label2 = hex(0x7F7F7F); label3 = hex(0x8A8A8A); title = hex(0x1F1F1F)
                glyph = hex(0x3C3C3C); glyphOff = hex(0xB4B4B4); plusMinus = hex(0x555555)
                capsule = hex(0xF7F7F7); capsuleEdge = hex(0x000000, 0.09); selection = hex(0x2F78F0)
                phTop = hex(0xC4C4C4); phBottom = hex(0xB3B3B3); phBar = hex(0x000000, 0.14)
                on = hex(0x387BF5); knobOn = hex(0xFFFFFF); off = hex(0x000000, 0.09); knobOff = hex(0xFFFFFF)
                outline = hex(0x000000, 0.18); alert = hex(0xF2F2F2)
            }
        }
    }

    private static func rect(_ context: inout GraphicsContext, _ r: CGRect, radius: CGFloat = 0, _ color: Color) {
        context.fill(radius > 0 ? Path(roundedRect: r, cornerRadius: radius, style: .circular) : Path(r), with: .color(color))
    }

    private static func text(_ context: inout GraphicsContext, _ string: String, size: CGFloat, weight: Font.Weight,
                             _ color: Color, at point: CGPoint, anchor: UnitPoint = .leading, tracking: CGFloat = 0) {
        let resolved = context.resolve(Text(string).font(.system(size: size, weight: weight)).tracking(tracking).foregroundStyle(color))
        context.draw(resolved, at: point, anchor: anchor)
    }

    /// Text placed by its baseline, the way the captures were measured.
    private static func label(_ context: inout GraphicsContext, _ string: String, size: CGFloat = 13.5, weight: Font.Weight = .regular,
                              _ color: Color, x: CGFloat, baseline: CGFloat, anchor: UnitPoint = .leading) {
        let resolved = context.resolve(Text(string).font(.system(size: size, weight: weight)).tracking(-0.02 * size).foregroundStyle(color))
        let firstBaseline = resolved.firstBaseline(in: CGSize(width: 2000, height: 200))
        let measured = resolved.measure(in: CGSize(width: 2000, height: 200))
        let topLeft = CGPoint(x: anchor == .center ? x - measured.width / 2 : x, y: baseline - firstBaseline)
        context.draw(resolved, in: CGRect(origin: topLeft, size: measured))
    }

    private static func drawWindow(_ context: inout GraphicsContext, pane: AccessGuidePane, pose: AccessGuidePose, name: String, c: Palette) {
        let W = windowSize.width, H = windowSize.height
        let shape = Path(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerRadius: 26, style: .continuous)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 10))
            layer.fill(shape, with: .color(c.frame))
        }
        context.drawLayer { win in
            win.clip(to: shape)
            rect(&win, CGRect(x: 0, y: 0, width: W, height: H), c.frame)
            rect(&win, CGRect(x: 223, y: 0, width: 500, height: H), c.content)
            drawList(&win, pane: pane, pose: pose, name: name, c: c)
            drawSidebar(&win, c: c)
            // Toolbar: back / forward capsule, then the page title.
            let capsule = Path(roundedRect: CGRect(x: 231.5, y: 9, width: 72, height: 34), cornerRadius: 17, style: .circular)
            win.fill(capsule, with: .color(c.capsule))
            win.stroke(capsule, with: .color(c.capsuleEdge), lineWidth: 1)
            rect(&win, CGRect(x: 267, y: 17, width: 1, height: 18), c.capsuleEdge)
            let chevron = StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)
            win.stroke(SVGPath.make("M253 20.5L247.5 26L253 31.5"), with: .color(c.glyph), style: chevron)
            win.stroke(SVGPath.make("M282.5 20.5L288 26L282.5 31.5"), with: .color(c.glyphOff), style: chevron)
            let title = win.resolve(Text(pane.listTitle).font(.system(size: 15.5, weight: .bold)).tracking(-0.23).foregroundStyle(c.title))
            let baseline = title.firstBaseline(in: CGSize(width: 600, height: 100))
            win.draw(title, at: CGPoint(x: 316.5, y: 31 - baseline), anchor: .topLeading)
        }
        context.stroke(Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1), cornerRadius: 25.5, style: .continuous),
                       with: .color(c.outline), lineWidth: 1)
    }

    private static let barWidths: [CGFloat] = [92, 128, 70, 112, 84, 140, 100, 76, 120, 66, 108]

    private static func drawList(_ context: inout GraphicsContext, pane: AccessGuidePane, pose: AccessGuidePose, name: String, c: Palette) {
        let H = windowSize.height
        let pitch: CGFloat = pane == .accessibility ? 40 : 43
        var centres: [CGFloat] = []
        let tokensY = tokensRowY(pane)
        switch pane {
        case .accessibility:
            var y = tokensY
            while y > 20 { centres.insert(y, at: 0); y -= pitch }
            rect(&context, CGRect(x: 243, y: -40, width: 459.5, height: H + 80), radius: 14, c.group)
        case .speechRecognition:
            var y: CGFloat = 127
            while y - pitch / 2 < H { centres.append(y); y += pitch }
            rect(&context, CGRect(x: 243, y: 53.5, width: 459.5, height: H), radius: 14, c.group)
            label(&context, "Allow the applications below to access speech recognition. Speech", c.label2, x: 253.5, baseline: 76)
            label(&context, "recognition sends recorded voice to Apple to process your requests.", c.label2, x: 253.5, baseline: 92)
            rect(&context, CGRect(x: 253, y: 105, width: 439.5, height: 1), c.sep)
        default:
            var y: CGFloat = 61
            while y - pitch / 2 < H { centres.append(y); y += pitch }
            rect(&context, CGRect(x: 243, y: -40, width: 459.5, height: H + 80), radius: 14, c.group)
        }
        for (i, y) in centres.enumerated() {
            if i > 0 || pane != .speechRecognition {
                rect(&context, CGRect(x: 283, y: y - pitch / 2 - 0.5, width: 409.5, height: 1), c.sep)
            }
            if y == tokensY {
                drawAppIcon(&context, CGRect(x: 252.5, y: y - 10.5, width: 21, height: 21))
                label(&context, name, c.label, x: 283, baseline: y + 5.5)
                drawSwitch(&context, centerY: y, on: pose.on * pose.reset, c: c)
            } else {
                let tile = Path(roundedRect: CGRect(x: 253, y: y - 10, width: 20, height: 20), cornerRadius: 4.6, style: .circular)
                context.fill(tile, with: .linearGradient(Gradient(colors: [c.phTop, c.phBottom]),
                                                         startPoint: CGPoint(x: 0, y: y - 10), endPoint: CGPoint(x: 0, y: y + 10)))
                rect(&context, CGRect(x: 283, y: y - 3.5, width: barWidths[i % barWidths.count], height: 7), radius: 3.5, c.phBar)
                drawSwitch(&context, centerY: y, on: 1, c: c)
            }
        }
        if pane == .accessibility {
            // The list's + / − bar (Accessibility only; the Microphone and Speech lists have none).
            rect(&context, CGRect(x: 243, y: H - 24, width: 459.5, height: 24), c.bar)
            rect(&context, CGRect(x: 243, y: H - 24.5, width: 459.5, height: 1), c.sep)
            context.stroke(SVGPath.make("M250.6 \(H - 12)H258.9M254.75 \(H - 16.15)V\(H - 7.85)M275.6 \(H - 12)H283.9"),
                           with: .color(c.plusMinus), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            rect(&context, CGRect(x: 267, y: H - 20, width: 1, height: 16), c.sep)
        }
        // The toolbar's scroll-edge fade over the list.
        context.fill(Path(CGRect(x: 223, y: 0, width: 500, height: 66)),
                     with: .linearGradient(Gradient(stops: [.init(color: c.content, location: 0), .init(color: c.content, location: 0.55),
                                                            .init(color: c.content.opacity(0), location: 1)]),
                                           startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 66)))
    }

    /// The macOS 26 switch: a 36 × 16 track and a 21 × 12.5 pill knob, 1.5 pt in.
    private static func drawSwitch(_ context: inout GraphicsContext, centerY: CGFloat, on: Double, c: Palette) {
        let track = CGRect(x: switchX, y: centerY - 8 + 0.75, width: 36, height: 16)
        let capsule = Path(roundedRect: track, cornerRadius: 8, style: .circular)
        context.fill(capsule, with: .color(c.off))
        if on > 0 { context.fill(capsule, with: .color(c.on.opacity(on))) }
        let x = track.minX + 1.5 + 12 * CGFloat(on)
        let knob = Path(roundedRect: CGRect(x: x, y: centerY - 6.25 + 0.75, width: 21, height: 12.5), cornerRadius: 6.25, style: .circular)
        context.fill(knob, with: .color(c.knobOff))
        if on > 0 { context.fill(knob, with: .color(c.knobOn.opacity(on))) }
    }

    /// Tokens' shipping icon: a light graph-paper tile with a pencil π.
    private static func drawAppIcon(_ context: inout GraphicsContext, _ r: CGRect) {
        var icon = context
        icon.translateBy(x: r.minX, y: r.minY)
        icon.scaleBy(x: r.width / 64, y: r.height / 64)
        let tile = Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 61, height: 61), cornerRadius: 14, style: .continuous)
        icon.fill(tile, with: .color(Color(.sRGB, red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEC / 255)))
        icon.drawLayer { grid in
            grid.clip(to: tile)
            var lines = Path()
            for v in stride(from: CGFloat(9.5), through: 57.5, by: 8) {
                lines.move(to: CGPoint(x: v, y: 2)); lines.addLine(to: CGPoint(x: v, y: 62))
                lines.move(to: CGPoint(x: 2, y: v)); lines.addLine(to: CGPoint(x: 62, y: v))
            }
            grid.stroke(lines, with: .color(Color(.sRGB, red: 0xB9 / 255, green: 0xC6 / 255, blue: 0xCC / 255, opacity: 0.45)), lineWidth: 0.5)
        }
        icon.stroke(tile, with: .color(Color(.sRGB, red: 0x9A / 255, green: 0xA3 / 255, blue: 0x9E / 255)), lineWidth: 1.2)
        icon.stroke(SVGPath.make("M12.5 24.5C14.5 20 19 18.6 24 19.4C31 20.5 37 20.4 43 18.6C47 17.4 50 16 52 14.8M25 19.6V46M38.8 19.6V46"),
                    with: .color(Color(.sRGB, red: 0x4A / 255, green: 0x4E / 255, blue: 0x4A / 255)),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
    }

    /// Sidebar items in macOS 26 order: name, y at the capture's scroll position, tile colours, glyph.
    private static let sidebarItems: [(String, CGFloat, UInt32, UInt32, SidebarGlyph)] = [
        ("Sound", 699.5, 0xED6B80, 0xEB445A, .sound),
        ("Focus", 731.5, 0x887EF7, 0x6055ED, .moon),
        ("Screen Time", 763.5, 0x887EF7, 0x6055ED, .hourglass),
        ("Lock Screen", 809.0, 0x323232, 0x000000, .lock),
        ("Privacy & Security", 841.0, 0x60A5F8, 0x3B86F6, .hand),
        ("Touch ID & Password", 873.0, 0xFEFFFF, 0xE5E6E5, .fingerprint),
        ("Users & Groups", 905.0, 0x60A5F8, 0x3B86F6, .users),
        ("Internet Accounts", 950.0, 0x60A5F8, 0x3B86F6, .at),
        ("Game Center", 982.0, 0xFFFEFD, 0xEBEAEA, .gameCenter),
        ("iCloud", 1014.0, 0xFFFFFE, 0xECEBEB, .cloud),
    ]

    private static func drawSidebar(_ context: inout GraphicsContext, c: Palette) {
        let H = windowSize.height
        let panel = Path(roundedRect: CGRect(x: 8.5, y: 8, width: 214, height: H - 16), cornerRadius: 18, style: .continuous)
        context.fill(panel, with: .color(c.side))
        context.stroke(panel, with: .color(c.sideEdge), lineWidth: 1)
        let offset = 841 - min(230, max(150, H * 0.57))
        context.drawLayer { list in
            list.clip(to: Path(CGRect(x: 8.5, y: 100, width: 214, height: H - 108)))
            for (name, yRef, top, bottom, glyph) in sidebarItems {
                let y = yRef - offset
                guard y - 16 < H - 8 else { continue }
                let selected = name == "Privacy & Security"
                if selected {
                    rect(&list, CGRect(x: 18.5, y: y - 16, width: 194, height: 31.5), radius: 9, c.selection)
                }
                let tile = Path(roundedRect: CGRect(x: 24, y: y - 10, width: 20, height: 20), cornerRadius: 4.6, style: .circular)
                list.fill(tile, with: .linearGradient(Gradient(colors: [rgb(top), rgb(bottom)]),
                                                      startPoint: CGPoint(x: 0, y: y - 10), endPoint: CGPoint(x: 0, y: y + 10)))
                if !selected {
                    list.stroke(Path(roundedRect: CGRect(x: 24.25, y: y - 9.75, width: 19.5, height: 19.5), cornerRadius: 4.35, style: .circular),
                                with: .color(.white.opacity(0.22)), lineWidth: 0.5)
                }
                var g = list
                g.translateBy(x: 34, y: y)
                g.scaleBy(x: 1.14, y: 1.14)
                g.translateBy(x: -10, y: -10)
                glyph.draw(&g)
                label(&list, name, weight: .medium, selected ? .white : c.label, x: 50, baseline: y + 4.5)
            }
        }
        // The pinned search field; the list fades out beneath it.
        context.fill(Path(CGRect(x: 8.5, y: 88, width: 214, height: 16)),
                     with: .linearGradient(Gradient(colors: [c.side, c.side.opacity(0)]), startPoint: CGPoint(x: 0, y: 88), endPoint: CGPoint(x: 0, y: 104)))
        rect(&context, CGRect(x: 18.5, y: 61.5, width: 194, height: 27), radius: 13.5, c.field)
        context.stroke(SVGPath.make("M37.5 74.2A4.9 4.9 0 1 1 27.7 74.2A4.9 4.9 0 1 1 37.5 74.2ZM36.2 77.8L39.6 81.2"),
                       with: .color(c.label3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        label(&context, "Search", c.label3, x: 46.5, baseline: 79.5)
        // Window controls.
        for (x, color) in [(25.75, 0xEC6765), (48.75, 0xF2CA44), (71.75, 0x65C466)] as [(CGFloat, UInt32)] {
            context.fill(Path(ellipseIn: CGRect(x: x - 6.5, y: 19.25, width: 13, height: 13)), with: .color(rgb(color)))
        }
    }

    private static func rgb(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// The first-time microphone alert, macOS 26 style: icon, bold question, the app's reason
    /// (bars, so nothing is invented), Don't Allow and Allow. Allow darkens on the click.
    private static func drawAlert(_ context: inout GraphicsContext, pose: AccessGuidePose, name: String, c: Palette) {
        let r = CGRect(origin: .zero, size: alertSize)
        let panel = Path(roundedRect: r, cornerRadius: 22, style: .continuous)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 10))
            layer.fill(panel, with: .color(c.alert))
        }
        context.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 21.5, style: .continuous), with: .color(c.outline), lineWidth: 1)
        drawAppIcon(&context, CGRect(x: r.midX - 32, y: 20, width: 64, height: 64))
        label(&context, "\u{201C}\(name)\u{201D} would like to access", size: 13, weight: .bold, c.label, x: r.midX, baseline: 108, anchor: .center)
        label(&context, "the microphone.", size: 13, weight: .bold, c.label, x: r.midX, baseline: 125, anchor: .center)
        rect(&context, CGRect(x: r.midX - 95, y: 140, width: 190, height: 7), radius: 3.5, c.phBar)
        rect(&context, CGRect(x: r.midX - 70, y: 154, width: 140, height: 7), radius: 3.5, c.phBar)
        let deny = CGRect(x: 16, y: allowButton.minY, width: allowButton.width, height: allowButton.height)
        let button = c.off
        rect(&context, deny, radius: 14, button)
        rect(&context, allowButton, radius: 14, button)
        let lit = pose.press > 0 ? pose.press : pose.on * pose.reset * 0.6
        if lit > 0 { rect(&context, allowButton, radius: 14, c.off.opacity(lit)) }
        label(&context, "Don\u{2019}t Allow", size: 13, weight: .regular, c.label, x: deny.midX, baseline: deny.midY + 4.5, anchor: .center)
        label(&context, "Allow", size: 13, weight: .regular, c.label, x: allowButton.midX, baseline: allowButton.midY + 4.5, anchor: .center)
    }

    /// The standard macOS arrow pointer: black with a white edge, tip at `tip`; it dips on the click.
    private static func drawPointer(_ context: inout GraphicsContext, at tip: CGPoint, pose: AccessGuidePose) {
        guard pose.pointerOpacity > 0 else { return }
        let k = 1 - 0.14 * CGFloat(pose.press)
        var p = context
        p.translateBy(x: tip.x, y: tip.y)
        p.scaleBy(x: k, y: k)
        let arrow = SVGPath.make("M0 0V16.8L3.9 13.1L6.4 18.9L9 17.8L6.6 12.1H11.9Z")
        p.drawLayer { layer in
            layer.opacity = pose.pointerOpacity
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1))
            layer.fill(arrow, with: .color(.black))
            layer.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
    }
}

/// SF-like sidebar glyphs (white unless noted) on a 20-point tile; drawn paths, not Apple artwork.
enum SidebarGlyph {
    case sound, moon, hourglass, lock, hand, fingerprint, users, at, gameCenter, cloud

    func draw(_ g: inout GraphicsContext) {
        let white = GraphicsContext.Shading.color(.white)
        func fill(_ d: String, _ s: GraphicsContext.Shading = white) { g.fill(SVGPath.make(d), with: s) }
        func stroke(_ d: String, _ w: CGFloat, _ color: Color = .white) {
            g.stroke(SVGPath.make(d), with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color = .white, _ opacity: Double = 1) {
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(opacity)))
        }
        func hex(_ v: UInt32) -> Color { Color(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255) }
        switch self {
        case .sound:
            fill("M4.6 8.2H6.8L9.8 5.6V14.4L6.8 11.8H4.6Z")
            stroke("M11.7 8.2A2.4 2.4 0 0 1 11.7 11.8M13.3 6.7A4.6 4.6 0 0 1 13.3 13.3", 1.2)
        case .moon:
            fill("M11.6 4.6A6 6 0 1 0 15.6 13.3A5 5 0 0 1 11.6 4.6Z")
        case .hourglass:
            stroke("M6.3 4.5H13.7M6.3 15.5H13.7M7.2 4.8C7.2 8 12.8 8.6 12.8 10C12.8 11.4 7.2 12 7.2 15.2M12.8 4.8C12.8 8 7.2 8.6 7.2 10C7.2 11.4 12.8 12 12.8 15.2", 1.5)
            fill("M8.2 14.6C8.6 13 11.4 13 11.8 14.6Z")
        case .lock:
            stroke("M8.1 8.1V6.6A1.9 1.9 0 0 1 11.9 6.6V8.1", 1.3)
            g.fill(Path(roundedRect: CGRect(x: 6.9, y: 7.9, width: 6.2, height: 5), cornerRadius: 1.1), with: white)
            for x: CGFloat in [5.6, 8.53, 11.47, 14.4] { dot(x, 15.6, 0.85) }
        case .hand:
            fill("M7.1 9.6V5.4A.95.95 0 0 1 9 5.4V9H9.3V4.3A.95.95 0 0 1 11.2 4.3V9H11.5V5A.95.95 0 0 1 13.4 5V10.2L13.7 10.1V7.4A.9.9 0 0 1 15.5 7.4V11.6C15.5 14.4 13.6 16.3 10.9 16.3C9.1 16.3 8 15.5 7.1 14.1L5 10.8A.95.95 0 0 1 6.5 9.7L7.1 10.5Z")
        case .fingerprint:
            stroke("M5.6 8.2A5 5 0 0 1 14.4 8.2M5 11.2A5.2 5.2 0 0 1 15.1 9.9C15.2 11 15.1 12.2 14.7 13.2M6.6 14.6C6.8 13.2 6.7 11.6 6.9 10.6A3.2 3.2 0 0 1 13.1 10.7C13.3 12 13.2 13.6 12.6 15.1M8.6 15.9C8.9 14.4 8.7 12.6 8.8 11.2A1.2 1.2 0 0 1 11.2 11.2C11.3 12.9 11.1 14.6 10.4 16.2M10 11.3C10.1 13.1 9.9 14.8 9.3 16.5M6.4 5.6A6.2 6.2 0 0 1 13.6 5.6", 0.95, hex(0xEE7E92))
        case .users:
            dot(7.6, 7.4, 2.2); dot(13, 7.9, 1.9)
            fill("M3.6 14.2C3.8 11.8 5.4 10.6 7.6 10.6C9.8 10.6 11.4 11.8 11.6 14.2Z")
            fill("M12.3 10.9C14.6 10.6 16.2 11.6 16.4 14.2H12.6C12.6 12.9 12.5 11.8 12.3 10.9Z")
        case .at:
            stroke("M12.5 10A2.5 2.5 0 1 1 7.5 10A2.5 2.5 0 1 1 12.5 10ZM12.5 8V11.1C12.5 12.4 14.6 12.6 15.1 10.9C15.9 7.6 13.4 4.6 10 4.6A5.4 5.4 0 1 0 12.9 14.6", 1.45)
        case .gameCenter:
            dot(8.3, 8.4, 3.6, hex(0xF45B8A)); dot(12, 8.3, 3.2, hex(0xFF9F3A), 0.9)
            dot(8.6, 12.2, 3.1, hex(0xB65AF2), 0.9); dot(12.2, 12.2, 3.1, hex(0x3E8EF7), 0.9)
        case .cloud:
            fill("M6 14.6A3 3 0 0 1 5.6 8.7A4.3 4.3 0 0 1 13.8 8.2A3.3 3.3 0 0 1 14.4 14.6Z", .color(hex(0x6FB0EE)))
        }
    }
}

/// A small SVG path-data reader (absolute M L H V C A Z), so the replica's measured shapes stay
/// in one readable form. Arcs are flattened into short lines.
enum SVGPath {
    static func make(_ d: String) -> Path {
        var path = Path()
        var tokens = tokenize(d)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        func number() -> CGFloat {
            guard case .number(let v)? = tokens.first else { return 0 }
            tokens.removeFirst()
            return CGFloat(v)
        }
        while let token = tokens.first {
            if case .command(let c) = token { command = c; tokens.removeFirst() }
            switch command {
            case "M":
                current = CGPoint(x: number(), y: number()); start = current
                path.move(to: current); command = "L"
            case "L":
                current = CGPoint(x: number(), y: number()); path.addLine(to: current)
            case "H":
                current.x = number(); path.addLine(to: current)
            case "V":
                current.y = number(); path.addLine(to: current)
            case "C":
                let c1 = CGPoint(x: number(), y: number()), c2 = CGPoint(x: number(), y: number())
                current = CGPoint(x: number(), y: number())
                path.addCurve(to: current, control1: c1, control2: c2)
            case "A":
                let rx = number(), ry = number(), rotation = number(), large = number() != 0, sweep = number() != 0
                let end = CGPoint(x: number(), y: number())
                arc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath(); current = start
                if case .number? = tokens.first { tokens.removeFirst() }
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    private enum Token { case command(Character), number(Double) }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var buffer = ""
        var sawDot = false, sawExp = false
        func flush() { if let v = Double(buffer) { out.append(.number(v)) }; buffer = ""; sawDot = false; sawExp = false }
        for ch in d {
            switch ch {
            case "0"..."9": buffer.append(ch)
            case ".":
                if sawDot { flush() }
                buffer.append(ch); sawDot = true
            case "-", "+":
                if let last = buffer.last, last == "e" || last == "E" { buffer.append(ch) } else { flush(); buffer.append(ch) }
            case "e", "E":
                if !sawExp && !buffer.isEmpty { buffer.append(ch); sawExp = true } else { flush() }
            case " ", ",", "\n", "\t": flush()
            default:
                flush(); out.append(.command(ch))
            }
        }
        flush()
        return out
    }

    /// SVG endpoint arc to centre form (SVG 1.1 F.6.5), drawn as line segments.
    private static func arc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p1 != p2 else { path.addLine(to: p2); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p1.x + p2.x) / 2
        let cy = sp * cxp + cp * cyp + (p1.y + p2.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let steps = max(6, Int(abs(delta) / (.pi / 16)))
        for i in 1...steps {
            let t = theta1 + delta * CGFloat(i) / CGFloat(steps)
            let x = cx + rx * cos(t) * cp - ry * sin(t) * sp
            let y = cy + rx * cos(t) * sp + ry * sin(t) * cp
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
}

