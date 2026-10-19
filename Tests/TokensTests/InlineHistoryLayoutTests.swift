import AppKit
import Testing
@testable import Tokens

/// Native layout is measured without opening a window, real History or the clipboard.
@Suite @MainActor struct InlineHistoryLayoutTests {
    @Test func expansionAffordanceTracksAvailableWidthAndPreviewLineLimit() {
        let text = String(repeating: "A spoken sentence. ", count: 5)
        #expect(TokensHistoryPreviewLayout.isTruncated(text, width: 120, lineLimit: 3))
        #expect(!TokensHistoryPreviewLayout.isTruncated(text, width: 1600, lineLimit: 3))
        #expect(TokensHistoryPreviewLayout.isTruncated(text, width: 500, lineLimit: 1))
        #expect(!TokensHistoryPreviewLayout.isTruncated(text, width: 500, lineLimit: 3))
    }

    @Test func expansionUsesGlyphWidthsInsteadOfCharacterCount() {
        let narrowGlyphs = String(repeating: "i", count: 80)
        let wideGlyphs = String(repeating: "W", count: 80)
        #expect(narrowGlyphs.count == wideGlyphs.count)
        #expect(!TokensHistoryPreviewLayout.isTruncated(narrowGlyphs, width: 160, lineLimit: 3))
        #expect(TokensHistoryPreviewLayout.isTruncated(wideGlyphs, width: 160, lineLimit: 3))
        #expect(!TokensHistoryPreviewLayout.isTruncated("Short entry.", width: 400, lineLimit: 1))
    }

    @Test func unmeasuredAndUnlimitedPreviewsDoNotOfferEmptyExpansion() {
        #expect(!TokensHistoryPreviewLayout.isTruncated("", width: 300, lineLimit: 3))
        #expect(!TokensHistoryPreviewLayout.isTruncated("Short entry.", width: 0, lineLimit: 3))
        #expect(!TokensHistoryPreviewLayout.isTruncated("Short entry.", width: .infinity, lineLimit: 3))
        #expect(!TokensHistoryPreviewLayout.isTruncated(String(repeating: "word ", count: 100), width: 100, lineLimit: 0))
    }

    @Test func narrowWindowWrapsFullTranscriptWithoutAHeightCap() {
        let text = String(repeating: "A longer saved dictation should remain selectable in full. ", count: 100)
        let wide = TokensInlineHistoryText.measuredSize(text, width: 700)
        let narrow = TokensInlineHistoryText.measuredSize(text, width: 240)
        #expect(narrow.height > wide.height)
        #expect(narrow.height > 20 * TokensUI.paperCell)
        #expect(narrow.height.truncatingRemainder(dividingBy: TokensUI.paperCell) == 0)
    }

    @Test func explicitBlankLinesAndTrailingNewlinesHaveRoom() {
        let one = TokensInlineHistoryText.measuredSize("First line", width: 500)
        let three = TokensInlineHistoryText.measuredSize("First line\n\nLast line\n", width: 500)
        #expect(three.height >= one.height + 2 * TokensUI.paperCell)
        #expect(three.height.truncatingRemainder(dividingBy: TokensUI.paperCell) == 0)
    }

    @Test func emptyAndComplexUnicodeRemainMeasurable() {
        for text in ["", "👩🏽‍💻 café e\u{301} 日本語\nخط عربي", String(repeating: "longword", count: 80)] {
            let size = TokensInlineHistoryText.measuredSize(text, width: 140)
            #expect(size.width == 140)
            #expect(size.height.isFinite && size.height >= TokensUI.paperCell)
        }
    }
}
