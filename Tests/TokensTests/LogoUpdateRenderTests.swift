
import AppKit
import SwiftUI
import Testing
@testable import Tokens

@Suite(.serialized) @MainActor struct LogoUpdateRenderTests {
    @Test func separateUpdateActionAppearsOnlyWithAnOffer() throws {
        let updater = Updater()
        updater.hasAgreement = { true }
        try render(updater, "logo-1-normal")
        #expect(!updater.showsUpdateNotice)
        updater.offerUpdate(version: "0.3.3", critical: false) { _ in }
        #expect(updater.showsUpdateNotice && updater.canActOnUpdateNotice)
        try render(updater, "logo-2-update")
    }

    /// No channel word widens the wordmark; "Update" adds exactly one 28-point line under the letters.
    @Test func wordmarkStandsAloneAndUpdateTakesOneLine() {
        let updater = Updater()
        updater.hasAgreement = { true }
        let width = TokensRail.wordmarkWidth
        let letters = width * TokensWordmarkRule.baselineFraction
        let plain = fittingSize(updater, width: width)
        #expect(abs(plain.width - width) < 0.5)
        // NSHostingView rounds its fitting size up to whole points.
        #expect(plain.height >= letters && plain.height - letters < 1)
        updater.offerUpdate(version: "0.3.3", critical: false) { _ in }
        let offered = fittingSize(updater, width: width)
        #expect(offered.height - plain.height == TokensRail.updateLine)
    }

    /// DESIGN.md §5.1 window points: letters on 112, Update on 140, rows on 168 / 224 / 280
    /// (28 lower with an update), status 44 above Settings, Settings at H − 28 or H − 64.
    @Test func railRowsLandOnTheirBaselines() {
        #expect(TokensRail.letterLine + TokensRail.updateLine == 140)
        for (notice, shift) in [(false, CGFloat(0)), (true, 28)] {
            let top = TokensRail.rowsTop(updateNotice: notice)
            for row in 0..<3 {
                let baseline = top + CGFloat(row) * TokensRail.rowPitch + TokensRail.rowBaseline
                #expect(baseline == 168 + CGFloat(row) * 56 + shift)
            }
        }
        #expect(TokensRail.rowHeight / 2 + 5 == TokensRail.rowBaseline)
        for dev in [false, true] {
            let fromBottom = TokensRail.settingsBottom(wide: true, dev: dev) + TokensRail.rowHeight - TokensRail.rowBaseline
            #expect(fromBottom == (dev ? 64 : 28))
            // The status slot ends at Settings' row top; its baseline is 44 above Settings' baseline.
            let statusFromBottom = fromBottom + TokensRail.rowBaseline + (TokensRail.statusSlot - TokensRail.statusBaseline)
            #expect(statusFromBottom == fromBottom + TokensRail.statusAboveSettings)
        }
        #expect(TokensRail.settingsBottom(wide: false, dev: true) + TokensRail.rowHeight / 2 == 40)
    }

    /// The Dev line is one 13-point line in every state; only a running merge adds the 3-point
    /// bars under it. Fixtures are fictional: nothing is read, polled or started.
    @Test func devLineStaysOneLine() throws {
        let states: [(String, String, Bool, Bool)] = [
            ("dev-1-idle-locked", "", false, false),
            ("dev-2-idle-mergeable", "", false, true),
            ("dev-3-running", "Step 2: building", true, true),
            ("dev-4-failed", "FAILED: fixture", false, true),
            ("dev-5-merged", "Merged", false, true),
        ]
        var heights: [String: CGFloat] = [:]
        for (name, status, running, promotable) in states {
            let row = DevMergeRow(fixtureStatus: status, running: running, promotable: promotable)
            heights[name] = NSHostingView(rootView: row).fittingSize.height
            try renderView(row.padding(.leading, TokensRail.textX)
                .frame(width: TokensRail.wideWidth, height: 48, alignment: .leading), name)
        }
        let line = try #require(heights["dev-1-idle-locked"])
        #expect(line < 20)
        for name in ["dev-2-idle-mergeable", "dev-4-failed", "dev-5-merged"] { #expect(heights[name] == line) }
        #expect(abs((heights["dev-3-running"] ?? 0) - line - 8) < 0.5)
    }

    private func fittingSize(_ updater: Updater, width: CGFloat) -> CGSize {
        TokensBrandAssets.overrideDirectory = artwork
        defer { TokensBrandAssets.overrideDirectory = nil }
        return NSHostingView(rootView: TokensLogoUpdate(updater: updater, appName: "Tokens", width: width)).fittingSize
    }

    // Render the shipped artwork, not the text fallback the test bundle would otherwise use.
    private var artwork: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Release/WaveIdentity")
    }

    private func render(_ updater: Updater, _ name: String) throws {
        TokensBrandAssets.overrideDirectory = artwork
        defer { TokensBrandAssets.overrideDirectory = nil }
        try renderView(TokensLogoUpdate(updater: updater, appName: "Tokens", width: TokensRail.wordmarkWidth)
            .padding(.leading, TokensRail.textX)
            .padding(.top, TokensRail.letterLine - TokensRail.wordmarkWidth * TokensWordmarkRule.baselineFraction)
            .frame(width: TokensRail.wideWidth, height: 180, alignment: .topLeading), name)
    }

    private func renderView(_ content: some View, _ name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"] else { return }
        let view = content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TokensUI.paper)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    }
}
