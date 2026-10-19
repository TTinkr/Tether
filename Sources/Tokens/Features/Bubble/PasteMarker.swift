
import AppKit
import SwiftUI

/// The saved on/off choice. On unless the user switched it off.
enum PasteMarkerPreference {
    static let key = "TokensPasteMarker.v1"
    static func load(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    static func save(_ value: Bool, _ defaults: UserDefaults = .standard) { defaults.set(value, forKey: key) }
}

/// Where the marker goes, in AppKit screen coordinates (origin bottom-left).
enum PasteMarkerGeometry {
    static let gap: CGFloat = 4
    /// The corners sit just outside the box so they never touch its text.
    static let outset: CGFloat = 4
    /// Room around the corners for the label above the top-left corner (build 81 RC5: two points
    /// more for the taller π).
    static let margin = CGSize(width: 4, height: 22)
    /// The label's ink (the π, the capitals and the halo) stays at least this far below the panel's top edge.
    static var labelTopInset: CGFloat { (labelBaseline - PasteMarkerLabel.inkRise).rounded(.down) }
    /// The label's leading edge (its halo room included), just left of the corner's dotted arm.
    static var labelLeadingInset: CGFloat { margin.width - 3 }
    /*
    The label's baseline, from the panel's top edge: 5 points above the corners' top line, so the
    top-left corner is a whole dotted L like the other three and the label sits just over it
    (a box clipped at the edge reads as broken). Its descenders end
    above the dots, so nothing of it touches the corner or enters the box.
    */
    static var labelBaseline: CGFloat { margin.height - 5 }

    /// Accessibility rectangles are top-left based from the top of the primary screen.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Why a box got no corner cues; logged (no text, only sizes) so a missed frame is explainable.
    enum Rejection: Error, Equatable {
        case tooSmall(CGSize), offscreen, tooBig(CGSize), noRoom

        var logValue: String {
            func size(_ s: CGSize) -> String { "\(Int(s.width.rounded()))x\(Int(s.height.rounded()))" }
            switch self {
            case .tooSmall(let s): return "too_small(\(size(s)))"
            case .offscreen: return "offscreen"
            case .tooBig(let s): return "too_big(\(size(s)))"
            case .noRoom: return "no_room"
            }
        }
    }

    /*
    The largest box still treated as a composer: about 1200x400 on a 1440x900 screen and
    above. Anything taller than this, or covering more than this share of the screen, is an
    editor pane or a whole document, which keeps the small caret label instead.
    */
    static let composerMaxHeight: CGFloat = 420
    static let composerMaxHeightShare: CGFloat = 0.45
    static let composerMaxAreaShare: CGFloat = 0.4

    /*
    The panel frame for corner cues around `field`, or nil when the box is missing, off every
    screen, or too large to be a composer (an editor pane or whole document), so the caller
    falls back to the caret label instead of outlining half the window.
    */
    static func cueFrame(field: CGRect, primaryHeight: CGFloat, visibleFrames: [CGRect]) -> CGRect? {
        if case .success(let frame) = cuePlacement(field: field, primaryHeight: primaryHeight, visibleFrames: visibleFrames) {
            return frame
        }
        return nil
    }

    static func cuePlacement(field: CGRect, primaryHeight: CGFloat,
                             visibleFrames: [CGRect]) -> Result<CGRect, Rejection> {
        guard !field.isNull, !field.isInfinite, field.width.isFinite, field.height.isFinite else {
            return .failure(.offscreen)
        }
        guard field.width >= 40, field.height >= 14 else { return .failure(.tooSmall(field.size)) }
        let flipped = flip(field, primaryHeight: primaryHeight)
        guard let visible = visibleFrames.first(where: { $0.contains(CGPoint(x: flipped.midX, y: flipped.midY)) })
                ?? visibleFrames.first(where: { $0.intersects(flipped) }) else { return .failure(.offscreen) }
        guard flipped.height <= max(composerMaxHeight, visible.height * composerMaxHeightShare),
              flipped.width * flipped.height <= visible.width * visible.height * composerMaxAreaShare else {
            return .failure(.tooBig(field.size))
        }
        let cues = flipped.insetBy(dx: -outset, dy: -outset).intersection(visible.insetBy(dx: 1, dy: 1))
        guard !cues.isNull, cues.width >= 40, cues.height >= 14 else { return .failure(.offscreen) }
        let frame = cues.insetBy(dx: -margin.width, dy: -margin.height)
        /*
        The label straddles the box's top-left corner. A box touching the top (or left) of the
        visible screen leaves no room for it there, so give up the corners and let the caller
        show the label alone by the caret, rather than drawing a label off screen or moving the
        corners away from the box.
        */
        guard frame.maxY - labelTopInset <= visible.maxY,
              frame.minX + labelLeadingInset >= visible.minX else { return .failure(.noRoom) }
        return .success(frame)
    }

    /*
    The caret-label fallback: above the caret with its left edge on it; below it if that
    would leave the screen; always inside the visible frame of the screen holding the caret.
    */
    static func origin(anchor: CGRect, size: CGSize, primaryHeight: CGFloat, visibleFrames: [CGRect]) -> CGPoint? {
        guard !anchor.isNull, !anchor.isInfinite, anchor.height > 0 || anchor.width > 0 else { return nil }
        let flipped = flip(anchor, primaryHeight: primaryHeight)
        let centre = CGPoint(x: flipped.midX, y: flipped.midY)
        guard let visible = visibleFrames.first(where: { $0.contains(centre) })
                ?? visibleFrames.first(where: { $0.intersects(flipped) }) else { return nil }
        var point = CGPoint(x: flipped.minX - 2, y: flipped.maxY + gap)
        if point.y + size.height > visible.maxY { point.y = flipped.minY - gap - size.height }
        point.x = min(max(point.x, visible.minX + 2), visible.maxX - size.width - 2)
        point.y = min(max(point.y, visible.minY + 2), visible.maxY - size.height - 2)
        return point
    }

    /// Small AX jitter (rounding, a blinking caret, a 1-point reflow) must not make it twitch.
    static func shouldMove(from old: CGRect?, to new: CGRect) -> Bool {
        guard let old else { return true }
        return abs(old.minX - new.minX) > 3 || abs(old.minY - new.minY) > 3
            || abs(old.width - new.width) > 3 || abs(old.height - new.height) > 3
    }
}

/// The marker's ink: one muted coral that reads on both light and dark composers.
private let cueInk = Color(red: 0.88, green: 0.40, blue: 0.33)
/*
The key name adjusts to the background (build 80): coral on dark composers, where the grey
name was missed entirely in Claude (build 79), and the quiet grey key name on light ones. The
panel follows the Mac's light or dark look, which the apps underneath follow too; reading the
pixels behind it would need Screen Recording, which Tokens never asks for.
*/
private let keyGrey = Color(red: 0.42, green: 0.42, blue: 0.44)
func pasteMarkerKeyInk(_ scheme: ColorScheme) -> Color { scheme == .dark ? cueInk : keyGrey }

/*
The coral logo π (LogoPi, the app icon's π, never a font glyph) and the dictation key as plain
type: no capsule, material, border or disc. The π is a capital's height: its bar's rising tail
meets the key name's cap line and its feet stand on the baseline. A very soft halo hugging the letters, in the system's
background tone (never a box), lifts it off whatever is drawn behind; on a plain composer of
the same look it is invisible.
*/
/// The logo π's size and its gap before the key name.
struct PasteMarkerPiStyle: Equatable {
    /// Ink height in key-name capitals.
    let tall: CGFloat
    /// Width as a share of the logo's own proportions at that height (1 = undistorted).
    let aspect: CGFloat
    /// Space between the π and the key name.
    let gap: CGFloat

    var size: CGSize {
        let natural = LogoPi.size(inkHeight: PasteMarkerLabel.capHeight * tall, lineWidth: PasteMarkerLabel.piLine)
        return CGSize(width: natural.width * aspect, height: natural.height)
    }

    /// Build 81 RC4 and earlier: 1.2 capitals, the width of a 1-capital logo times 0.82, 2.5 apart.
    static let build81 = PasteMarkerPiStyle(tall: 1.2, aspect: build81Aspect, gap: 2.5)
    static var build81Aspect: CGFloat {
        let cap = PasteMarkerLabel.capHeight, line = PasteMarkerLabel.piLine
        return LogoPi.size(inkHeight: cap, lineWidth: line).width * 0.82
            / LogoPi.size(inkHeight: cap * 1.2, lineWidth: line).width
    }
    static let chosen = PasteMarkerPiStyle(tall: 1.5, aspect: 0.8, gap: 4)
}

struct PasteMarkerLabel: View {
    let shortcutName: String
    /// The π's size and gap; the shipped style unless a comparison render asks for another.
    var pi: PasteMarkerPiStyle = PasteMarkerLabel.piStyle
    @Environment(\.colorScheme) private var colorScheme

    static let keySize: CGFloat = 12
    /// Room around the type for its halo, so a tight caret-label panel never clips it.
    static let haloRoom: CGFloat = 2

    /// The logo π's line width: a little heavier than the 12-point semibold key name's stem.
    static let piLine: CGFloat = 1.6
    static let capHeight = NSFont.systemFont(ofSize: keySize, weight: .semibold).capHeight
    /*
    The logo π (LogoPi, never a font glyph), its feet on the key name's baseline. Build 81 RC5
    (the π looked odd beside Right Option and needed to be larger): it was 1.2
    capitals tall and squeezed to two-thirds of the logo's own proportions (the website's PI_TALL
    1.2 / PI_NARROW 0.82), so its bar read as a cramped hat. It is now `piStyle` below, with a
    wider gap before the key name. Earlier (2026-10-15) the verticals were made bigger.
    */
    static let piStyle = PasteMarkerPiStyle.chosen
    static var piTall: CGFloat { piStyle.tall }
    static var piSize: CGSize { piStyle.size }
    /// How far the label's ink rises above its baseline, halo included.
    static var inkRise: CGFloat { max(piSize.height + piLine, capHeight) + haloRoom }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: pi.gap) {
            LogoPi()
                .stroke(cueInk, style: StrokeStyle(lineWidth: Self.piLine, lineCap: .round, lineJoin: .round))
                .frame(width: pi.size.width, height: pi.size.height)
                .padding(Self.piLine / 2)
                // The feet's ink stands on the key name's baseline.
                .alignmentGuide(.firstTextBaseline) { $0.height }
            Text(shortcutName)
                .font(.system(size: Self.keySize, weight: .semibold))
                .foregroundStyle(pasteMarkerKeyInk(colorScheme))
                .lineLimit(1)
        }
        .fixedSize()
        .shadow(color: halo, radius: 0.75)
        .padding(Self.haloRoom)
        .accessibilityHidden(true)
    }

    private var halo: Color { colorScheme == .dark ? .black.opacity(0.5) : .white.opacity(0.45) }
}

/// Four whole dotted corner brackets; the label stands above the top-left one.
struct CornerCues: Shape {
    var labelWidth: CGFloat = 0

    /// The arms along the top and bottom, and down the sides.
    static let armLength: CGFloat = 18
    /*
    Build 81: the arms used to shrink to a third of the box's height, so a one-line composer
    (16 to 30 points tall, Claude, Codex, a search box) got four clusters of four or five dots
    700 points apart, which read as no box at all (the highlighting box was
    not visible). The side arms now run up to half the height, so on a short box they
    meet and each end reads as a bracket; the top and bottom arms keep their full length.
    */
    static func arms(_ rect: CGRect) -> (across: CGFloat, down: CGFloat) {
        (min(armLength, rect.width / 4), min(armLength, rect.height / 2))
    }

    func path(in rect: CGRect) -> Path {
        let (across, down) = Self.arms(rect)
        var path = Path()
        // Top-left.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + down))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + across, y: rect.minY))
        // Top-right.
        path.move(to: CGPoint(x: rect.maxX - across, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + down))
        // Bottom-right.
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - down))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - across, y: rect.maxY))
        // Bottom-left.
        path.move(to: CGPoint(x: rect.minX + across, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - down))
        return path
    }
}

/// The whole overlay: corners around the box, the label just above its top-left corner.
struct PasteMarkerView: View {
    let shortcutName: String
    /// False for the caret fallback: the label alone.
    var framed = true
    /// The π's style; only comparison renders pass another.
    var pi: PasteMarkerPiStyle = PasteMarkerLabel.piStyle

    var body: some View {
        if framed {
            CornerCues()
                .stroke(cueInk, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [0.01, 3.4]))
                .padding(EdgeInsets(top: PasteMarkerGeometry.margin.height, leading: PasteMarkerGeometry.margin.width,
                                    bottom: PasteMarkerGeometry.margin.height, trailing: PasteMarkerGeometry.margin.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // An overlay, so placing the label by its baseline never resizes or moves the corners.
                .overlay(alignment: .topLeading) {
                    PasteMarkerLabel(shortcutName: shortcutName, pi: pi)
                        .alignmentGuide(.top) { $0[.firstTextBaseline] }
                        .offset(x: PasteMarkerGeometry.labelLeadingInset, y: PasteMarkerGeometry.labelBaseline)
                }
        } else {
            PasteMarkerLabel(shortcutName: shortcutName, pi: pi)
        }
    }
}

/// One click-through panel, shown and moved only from the destination preview (main thread).
final class PasteMarker {
    static let shared = PasteMarker()
    private var panel: NSPanel?
    private var hosting: NSHostingView<PasteMarkerView>?
    private var lastFrame: CGRect?
    private var lastNote: String?
    /// Marker lines this talk; a flickering marker logs its first few changes, not hundreds.
    private var notesThisTalk = 0
    static let notesPerTalk = 24

    /// `field` and `caret` are Accessibility rectangles; the box wins, the caret is the fallback.
    /// `role` is the box's AX role, for the diagnostic line only (never any text).
    func show(field: CGRect?, caret: CGRect?, shortcutName: String, role: String? = nil) {
        let panel = self.panel ?? makePanel()
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let visible = NSScreen.screens.map(\.visibleFrame)
        var target: CGRect?
        var reason = "no_field"
        if let field {
            switch PasteMarkerGeometry.cuePlacement(field: field, primaryHeight: primaryHeight, visibleFrames: visible) {
            case .success(let cues): target = cues; reason = "ok"
            case .failure(let rejection): reason = rejection.logValue
            }
        }
        let framed = target != nil
        if framed {
            hosting?.rootView = PasteMarkerView(shortcutName: shortcutName, framed: true)
        } else if let caret {
            hosting?.rootView = PasteMarkerView(shortcutName: shortcutName, framed: false)
            let size = Self.caretLabelSize(shortcutName: shortcutName)
            if let origin = PasteMarkerGeometry.origin(anchor: caret, size: size, primaryHeight: primaryHeight, visibleFrames: visible) {
                target = CGRect(origin: origin, size: size)
            }
        }
        guard let target else {
            note("paste_marker_skipped reason=\(reason) caret=\(caret != nil) role=\(role ?? "-")")
            hide(); return
        }
        if PasteMarkerGeometry.shouldMove(from: lastFrame, to: target) {
            panel.setFrame(target, display: true)
            lastFrame = target
        }
        // Once per distinct outcome per talk, not once per poll; the size shows how big it drew.
        note("paste_marker_shown framed=\(framed) reason=\(reason) role=\(role ?? "-") cue=\(Int(target.width))x\(Int(target.height))")
        guard !panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }
        }
    }

    /*
    The caret label's own size, measured apart from the panel. The panel's hosting view has no
    sizing options (so it never resizes the panel), and such a view reports a zero fitting size:
    the caret fallback was a 0x0 panel, so a whole-document field showed nothing at all (Codex
    RC4 live QA: "framed=false reason=too_big(571x560) ... cue=0x0").
    */
    static func caretLabelSize(shortcutName: String) -> CGSize {
        let measured = NSHostingView(rootView: PasteMarkerView(shortcutName: shortcutName, framed: false)).fittingSize
        return measured.width >= 1 && measured.height >= 1 ? measured : CGSize(width: 96, height: 18)
    }

    /// A diagnostic line, written only when it differs from the last one of this talk.
    func note(_ line: String) {
        guard line != lastNote, notesThisTalk < Self.notesPerTalk else { return }
        lastNote = line
        notesThisTalk += 1
        Diagnostics.event(line)
    }

    /// A new talk logs its outcomes afresh.
    func resetDiagnostics() { lastNote = nil; notesThisTalk = 0 }

    /// Whether the marker is on screen now (the destination preview keeps it through a blip).
    var isShowing: Bool { panel?.isVisible == true }

    /*
    Takes the marker down. A visible marker logs why (build 81: hides were silent, so one
    "paste_marker_shown" could stand for a marker that was up for a moment of a 19 s talk),
    and the next show logs again.
    */
    func hide(reason: String? = nil) {
        lastFrame = nil
        guard let panel, panel.isVisible else { return }
        if let reason { note("paste_marker_hidden reason=\(reason)") }
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 18),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Hide Others (⌥⌘H) in the app being talked into must not hide where its words land.
        panel.canHide = false
        let hosting = NSHostingView(rootView: PasteMarkerView(shortcutName: ""))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }
}
