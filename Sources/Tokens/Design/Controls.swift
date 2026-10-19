


//
import AppKit
import CoreText
import SwiftUI


// TokensButton — pencil button: a ruled box (standard, primary) or underlined words (quiet)


// MARK: Controls

struct TokensButton: View {
    /*
    standard: ruled box. primary: the same box drawn heavier. quiet: underlined words, no box.
    `large` makes the button stretch to the full width it is given.
    */
    enum Kind { case standard, primary, quiet }
    let title: String
    var symbol: String?
    var kind: Kind = .standard
    var large      = false
    var disabled   = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, symbol: String? = nil, kind: Kind = .standard, large: Bool = false,
         disabled: Bool = false, action: @escaping () -> Void) {
        self.title    = title
        self.symbol   = symbol
        self.kind     = kind
        self.large    = large
        self.disabled = disabled
        self.action   = action
    }

    /*
    Box width in whole squares: the title's width at size 15 plus 12 points of room (30 when there
    is an icon), rounded up to the next square, never narrower than two squares. nil means "no
    fixed width": quiet buttons and `large` ones size themselves.
    */
    private var boxWidth: CGFloat? {
        guard kind != .quiet, !large else { return nil }
        return max(2 * TokensUI.module, TokensUI.snap(TokensUI.textWidth(title, size: 15) + (symbol == nil ? 12 : 30)))
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .bottom, spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .light)).tokensLine() }
                TokensLabel(title, ink: disabled ? .secondary : .primary)
            }
            /*
            Words get a hover underline only while the button is enabled and is not quiet (a quiet button
            already draws its own underline in the style).
            */
            .tokensHoverUnderline(hovered && !disabled && kind != .quiet, reduceMotion: reduceMotion)
            .frame(width: boxWidth)
            .frame(maxWidth: large ? .infinity : nil)
        }
        .buttonStyle(TokensButtonStyle(kind: kind, hovered: hovered, seed: TokensPencil.seed(title)))
        /*
        The box is drawn half a square below the label's slot (see TokensButtonStyle), so the keyboard
        focus outline is told to reach that far down too.
        */
        .tokensFocus(below: TokensUI.module / 2)
        .onHover { hovered = $0 }
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}


// TokensButtonStyle — Standard: a ruled box


/// Standard: a ruled box. Primary: the same box drawn heavier. Quiet: underlined writing. Nothing is filled.
struct TokensButtonStyle: ButtonStyle {

//
// :)
//
//
    let kind: TokensButton.Kind
    let hovered: Bool
    var seed = 0
    @Environment(\.isEnabled) private var isEnabled

    /*
    Layout trick used by the boxed controls: pad the label by half a square at the bottom, draw the
    box behind the padded label (the box hangs half a square under the writing), set the click
    area, then take the padding back with a negative amount. The box and click area keep the extra
    height but the control takes no more room in the layout.
    */
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? TokensUI.ink : TokensUI.secondary)
            // The box runs from the grid line above the writing to half a square below its baseline.
            .padding(.bottom, TokensUI.module / 2)
            .background { decoration(pressed: configuration.isPressed) }
            .contentShape(Rectangle())
            .padding(.bottom, -TokensUI.module / 2)
    }

    /*
    Quiet: a pencil underline (thicker under the pointer, dashed when disabled). Other kinds: a
    faint wash while pressed and a pencil box; primary is the heavier box in main ink, standard
    the thin graphite one, and a disabled box is dashed.
    */
    @ViewBuilder
    private func decoration(pressed: Bool) -> some View {
        if kind == .quiet {
            TokensPencilEdge(edge: .bottom, seed: seed, offset: 4 - TokensUI.module / 2)
                .stroke(isEnabled ? TokensUI.rule : TokensUI.secondary,
                        style: TokensPencil.style(hovered && isEnabled ? 1.5 : 1, dashed: !isEnabled))
        } else {
            ZStack {
                Rectangle().fill(TokensUI.rule.opacity(pressed ? 0.08 : 0)).padding(.leading, 1).padding(.top, 1)
                TokensPencilBox(seed: seed)
                    .stroke(kind == .primary && isEnabled ? TokensUI.ink : TokensUI.rule,
                            style: TokensPencil.style(kind == .primary ? 1.75 : 1, dashed: !isEnabled))
            }
        }
    }
}


// TokensBareButtonStyle — A button that draws only its label: no system dimming, no fill


/// A button that draws only its label: no system dimming, no fill.
struct TokensBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { Rectangle().fill(TokensUI.rule.opacity(configuration.isPressed ? 0.08 : 0)) }
    }
}


// TokensRowButtonStyle — a row you can open: underline on hover, light wash when pressed


/// A row you can open: underlined in graphite under the pointer, washed lightly while pressed.
struct TokensRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TokensRowButtonBody(configuration: configuration) }
}


// TokensRowButtonBody — holds a row button's hover state; draws its underline and press wash


struct TokensRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .tokensHoverUnderline(hovered, reduceMotion: reduceMotion)
            .background { Rectangle().fill(TokensUI.rule.opacity(configuration.isPressed ? 0.08 : 0)) }
            .onHover { hovered = $0 }
    }
}

//
// :)
//
//
// TokensKeycap — a shortcut name inside one pencil outline.

/// One outline keeps the shortcut legible; the Option glyph reinforces its physical key.
struct TokensKeycap: View {
    let name: String
    var ink: TokensInk = .primary

    private var displayedName: String {
        name.hasSuffix("Option") ? "⌥ " + name : name
    }

    var body: some View {
        TokensLabel(displayedName, ink: ink)
            .frame(width: max(2 * TokensUI.module, TokensUI.snap(TokensUI.textWidth(displayedName, size: 15) + 20)))
            .padding(.bottom, TokensUI.module / 2)
            .background {
                TokensPencilBox(seed: TokensPencil.seed(name))
                    .stroke(ink.color, style: TokensPencil.style())
                    .allowsHitTesting(false)
            }
            .padding(.bottom, -TokensUI.module / 2)
            .accessibilityLabel(name)
    }
}


// TokensToggleStyle — on/off switch: hollow dot on the left is off, solid on the right is on


/// A switch drawn across two squares: a hollow dot on the left is off, a solid one on the right is on.
struct TokensToggleStyle: ToggleStyle {
    /*
    VoiceOver is given a real system Toggle (accessibilityRepresentation) while the pencil mark is
    what appears on screen.
    */
    func makeBody(configuration: Configuration) -> some View {
        TokensToggleMark(isOn: configuration.$isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}


/// A paper-native On / Off choice; the red pen circle identifies the selection.
struct TokensAutoSendStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            choice("Off", selected: !configuration.isOn) { configuration.isOn = false }
            choice("On", selected: configuration.isOn) { configuration.isOn = true }
        }
        .alignmentGuide(.firstTextBaseline) { _ in 17 }
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }

    private func choice(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(selected ? TokensUI.ink : TokensUI.secondary)
                .frame(width: 44, height: 24)
                .background {
                    TokensPenCircle(seed: 41).stroke(TokensUI.red, lineWidth: 1.25)
                        .frame(width: 43, height: 25)
                        .rotationEffect(.degrees(-5))
                        .opacity(selected ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(TokensBareButtonStyle())
        .tokensFocus()
    }
}

// TokensToggleMark — the drawn switch itself: a ruled two-square box holding one dot


struct TokensToggleMark: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /*
    The box is two squares wide and one tall. Both dots are always present; isOn fades the hollow
    one out on the left and the solid one in on the right (no fade under Reduce Motion). A disabled
    switch gets a dashed box and its solid dot turns grey.
    */
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: .topLeading) {
                TokensPencilBox(seed: 41, overshoot: 1.5)
                    .stroke(TokensUI.rule, style: TokensPencil.style(dashed: !isEnabled))
                Circle().stroke(TokensUI.rule, lineWidth: 1).frame(width: 11, height: 11)
                    .offset(x: (TokensUI.module - 11) / 2, y: (TokensUI.module - 11) / 2).opacity(isOn ? 0 : 1)
                Circle().fill(isEnabled ? TokensUI.ink : TokensUI.secondary).frame(width: 12, height: 12)
                    .offset(x: TokensUI.module + (TokensUI.module - 12) / 2, y: (TokensUI.module - 12) / 2).opacity(isOn ? 1 : 0)
            }
            .frame(width: 2 * TokensUI.module, height: TokensUI.module, alignment: .topLeading)
            .contentShape(Rectangle())
            .animation(TokensUI.fade(reduceMotion), value: isOn)
        }
        .buttonStyle(TokensBareButtonStyle())
        .tokensFocus()
    }
}

//
// :)
//
//
// TokensPencilCheckboxStyle — a tick box exactly one graph square across, ticked in pencil


/// A tick box that is exactly one graph square, ticked in pencil.
struct TokensPencilCheckboxStyle: ToggleStyle {
    /*
    The tick is always in the view and only its opacity changes with the state. Like the switch,
    VoiceOver gets a real system Toggle.
    */
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .bottom, spacing: TokensUI.module / 2) {
                ZStack {
                    TokensPencilBox(seed: 43, overshoot: 1.5).stroke(TokensUI.rule, style: TokensPencil.style())
                    TokensPencilCheck().stroke(TokensUI.ink, style: TokensPencil.style(1.5))
                        .opacity(configuration.isOn ? 1 : 0)
                }
                .frame(width: TokensUI.module, height: TokensUI.module)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TokensBareButtonStyle())
        .tokensFocus()
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}


// TokensSlider — a number line ruled on a grid line, set by dragging or the arrow keys


/// A number line ruled along a grid line: one square per whole unit, a tick per step, a solid dot for the value.
struct TokensSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    @Environment(\.isEnabled) private var isEnabled
    /*
    Room around the line for the dot and the ticks to draw in: the canvas is this much bigger on
    every side, and the `.padding(-reach)` near the end of body takes it back, so the control
    takes up only the line's own size in the layout.
    */
    private let reach: CGFloat = 8

    // One square of width for each whole unit of the range.
    private var width: CGFloat { CGFloat((range.upperBound - range.lowerBound).rounded()) * TokensUI.module }

    var body: some View {
        /*
        Draws one ruled line with a tick for every `step` (taller where the tick falls on a whole
        number) in graphite, then the value as a solid 12-point dot in ink. The +0.5 offsets put the
        1-point lines on the centre of the paper's grid lines. The dot's x is the value's fraction of
        the line's width.
        */
        Canvas { context, size in
            let origin = CGPoint(x: reach, y: size.height - reach)
            let colour = GraphicsContext.Shading.color(isEnabled ? TokensUI.rule : TokensUI.secondary)
            var lines  = Path()
            TokensPencil.stroke(&lines, from: CGPoint(x: origin.x + 0.5, y: origin.y + 0.5),
                                to: CGPoint(x: origin.x + width + 0.5, y: origin.y + 0.5), seed: 61, overshoot: 2)
            let steps = Int(((range.upperBound - range.lowerBound) / step).rounded())
            for index in 0...max(steps, 1) {
                let x     = origin.x + width * CGFloat(index) / CGFloat(max(steps, 1)) + 0.5
                let whole = (Double(index) * step).truncatingRemainder(dividingBy: 1) == 0
                TokensPencil.stroke(&lines, from: CGPoint(x: x, y: origin.y - (whole ? 5 : 2.5)),
                                    to: CGPoint(x: x, y: origin.y + 0.5), seed: 62 + index)
            }
            context.stroke(lines, with: colour, style: TokensPencil.style())
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knob = CGRect(x: origin.x + width * CGFloat(fraction) - 5.5, y: origin.y - 5.5, width: 12, height: 12)
            context.fill(Path(ellipseIn: knob), with: .color(isEnabled ? TokensUI.ink : TokensUI.secondary))
        }
        .frame(width: width + 2 * reach, height: TokensUI.module + 2 * reach)
        .contentShape(Rectangle())
        /*
        A plain click (minimumDistance 0) already sets the value, before any dragging. The pointer's
        x becomes a fraction of the line's width, clamped to 0...1, then snapped to the nearest
        multiple of `step`. The assignment is skipped when the value would not change.
        */
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let fraction = Double(min(max((drag.location.x - reach) / width, 0), 1))
            let raw      = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            let snapped  = (raw / step).rounded() * step
            if snapped != value { value = snapped }
        })
        .padding(-reach)
        .focusable()
        .tokensFocus()
        /*
        Arrow keys while focused: left/down lower the value by one step and right/up raise it,
        stopping at the ends of the range.
        */
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: value = max(range.lowerBound, value - step)
            case .right, .up:  value = min(range.upperBound, value + step)
            default:           break
            }
        }
        // VoiceOver gets a real system Slider with the same range and step.
        .accessibilityRepresentation { Slider(value: $value, in: range, step: step) { Text(label) } }
    }
}

