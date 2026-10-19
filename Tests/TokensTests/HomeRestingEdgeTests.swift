
import AppKit
import SwiftUI
import Testing
@testable import Tokens
import TokensCore

/// Records which probe rows said they sit under the resting edge.
@MainActor private final class EdgeProbe {
    var under: [Int: Bool] = [:]
}

/*
Build 81 Home and History fixes: rows hidden under the bottom edge take no clicks (C49), Recent
asks only for the rows that fit below the real hero (C50), the held-words line names its own
Copy instead of "Copy latest" (C51), and History search matches the words rows show (C52).
*/
@Suite("Home and History edges (build 81)", .appKitWarmup)
struct HomeRestingEdgeTests {

    // MARK: C49 rows under the resting edge

    /// 1040 x 720: History's slot is 608 and its cut 573. The row straddling the cut (top 560)
    /// shows only 13 blank points, so it is hidden; the row above it (top 504) is whole.
    @Test func theRowStraddlingTheEdgeIsHidden() {
        #expect(TokensRestingEdgeMask.hides(rowTop: 560, slotHeight: 608))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 504, slotHeight: 608))
        // Home's slot (664, cut 629): a row from 616 shows 13 blank points; one from 560 is whole.
        #expect(TokensRestingEdgeMask.hides(rowTop: 616, slotHeight: 664))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 560, slotHeight: 664))
        // A tall open row whose first half-square still shows stays (its first words are on screen).
        #expect(!TokensRestingEdgeMask.hides(rowTop: 504, rowHeight: 168, slotHeight: 608 - 30))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 504, rowHeight: 168, slotHeight: 578))
        // Rows scrolled up under the title are never treated as under the bottom edge.
        #expect(!TokensRestingEdgeMask.hides(rowTop: -200, slotHeight: 608))
        // A short slot with nothing cut (the lifted Home at 520 / 1.5): only rows below its end hide.
        let short = 520 / 1.5 - 56
        #expect(TokensRestingEdgeMask.hides(rowTop: 280, slotHeight: short))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 224, slotHeight: short))
    }

    /// Build 81: History at 760 x 520 (slot 408, cut 405). A two-square row from 336 rests on its
    /// middle rule (392), so its second line was sliced at the window's bottom; it is hidden whole.
    /// The row above it is whole, and one-square rows are judged exactly as before.
    @Test func aTwoSquareRowTheEdgeWouldSliceIsHiddenWhole() {
        #expect(TokensRestingEdgeMask.cut(height: 408) == 405)
        #expect(TokensRestingEdgeMask.hides(rowTop: 336, rowHeight: 112, slotHeight: 408))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 224, rowHeight: 112, slotHeight: 408))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 336, rowHeight: 56, slotHeight: 408))
        #expect(TokensRestingEdgeMask.hides(rowTop: 392, rowHeight: 56, slotHeight: 408))
        // 1440 x 900 (slot 788): the term from 784 shows 4 points; it is under the edge, so its
        // just-added wash is not drawn as a strip there.
        #expect(TokensRestingEdgeMask.hides(rowTop: 784, slotHeight: 788))
        #expect(!TokensRestingEdgeMask.hides(rowTop: 728, slotHeight: 788))
        // At rest every one-square row is judged the same with or without its height.
        for slot: CGFloat in [235, 408, 608, 664, 788] {
            for top in stride(from: CGFloat(0), through: 840, by: 56) {
                #expect(TokensRestingEdgeMask.hides(rowTop: top, slotHeight: slot)
                        == (top + TokensUI.halfCell > TokensRestingEdgeMask.cut(height: slot)))
            }
        }
    }

    /*
    A row under the edge is not drawn at all (build 81). Rendered offscreen in a 608-point slot:
    the one-square row from 560 and a two-square row from 504 leave no ink below the cut (573),
    and the rows above them still draw.
    */
    @MainActor @Test func aRowUnderTheEdgeIsNotDrawn() throws {
        func alpha(_ rows: [CGFloat], at y: Int) throws -> UInt8 {
            let view = VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, height in
                    Color.black.frame(width: 8, height: height).tokensQuietUnderRestingEdge()
                }
                Spacer(minLength: 0)
            }
            .frame(width: 8, height: 608, alignment: .top)
            .coordinateSpace(.named(TokensRestingEdgeMask.space))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                // Shift the image so pixel row y (from the top) lands on the 1 x 1 context.
                context.draw(image, in: CGRect(x: -2, y: CGFloat(y + 1 - image.height),
                                               width: CGFloat(image.width), height: CGFloat(image.height)))
                return true
            }
            try #require(drawn)
            return pixel[3]
        }
        let squares = [CGFloat](repeating: 56, count: 11)            // the eleventh is 560-616
        #expect(try alpha(squares, at: 530) == 255)
        #expect(try alpha(squares, at: 565) == 0)
        let tall = [CGFloat](repeating: 56, count: 9) + [112]        // 504-616, its middle rule 560
        #expect(try alpha(tall, at: 500) == 255)
        #expect(try alpha(tall, at: 530) == 0)
    }

    /// The blank square between a field and its rows stays unless the sheet is too short to show a
    /// first row after it: 760 x 520 at 150% (sheet 347 tall) drops it so a row shows.
    @Test func fieldClearanceDropsOnlyOnAShortSheet() {
        #expect(TokensFieldClearance.shows(sheetHeight: 720))           // 1040 x 720
        #expect(TokensFieldClearance.shows(sheetHeight: 520))           // 760 x 520
        #expect(TokensFieldClearance.shows(sheetHeight: 900))           // 1440 x 900
        #expect(TokensFieldClearance.shows(sheetHeight: 720 / 1.5))     // 1040 x 720 at 150%
        #expect(!TokensFieldClearance.shows(sheetHeight: 520 / 1.5))    // 760 x 520 at 150%
        #expect(TokensDictionaryPage.fieldOverhang == 14)
    }

    /// The gate's own measure, through a real ScrollView in the slot tokensRestingEdge() names:
    /// rows from the cut down are under the edge, rows above it are not, and a row outside any
    /// slot never is.
    @MainActor @Test func slotNamedByTheRestingEdgeLocatesItsRows() {
        let probe = EdgeProbe()
        let view = ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(0..<14, id: \.self) { index in
                    Color.clear.frame(height: TokensUI.paperCell)
                        .onGeometryChange(for: Bool.self) { TokensRestingEdgeGate.underEdge($0) } action: { probe.under[index] = $0 }
                }
            }
        }
        .tokensRestingEdge()
        .frame(width: 400, height: 608)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 608)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where probe.under[10] == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        // Rows are 56 tall from 0: row 9 is 504-560 (whole), row 10 is 560-616 (straddles 573).
        #expect(probe.under[9] == false)
        #expect(probe.under[10] == true)
        #expect(probe.under[0] == false)
        window.contentView = nil

        // The gate measures each row's own height: a two-square row from 448 is whole (it ends on
        // 560), and the next one from 560 straddles the cut, as does one from 504 resting on its
        // middle rule.
        for (first, sliced) in [(8, false), (9, true)] {
            let tall = EdgeProbe()
            let rows = ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: CGFloat(first) * TokensUI.paperCell)
                    ForEach(0..<3, id: \.self) { row in
                        Color.clear.frame(height: 2 * TokensUI.paperCell)
                            .onGeometryChange(for: Bool.self) { TokensRestingEdgeGate.underEdge($0) } action: { tall.under[row] = $0 }
                    }
                }
            }
            .tokensRestingEdge()
            .frame(width: 400, height: 608)
            let tallHost = NSHostingView(rootView: rows)
            tallHost.frame = NSRect(x: 0, y: 0, width: 400, height: 608)
            let tallWindow = NSWindow(contentRect: tallHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            tallWindow.contentView = tallHost
            tallHost.layoutSubtreeIfNeeded()
            for _ in 0..<20 where tall.under[1] == nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                tallHost.layoutSubtreeIfNeeded()
            }
            // After 8 squares: rows 448-560 (whole) and 560-672. After 9: 504-616 (sliced) and on.
            #expect(tall.under[0] == sliced, "two-square row after \(first) squares")
            #expect(tall.under[1] == true)
            tallWindow.contentView = nil
        }

        // Outside a page slot (no tokensRestingEdge) the gate never turns a row off.
        let loose = EdgeProbe()
        let plain = NSHostingView(rootView: Color.clear.frame(width: 100, height: 56)
            .offset(y: 900)
            .onGeometryChange(for: Bool.self) { TokensRestingEdgeGate.underEdge($0) } action: { loose.under[0] = $0 })
        plain.frame = NSRect(x: 0, y: 0, width: 100, height: 56)
        plain.layoutSubtreeIfNeeded()
        for _ in 0..<10 where loose.under[0] == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            plain.layoutSubtreeIfNeeded()
        }
        #expect(loose.under[0] != true)
    }

    // MARK: C50 Recent's row budget

    /// The plain Ready hero is heading, dictate, Speech model and Today: the first row ends on rule 8.
    @Test func recentCountsTheSpeechModelLine() {
        #expect(TokensHomeLayout.firstRowRule == 8)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 720) == 5)
        // Every row it asks for ends above the 720 sheet's resting edge (sheet y 685).
        let lastRowEnd = CGFloat(TokensHomeLayout.firstRowRule + 5 - 1) * TokensUI.paperCell
        #expect(lastRowEnd <= 56 + TokensRestingEdgeMask.cut(height: 720 - 56))
    }

    /// Held words and an earlier talk each take a square; so does the Today line.
    @Test func optionalHeroLinesTakeRows() {
        let wide: CGFloat = 616
        let plain = TokensHomeHeroLines()
        #expect(TokensHomeLayout.heroCells(plain, columnWidth: wide) == 4)
        let held = TokensHomeHeroLines(held: "Paste unavailable", heldCopy: true)
        #expect(TokensHomeLayout.heroCells(held, columnWidth: wide) == 5)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 720, heroCells: 5) == 4)
        let both = TokensHomeHeroLines(held: "Paste unavailable", heldCopy: true, earlier: true)
        #expect(TokensHomeLayout.heroCells(both, columnWidth: wide) == 6)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 720, heroCells: 6) == 3)
        #expect(TokensHomeLayout.heroCells(TokensHomeHeroLines(today: false), columnWidth: wide) == 3)
        // Blocked: heading, blocker, "Then hold [key] to talk", Speech model.
        #expect(TokensHomeLayout.heroCells(TokensHomeHeroLines(ready: false, held: "x"), columnWidth: wide) == 4)
    }

    /// A long reason wraps at the 28-point pitch: two or three lines take two squares.
    @Test func aWrappedReasonTakesTwoSquares() {
        let reason = "Orukeet did not become ready. Check Speech engine in Settings, then retry."
        #expect(TokensHomeLayout.heldCells(reason, width: 900) == 1)
        #expect(TokensHomeLayout.heldCells(reason, width: 320) == 2)
        #expect(TokensHomeLayout.heldCells(reason, width: 90) == 3)
    }

    /// Unchanged outside the 10-14 rule band: tall sheets still show 8, short ones still scroll at 3.
    @Test func clampsStillHold() {
        #expect(TokensHomeLayout.recentRows(sheetHeight: 900) == 8)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 520) == 3)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 720 / 1.5) == 3)
        #expect(TokensHomeLayout.recentRows(sheetHeight: 2_000) == 8)
    }

    // MARK: C51 the held-words line

    /// The line names its own Copy, so the stored "· Copy latest" hint is dropped on Home only.
    @Test func heldReasonDropsTheMenuHint() {
        #expect(TokensHomeHeld.reason("Paste unavailable · Copy latest") == "Paste unavailable")
        #expect(TokensHomeHeld.reason("Text inserted · Send unavailable · Copy latest") == "Text inserted · Send unavailable")
        #expect(TokensHomeHeld.reason("Final words unavailable · Copy captured words") == "Final words unavailable")
        #expect(TokensHomeHeld.reason(TalkModel.keptInAppMessage) == TalkModel.keptInAppMessage)
        // Words that merely contain the phrase mid-sentence are left alone.
        #expect(TokensHomeHeld.reason("Microphone changed. Copy latest, then tap to resume.")
                == "Microphone changed. Copy latest, then tap to resume.")
        #expect(TokensHomeHeld.reason("") == "")
        // The pop-up still reads the stored message, suffix and all.
        #expect(RecoveryPresentation(message: "Paste unavailable · Copy latest").headline == "We couldn’t paste your words.")
    }

    // MARK: C52 History search

    private func entry(_ spoken: String, saved: String, typed: String = "") -> PromptHistoryEntry {
        PromptHistoryEntry(id: UUID(), createdAt: Date(),
                           authored: AuthoredPrompt(transcript: saved, spokenText: spoken, typed: typed))
    }

    /// Search matches the words a row shows, not the tags or metadata saved around them.
    @Test func searchMatchesTheShownWords() {
        let tagged = entry("call 555 123 4567 tomorrow", saved: "call <num>555 123 4567</num> tomorrow")
        #expect(TalkModel.historyMatches(tagged, query: "call 555"))
        #expect(TalkModel.historyMatches(tagged, query: "4567 tomorrow"))
        #expect(!TalkModel.historyMatches(tagged, query: "num"))

        let metadata = "# π\nMove the reading list\n\n---\n\n" + AuthoredPrompt.metadataHeading
            + "\n\n> *4.1000s · 4 words · 59 wpm · 0x thinking (0.0000s)*"
        let withMetadata = entry("Move the reading list", saved: metadata)
        #expect(TalkModel.historyMatches(withMetadata, query: "reading LIST"))
        for markup in ["wpm", "words", "Metadata", "thinking", "π"] {
            #expect(!TalkModel.historyMatches(withMetadata, query: markup))
        }
        // A blank query keeps every talk.
        #expect(TalkModel.historyMatches(withMetadata, query: "  "))
    }

    /// Typed notes stay findable, and older entries without authorship search their preview.
    @Test func typedNotesAndLegacyEntriesStayFindable() {
        let typed = entry("draft the reply", saved: "draft the reply", typed: "see\nattached   notes")
        #expect(TalkModel.historyMatches(typed, query: "attached notes"))
        let legacy = PromptHistoryEntry(id: UUID(), createdAt: Date(),
                                        text: "# π\nGreen notebook, blue pencil\n\n---\n\n# Metadata\n\n> *3 words · 90 wpm*")
        #expect(TalkModel.historyMatches(legacy, query: "blue pencil"))
        #expect(!TalkModel.historyMatches(legacy, query: "wpm"))
        // Accents and case are ignored, as before.
        let cafe = entry("the café order is ready", saved: "the café order is ready")
        #expect(TalkModel.historyMatches(cafe, query: "CAFE"))
    }
}
