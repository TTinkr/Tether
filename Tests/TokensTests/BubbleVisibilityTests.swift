


//
import AppKit
import Testing
@testable import Tokens

/*
Execute the real lifecycle methods while intercepting window ordering: no foreground,
microphone, shortcut or clipboard operations. These do not reproduce Mission Control.
*/
@MainActor private final class UnshownBubble: CaptureBubblePanel {
    var showCount = 0
    var hideCount = 0
    override func orderFrontRegardless() { showCount += 1 }
    override func orderOut(_ sender: Any?) { hideCount += 1 }
}

@Suite(.serialized) @MainActor struct BubbleVisibilityTests {
    private func panel() -> UnshownBubble {
        let panel = UnshownBubble(contentRect: NSRect(x: 100, y: 100, width: 272, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    @Test func aRequestedBubbleRecoversWithoutBecomingKey() {
        let p = panel(); defer { p.close() }
        p.presentRequested()
        p.restoreAfterTransition(generation: p.presentationGeneration, applicationHidden: false)
        #expect(p.showCount == 2)
        #expect(!p.canBecomeKey && !p.canBecomeMain)
        #expect(!p.isVisible)
    }

    @Test func cancellationAndNewTalkInvalidateQueuedRestoration() {
        let p = panel(); defer { p.close() }
        p.presentRequested(); let stale = p.presentationGeneration
        p.dismissRequested()
        p.restoreAfterTransition(generation: stale, applicationHidden: false)
        #expect(p.showCount == 1 && p.hideCount == 1)
        p.presentRequested()
        p.restoreAfterTransition(generation: stale, applicationHidden: false)
        #expect(p.showCount == 2)
        p.restoreAfterTransition(generation: p.presentationGeneration, applicationHidden: false)
        #expect(p.showCount == 3)
    }

    @Test func applicationHideDoesNotResurrectOrForgetTheRequest() {
        let p = panel(); defer { p.close() }
        p.presentRequested(); let ticket = p.presentationGeneration
        p.restoreAfterTransition(generation: ticket, applicationHidden: true)
        #expect(p.showCount == 1 && p.presentationRequested)
        p.restoreAfterTransition(generation: ticket, applicationHidden: false)
        #expect(p.showCount == 2)
        p.dismissRequested()
        p.restoreAfterTransition(generation: p.presentationGeneration, applicationHidden: false)
        #expect(p.showCount == 2 && !p.presentationRequested)
    }

    @Test func persistentPolicyRestoresTheSamePanelAfterSuppressionWithoutTakingFocus() {
        let p = panel(); defer { p.close() }
        PersistentBubblePolicy.apply(.standby, to: p)
        #expect(p.showCount == 1 && p.presentationRequested)
        PersistentBubblePolicy.apply(.suppressed, to: p)
        #expect(p.hideCount == 1 && !p.presentationRequested)
        PersistentBubblePolicy.apply(.standby, to: p)
        #expect(p.showCount == 2 && p.presentationRequested)
        PersistentBubblePolicy.apply(.modelControlledRecovery, to: p)
        #expect(p.showCount == 2 && p.hideCount == 1)
        #expect(!p.canBecomeKey && !p.canBecomeMain)
    }

    @Test func visibleFailureReturnsAfterSleepWithoutTakingFocus() {
        let p = panel(); defer { p.close() }
        var restore = PersistentBubbleRecoveryRestoreState()

        PersistentBubblePolicy.apply(.activeTalk, to: p)
        let enteredSleep = restore.transition(suspended: true, failed: true,
                                              panelPresentationRequested: p.presentationRequested)
        #expect(!enteredSleep)
        PersistentBubblePolicy.apply(.suppressed, to: p)
        #expect(!p.presentationRequested && p.hideCount == 1)

        let shouldRestore = restore.transition(suspended: false, failed: true,
                                               panelPresentationRequested: p.presentationRequested)
        PersistentBubblePolicy.apply(.modelControlledRecovery, to: p)
        if shouldRestore { PersistentBubblePolicy.apply(.activeTalk, to: p) }

        #expect(p.presentationRequested && p.showCount == 2)
        #expect(!p.canBecomeKey && !p.canBecomeMain)
    }

    @Test func recoveryKeepsHorizontalAndVerticalSizesAndNegativeDisplayCoordinates() {
        let screen = NSRect(x: -1512, y: 24, width: 1512, height: 920)
        for size in [NSSize(width: 272, height: 44), NSSize(width: 104, height: 148)] {
            let original = NSRect(origin: NSPoint(x: -1300, y: 100), size: size)
            #expect(CaptureBubblePanel.frameKeptOnScreen(original, visible: screen) == original)
            let offscreen = NSRect(origin: NSPoint(x: 2000, y: 2000), size: size)
            let adjusted = CaptureBubblePanel.frameKeptOnScreen(offscreen, visible: screen)
            #expect(adjusted.size == size)
            #expect(screen.contains(adjusted))
        }
    }

    @Test func spaceNotificationRestoresButPendingWorkCannotUndoDismissal() async throws {
        let p = panel(); defer { p.close() }
        p.observeTransitions(); p.observeTransitions() // registration is idempotent
        p.presentRequested()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(p.showCount == 2)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        p.dismissRequested()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(p.showCount == 2 && p.hideCount == 1)
    }
}

