
import AppKit
import Testing
@testable import Tokens

struct PasteMarkerScreenEdgeRegressionTests {
    @Test func aComposerJustBelowTheTopStillGetsCorners() throws {
        // 24 points of room above the box is enough for the label (it stands above a whole dotted L since build 79).
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let panel = try #require(PasteMarkerGeometry.cueFrame(field: CGRect(x: 300, y: 49, width: 600, height: 80),
                                                              primaryHeight: 900, visibleFrames: [screen]))
        #expect(panel.maxY - PasteMarkerGeometry.labelTopInset <= screen.maxY)
    }

    @Test func aComposerTouchingTheTopFallsBackToTheCaretLabel() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(PasteMarkerGeometry.cueFrame(field: CGRect(x: 300, y: 25, width: 600, height: 80),
                                             primaryHeight: 900, visibleFrames: [screen]) == nil)
    }

    @Test func fieldCueLabelFitsAtVisibleTopAndFullscreenTop() throws {
        for top in [CGFloat(875), CGFloat(900)] {
            let screen = CGRect(x: 0, y: 0, width: 1440, height: top)
            let field = CGRect(x: 300, y: 900 - top, width: 600, height: 80)
            if let panel = PasteMarkerGeometry.cueFrame(field: field, primaryHeight: 900, visibleFrames: [screen]) {
                // PasteMarkerView keeps the label's ink at least labelTopInset below the panel's upper edge
                // (PasteMarkerRenderTests.labelNeverEntersTheBox measures it).
                let labelTop = panel.maxY - PasteMarkerGeometry.labelTopInset
                #expect(labelTop <= screen.maxY, "Corner label must stay inside the visible screen")
            }
        }
    }
}
