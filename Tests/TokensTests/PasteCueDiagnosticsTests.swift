import AppKit
import Testing
@testable import Tokens

/// Uses a non-presenting panel: state transitions are tested without taking the desktop.
@Suite(.serialized) @MainActor struct PasteCueDiagnosticsTests {
    final class NonPresentingPanel: NSPanel {
        var ordered = false
        var activeSpace = true
        var orderRequests = 0
        override var isVisible: Bool { ordered }
        override var isOnActiveSpace: Bool { activeSpace }
        override func orderFrontRegardless() { ordered = true; activeSpace = true; orderRequests += 1 }
        override func orderOut(_ sender: Any?) { ordered = false }
    }

    @Test func orderedCursorOutsideActiveSpaceIsPresentedAgain() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let marker = PasteMarker(panel: panel, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) }, enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        #expect(panel.orderRequests == 1)
        panel.activeSpace = false
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == 2 && panel.isOnActiveSpace && marker.mode == .cursor)
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == 2)
        marker.hide()
        panel.activeSpace = false
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == 2 && !panel.isVisible)
    }

    @Test func orderedFieldOutsideActiveSpaceIsPresentedWithoutFadingAgain() throws {
        let screen = try #require(NSScreen.screens.first)
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.ordered = true
        panel.activeSpace = false
        panel.alphaValue = 1
        let marker = PasteMarker(panel: panel, enabled: { true })
        defer { marker.hide() }
        let field = CGRect(x: screen.visibleFrame.midX - 100,
                           y: screen.frame.maxY - screen.visibleFrame.midY - 30, width: 200, height: 60)
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(panel.orderRequests == 1 && panel.isOnActiveSpace && marker.mode == .field)
        #expect(panel.alphaValue == 1)
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(panel.orderRequests == 1)
    }

    @Test func cursorLossAndStopAreObservableWithoutLoggingEveryPoll() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.contentView = NSView()
        var frame: CGRect? = CGRect(x: 20, y: 30, width: 30, height: 30)
        var events: [String] = []
        let marker = PasteMarker(panel: panel, cursorFrame: { frame }, enabled: { true }, recordEvent: { events.append($0) })
        defer { marker.hide() }
        marker.showCursor()
        #expect(events.last?.contains("mode=cursor ordered=true alpha=100") == true)
        let count = events.count
        for _ in 0..<50 { marker.refreshCursorPlacement() }
        #expect(events.count == count)
        frame = nil
        marker.refreshCursorPlacement()
        #expect(events.last?.contains("mode=cursor ordered=false") == true)
        marker.hide()
        #expect(events.last?.contains("mode=hidden ordered=false") == true)
        #expect(events.allSatisfy { !$0.contains("20") && !$0.contains("30") })
    }

    @Test func requestedFieldDoesNotPretendTransparentWindowIsVisible() throws {
        let screen = try #require(NSScreen.screens.first)
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.ordered = true
        panel.alphaValue = 0
        var events: [String] = []
        let marker = PasteMarker(panel: panel, enabled: { true }, recordEvent: { events.append($0) })
        defer { marker.hide() }
        marker.show(field: CGRect(x: screen.visibleFrame.midX - 100,
                                 y: screen.frame.maxY - screen.visibleFrame.midY - 30,
                                 width: 200, height: 60), caret: nil, shortcutName: "Right Option")
        #expect(events.contains { $0.hasPrefix("paste_marker_shown") })
        #expect(events.contains { $0.contains("paste_cue_window mode=field ordered=true alpha=0") })
    }

    @Test func diagnosticsRemainBoundedDuringRepeatedModeChanges() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        var events: [String] = []
        let marker = PasteMarker(panel: panel, cursorFrame: { CGRect(x: 0, y: 0, width: 30, height: 30) },
                                 enabled: { true }, recordEvent: { events.append($0) })
        for _ in 0..<50 { marker.showCursor(); marker.hide() }
        #expect(events.count == PasteMarker.notesPerTalk)
        marker.resetDiagnostics()
        marker.showCursor()
        #expect(events.count == PasteMarker.notesPerTalk + 1)
        marker.hide()
    }
}
