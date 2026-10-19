
import AppKit
import SwiftUI
import Testing
@testable import Tokens

@Suite(.serialized) @MainActor struct UpdateCheckCardTests {
    @Test func everyCheckRequestHasAVisibleStep() {
        func step(agreed: Bool = true, available: Bool = false, busy: Bool = false,
                  quiet: Bool = false, sparkle: Bool = false) -> Updater.CheckStep {
            Updater.checkStep(agreed: agreed, available: available, busy: busy,
                              quietCheckRunning: quiet, sparkleBusy: sparkle)
        }
        #expect(step(agreed: false, available: true) == .needsAgreement)
        // A waiting offer is shown again, never re-checked: checking is not consent to install.
        #expect(step(available: true, busy: true, quiet: true) == .showOffer)
        #expect(step(busy: true, quiet: true) == .showProgress)
        // A quiet background check already asking is waited for, not doubled or ignored.
        #expect(step(quiet: true, sparkle: true) == .waitForQuietCheck)
        #expect(step(sparkle: true) == .showProgress)
        #expect(step() == .start)
    }

    @Test func aWaitingOfferIsShownWithoutAnotherCheckOrConsent() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var choices: [Int] = []
        updater.offerUpdate(version: "0.0 fixture", critical: false) { _ in choices.append(1) }
        updater.check()
        #expect(updater.available && !updater.busy)
        #expect(updater.label == "Update 0.0 fixture available")
        #expect(choices.isEmpty)
    }

    @Test func renderTheCardOffscreen() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_UPDATE_CARD_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        let states: [(String, (Updater) -> Void)] = [
            ("checking", { $0.showUserInitiatedUpdateCheck(cancellation: {}) }),
            ("up-to-date", { $0.showUpdateNotFoundWithError(NSError(domain: "fixture", code: 1)) {} }),
            ("available", { $0.offerUpdate(version: "1.0 (82) fixture", critical: false) { _ in } }),
            ("offline", { $0.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) {} }),
        ]
        for theme in [TokensTheme.paper, .chalkboard] {
            TokensTheme.current = theme
            for (name, apply) in states {
                let updater = Updater()
                updater.hasAgreement = { true }
                apply(updater)
                let host = NSHostingView(rootView: UpdateCheckCard(updater: updater))
                let size = host.fittingSize
                #expect(size.width == UpdateCheckCard.width)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: theme.palette.isDark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("update-card-\(theme.rawValue)-\(name).png"))
                window.close()
            }
        }
    }
}
