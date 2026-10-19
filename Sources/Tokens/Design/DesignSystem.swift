


//
import AppKit
import CoreText
import SwiftUI


// TokensUI — the graph-paper grid size, pencil font, colours and snapping helpers


/// Shared graph-paper layout with native system typography; pencil is explicit for live words and branding.
/// Compact forms use layout modules; Home structural edges use printed paper cells.
enum TokensUI {
    /*
    Forms retain their compact 24-point rhythm. Home's structural edges use the independent
    56-point paperCell, so enlarging graph squares never enlarges every form control.
    */
    /// Compact control rhythm; deliberately independent of the printed paper cells.
    static let module: CGFloat = 24
    /// Large square graph cells used by the continuous Home sheet.
    static let paperCoordinateSpace = "tokens.paper.logical"
    static let paperCell: CGFloat = 56
    /// Half a graph square: the line pitch for wrapped reading text (DESIGN.md §4.2 R2).
    static let halfCell: CGFloat = 28
    static let sectionRuleWidth: CGFloat = 1.75
    /// Every pencil size is written this much larger, so text fills the larger squares.
    static let textScale: CGFloat    = 1.15
    static let sidebarWidth: CGFloat = 3 * paperCell
    /// The pencil hand. One constant, so trying another face is a one-line change.
    static let face = "Noteworthy-Light"

    // Window colours come from the chosen theme (Design/Theme.swift); see TokensTheme.current.
    static var paper: Color { Color(tokensHex: TokensTheme.current.palette.paper) }
    /// The working sheet's ground, under its graph lines.
    static var sheet: Color { Color(tokensHex: TokensTheme.current.palette.sheet) }
    static var gridInk: Color { Color(tokensHex: TokensTheme.current.palette.grid) }
    static var gridMinor: Color { gridInk.opacity(TokensTheme.current.palette.gridMinor) }
    static var gridMajor: Color { gridInk.opacity(TokensTheme.current.palette.gridMajor) }
    static var isDark: Bool { TokensTheme.current.palette.isDark }
    /// Every this-many paper cells, TokensPaper draws a major line.
    static let gridMajorEvery = 4
    static var ink: Color       { TokensInk.primary.color }
    static var secondary: Color { TokensInk.secondary.color }
    /// Graphite for ruled lines and boxes.
    static var rule: Color { secondary.opacity(0.6) }
    /// The one red pencil: the selected page, the chosen key, and "needs access" marks.
    static var red: Color { TokensInk.red.color }
    /// Red for fills under white labels; see TokensPalette.redFill.
    static var redFill: Color { Color(tokensHex: TokensTheme.current.palette.redFill) }

    /// One AppKit font instance defines both native measurements and SwiftUI rendering.
    /// Regular UI uses unscaled system sizes; pencil keeps its existing visual scale.
    static func nsFont(_ size: CGFloat, pencil: Bool = false) -> NSFont {
        guard pencil else { return .systemFont(ofSize: size) }
        return NSFont(name: face, size: size * textScale) ?? .systemFont(ofSize: size * textScale)
    }
    static func font(_ size: CGFloat, pencil: Bool = false) -> Font { Font(nsFont(size, pencil: pencil)) }

    static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: nsFont(size)]).size().width)
    }

    /// Rounds a length up to whole squares so both edges of a box land on grid lines.
    static func snap(_ length: CGFloat) -> CGFloat { ceil(length / module) * module }

    /// The app only fades, and not at all under Reduce Motion.
    static func fade(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.1) }
}


// TokensInk — the three pencil colours (main, secondary, red) as AppKit and SwiftUI colours


enum TokensInk {
    case primary, secondary, red

    /*
    The single place the ink values are written down. TokensUI.ink / secondary / red and the
    SwiftUI `color` below both read from here, so AppKit and SwiftUI always show the same shade.
    */
    var nsColor: NSColor {
        let palette = TokensTheme.current.palette
        switch self {
        case .primary:   return NSColor(tokensHex: palette.ink)
        case .secondary: return NSColor(tokensHex: palette.secondary)
        case .red:       return NSColor(tokensHex: palette.red)
        }
    }

//
// :)
//
//
    var color: Color { Color(nsColor: nsColor) }
}

