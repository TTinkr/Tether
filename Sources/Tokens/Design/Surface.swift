


//
import AppKit
import SwiftUI

extension TokensUI {
    /// One-point hairline inside panels: ink at 10%, translucent so it suits any surface.
    static var hairline: Color { TokensInk.primary.color.opacity(TokensTheme.current.palette.hairline) }
    /// Hover wash behind rail rows and list rows: ink at the palette's hover alpha.
    static var hover: Color { TokensInk.primary.color.opacity(TokensTheme.current.palette.hover) }
    /// Legacy red washes. Still declared so older views compile; no V3 view uses them (DESIGN.md §2.4).
    static var redWash: Color { TokensInk.red.color.opacity(isDark ? 0.14 : 0.08) }
    static var redChip: Color { TokensInk.red.color.opacity(isDark ? 0.16 : 0.10) }
    /// The inset panel surface (Terms reader, Dictionary text editor, full keyboard only).
    static var card: Color { Color(tokensHex: TokensTheme.current.palette.card) }
    static let cardRadius: CGFloat = 12
    /// The page column's widest measure: 11 squares. TokensColumn places it on the rules.
    static let pageMaxWidth: CGFloat = 616
    /// Legacy side margin for views that do not use TokensColumn yet: one square.
    static let pageGutter: CGFloat = 56

    /*
    Ink blended over a palette surface, returned opaque. Opaque controls hide the grid line that
    passes behind them. Each channel is base × (1 − alpha) + ink × alpha, rounded to 8 bits, so
    Chalkboard values match DESIGN.md §2.3 exactly (ink 0.06 over the sheet is #2A2F2D).
    */
    static func opaqueHex(_ inkAlpha: Double, over base: UInt32, ink: UInt32 = TokensTheme.current.palette.ink) -> UInt32 {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) }
        var result: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let mixed = channel(base, shift) * (1 - inkAlpha) + channel(ink, shift) * inkAlpha
            result |= UInt32(min(255, max(0, mixed.rounded()))) << shift
        }
        return result
    }
    static func opaque(_ inkAlpha: Double, over base: UInt32) -> Color { Color(tokensHex: opaqueHex(inkAlpha, over: base)) }

    private static var sheetHex: UInt32 { TokensTheme.current.palette.sheet }
    /// Second ink: the greeting, unselected rail labels and icons, the blocker message.
    static var ink2: Color { Color(tokensHex: ink2Hex(TokensTheme.current.palette)) }
    /// ink2 for one palette: ink at the palette's ink2Alpha over its sheet (0.82 dark, 0.92 Paper).
    static func ink2Hex(_ palette: TokensPalette) -> UInt32 {
        opaqueHex(palette.ink2Alpha, over: palette.sheet, ink: palette.ink)
    }
    /// Decorative glyphs and disabled strokes only. Never text (2.46:1).
    static var faint: Color { opaque(0.30, over: sheetHex) }
    /// Quiet buttons, text fields, the segmented track and the stepper.
    static var raised: Color { opaque(0.06, over: sheetHex) }
    /// The key chip and keyboard keycaps, and their hover.
    static var chip: Color { opaque(0.08, over: sheetHex) }
    static var chipHover: Color { opaque(0.12, over: sheetHex) }
    /// The selected segment.
    static var selected: Color { opaque(0.14, over: sheetHex) }
    /// Disabled primary and quiet buttons; the secondary label on it stays readable.
    static var disabledFill: Color { opaque(0.05, over: sheetHex) }
    /// The one rule under Home's hero; opaque, so it covers the grid line it sits on.
    static var divider: Color { opaque(0.12, over: sheetHex) }
    /// Inset panel border and control borders (translucent: they sit on their own fills).
    static var panelEdge: Color { TokensInk.primary.color.opacity(0.07) }
    static var controlEdge: Color { TokensInk.primary.color.opacity(0.16) }
    /// The 1-point line between the rail and the working sheet.
    static var seam: Color { Color(tokensHex: TokensTheme.current.palette.seam) }
    /// The primary fill while pressed: redFill at 90% brightness (#B83C33 on Chalkboard).
    static var redPressed: Color {
        Color(tokensHex: opaqueHex(0.10, over: TokensTheme.current.palette.redFill, ink: 0x000000))
    }
}

/// The type scale. SF system only, regular and medium only; the wordmark is the only other face.
enum TokensType {
    /// Home headline only. Views add `.tracking(displayTracking)` and a 0.75 minimum scale.
    static let display       = Font.system(size: 44, weight: .regular)
    static let displayTracking: CGFloat = -0.4
    /// Setup step headline.
    static let headline      = Font.system(size: 28, weight: .regular)
    /// Page titles; Home greeting (in ink2).
    static let title         = Font.system(size: 24, weight: .regular)
    /// Home hint line, live transcript, setup lead line.
    static let lead          = Font.system(size: 17, weight: .regular)
    /// Legacy 16 medium, used only by the Access step.
    static let section       = Font.system(size: 16, weight: .medium)
    /// Row text, settings row titles, reading text, checkbox label.
    static let body          = Font.system(size: 15, weight: .regular)
    /// 48-point buttons.
    static let labelLarge    = Font.system(size: 15, weight: .medium)
    /// 32-point buttons, selected rail label, selected segment.
    static let label         = Font.system(size: 14, weight: .medium)
    /// Times, values, hints, links, captions.
    static let caption       = Font.system(size: 13, weight: .regular)
    /// Section labels ("General") and day labels ("Today").
    static let captionStrong = Font.system(size: 13, weight: .medium)
    static let eyebrow       = captionStrong
    /// Keyboard keycap legends only.
    static let micro         = Font.system(size: 11, weight: .medium)
    static let stat          = Font.system(size: 13, weight: .medium).monospacedDigit()

    /*
    Line spacing that gives wrapped text a `pitch` line pitch: pitch minus the line box SwiftUI
    actually draws for the system font. SwiftUI snaps that box to whole points: the ascender
    rounded plus the descender (and leading) rounded up, measured 2026-10-13 as 16, 19 and 20 at
    13, 15 and 17 points (exact for 11-23 points). The raw NSFont sum ascender − descender +
    leading (17.7 at 15) left a 29.5-point pitch, so it is not used. Never type the constant;
    PaperAlignmentTests measures the real pitch.
    */
    static func lineSpacing(size: CGFloat, pitch: CGFloat = TokensUI.halfCell) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return pitch - (font.ascender.rounded() + (font.leading - font.descender).rounded(.up))
    }
}

//
// :)
//
//
/// The inset panel: card fill, 1-point panel edge, radius 12, no shadow. Panels never nest.
struct TokensCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TokensUI.card, in: RoundedRectangle(cornerRadius: TokensUI.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TokensUI.cardRadius, style: .continuous)
                    .strokeBorder(TokensUI.panelEdge, lineWidth: 1)
            }
    }
}

/// A one-point line: ink at 10% inside panels, or the opaque divider when `strong`. Its text
/// baseline is its top edge, so `.tokensOnRule()` draws it exactly over a grid rule.
struct TokensHairline: View {
    var strong = false
    init(strong: Bool = false) { self.strong = strong }
    // One screen point at any zoom, like the sheet grid and TokensHistoryDivider (render sweep
    // 2026-10-16: at 150% a fixed 1 pt rule bled into a second pixel row beside the grid line).
    @Environment(\.tokensSheetZoom) private var zoom
    var body: some View {
        Rectangle().fill(strong ? TokensUI.divider : TokensUI.hairline).frame(height: TokensHistoryDivider.weight(zoom: zoom))
            .alignmentGuide(.firstTextBaseline) { _ in 0 }
            .alignmentGuide(.lastTextBaseline) { _ in 0 }
            .accessibilityHidden(true)
    }
}

/// A group label ("Today", "General") in sentence case: 13 medium secondary, no tracking.
struct TokensEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(TokensType.eyebrow)
            .foregroundStyle(TokensUI.secondary)
    }
}

/// A 6-point status dot. In a baseline row it centres on 13-point text's x-height.
struct TokensStatusDot: View {
    let color: Color
    init(color: Color) { self.color = color }
    private static let xHeightCentre = NSFont.systemFont(ofSize: 13).xHeight / 2
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.xHeightCentre }
            .alignmentGuide(.lastTextBaseline) { $0.height / 2 + Self.xHeightCentre }
            .accessibilityHidden(true)
    }
}

//
// :)
//
//
/// Button heights (DESIGN.md §5.5): regular 32 in pages, compact 36 in the short setup window,
/// large 48 for setup actions.
enum TokensButtonSize {
    case regular, compact, large

    var height: CGFloat {
        switch self {
        case .regular: return 32
        case .compact: return 36
        case .large:   return 48
        }
    }
    var radius: CGFloat { self == .large ? 10 : 8 }
    var padding: CGFloat {
        switch self {
        case .regular: return 14
        case .compact: return 16
        case .large:   return 22
        }
    }
    var font: Font { self == .large ? TokensType.labelLarge : TokensType.label }
}

/// Font, padding and height go on the label first, then the fill: the drawn shape is the hit
/// target, and a caller's maxWidth .infinity on the label fills the shape.
private struct TokensButtonChrome: ViewModifier {
    let size: TokensButtonSize
    let fill: Color
    let edge: Color?
    let ink: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        content
            .font(size.font)
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .background(fill, in: shape)
            .overlay { if let edge { shape.strokeBorder(edge, lineWidth: 1) } }
            .contentShape(shape)
    }
}

/// Disabled primary and quiet buttons look the same: neutral fill, hairline, secondary label.
private extension TokensButtonChrome {
    static func disabled(_ size: TokensButtonSize) -> TokensButtonChrome {
        TokensButtonChrome(size: size, fill: TokensUI.disabledFill,
                           edge: TokensInk.primary.color.opacity(0.14), ink: TokensUI.secondary)
    }
}

/// The one red action on a screen: red fill, white label. Disabled is never red.
struct TokensPrimaryButtonStyle: ButtonStyle {
    var size: TokensButtonSize = .regular
    init(size: TokensButtonSize = .regular) { self.size = size }

    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, size: size) }

    private struct Chrome: View {
        let configuration: Configuration
        let size: TokensButtonSize
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.modifier(enabled
                ? TokensButtonChrome(size: size, fill: configuration.isPressed ? TokensUI.redPressed : TokensUI.redFill,
                                     edge: nil, ink: .white)
                : .disabled(size))
        }
    }
}

/// A quiet button: raised fill, control edge, ink label; pressed shows the chip-hover fill.
struct TokensQuietButtonStyle: ButtonStyle {
    var size: TokensButtonSize = .regular
    init(size: TokensButtonSize = .regular) { self.size = size }

    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, size: size) }

    private struct Chrome: View {
        let configuration: Configuration
        let size: TokensButtonSize
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.modifier(enabled
                ? TokensButtonChrome(size: size, fill: configuration.isPressed ? TokensUI.chipHover : TokensUI.raised,
                                     edge: TokensUI.controlEdge, ink: TokensUI.ink)
                : .disabled(size))
        }
    }
}

/*
Text links. The style sets no font, so a link takes the size of the line it sits in. Quiet
(the default) is secondary and turns ink on hover and press: See all, Back, Show all keys, Edit
as text, Terms and Privacy. Accent is red, only for the rail's Update offer and hard-error retry.
*/
struct TokensLinkButtonStyle: ButtonStyle {
    enum Tone { case quiet, accent }
    var tone: Tone = .quiet
    init(tone: Tone = .quiet) { self.tone = tone }

    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, tone: tone) }

    private struct Chrome: View {
        let configuration: Configuration
        let tone: Tone
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        private var ink: Color {
            guard enabled else { return TokensUI.secondary }
            switch tone {
            case .quiet:  return hovered || configuration.isPressed ? TokensUI.ink : TokensUI.secondary
            case .accent: return TokensUI.red
            }
        }
        var body: some View {
            configuration.label
                .foregroundStyle(ink)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/*
The dictation key as a neutral chalk keycap: chip fill, control edge, a 1-point lip of ink at
22% inside the bottom edge, radius 6, height size + 12. The modifier glyph is secondary and the
name ink. Never red. Inside a Button pass interactive: true for the hover fill.
*/
struct TokensKeyChip: View {
    let name: String
    var size: CGFloat = 14
    var interactive = false
    @State private var hovered = false

    init(name: String, size: CGFloat = 14, interactive: Bool = false) {
        self.name = name
        self.size = size
        self.interactive = interactive
    }

    private var glyph: String {
        if name.contains("Option") { return "⌥" }
        if name.contains("Command") { return "⌘" }
        if name.contains("Control") { return "⌃" }
        return ""
    }
    private var globe: Bool { name.contains("Globe") || name.contains("Fn") }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if globe {
                Image(systemName: "globe").font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(TokensUI.secondary)
            } else if !glyph.isEmpty {
                Text(glyph).font(.system(size: size, weight: .medium)).foregroundStyle(TokensUI.secondary)
            }
            Text(name).font(.system(size: size, weight: .medium)).foregroundStyle(TokensUI.ink)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: size + 12)
        .background(interactive && hovered ? TokensUI.chipHover : TokensUI.chip, in: shape)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TokensInk.primary.color.opacity(0.22)).frame(height: 1).padding(.bottom, 1)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(TokensUI.controlEdge, lineWidth: 1) }
        .onHover { hovered = interactive && $0 }
        .accessibilityLabel("Talk key \(name)")
    }
}

//
// :)
//
//
/*
A 36 × 20 switch with a 16-point knob. On: an ink track and a sheet-coloured knob. Off: a faint
track, a 1.5-point edge and a light knob. Disabled keeps its real position on a neutral track.
It centres 5 points above the row's baseline, like every control on a line.
*/
struct TokensSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var look: (track: Color, edge: Color?, knob: Color) {
            let sheet = TokensTheme.current.palette.sheet
            if !enabled {
                return (TokensUI.disabledFill, TokensUI.opaque(0.14, over: sheet), TokensUI.opaque(0.30, over: sheet))
            }
            if configuration.isOn { return (TokensUI.ink, nil, TokensUI.sheet) }
            return (TokensUI.opaque(0.10, over: sheet), TokensUI.opaque(0.38, over: sheet), TokensUI.opaque(0.75, over: sheet))
        }

        var body: some View {
            let look = look
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 0) {
                    configuration.label.lineLimit(1).fixedSize().frame(width: 0, height: 0).clipped().hidden()
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule().fill(look.track)
                        if let edge = look.edge { Capsule().strokeBorder(edge, lineWidth: 1.5) }
                        Circle().fill(look.knob).frame(width: 16, height: 16).padding(2)
                    }
                    .frame(width: 36, height: 20)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .tokensControlOnBaseline()
            .accessibilityAddTraits(.isToggle)
        }
    }
}

/*
An 18 × 18 checkbox, radius 4, 10 points before its 15-point label; the whole row (at least 32
tall) is the hit shape. Off: raised fill and a 1.5-point edge. On: an ink box with a checkmark in
the sheet colour. Disabled: a fainter edge, no fill, secondary label.
*/
struct TokensCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        private var box: some View {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            let sheet = TokensTheme.current.palette.sheet
            return ZStack {
                if configuration.isOn && enabled {
                    shape.fill(TokensUI.ink)
                } else {
                    shape.fill(enabled ? TokensUI.raised : Color.clear)
                    shape.strokeBorder(TokensUI.opaque(enabled ? 0.45 : 0.20, over: sheet), lineWidth: 1.5)
                }
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(enabled ? TokensUI.sheet : TokensUI.secondary)
                }
            }
            .frame(width: 18, height: 18)
        }

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    box.tokensControlOnBaseline()
                    configuration.label
                        .font(TokensType.body)
                        .foregroundStyle(enabled ? TokensUI.ink : TokensUI.secondary)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // VoiceOver gets a real system checkbox with the same label and state.
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/*
A raised track (1-point control edge, radius 8, 28 tall, 2-point inset). The chosen segment is
the selected fill with ink 14 medium; the others are secondary 14 regular. No red. A hidden
medium copy holds each segment's width so choosing one never shifts the others.
*/
struct TokensSegmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// What VoiceOver says for a segment when its short label isn't enough ("7" → "Last 7 days").
    var spoken: ((Option) -> String)? = nil
    /// A per-segment identifier prefix, so automation can tell the segments apart.
    var identifierPrefix: String? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, label in
                let on = option == selection
                Button { selection = option } label: {
                    ZStack {
                        Text(label).font(TokensType.label).hidden()
                        Text(label)
                            .font(on ? TokensType.label : .system(size: 14, weight: .regular))
                            .foregroundStyle(on ? TokensUI.ink : TokensUI.secondary)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(on ? TokensUI.selected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken?(option) ?? label)
                .accessibilityIdentifier(identifierPrefix.map { "\($0).\(label.lowercased())" } ?? "")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(TokensUI.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TokensUI.controlEdge, lineWidth: 1) }
    }
}

extension View {
    /*
    The text-field surface: raised fill, radius 8, 36 tall, 12 inside, 15-point text, and a
    1.5-point ink edge while focused. Typed text keeps the dark scheme's label colour. Apply it
    to the TextField, or to an HStack holding a leading icon and the TextField.
    */
    func tokensFieldSurface(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return textFieldStyle(.plain)
            .font(TokensType.body)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(TokensUI.raised, in: shape)
            .overlay { if focused { shape.strokeBorder(TokensInk.primary.color.opacity(0.45), lineWidth: 1.5) } }
    }

    /*
    The placeholder in secondary, drawn by Tokens. macOS draws a TextField's own prompt or title
    in a fixed bright grey (measured 220 of 255 on Chalkboard, typed text 251) whatever
    foregroundStyle the prompt or the field carries, so it looks typed. Give the TextField an
    empty title and no prompt, then apply this to the TextField itself:
    TextField("", text: $entry).tokensFieldPlaceholder("Add a word or name", empty: entry.isEmpty)
    It is hidden from VoiceOver; give the field its own accessibility label.
    */
    func tokensFieldPlaceholder(_ text: String, empty: Bool) -> some View {
        overlay(alignment: .leading) {
            if empty {
                Text(text)
                    .font(TokensType.body)
                    .foregroundStyle(TokensUI.secondary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Shows its content only while the pointer is over the enclosing row (always in proof renders,
/// which have no pointer, so the frames show the action). Pages choose which rows use it.
struct TokensHoverReveal<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: Content
    private static var alwaysShow: Bool { ProcessInfo.processInfo.arguments.contains("--render-preview-frames") }

    var body: some View {
        content
            .opacity(hovering || Self.alwaysShow ? 1 : 0)
            .onHover { hovering = $0 }
    }
}

//
// :)
//
//
/*
The page column (DESIGN.md §4.4): TokensColumn's width and leading for the current sheet, no top
padding (the first line lands on rule 3), and bottom padding so the last scroll position also
rests on a rule. The sheet size comes from the environment, never from a GeometryReader.
*/
struct TokensPageColumn: ViewModifier {
    var maxWidth: CGFloat = TokensUI.pageMaxWidth
    @Environment(\.tokensSheetSize) private var sheet

    func body(content: Content) -> some View {
        let column = TokensColumn.layout(sheetWidth: sheet.width, maxWidth: maxWidth)
        content
            .frame(width: column.width, alignment: .leading)
            .padding(.leading, column.leading)
            .padding(.bottom, TokensColumn.bottomPadding(sheetHeight: sheet.height))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func tokensPageColumn(maxWidth: CGFloat = TokensUI.pageMaxWidth) -> some View {
        modifier(TokensPageColumn(maxWidth: maxWidth))
    }
}

/// Render-only preview switches. Each needs --render-preview-frames and a proof-allowed build,
/// and none writes preferences or consent.
enum TokensPreview {
    /// --public-preview-ready: Home and the rail draw the Ready state.
    static var forcesReady: Bool {
        forcesReady(arguments: ProcessInfo.processInfo.arguments, allowed: ProofRoutes.isAllowed)
    }
    static func forcesReady(arguments: [String], allowed: Bool) -> Bool {
        allowed && arguments.contains("--render-preview-frames") && arguments.contains("--public-preview-ready")
    }
}

//
// :)
//
//
/*
Every role, ink level and control on the rules, for proof renders only
(--render-preview-frames --public-preview-page kit). Static: no model, constant bindings, and
nothing here saves anything. Each row is one .tokensOnRule() line; red appears only on the
enabled primary buttons and the accent link.
*/
struct TokensKitSpecimen: View {
    private func row<Content: View>(spacing: CGFloat = 16, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
    }

    private func buttons(_ size: TokensButtonSize, primary: String, quiet: String) -> some View {
        row(spacing: 12) {
            Button(primary) {}.buttonStyle(TokensPrimaryButtonStyle(size: size))
            Button(primary) {}.buttonStyle(TokensPrimaryButtonStyle(size: size)).disabled(true)
            Button(quiet) {}.buttonStyle(TokensQuietButtonStyle(size: size))
            Button(quiet) {}.buttonStyle(TokensQuietButtonStyle(size: size)).disabled(true)
            Text("\(Int(size.height)) tall").font(TokensType.caption).foregroundStyle(TokensUI.secondary)
        }
    }

    private func toggle(_ on: Bool, checkbox: Bool = false, label: String = "", disabled: Bool = false) -> some View {
        Group {
            if checkbox {
                Toggle(label, isOn: .constant(on)).toggleStyle(TokensCheckboxStyle())
            } else {
                Toggle(label, isOn: .constant(on)).toggleStyle(TokensSwitchStyle())
            }
        }
        .disabled(disabled)
    }

    private func field(_ text: String, focused: Bool) -> some View {
        TextField("", text: .constant(text))
            .tokensFieldPlaceholder("Add a word or name", empty: text.isEmpty)
            .tokensFieldSurface(focused: focused)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(spacing: 20) {
                Text("Ready").font(TokensType.display).tracking(TokensType.displayTracking)
                Text("Headline").font(TokensType.headline)
                Text("Title").font(TokensType.title)
                Text("Lead").font(TokensType.lead)
            }
            .foregroundStyle(TokensUI.ink)
            row {
                Text("Body").font(TokensType.body)
                Text("Label large").font(TokensType.labelLarge)
                Text("Label").font(TokensType.label)
                Text("Caption").font(TokensType.caption)
                Text("Caption strong").font(TokensType.captionStrong)
                Text("Micro").font(TokensType.micro)
                Text("27").font(TokensType.stat)
            }
            .foregroundStyle(TokensUI.ink)
            row {
                Text("Ink").foregroundStyle(TokensUI.ink)
                Text("Ink 2").foregroundStyle(TokensUI.ink2)
                Text("Secondary").foregroundStyle(TokensUI.secondary)
                Capsule().fill(TokensUI.faint).frame(width: 24, height: 3).tokensControlOnBaseline(3)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TokensStatusDot(color: TokensUI.secondary)
                    Text("Finishing").font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                }
                Button {} label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("See all")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(TokensLinkButtonStyle())
                Button("Update") {}.buttonStyle(TokensLinkButtonStyle(tone: .accent))
            }
            .font(TokensType.body)
            buttons(.regular, primary: "Agree", quiet: "Copy")
            buttons(.compact, primary: "Start", quiet: "Skip for now")
            buttons(.large, primary: "Agree", quiet: "Decline")
            row(spacing: 12) {
                toggle(true)
                toggle(false)
                toggle(true, disabled: true)
                toggle(false, disabled: true)
                TokensSegmented(options: [(0, "Press"), (1, "Hold")], selection: .constant(0))
                    .tokensControlOnBaseline()
                TokensKeyChip(name: "Left Option", size: 14)
            }
            row(spacing: 20) {
                toggle(false, checkbox: true, label: "Off")
                toggle(true, checkbox: true, label: "On")
                toggle(false, checkbox: true, label: "Disabled", disabled: true)
                TokensKeyChip(name: "Left Option", size: 15)
                TokensKeyChip(name: "Fn", size: 20)
            }
            row(spacing: 12) {
                field("", focused: false)
                field("Kestrel", focused: true)
            }
            row(spacing: 24) {
                Text("Hairline").font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                TokensHairline().frame(width: 196)
                Text("Divider").font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                TokensHairline(strong: true).frame(width: 196)
            }
            HStack(alignment: .top, spacing: TokensUI.paperCell) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keep every recognized word.").tokensOnRule()
                    Text("Make the capsule feel calm.").tokensOnRule()
                    Text("Show all previous prompts.").tokensOnRule()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Reading text wraps at a 28-point pitch, so every line sits on a rule or half-way between.")
                    .tokensReadingPitch()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tokensOnRule()
            }
            .font(TokensType.body)
            .foregroundStyle(TokensUI.ink)
            TokensRuleSpacer(cells: 0.5)
            TokensCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Inset panel").font(TokensType.labelLarge).foregroundStyle(TokensUI.ink)
                    TokensHairline()
                    Text("Card fill, 1-point panel edge, radius 12, no shadow.")
                        .font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                }
                // Two whole squares tall with the default 16 padding: both edges on half-rules.
                .frame(height: 2 * TokensUI.paperCell - 32, alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("tokens.kit")
    }
}

