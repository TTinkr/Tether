


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// ShortcutKeyboard — the talk-key picker: a drawn Mac keyboard where a click picks the key


struct ShortcutKeyboard: View {


    // The keys — codes, names and the layout rows


    /*
    One physical key: its macOS key code, the label drawn on it, and a width in points (used only by
    the older full-size keyboard; the compact keyboard uses compactRows instead).
    */
    private struct Key: Identifiable {
        let code: UInt16
        let label: String
        let width: CGFloat
        var id: UInt16 { code }
        var shortcut: TalkShortcut {
            TalkShortcut(keyCode: code, displayName: Self.displayName(code: code, label: label))
        }
        // Readable names for modifier, arrow and a few special keys. Every other key is named by its label.
        private static func displayName(code: UInt16, label: String) -> String {
            switch code {
            case 54:  return "Right Command"
            case 55:  return "Left Command"
            case 56:  return "Left Shift"
            case 60:  return "Right Shift"
            case 58:  return "Left Option"
            case 61:  return "Right Option"
            case 59:  return "Left Control"
            case 62:  return "Right Control"
            case 63:  return "Fn / Globe"
            case 49:  return "Space"
            case 36:  return "Return"
            case 51:  return "Delete"
            case 53:  return "Escape"
            case 123: return "Left Arrow"
            case 124: return "Right Arrow"
            case 125: return "Down Arrow"
            case 126: return "Up Arrow"
            default:  return label
            }
        }
        // Nothing in the app reads spokenName at the moment.
        var spokenName: String {
            switch code {
            case 50: return "Grave Accent"
            case 27: return "Minus"
            case 24: return "Equals"
            case 33: return "Left Bracket"
            case 30: return "Right Bracket"
            case 42: return "Backslash"
            case 41: return "Semicolon"
            case 39: return "Apostrophe"
            case 43: return "Comma"
            case 47: return "Period"
            case 44: return "Slash"
            default: return shortcut.displayName
            }
        }
    }

    let selectedKeyCode: UInt16
    /// Keys another Tokens channel owns; shown but not selectable.
    private let reservedKeys = TalkShortcut.siblingReservedKeys()
    let compact: Bool
    let selectionEnabled: Bool

//
// :)
//
//
    let onSelect: (TalkShortcut) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingTypingKey: TalkShortcut?

    init(selectedKeyCode: UInt16, compact: Bool = false, selectionEnabled: Bool = true,
         onSelect: @escaping (TalkShortcut) -> Void) {
        self.selectedKeyCode  = selectedKeyCode
        self.compact          = compact
        self.selectionEnabled = selectionEnabled
        self.onSelect         = onSelect
    }

    /*
    Shorthand for the rows below: key(code, label, width). The width is only used by the older
    full-size keyboard and defaults to 34 points.
    */
    private static func key(_ code: UInt16, _ label: String, _ width: CGFloat = 34) -> Key {
        Key(code: code, label: label, width: width)
    }

    /*
    Six rows laid out like a Mac keyboard. The first number in each key(...) is the macOS key code
    (for example 49 is space, 58 Left Option, 61 Right Option, 63 Fn / Globe).
    */
    private let rows: [[Key]] = [
        [key(53, "esc", 48), key(122, "F1"), key(120, "F2"), key(99, "F3"), key(118, "F4"), key(96, "F5"), key(97, "F6"), key(98, "F7"), key(100, "F8"), key(101, "F9"), key(109, "F10"), key(103, "F11"), key(111, "F12")],
        [key(50, "`"), key(18, "1"), key(19, "2"), key(20, "3"), key(21, "4"), key(23, "5"), key(22, "6"), key(26, "7"), key(28, "8"), key(25, "9"), key(29, "0"), key(27, "-"), key(24, "="), key(51, "delete", 64)],
        [key(48, "tab", 54), key(12, "Q"), key(13, "W"), key(14, "E"), key(15, "R"), key(17, "T"), key(16, "Y"), key(32, "U"), key(34, "I"), key(31, "O"), key(35, "P"), key(33, "["), key(30, "]"), key(42, "\\", 44)],
        [key(57, "caps", 64), key(0, "A"), key(1, "S"), key(2, "D"), key(3, "F"), key(5, "G"), key(4, "H"), key(38, "J"), key(40, "K"), key(37, "L"), key(41, ";"), key(39, "'"), key(36, "return", 76)],
        [key(56, "shift", 78), key(6, "Z"), key(7, "X"), key(8, "C"), key(9, "V"), key(11, "B"), key(45, "N"), key(46, "M"), key(43, ","), key(47, "."), key(44, "/"), key(60, "shift", 88)],
        [key(63, "fn", 42), key(59, "ctrl", 48), key(58, "⌥ left", 66), key(55, "⌘", 48), key(49, "space", 210), key(54, "⌘", 48), key(61, "⌥ right", 78), key(62, "ctrl", 48), key(123, "←"), key(125, "↓"), key(126, "↑"), key(124, "→")]
    ]


    // The older full-size keyboard


    var body: some View {
        Group {
            /*
            compact: the chalk keyboard used in the Tokens window. Otherwise the older full-size one
            below (only the old shell, Unreached/OldShell.swift, still asks for it). The VStack that
            follows is the body of the `else` on the next line even though it is not indented under
            it.
            */
            if compact { compactKeyboard }
            else {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose the talk key")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                    Text("The highlighted key is active. One press starts; the next press pastes.")
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(academicPencil)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            /*
            Full-size keyboard: rows of rounded keys that scroll sideways if the window is narrow.
            The chosen key is solid ink with card-coloured text (no red, DESIGN.md §2.4); a key
            reserved by a sibling app is dimmed to 35%, cannot be clicked and says who uses it in its
            tooltip.
            */
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row) { key in
                                Button { selectCompactKey(key) } label: {
                                    Text(key.label)
                                        .font(.system(size: 10.5, weight: key.code == selectedKeyCode ? .bold : .medium, design: .rounded))
                                        .foregroundStyle(key.code == selectedKeyCode ? TokensUI.card : academicInk)
                                        .frame(width: key.width, height: 30)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(key.code == selectedKeyCode ? TokensUI.ink : TokensUI.card)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .strokeBorder(TokensInk.primary.color.opacity(0.08), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .disabled(reservedKeys[key.code] != nil)
                                .opacity(reservedKeys[key.code] != nil ? 0.35 : 1)
                                .help(reservedKeys[key.code].map { "Used by \($0)" } ?? "")
                                .accessibilityLabel(key.shortcut.displayName)
                                .accessibilityValue(key.code == selectedKeyCode ? "Selected talk key"
                                                    : reservedKeys[key.code].map { "Used by \($0)" } ?? "")
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 310)
        .background(AcademicGraphPaper())
        .preferredColorScheme(TokensUI.isDark ? .dark : .light)
            }
        }
    }

//
// :)
//
//
    // The keyboard used in the Tokens window (V3 chalk keycaps, DESIGN.md §6.6)


    /*
    One place in the compact layout: a key some number of half-units wide (a letter key is two),
    a blank gap between key groups, or the stacked up and down arrows sharing one column.
    */
    private enum Slot {
        case key(UInt16, Int)
        case gap(Int)
        case upDown
    }

    /*
    Six rows, each 30 half-units wide so every row ends on the same edge. No key is narrower than a
    letter key (two half-units): the old one-half-unit grave, backslash and arrow keys are gone.
    The function row is grouped in fours like a Mac keyboard; the arrows are an inverted T.
    */
    private static let compactRows: [[Slot]] = [
        [.key(53, 3), .gap(1), .key(122, 2), .key(120, 2), .key(99, 2), .key(118, 2), .gap(1),
         .key(96, 2), .key(97, 2), .key(98, 2), .key(100, 2), .gap(1),
         .key(101, 2), .key(109, 2), .key(103, 2), .key(111, 2)],
        [.key(50, 2), .key(18, 2), .key(19, 2), .key(20, 2), .key(21, 2), .key(23, 2), .key(22, 2), .key(26, 2),
         .key(28, 2), .key(25, 2), .key(29, 2), .key(27, 2), .key(24, 2), .key(51, 4)],
        [.key(48, 3), .key(12, 2), .key(13, 2), .key(14, 2), .key(15, 2), .key(17, 2), .key(16, 2), .key(32, 2),
         .key(34, 2), .key(31, 2), .key(35, 2), .key(33, 2), .key(30, 2), .key(42, 3)],
        [.key(57, 4), .key(0, 2), .key(1, 2), .key(2, 2), .key(3, 2), .key(5, 2), .key(4, 2), .key(38, 2),
         .key(40, 2), .key(37, 2), .key(41, 2), .key(39, 2), .key(36, 4)],
        [.key(56, 5), .key(6, 2), .key(7, 2), .key(8, 2), .key(9, 2), .key(11, 2), .key(45, 2), .key(46, 2),
         .key(43, 2), .key(47, 2), .key(44, 2), .key(60, 5)],
        [.key(63, 2), .key(59, 2), .key(58, 3), .key(55, 2), .key(49, 8), .key(54, 2), .key(61, 3), .key(62, 2),
         .key(123, 2), .upDown, .key(124, 2)]
    ]

    /// Half-units in each compact row and the narrowest key; the tests pin both.
    static var compactRowWidths: [Int] {
        compactRows.map { row in
            row.reduce(0) { total, slot in
                switch slot {
                case .key(_, let units), .gap(let units): return total + units
                case .upDown: return total + 2
                }
            }
        }
    }
    static var compactNarrowestKey: Int {
        compactRows.flatMap { $0 }.compactMap { slot -> Int? in
            switch slot {
            case .key(_, let units): return units
            case .upDown:            return 2
            case .gap:               return nil
            }
        }.min() ?? 0
    }

    /// Every key code the compact keyboard draws, in reading order.
    static var compactKeyCodes: [UInt16] {
        compactRows.flatMap { row in
            row.flatMap { slot -> [UInt16] in
                switch slot {
                case .key(let code, _): return [code]
                case .upDown:           return [126, 125]
                case .gap:              return []
                }
            }
        }
    }

    /*
    The smallest half-unit compactKeyboard tries. The narrowest page column the window allows is
    336 points (760 × 520 at 150%), and the panel's 16-point padding leaves 304 inside it. At 11 the
    keyboard was 327 wide, so it pushed the panel and the page 23 points past the column's right
    rule (DESIGN.md §4.4, §7). At 10 it is 297. The tests check it fits every window and zoom.
    */
    static let compactMinimumUnit: CGFloat = 10

    /// The space between keys and between rows at one half-unit width.
    static func compactGap(unit: CGFloat) -> CGFloat { unit >= 16 ? 4 : 3 }

    /// The keyboard's width at one half-unit: a full row of half-units less one gap.
    static func compactWidth(unit: CGFloat) -> CGFloat {
        CGFloat(compactRowWidths.max() ?? 0) * unit - compactGap(unit: unit)
    }

    /// The key picker: chalk keycaps on the inset panel; the chosen key is solid ink. No red.
    private var compactKeyboard: some View {
        /*
        Tries the widest half-unit first and steps down until the keyboard fits the panel. Every
        row is 30 half-units wide, so all rows end on the same edge. Only the narrowest column
        reaches the last step; every wider one stops at the same step as before.
        */
        ViewThatFits(in: .horizontal) {
            keyRows(unit: 22)
            keyRows(unit: 20)
            keyRows(unit: 19)
            keyRows(unit: 18)
            keyRows(unit: 17)
            keyRows(unit: 16)
            keyRows(unit: 15)
            keyRows(unit: 14)
            keyRows(unit: 13)
            keyRows(unit: 12)
            keyRows(unit: 11)
            keyRows(unit: Self.compactMinimumUnit)
        }
        .frame(maxWidth: .infinity)
        // The panel speaks its purpose and the current key once; each key is its own button inside.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Click a key to use it. Current key: \(selectedKeyName).")
        .accessibilityIdentifier("selected-dictation-key")
        /*
        Confirmation for ordinary typing keys (see selectCompactKey): they could start a talk by
        accident while typing, so the person is asked first.
        */
        .alert("Use \(pendingTypingKey?.displayName ?? "this key") for talking?",
               isPresented: Binding(
                get: { pendingTypingKey != nil },
                set: { if !$0 { pendingTypingKey = nil } }
               )) {
            Button("Cancel", role: .cancel) { pendingTypingKey = nil }
            Button("Use key") {
                if let pendingTypingKey { onSelect(pendingTypingKey) }
                pendingTypingKey = nil
            }
        } message: {
            Text(TalkKeyAdvice.confirmation(for: pendingTypingKey, standardFunctionKeys: TalkKeyAdvice.standardFunctionKeys()))
        }
    }

    /*
    Six rows at one half-unit width. A key n half-units wide is n × unit minus the gap, so keys and
    gaps add up to the same row width. The stacked arrows split one key height in two.
    */
    private func keyRows(unit: CGFloat) -> some View {
        let gap = Self.compactGap(unit: unit)
        let half = (0.8 * unit - gap / 2).rounded()
        let height = 2 * half + gap
        let byCode = Dictionary(rows.flatMap { $0 }.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(Self.compactRows.enumerated()), id: \.offset) { index, row in
                let rowHeight = index == 0 ? (height * 0.7).rounded() : height
                HStack(spacing: gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, slot in
                        switch slot {
                        case .key(let code, let units):
                            if let key = byCode[code] {
                                keycap(key, width: CGFloat(units) * unit - gap, height: rowHeight)
                            }
                        case .gap(let units):
                            Color.clear.frame(width: CGFloat(units) * unit - gap, height: rowHeight)
                                .accessibilityHidden(true)
                        case .upDown:
                            VStack(spacing: gap) {
                                if let up = byCode[126] { keycap(up, width: 2 * unit - gap, height: half) }
                                if let down = byCode[125] { keycap(down, width: 2 * unit - gap, height: half) }
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    /*
    Reserved keys get a dashed edge and secondary words and cannot be clicked, and nothing can be
    clicked while selectionEnabled is false.
    */
    private func keycap(_ key: Key, width: CGFloat, height: CGFloat) -> some View {
        let selected = key.code == selectedKeyCode
        let reserved = reservedKeys[key.code]
        return Button { selectCompactKey(key) } label: {
            compactKeyFace(key)
                .lineLimit(1)
                .minimumScaleFactor(Self.legendMinimumScale)
                .frame(width: width, height: height)
        }
        .buttonStyle(ShortcutKeycapStyle(selected: selected, reserved: reserved != nil,
                                         modifier: key.shortcut.modifierMask != nil))
        .disabled(!selectionEnabled || reserved != nil)
        .help(reserved.map { "Used by \($0)" } ?? "")
        .accessibilityLabel("\(key.shortcut.displayName) key")
        .accessibilityValue(selected ? "Selected talk key"
                            : reserved.map { "Used by \($0)" } ?? "")
    }

//
// :)
//
//
    /*
    Legends are 11-point medium (TokensType.micro) and shrink to fit their key, down to 60%. At the
    smallest step "⌥ right" has a 27-point key, too narrow at 70%: it showed "⌥ ri…". Every other
    legend at every step fits at 70% or more, so nothing else changes size.
    */
    static let legendMinimumScale: CGFloat = 0.6

    /*
    Return and the arrow keys are drawn as symbols; Option and Command are shortened to "⌥ left" /
    "⌘" to fit; every other key shows its label.
    */
    @ViewBuilder
    private func compactKeyFace(_ key: Key) -> some View {
        switch key.code {
        case 36:     Image(systemName: "return").font(.system(size: 10, weight: .medium))
        case 123:    Image(systemName: "arrow.left").font(.system(size: 9, weight: .medium))
        case 124:    Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium))
        case 125:    Image(systemName: "arrow.down").font(.system(size: 8, weight: .medium))
        case 126:    Image(systemName: "arrow.up").font(.system(size: 8, weight: .medium))
        default:     Text(verbatim: Self.compactLegend(code: key.code, label: key.label) ?? key.label)
                         .font(TokensType.micro)
        }
    }

    /// The words on a compact key, or nil for the keys drawn as symbols.
    static func compactLegend(code: UInt16, label: String) -> String? {
        switch code {
        case 36, 123, 124, 125, 126: return nil
        case 58:                     return "⌥ left"
        case 61:                     return "⌥ right"
        case 54, 55:                 return "⌘"
        default:                     return label
        }
    }

    /// Each worded key's legend and its width in half-units; the tests check each fits at the smallest step.
    static var compactLegendWidths: [(legend: String, units: Int)] {
        let labels = Dictionary(ShortcutKeyboard(selectedKeyCode: 0) { _ in }.rows.flatMap { $0 }.map { ($0.code, $0.label) },
                                uniquingKeysWith: { first, _ in first })
        return compactRows.flatMap { $0 }.compactMap { slot -> (legend: String, units: Int)? in
            guard case .key(let code, let units) = slot, let label = labels[code],
                  let legend = compactLegend(code: code, label: label) else { return nil }
            return (legend, units)
        }
    }

    /// Every key code in the layout rows; the tests check the compact layout draws each one once.
    static var drawnKeyCodes: [UInt16] {
        ShortcutKeyboard(selectedKeyCode: 0) { _ in }.rows.flatMap { $0 }.map(\.code)
    }

    // Name of the chosen key, or "Custom key" if it is not one of the keys drawn here.
    private var selectedKeyName: String {
        rows.flatMap { $0 }.first(where: { $0.code == selectedKeyCode })?.shortcut.displayName ?? "Custom key"
    }

    /*
    Clicks on the already-chosen key and on reserved keys do nothing. A modifier key is chosen at
    once. Any ordinary typing key, and Caps Lock (57), first raises the confirmation alert.
    */
    private func selectCompactKey(_ key: Key) {
        guard key.code != selectedKeyCode, reservedKeys[key.code] == nil else { return }
        if key.shortcut.modifierMask == nil || key.code == 57 {
            pendingTypingKey = key.shortcut
        } else {
            onSelect(key.shortcut)
        }
    }
}

/*
A chalk keycap on the inset panel (DESIGN.md §6.6): the chip fill blended over the card, a
1-point ink edge at 8% and no shadow; hover is the chip-hover fill. Modifier legends are ink and
the rest secondary. The chosen key is solid ink with its legend in the card colour. A reserved
key has no fill, a dashed 1-point edge and a secondary legend. Never red.
*/
struct ShortcutKeycapStyle: ButtonStyle {
    let selected: Bool
    let reserved: Bool
    let modifier: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, selected: selected, reserved: reserved, modifier: modifier)
    }

    /// Fill, edge and legend for one state; `card` is the panel the keycap sits on.
    static func look(selected: Bool, reserved: Bool, modifier: Bool, enabled: Bool, hovered: Bool,
                     card: UInt32 = TokensTheme.current.palette.card) -> (fill: Color, legend: Color) {
        if selected { return (TokensUI.ink, TokensUI.card) }
        if reserved { return (.clear, TokensUI.secondary) }
        let fill = TokensUI.opaque(enabled && hovered ? 0.12 : 0.08, over: card)
        return (fill, enabled && modifier ? TokensUI.ink : TokensUI.secondary)
    }

    private struct Face: View {
        let configuration: Configuration
        let selected: Bool
        let reserved: Bool
        let modifier: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            let look = ShortcutKeycapStyle.look(selected: selected, reserved: reserved, modifier: modifier,
                                                enabled: enabled, hovered: hovered || configuration.isPressed)
            configuration.label
                .foregroundStyle(look.legend)
                .background(look.fill, in: shape)
                .overlay {
                    if reserved {
                        shape.strokeBorder(TokensInk.primary.color.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else if !selected {
                        shape.strokeBorder(TokensInk.primary.color.opacity(0.08), lineWidth: 1)
                    }
                }
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}


/*
What the key picker says before an ordinary key becomes the talk key (build 81). F1 to F12 on a
Mac keyboard send brightness, Mission Control, media and volume unless "Use F1, F2, etc. keys as
standard function keys" is on, so a chosen F8 never started a talk (three tries in real logs).
*/
enum TalkKeyAdvice {
    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// macOS's "Use F1, F2, etc. keys as standard function keys" (read only; never changed).
    static func standardFunctionKeys(_ global: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)) -> Bool {
        (global?["com.apple.keyboard.fnState"] as? Bool) ?? false
    }

    static func confirmation(for key: TalkShortcut?, standardFunctionKeys: Bool) -> String {
        let back = "Select \(TalkShortcut.productDefault().displayName) on the keyboard to switch back."
        if let key, functionKeyCodes.contains(key.keyCode), !standardFunctionKeys {
            return "On this Mac \(key.displayName) controls brightness, media or volume, so it only talks with fn held down. To use it alone, turn on \"Use F1, F2, etc. keys as standard function keys\" in Keyboard Settings. \(back)"
        }
        return "This key is used in ordinary typing and may start talking unexpectedly. \(back)"
    }
}
