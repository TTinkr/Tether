


//
import AppKit

/// The recording bubble's visibility is an app decision, separate from whether the window
/// server currently presents it in a Space. A Space transition must not revive a finished talk.
class CaptureBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private(set) var presentationRequested = false
    private(set) var presentationGeneration: UInt64 = 0
    private var pendingRestore: DispatchWorkItem?
    private var observingTransitions = false
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter

    func observeTransitions() {
        precondition(Thread.isMainThread)
        guard !observingTransitions else { return }
        observingTransitions = true
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspaceNotifications.addObserver(self, selector: #selector(transitionFinished(_:)),
                                               name: name, object: nil)
        }
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(transitionFinished(_:)),
                                                   name: name, object: nil)
        }
    }

    func presentRequested() {
        precondition(Thread.isMainThread)
        presentationGeneration &+= 1
        presentationRequested = true
        pendingRestore?.cancel()
        orderFrontRegardless()
    }

    func dismissRequested() {
        precondition(Thread.isMainThread)
        presentationGeneration &+= 1
        presentationRequested = false
        pendingRestore?.cancel()
        orderOut(nil)
    }

    @objc private func transitionFinished(_ notification: Notification) {
        /*
        Notification delivery follows its posting thread. Keep all intent and work-item
        mutations on the same queue as show/dismiss, including injected notifications.
        */
        DispatchQueue.main.async { [weak self] in self?.scheduleRestoration() }
    }

    private func scheduleRestoration() {
        precondition(Thread.isMainThread)
        guard presentationRequested else { return }
        pendingRestore?.cancel()
        let generation = presentationGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.restoreAfterTransition(generation: generation, applicationHidden: NSApp.isHidden)
            }
        }
        pendingRestore = work
        // Re-order after the Space begins settling, never activate the app or recreate the view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func restoreAfterTransition(generation: UInt64, applicationHidden: Bool) {
        precondition(Thread.isMainThread)
        guard presentationRequested, generation == presentationGeneration,
              !applicationHidden, !isMiniaturized else { return }
        // Keep the same display/position while it exists; only pull an offscreen frame back in.
        if let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let frameOnScreen = Self.frameKeptOnScreen(frame, visible: visible)
            if frameOnScreen != frame { setFrame(frameOnScreen, display: false) }
        }
        orderFrontRegardless()
    }

//
// :)
//
//
    static func frameKeptOnScreen(_ frame: NSRect, visible: NSRect) -> NSRect {
        // Do not use the legacy 272x44 clamp: it would flatten a 104x148 side preset.
        let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    deinit {
        pendingRestore?.cancel()
        workspaceNotifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}

