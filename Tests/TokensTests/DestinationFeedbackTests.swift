import AppKit
import SwiftUI
import Testing
@testable import Tokens

struct DestinationFeedbackPolicyTests {
    /// finishing or delivering, or after a failure.
    @Test func cuesRunOnlyWhileATalkRecords() {
        #expect(DestinationPreviewPolicy.runs(phase: .capturing))
        for phase: TalkPhase in [.idle, .finalizing, .delivered, .failed] {
            #expect(!DestinationPreviewPolicy.runs(phase: phase))
        }
        #expect(DestinationPreviewPolicy.pollInterval < DestinationPreviewPolicy.cueLifetime)
    }

    @Test func suspensionOverridesCapture() {
        for phase: TalkPhase in [.idle, .capturing, .finalizing, .delivered, .failed] {
            #expect(!DestinationPreviewPolicy.runs(phase: phase, suspended: true))
        }
    }

    @Test func unsupportedSupplementaryNotificationsDoNotSuppressVerifiedFields() {
        let supplemental = [AXError](repeating: .notificationUnsupported, count: 8)
        #expect(DestinationObservationReadiness.ready(results: [.success, .success] + supplemental,
                                                     requiredCount: 10, mandatoryCount: 2))
        for focusFailure in [AXError.notificationUnsupported, .cannotComplete, .invalidUIElement] {
            #expect(!DestinationObservationReadiness.ready(results: [.success, focusFailure] + supplemental,
                                                          requiredCount: 10, mandatoryCount: 2))
        }
        #expect(!DestinationObservationReadiness.ready(results: [.success, .success] + [.cannotComplete] + supplemental.dropFirst(),
                                                      requiredCount: 10, mandatoryCount: 2))
        #expect(!DestinationObservationReadiness.ready(results: [.success, .success], requiredCount: 10, mandatoryCount: 2))
    }

    @Test func cursorFallbackStaysOnItsOwnScreenWithoutInventingAField() {
        let screens = [CGRect(x: -1280, y: -200, width: 1280, height: 800), CGRect(x: 0, y: 0, width: 1440, height: 900)]
        for point in [CGPoint(x: -1279, y: -199), CGPoint(x: -1, y: 599), CGPoint(x: 1439, y: 899), .zero] {
            let frame = DestinationCursorGeometry.frame(at: point, screens: screens)
            #expect(frame != nil)
            #expect(screens.contains { $0.contains(frame!) })
            #expect(frame?.width == 30 && frame?.height == 30)
        }
        #expect(DestinationCursorGeometry.frame(at: CGPoint(x: 2000, y: 0), screens: screens) == nil)
        #expect(DestinationCursorGeometry.frame(at: CGPoint(x: CGFloat.nan, y: 0), screens: screens) == nil)
    }
}

@Suite(.serialized) @MainActor struct DestinationCursorRenderTests {
    @Test func cursorCueIsAnEmptyRingInBothThemes() throws {
        for dark in [false, true] {
            let view = PasteMarkerView(shortcutName: "", framed: false, cursorFallback: true)
                .frame(width: 30, height: 30)
                .padding(35)
                .background(dark ? Color.black : Color.white)
                .preferredColorScheme(dark ? .dark : .light)
            let rep = try PasteMarkerPNG.render(view, size: CGSize(width: 100, height: 100), scale: 2, dark: dark)
            let path = ProcessInfo.processInfo.environment["TOKENS_FEEDBACK_RENDER_DIR"]
            if let path, let data = rep.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("cursor-\(dark ? "dark" : "light").png"))
            }
            #expect(rep.pixelsWide == 200 && rep.pixelsHigh == 200)
        }
    }
}

@Suite(.serialized) @MainActor struct DestinationCursorLifecycleTests {
    final class UnshownPanel: NSPanel {
        var requested = false
        override var isVisible: Bool { requested }
        // Not about Spaces: a shown test window counts as on the active Space (build 89 recovery stays out).
        override var isOnActiveSpace: Bool { requested }
        override func orderFrontRegardless() { requested = true }
        override func orderOut(_ sender: Any?) { requested = false }
    }

    @Test func invalidScreenNeverShowsOldTargetAndValidScreenRestoresCursor() {
        let panel = UnshownPanel(contentRect: CGRect(x: 900, y: 700, width: 300, height: 80),
                                 styleMask: [.borderless], backing: .buffered, defer: true)
        var frame: CGRect? = nil
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { frame }, enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        #expect(marker.mode == .cursor && !panel.isVisible)
        frame = CGRect(x: 20, y: 30, width: 30, height: 30)
        marker.refreshCursorPlacement()
        #expect(panel.isVisible && panel.frame == frame)
        frame = nil
        marker.refreshCursorPlacement()
        #expect(!panel.isVisible)
        frame = CGRect(x: 40, y: 50, width: 30, height: 30)
        marker.refreshCursorPlacement()
        #expect(panel.isVisible && panel.frame == frame)
        marker.hide()
        marker.refreshCursorPlacement()
        #expect(marker.mode == .hidden && !panel.isVisible)
    }

    @Test func disablingFeedbackRemovesTheCursor() {
        let panel = UnshownPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        var enabled = true
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) }, enabled: { enabled })
        marker.showCursor()
        #expect(panel.isVisible)
        enabled = false
        marker.showCursor()
        #expect(!panel.isVisible && marker.mode == .hidden)
    }

    @Test func expiredFieldBecomesCursorButHiddenFieldCannotReturn() async throws {
        let screen = try #require(NSScreen.screens.first)
        let field = CGRect(x: screen.visibleFrame.midX - 100,
                           y: screen.frame.maxY - screen.visibleFrame.midY - 30,
                           width: 200, height: 60)
        let panel = UnshownPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        // Whole points: windows snap to them, and visibleFrame's middle can be x.5 (menu bar shown).
        let cursor = CGRect(x: screen.visibleFrame.midX.rounded(), y: screen.visibleFrame.midY.rounded(), width: 30, height: 30)
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { cursor }, enabled: { true })
        defer { marker.hide() }
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(marker.mode == .field)
        // Past the cue's lifetime (1.5 s since build 83, so typing never blinks the box).
        try await Task.sleep(for: .milliseconds(Int(DestinationPreviewPolicy.cueLifetime * 1000) + 150))
        #expect(marker.mode == .cursor && panel.frame == cursor)
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(marker.mode == .field)
        marker.hide()
        try await Task.sleep(for: .milliseconds(600))
        #expect(marker.mode == .hidden && !panel.isVisible)
    }
}
