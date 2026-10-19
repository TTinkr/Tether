


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension AppDelegate {


    // The bubble window — configureCompactWindow()


    /*
    Makes the panel a bubble: floats above other windows, appears on every Space and beside
    full-screen apps, is see-through with a shadow, and stays up when the app is not active.
    Preview runs use fixed spots. Public Tokens loads one of four edge presets immediately,
    including migration of old custom settings; retained products keep their frame restoration.
    */
    func configureCompactWindow(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .utilityWindow
        window.hidesOnDeactivate = false
        // Hiding Tokens (⌘H, or Hide Others in another app) must not hide a talk's bubble (build 81).
        window.canHide = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        (window as? CaptureBubblePanel)?.observeTransitions()
        window.minSize = panelMinimumSize
        window.maxSize = panelMaximumSize
        window.isReleasedWhenClosed = false
        if let panel = window as? NSPanel {
            panel.becomesKeyOnlyIfNeeded = true
            panel.isFloatingPanel        = true
        }
        window.setContentSize(panelDefaultSize)
        if bubbleInteractivePreview {
            if let visible = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.midX - panelDefaultSize.width / 2, y: visible.minY + 64))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--render-preview-frames") {
            window.setFrame(NSRect(origin: .zero, size: panelDefaultSize), display: false)
        } else if ProofRoutes.nativeBubblePreview {
            if let visible = tokensTargetScreen(for: nil)?.visibleFrame {
                BubbleWindowPlacement.apply(.right, to: window, visible: visible)
            }
        } else if publicTokens {
            if let visible = tokensTargetScreen(for: nil)?.visibleFrame {
                let placement = BubblePlacement.loadPreset(defaultingTo: .right)
                BubbleWindowPlacement.apply(placement, to: window, visible: visible)
            }
        } else {
            /*
            Try the current saved-frame name, then the older one. A frame saved under either
            keeps its centre but takes the current size, and is pulled back onto the screen.
            */
            let restored = window.setFrameUsingName(panelFrameName, force: true) ||
                window.setFrameUsingName(panelLegacyFrameName, force: true)
            if !restored {
                placeSurfaceWindow(window)
            } else {
                let migrated = resizeSurfaceFramePreservingCenter(window.frame)
                window.setFrame(clampSurfaceFrame(migrated, on: window.screen), display: false)
            }
            window.setFrameAutosaveName(panelFrameName)
            saveSurfaceFrame(window)
        }
    }


    /// Normal public launches keep one policy owner for standby visibility and destination preview.
    /// Proof/preview branches never call this entry point.
    @MainActor func startPersistentBubbleLifecycle() {
        guard publicTokens, let panel = surfaceWindow, panel.persistentLifecycle == nil else { return }
        let lifecycle = PersistentBubbleLifecycle(model: model, panel: panel)
        panel.persistentLifecycle = lifecycle
        lifecycle.start()
    }

}

