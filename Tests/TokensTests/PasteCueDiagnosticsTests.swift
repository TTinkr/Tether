import AppKit
import Testing
@testable import Tokens

/// Uses a non-presenting panel: state transitions are tested without taking the desktop.
@Suite(.serialized) @MainActor struct PasteCueDiagnosticsTests {
    final class NonPresentingPanel: NSPanel {
        var ordered = false
        var activeSpace = true
        var orderRequests = 0
        var orderOutRequests = 0
        var remainsOffSpace = false
        var onOrderOut: (() -> Void)?
        override var isVisible: Bool { ordered }
        override var isOnActiveSpace: Bool { activeSpace }
        override func orderFrontRegardless() {
            // Reordering an already ordered panel does not repair the reported native failure.
            if !ordered { activeSpace = !remainsOffSpace }
            ordered = true
            orderRequests += 1
        }
        override func orderOut(_ sender: Any?) {
            ordered = false
            orderOutRequests += 1
            onOrderOut?()
        }
    }

    @Test func orderedCursorOutsideActiveSpaceIsPresentedAgain() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) }, enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        #expect(panel.orderRequests == 1)
        panel.activeSpace = false
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == 2 && panel.isOnActiveSpace && marker.mode == .cursor)
        #expect(panel.orderOutRequests == 1)
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
        let marker = PasteMarker(panel: panel, makePanel: { panel }, enabled: { true })
        defer { marker.hide() }
        let field = CGRect(x: screen.visibleFrame.midX - 100,
                           y: screen.frame.maxY - screen.visibleFrame.midY - 30, width: 200, height: 60)
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(panel.orderRequests == 1 && panel.isOnActiveSpace && marker.mode == .field)
        #expect(panel.alphaValue == 1 && panel.orderOutRequests == 1)
        let recoveredFrame = panel.frame
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(panel.orderRequests == 1 && panel.frame == recoveredFrame)
    }

    @Test func failedSpaceRecoveryIsRateLimitedAndBounded() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.remainsOffSpace = true
        var now: TimeInterval = 10
        let frame = CGRect(x: 20, y: 30, width: 30, height: 30)
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { frame }, enabled: { true }, uptime: { now })
        defer { marker.hide() }
        marker.showCursor()
        marker.refreshCursorPlacement()
        #expect(panel.orderOutRequests == 1)
        for _ in 0..<100 { marker.refreshCursorPlacement() }
        #expect(panel.orderOutRequests == 1)
        now += PasteMarker.spaceRecoveryInterval - 0.01
        marker.refreshCursorPlacement()
        #expect(panel.orderOutRequests == 1)
        now += 0.02
        marker.refreshCursorPlacement()
        #expect(panel.orderOutRequests == 2)
        for _ in 0..<10 {
            now += PasteMarker.spaceRecoveryInterval
            marker.refreshCursorPlacement()
        }
        #expect(panel.orderOutRequests == PasteMarker.spaceRecoveryLimit)
        #expect(panel.frame == frame && panel.alphaValue == 1 && marker.mode == .cursor)
        marker.hide()
        let count = panel.orderRequests
        now += 10
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == count && marker.mode == .hidden && !panel.isVisible)
    }

    @Test func stopDuringSpaceRecoveryDoesNotOrderCueBackIn() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) }, enabled: { true })
        defer { panel.onOrderOut = nil; marker.hide() }
        marker.showCursor()
        panel.activeSpace = false
        panel.onOrderOut = { marker.hide() }
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == 1 && !panel.isVisible && marker.mode == .hidden)
    }

    @Test func stoppedCaptureCannotRecoverCursorBeforeNextTimerTick() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        var capturing = true
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) }, enabled: { capturing })
        defer { marker.hide() }
        marker.showCursor()
        panel.activeSpace = false
        capturing = false
        marker.refreshCursorPlacement()
        #expect(panel.orderRequests == 1 && !panel.isVisible && marker.mode == .hidden)
    }

    @Test func cursorLossAndStopAreObservableWithoutLoggingEveryPoll() {
        let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.contentView = NSView()
        var frame: CGRect? = CGRect(x: 20, y: 30, width: 30, height: 30)
        var events: [String] = []
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { frame }, enabled: { true }, recordEvent: { events.append($0) })
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
        let marker = PasteMarker(panel: panel, makePanel: { panel }, enabled: { true }, recordEvent: { events.append($0) })
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
        let marker = PasteMarker(panel: panel, makePanel: { panel }, cursorFrame: { CGRect(x: 0, y: 0, width: 30, height: 30) },
                                 enabled: { true }, recordEvent: { events.append($0) })
        for _ in 0..<50 { marker.showCursor(); marker.hide() }
        #expect(events.count == PasteMarker.notesPerTalk)
        marker.resetDiagnostics()
        marker.showCursor()
        #expect(events.count == PasteMarker.notesPerTalk + 1)
        marker.hide()
    }

    // Build 89: a full-screen Space closing strands hidden windows on one Space; never show one again.

    final class Windows {
        var made: [NonPresentingPanel] = []
        func make() -> NSPanel {
            let panel = NonPresentingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            made.append(panel)
            return panel
        }
    }

    @Test func aHiddenRingWindowIsNeverShownAgain() throws {
        let windows = Windows()
        let marker = PasteMarker(makePanel: windows.make, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) },
                                 enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        let first = try #require(windows.made.first)
        #expect(windows.made.count == 1 && first.isVisible && first.orderRequests == 1)
        marker.hide()
        marker.showCursor()
        let second = try #require(windows.made.last)
        #expect(windows.made.count == 2 && second !== first)
        #expect(second.isVisible && !first.isVisible && first.orderRequests == 1)
        #expect(marker.currentWindow === second && second.frame == CGRect(x: 20, y: 30, width: 30, height: 30))
    }

    @Test func aRingHiddenForAMomentComesBackInANewWindow() throws {
        let windows = Windows()
        var frame: CGRect? = CGRect(x: 20, y: 30, width: 30, height: 30)
        let marker = PasteMarker(makePanel: windows.make, cursorFrame: { frame }, enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        frame = nil
        marker.refreshCursorPlacement()
        #expect(windows.made.count == 1 && !windows.made[0].isVisible)
        frame = CGRect(x: 40, y: 50, width: 30, height: 30)
        marker.refreshCursorPlacement()
        let second = try #require(windows.made.last)
        #expect(windows.made.count == 2 && second.isVisible && second.frame == frame)
        #expect(windows.made[0].orderRequests == 1 && marker.mode == .cursor)
    }

    @Test func aHiddenBoxWindowIsNeverShownAgain() throws {
        let screen = try #require(NSScreen.screens.first)
        let windows = Windows()
        let marker = PasteMarker(makePanel: windows.make, enabled: { true })
        defer { marker.hide() }
        let field = CGRect(x: screen.visibleFrame.midX - 100,
                           y: screen.frame.maxY - screen.visibleFrame.midY - 30, width: 200, height: 60)
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(windows.made.count == 1 && windows.made[0].isVisible && marker.mode == .field)
        // Polling a box that is already up keeps the same window.
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        #expect(windows.made.count == 1)
        marker.hide()
        marker.show(field: field, caret: nil, shortcutName: "Right Option")
        let second = try #require(windows.made.last)
        #expect(windows.made.count == 2 && second.isVisible && windows.made[0].orderRequests == 1)
        #expect(second.frame == windows.made[0].frame && marker.mode == .field)
    }

    @Test func offSpaceRecoveryMovesTheCueToANewWindow() throws {
        let windows = Windows()
        let frame = CGRect(x: 20, y: 30, width: 30, height: 30)
        let marker = PasteMarker(makePanel: windows.make, cursorFrame: { frame }, enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        let first = try #require(windows.made.first)
        first.activeSpace = false
        marker.refreshCursorPlacement()
        let second = try #require(windows.made.last)
        #expect(windows.made.count == 2 && !first.isVisible && first.orderOutRequests == 1)
        #expect(second.isVisible && second.isOnActiveSpace && second.frame == frame && second.alphaValue == 1)
        #expect(marker.currentWindow === second && marker.mode == .cursor)
    }

    @Test func stopDuringNewWindowRecoveryLeavesNothingOnScreen() throws {
        let windows = Windows()
        let marker = PasteMarker(makePanel: windows.make, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) },
                                 enabled: { true })
        defer { marker.hide() }
        marker.showCursor()
        let first = try #require(windows.made.first)
        first.activeSpace = false
        first.onOrderOut = { marker.hide() }
        marker.refreshCursorPlacement()
        #expect(marker.mode == .hidden && windows.made.allSatisfy { !$0.isVisible })
        #expect(windows.made.dropFirst().allSatisfy { $0.orderRequests == 0 })
    }

    @Test func eachTalkStartsWithANewWindow() throws {
        let windows = Windows()
        let marker = PasteMarker(makePanel: windows.make, cursorFrame: { CGRect(x: 20, y: 30, width: 30, height: 30) },
                                 enabled: { true })
        marker.showCursor()
        marker.discardWindow()
        #expect(marker.currentWindow == nil && marker.mode == .hidden && !windows.made[0].isVisible)
        marker.showCursor()
        #expect(windows.made.count == 2 && windows.made[1].isVisible)
        marker.discardWindow()
    }

    @Test func talkPreviewStopDiscardsTheCueWindow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let preview = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Talk/TalkModel+DestinationPreview.swift"), encoding: .utf8)
        let stop = try #require(preview.range(of: "func stopDestinationPreview() {"))
        #expect(preview[stop.upperBound...].prefix(200).contains("PasteMarker.shared.discardWindow()"))
    }
}
