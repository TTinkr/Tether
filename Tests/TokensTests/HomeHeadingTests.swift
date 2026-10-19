import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tokens

/// What a parent sees of its one child: height and both text baselines.
private final class HeadingProbe {
    var height: CGFloat = -1
    var first: CGFloat = -1
    var last: CGFloat = -1
}

private struct HeadingProbeLayout: Layout {
    let probe: HeadingProbe
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let dimensions = view.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        probe.height = dimensions.height
        probe.first = dimensions[.firstTextBaseline]
        probe.last = dimensions[.lastTextBaseline]
        return CGSize(width: dimensions.width, height: dimensions.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A time-of-day greeting ("Good evening") is rejected. Home shows one short, action-oriented
/// heading ("Time to talk", or "Almost ready" while setup blocks dictation) and no greeting.
@Suite("Home heading")
struct HomeHeadingTests {
    @Test func headingNamesTheStateInOneShortLine() {
        #expect(TokensHomeHeading.text(ready: true) == "Time to talk")
        #expect(TokensHomeHeading.text(ready: false) == "Almost ready")
        for ready in [true, false] {
            let heading = TokensHomeHeading.text(ready: ready)
            #expect(!heading.contains("\n"))
            #expect(heading.split(separator: " ").count <= 3)
            for word in ["Good", "morning", "afternoon", "evening"] {
                #expect(!heading.localizedCaseInsensitiveContains(word))
            }
        }
    }

    /// The header title for Home is its section name, never a time-of-day greeting.
    @Test func homePageTitleIsItsName() {
        #expect(TokensHome.sectionTitle(.home) == "Home")
        #expect(TokensHome.sectionTitle(.history) == "History")
    }

    /// One rule tall with one baseline on the first rule, at the wide and the narrow column.
    @MainActor @Test(arguments: [true, false], [CGFloat(560), 320, 240])
    func headingIsOneLineOnTheFirstRule(ready: Bool, width: CGFloat) {
        let probe = HeadingProbe()
        let host = NSHostingView(rootView: HeadingProbeLayout(probe: probe) { TokensHomeHeading(ready: ready) }
            .frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        #expect(probe.height == TokensUI.paperCell)
        #expect(abs(probe.first - TokensUI.paperCell) < 0.01)
        #expect(abs(probe.last - probe.first) < 0.01)
    }

    /// No source path, render previews included, carries a time-of-day greeting any more.
    @Test func noTimeOfDayGreetingInTheAppSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Tokens")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for greeting in ["\"Good morning", "\"Good afternoon", "\"Good evening"] {
                #expect(!text.contains(greeting), "\(url.lastPathComponent) still greets with \(greeting)\"")
            }
        }
        #expect(scanned > 50)
    }
}
