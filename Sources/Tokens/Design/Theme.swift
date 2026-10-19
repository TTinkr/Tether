


import AppKit
import SwiftUI

/// One window palette. Colours are sRGB hex; alphas are for the graph lines on the working sheet.
struct TokensPalette {
    let isDark: Bool
    /// Rail and window margin behind the working sheet.
    let paper: UInt32
    /// The working sheet (graph paper) to the right of the rail.
    let sheet: UInt32
    /// Cards on the sheet.
    let card: UInt32
    let ink: UInt32
    let secondary: UInt32
    let red: UInt32
    /// Red behind white labels (buttons, on switches, chosen segments): ≥ 4.5:1 against white.
    let redFill: UInt32
    let grid: UInt32
    let gridMinor: Double
    /// Kept for provenance; V3 draws one grid weight only (DESIGN.md §4.1).
    let gridMajor: Double
    /// The 1-point line on the rail's trailing edge, between the rail and the working sheet.
    let seam: UInt32
    /// Hairlines and hover washes are ink at these alphas.
    let hairline: Double
    let hover: Double
    /*
    Alpha of ink over the sheet for the second ink, TokensUI.ink2 (DESIGN.md §2.2). Fading dark ink
    toward white loses contrast much faster than fading light ink toward a dark sheet, so at the dark
    themes' 0.82 Paper's ink2 (#5A5C58) came out lighter than its secondary. Paper uses 0.92 (#464843,
    9.26:1 on the sheet) so ink > ink2 > secondary holds there too.
    */
    let ink2Alpha: Double
}

enum TokensTheme: String, CaseIterable, Identifiable {
    case chalkboard, graphite, blueprint, paper

    static let defaultsKey = "TokensTheme.v1"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chalkboard: return "Chalkboard"
        case .graphite:   return "Graphite"
        case .blueprint:  return "Blueprint"
        case .paper:      return "Paper"
        }
    }

    var palette: TokensPalette {
        switch self {
        case .chalkboard:
            return TokensPalette(isDark: true, paper: 0x161A19, sheet: 0x1E2321, card: 0x252B29,
                                 ink: 0xE9ECE6, secondary: 0x9AA39E, red: 0xF0675C, redFill: 0xCC4339,
                                 grid: 0xDCE6E0, gridMinor: 0.045, gridMajor: 0.085, seam: 0x111413,
                                 hairline: 0.10, hover: 0.06, ink2Alpha: 0.82)
        case .graphite:
            return TokensPalette(isDark: true, paper: 0x111112, sheet: 0x19191B, card: 0x212124,
                                 ink: 0xEDEDEF, secondary: 0x98989F, red: 0xFF5C52, redFill: 0xCC4339,
                                 grid: 0xFFFFFF, gridMinor: 0.035, gridMajor: 0.07, seam: 0x0C0C0D,
                                 hairline: 0.09, hover: 0.06, ink2Alpha: 0.82)
        case .blueprint:
            return TokensPalette(isDark: true, paper: 0x0F1424, sheet: 0x151C30, card: 0x1C2439,
                                 ink: 0xE6EAF4, secondary: 0x8F9AB5, red: 0xFF6A5C, redFill: 0xC8453C,
                                 grid: 0x8FB4FF, gridMinor: 0.07, gridMajor: 0.13, seam: 0x0A0F1C,
                                 hairline: 0.10, hover: 0.06, ink2Alpha: 0.82)
        case .paper:
            // red #B83B38 is the earlier #D64541 at 86% (same hue): 5.17:1 on the rail, 5.64:1 on the sheet,
            // Chalkboard's level (5.16 sheet, 5.69 rail). #D64541 was 4.02:1 on the rail, under 4.5 for 14 pt labels.
            // redFill stays: white on #C63D39 is 5.09:1.
            return TokensPalette(isDark: false, paper: 0xF6F5F1, sheet: 0xFFFFFF, card: 0xFFFFFF,
                                 ink: 0x363833, secondary: 0x56584F, red: 0xB83B38, redFill: 0xC63D39,
                                 grid: 0x7299B2, gridMinor: 0.10, gridMajor: 0.18, seam: 0xE4E2DC,
                                 hairline: 0.10, hover: 0.05, ink2Alpha: 0.92)
        }
    }

    /// The theme in use. Proof renders pass --theme NAME; otherwise the saved choice, else Chalkboard.
    static var current: TokensTheme = resolve()

    static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments,
                        defaults: UserDefaults = .standard) -> TokensTheme {
        if let flag = arguments.firstIndex(of: "--theme"), flag + 1 < arguments.count,
           let theme = TokensTheme(rawValue: arguments[flag + 1].lowercased()) { return theme }
        return defaults.string(forKey: defaultsKey).flatMap(TokensTheme.init(rawValue:)) ?? .chalkboard
    }

    /// Save and apply a theme; TokensHome watches the same key and redraws.
    static func choose(_ theme: TokensTheme, defaults: UserDefaults = .standard) {
        current = theme
        defaults.set(theme.rawValue, forKey: defaultsKey)
    }
}

extension NSColor {
    convenience init(tokensHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(tokensHex hex: UInt32) { self.init(nsColor: NSColor(tokensHex: hex)) }
}

