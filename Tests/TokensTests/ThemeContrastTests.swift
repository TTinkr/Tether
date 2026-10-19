


import Foundation
import Testing
@testable import Tokens

@Suite("Theme contrast: ink order and red text on every palette")
struct ThemeContrastTests {
    /// WCAG 2 relative luminance of an sRGB hex colour.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /*
    DESIGN.md §2.2: ink > ink2 > secondary on the sheet and on the rail, each a clear step (at least
    1.2x), not a tie. Chalkboard is 13.36 / 9.41 / 6.15 on the sheet. Paper at the dark themes' 0.82
    was 11.86 / 6.76 / 7.23: the blocker message read fainter than the hint under it.
    */
    @Test(arguments: TokensTheme.allCases)
    func inkLevelsKeepTheirOrder(theme: TokensTheme) {
        let palette = theme.palette
        let ink2 = TokensUI.ink2Hex(palette)
        for (name, surface) in [("sheet", palette.sheet), ("rail", palette.paper)] {
            let ink = Self.contrast(palette.ink, surface)
            let second = Self.contrast(ink2, surface)
            let hint = Self.contrast(palette.secondary, surface)
            #expect(ink >= second * 1.2, "\(theme) \(name): ink \(ink) vs ink2 \(second)")
            #expect(second >= hint * 1.2, "\(theme) \(name): ink2 \(second) vs secondary \(hint)")
        }
    }

    /// DESIGN.md §2.1: red text at Chalkboard level (5.16 sheet / 5.69 rail). Paper's old #D64541 was 4.02 on the rail.
    @Test(arguments: TokensTheme.allCases)
    func redTextReadsOnRailAndSheet(theme: TokensTheme) {
        let palette = theme.palette
        #expect(Self.contrast(palette.red, palette.paper) >= 5.1, "\(theme) red on the rail")
        #expect(Self.contrast(palette.red, palette.sheet) >= 5.1, "\(theme) red on the sheet")
        #expect(Self.contrast(0xFFFFFF, palette.redFill) >= 4.5, "\(theme) white label on redFill")
    }

    /// Paper's chosen values, and the three dark themes exactly as they were before the Paper fix.
    @Test func paperValuesAndDarkThemesUnchanged() {
        let paper = TokensTheme.paper.palette
        #expect(paper.ink2Alpha == 0.92)
        #expect(TokensUI.ink2Hex(paper) == 0x464843)
        #expect(paper.red == 0xB83B38)
        #expect(paper.redFill == 0xC63D39)
        #expect(paper.secondary == 0x56584F)
        let dark: [(TokensTheme, ink2: UInt32, red: UInt32)] = [
            (.chalkboard, 0xC4C8C3, 0xF0675C), (.graphite, 0xC7C7C9, 0xFF5C52), (.blueprint, 0xC0C5D1, 0xFF6A5C),
        ]
        for (theme, ink2, red) in dark {
            #expect(theme.palette.ink2Alpha == 0.82, "\(theme)")
            #expect(TokensUI.ink2Hex(theme.palette) == ink2, "\(theme)")
            #expect(theme.palette.red == red, "\(theme)")
        }
    }
}

