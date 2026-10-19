


//
import AppKit
import SwiftUI
import TokensCore

/*
Spec (kept deliberately simple): a 3 x 2 cell screen whose four edges are paper
rules, a floor matching the screen width , and one pill per edge shaped like the
real bubble there: wide at the top and bottom, tall at the sides. `cell` is the printed paper
cell; the sheet zoom scales the whole drawing, so every edge stays on a rule at 75–150%.
*/
/// Pure geometry for the bubble picker. Every length is a fraction of `cell`.
struct TokensBubblePickerGeometry: Equatable {
    /// Where the screen sits inside a frame that is wider than it.
    enum Side { case leading, trailing }
    /// Arrow keys select spatially: up is the top edge, left the left edge, and so on.
    enum Arrow { case up, down, left, right }

    /// Clockwise from the top, the order VoiceOver and the spoken labels use.
    static let slots: [BubblePlacement] = [.top, .right, .bottom, .left]

    let cell: CGFloat
    init(cell: CGFloat = TokensUI.paperCell) { self.cell = cell }

    /// The outline, three cells wide and two tall, with its top-left on a rule crossing.
    var screen: CGRect { CGRect(x: 0, y: 0, width: 3 * cell, height: 2 * cell) }
    /// The floor shares the screen's exact left and right edges; no laptop-style overhang.
    var base: CGRect { CGRect(x: screen.minX, y: screen.maxY, width: screen.width, height: 0) }
    /// A quarter-row clear gap keeps the heading away from the screen border.
    var titleGap: CGFloat { cell / 4 }
    /// With the heading and gap included, the caption returns to the fourth paper rule.
    var captionBaseline: CGFloat { 3 * cell - titleGap }
    /// Keep the existing focus/caption gutter without expanding the floor beyond the screen.
    var horizontalInset: CGFloat { cell / 4 + 1 }
    var minimumWidth: CGFloat { screen.width + 2 * horizontalInset }
    /// Height of the diagram and caption; the row adds its own heading and clear row.
    var height: CGFloat { captionBaseline }

    /// The pill that mirrors the real bubble at that edge, inset 0.15 cells from it.
    func pill(_ placement: BubblePlacement) -> CGRect {
        let long = 0.75 * cell, short = 0.2 * cell, inset = 0.15 * cell
        switch placement {
        case .top:             return CGRect(x: screen.midX - long / 2, y: inset, width: long, height: short)
        case .left:            return CGRect(x: inset, y: screen.midY - long / 2, width: short, height: long)
        case .right:           return CGRect(x: screen.maxX - inset - short, y: screen.midY - long / 2,
                                             width: short, height: long)
        case .bottom, .custom: return CGRect(x: screen.midX - long / 2, y: screen.maxY - inset - short,
                                             width: long, height: short)
        }
    }

    /*
    Click areas split the screen interior into four parts that never overlap: full-height
    strips 0.75 cells wide at the sides, and the middle column halved for top and bottom.
    Each is at least 0.9 x 0.6 cells along its pill, and each contains its own pill.
    */
    func hitArea(_ placement: BubblePlacement) -> CGRect {
        let strip = 0.75 * cell
        switch placement {
        case .left:            return CGRect(x: 0, y: 0, width: strip, height: screen.height)
        case .right:           return CGRect(x: screen.maxX - strip, y: 0, width: strip, height: screen.height)
        case .top:             return CGRect(x: strip, y: 0, width: screen.width - 2 * strip, height: screen.midY)
        case .bottom, .custom: return CGRect(x: strip, y: screen.midY, width: screen.width - 2 * strip,
                                             height: screen.midY)
        }
    }

    /// Prefer a paper rule while keeping the entire deck inside the offered bounds.
    /// If no rule fits, containment wins; a narrow container must never paint on a neighbour.
    func screenMinX(frameMinX: CGFloat, frameMaxX: CGFloat, side: Side) -> CGFloat {
        let tolerance: CGFloat = 0.01
        let lower = frameMinX + horizontalInset
        let upper = frameMaxX - horizontalInset - screen.width
        guard upper >= lower else { return lower }
        let first = ceil((lower - tolerance) / cell) * cell
        let last = floor((upper + tolerance) / cell) * cell
        guard first <= last else { return side == .leading ? lower : upper }
        return side == .leading ? first : last
    }

    static func placement(for arrow: Arrow) -> BubblePlacement {
        switch arrow {
        case .up:    return .top
        case .down:  return .bottom
        case .left:  return .left
        case .right: return .right
        }
    }

    /// The one caption under the deck names the choice in plain words.
    static func caption(_ placement: BubblePlacement) -> String {
        switch placement {
        case .top:             return "Top of the screen"
        case .left:            return "Left side of the screen"
        case .right:           return "Right side of the screen"
        case .bottom, .custom: return "Bottom of the screen"
        }
    }

    static func accessibilityLabel(_ placement: BubblePlacement) -> String {
        "Bubble position " + placement.rawValue.capitalized
    }
}

//
// :)
//
//
/// The fixed 72 × 46 mini screen used by the V3 Settings row (DESIGN.md §6.5). Same four slots,
/// same clockwise order and the same non-overlapping click-area rule as the paper geometry above.
enum TokensBubbleMiniScreen {
    static let size = CGSize(width: 72, height: 46)
    static let radius: CGFloat = 6

    /// The pill that mirrors the real bubble at that edge: wide at top/bottom, tall at the sides.
    static func pill(_ placement: BubblePlacement) -> CGRect {
        let long: CGFloat = 20, short: CGFloat = 5, inset: CGFloat = 5
        switch placement {
        case .top:             return CGRect(x: (size.width - long) / 2, y: inset, width: long, height: short)
        case .left:            return CGRect(x: inset, y: (size.height - long) / 2, width: short, height: long)
        case .right:           return CGRect(x: size.width - inset - short, y: (size.height - long) / 2,
                                             width: short, height: long)
        case .bottom, .custom: return CGRect(x: (size.width - long) / 2, y: size.height - inset - short,
                                             width: long, height: short)
        }
    }

    /// Full-height strips at the sides (a quarter of the width), the middle halved for top and bottom.
    static func hitArea(_ placement: BubblePlacement) -> CGRect {
        let strip: CGFloat = size.width / 4
        switch placement {
        case .left:            return CGRect(x: 0, y: 0, width: strip, height: size.height)
        case .right:           return CGRect(x: size.width - strip, y: 0, width: strip, height: size.height)
        case .top:             return CGRect(x: strip, y: 0, width: size.width - 2 * strip, height: size.height / 2)
        case .bottom, .custom: return CGRect(x: strip, y: size.height / 2, width: size.width - 2 * strip,
                                             height: size.height / 2)
        }
    }

    /*
    Pill ink levels. The chosen edge is solid ink, never red (DESIGN.md §2.4); idle edges are ink
    at 25%, a hovered or pressed edge ink at 50%. While a talk is finishing the picker is locked
    and every pill steps down, with no opacity multiplier on the whole control (DESIGN.md D3).
    */
    static let selectedAlpha: Double = 1
    static let hoverAlpha: Double = 0.5
    static let idleAlpha: Double = 0.25
    static let disabledSelectedAlpha: Double = 0.30
    static let disabledIdleAlpha: Double = 0.12

    static func pillAlpha(selected: Bool, hovered: Bool, pressed: Bool, enabled: Bool) -> Double {
        if !enabled { return selected ? disabledSelectedAlpha : disabledIdleAlpha }
        if selected { return selectedAlpha }
        return hovered || pressed ? hoverAlpha : idleAlpha
    }
}

/// The tiny screen: a raised 72 × 46 surface with a control edge and one pill per edge; the chosen
/// pill is solid ink. Click a pill, or focus the screen and use the arrow keys.
struct TokensBubblePlacementPicker: View {
    let selection: BubblePlacement
    /// Kept for source compatibility with the paper layout; the mini screen no longer snaps.
    var side: TokensBubblePickerGeometry.Side = .trailing
    let select: (BubblePlacement) -> Void

    @State private var hovered: BubblePlacement? = TokensBubblePickerPreview.hovered
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var enabled: Bool { isEnabled && !TokensBubblePickerPreview.disabled }

    var body: some View {
        let size = TokensBubbleMiniScreen.size
        let shape = RoundedRectangle(cornerRadius: TokensBubbleMiniScreen.radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(enabled ? TokensUI.raised : TokensUI.disabledFill)
            // Focus shows as a brighter ink edge, the same cue as a focused text field.
            shape.strokeBorder(focused ? TokensInk.primary.color.opacity(0.45) : TokensUI.controlEdge, lineWidth: 1)
            ForEach(TokensBubblePickerGeometry.slots, id: \.self) { slot in
                let area = TokensBubbleMiniScreen.hitArea(slot)
                slotButton(slot).offset(x: area.minX, y: area.minY)
            }
        }
        .frame(width: size.width, height: size.height)
        .disabled(!enabled)
        .focusable(enabled)
        .focused($focused)
        .focusEffectDisabled()
        // Arrow keys pick that edge. Returning .handled consumes the key, so AppKit never beeps.
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            let arrow: TokensBubblePickerGeometry.Arrow
            switch press.key {
            case .upArrow:   arrow = .up
            case .downArrow: arrow = .down
            case .leftArrow: arrow = .left
            default:         arrow = .right
            }
            if enabled { select(TokensBubblePickerGeometry.placement(for: arrow)) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bubble position")
        .accessibilityValue(TokensBubblePickerGeometry.caption(selection))
    }

    private func slotButton(_ slot: BubblePlacement) -> some View {
        let area = TokensBubbleMiniScreen.hitArea(slot)
        let selected = selection == slot
        return Button { select(slot) } label: {
            Color.clear
                .frame(width: area.width, height: area.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(TokensBubbleSlotStyle(pill: TokensBubbleMiniScreen.pill(slot).offsetBy(dx: -area.minX, dy: -area.minY),
                                           selected: selected, hovered: enabled && hovered == slot,
                                           enabled: enabled, reduceMotion: reduceMotion))
        .onHover { inside in
            if inside { hovered = slot } else if hovered == slot { hovered = nil }
        }
        .accessibilityLabel(TokensBubblePickerGeometry.accessibilityLabel(slot))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A solid capsule per edge in ink at the level TokensBubbleMiniScreen.pillAlpha gives:
/// selected solid, hover or press half, idle a quarter. No labels are drawn inside the screen.
struct TokensBubbleSlotStyle: ButtonStyle {
    let pill: CGRect
    let selected: Bool
    let hovered: Bool
    var enabled = true
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let alpha = TokensBubbleMiniScreen.pillAlpha(selected: selected, hovered: hovered,
                                                     pressed: configuration.isPressed, enabled: enabled)
        return configuration.label.overlay(alignment: .topLeading) {
            Capsule().fill(TokensInk.primary.color.opacity(alpha))
                .frame(width: pill.width, height: pill.height)
                .offset(x: pill.minX, y: pill.minY)
                .animation(TokensUI.fade(reduceMotion), value: hovered)
                .allowsHitTesting(false)
        }
    }
}

/// Title, the mini screen and the plain-words caption, for callers that want a stacked row.
/// Settings draws its own row (title and caption left, screen right) around the picker.
struct TokensBubblePlacementRow: View {
    let selection: BubblePlacement
    var side: TokensBubblePickerGeometry.Side = .trailing
    let select: (BubblePlacement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The group carries the spoken name; the written title is not read twice.
            Text("Bubble position").font(TokensType.body).foregroundStyle(TokensUI.ink).accessibilityHidden(true)
            TokensBubblePlacementPicker(selection: selection, side: side, select: select)
            Text(TokensBubblePickerGeometry.caption(selection)).font(TokensType.caption).foregroundStyle(TokensUI.secondary)
        }
    }
}

/// Offscreen proof states only, read once from the launch arguments of a frame render
/// (`--render-preview-frames`). They never save a placement.
enum TokensBubblePickerPreview {
    private static let arguments = ProcessInfo.processInfo.arguments
    private static let rendering = arguments.contains("--render-preview-frames")

    private static func edge(after flag: String) -> BubblePlacement? {
        guard rendering, let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              let edge = BubblePlacement(rawValue: arguments[index + 1].lowercased()),
              BubblePlacement.presets.contains(edge) else { return nil }
        return edge
    }

    /// `--public-preview-bubble <top|right|bottom|left>`: the selected edge to draw.
    static let placement = edge(after: "--public-preview-bubble")
    /// `--public-preview-bubble-hover <edge>`: draw that idle slot as hovered.
    static let hovered = edge(after: "--public-preview-bubble-hover")
    /// `--public-preview-bubble-disabled`: draw the finishing (disabled) state.
    static let disabled = rendering && arguments.contains("--public-preview-bubble-disabled")
}

