


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Panels


extension TalkModel {

    /// Hides the notes panel and chip as delivery launches, until the next explicit show.
    func dismissTinkeringAfterSend() {
        asideDismissedAfterSend = true
        asidePanel?.orderOut(nil); ambientChip?.orderOut(nil)
    }

    /// The panel's hide control: no capture, model or focus change.
    func hideTinkeringPanel() {
        asideHiddenByUser = true
        asidePanel?.orderOut(nil)
        showAmbientChip()
    }

    /// The small chip that stands in for a hidden notes panel. A nonactivating panel, so
    /// it never takes focus from the user's app.
    private func showAmbientChip() {
        guard !publicTokens, thinkingExperience, !isSyntheticRun, !asideDismissedAfterSend else { return }
        if ambientChip == nil {
            let chip = NonactivatingPanel(contentRect: NSRect(x: 120, y: 160, width: 96, height: 40),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            chip.isOpaque           = false; chip.backgroundColor = .clear; chip.hasShadow = true
            chip.level              = .floating; chip.isMovableByWindowBackground = true
            chip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            chip.contentView        = FirstMouseHostingView(rootView: AmbientChip(model: self, audio: audio))
            chip.setFrameAutosaveName("TTTAmbientChip.v1")
            ambientChip = chip
        }
        ambientChip?.orderFrontRegardless()
    }

    func restoreTinkering() { showPauseAside(explicit: true) }

    /// `explicit` is a capture start or the user's setting; it clears the
    /// panel's own hide. Anything else leaves a hidden panel hidden.
    func showPauseAside(explicit: Bool) {
        // Tokens shows only the small capture bubble; the notes window was cut.
        guard !publicTokens, showLiveTinkering, thinkingExperience, !isSyntheticRun else {
            asidePanel?.orderOut(nil); ambientChip?.orderOut(nil); return
        }
        if explicit { asideHiddenByUser = false; asideDismissedAfterSend = false }
        guard !asideDismissedAfterSend else { return }
        guard !asideHiddenByUser else { showAmbientChip(); return }
        ambientChip?.orderOut(nil)
        let panel: NSPanel
        if let existing = asidePanel { panel = existing } else {
            panel = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .floating; panel.ignoresMouseEvents = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.identifier = NSUserInterfaceItemIdentifier("TTTMachineGuess")
            let hosting = FirstMouseHostingView(rootView: AmbientWorkspace(model: self, audio: audio))
            // The user sizes the window; SwiftUI content follows it.
            hosting.sizingOptions    = []
            hosting.autoresizingMask = [.width, .height]
            panel.contentView        = hosting
            panel.contentMinSize     = NSSize(width: 320, height: 190)
            panel.contentMaxSize     = NSSize(width: 900, height: 700)
            /*
            First placement: above the bubble and centred on it, unless a saved frame exists;
            then the frame is clamped to the screen.
            */
            let surface = compactWindow()
            let screen  = surface?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let anchor  = surface?.frame ?? screen
            let x       = min(max(anchor.midX - 220, screen.minX + 8), screen.maxX - 448)
            if !panel.setFrameUsingName("TTTLiveTinkering.v1") {
                panel.setFrameOrigin(NSPoint(x: x, y: min(anchor.maxY + 12, screen.maxY - 258)))
            }
            let restored = panel.frame
            let width = min(max(restored.width, panel.contentMinSize.width), min(panel.contentMaxSize.width, screen.width))
            let height = min(max(restored.height, panel.contentMinSize.height), min(panel.contentMaxSize.height, screen.height))
            panel.setFrame(NSRect(x: min(max(restored.minX, screen.minX), screen.maxX - width),
                                  y: min(max(restored.minY, screen.minY), screen.maxY - height),
                                  width: width, height: height), display: false)
            panel.setFrameAutosaveName("TTTLiveTinkering.v1")
            asidePanel = panel
        }
        /*
        Streaming mutates the observed model inside one hosting view. Neither
        refresh nor partial validation recreates/repositions the window.
        */
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

//
// :)
//
//
    // Bubble window — show and hide the bubble without taking focus

    /// Shows the bubble with orderFrontRegardless, which does not activate Tokens, so the
    /// user's app keeps focus. In the Tokens thinking experience the bubble is placed by
    /// BubblePlacement on the target's screen (or the screen with keyboard focus); other
    /// products restore the user's own spot.
    func showSurface(on screenFrame: NSRect? = nil) {
        surfaceHeldInApp = false
        if bubbleStandbyOverride { bubbleStandbyOverride = false }
        guard let window = compactWindow() else {
            print("TTT_EVENT surface_missing windows=\(NSApp.windows.count)")
            return
        }
        let renderingPreview = ProcessInfo.processInfo.arguments.contains("--render-preview-frames")
        if thinkingExperience, !renderingPreview, let visible = tokensTargetScreen(for: screenFrame)?.visibleFrame {
            if !surfaceLocked { unlockedSurfaceFrame = window.frame }
            surfaceLocked           = true
            let placement = BubblePlacement.loadPreset()
            let layout = BubbleLayout.shared
            layout.vertical = placement.isVerticalPreset
            window.minSize  = panelMinimumSize
            window.maxSize  = panelMaximumSize
            let size        = layout.size
            window.setFrame(NSRect(origin: BubbleGeometry.origin(placement, custom: nil, size: size, visible: visible), size: size), display: false)
        } else {
            if surfaceLocked, let saved = unlockedSurfaceFrame {
                // Other products keep the position the user gave them.
                window.setFrame(saved, display: false)
                saveSurfaceFrame(window)
            }
            surfaceLocked        = false
            unlockedSurfaceFrame = nil
            window.setFrame(clampSurfaceFrame(window.frame, on: window.screen), display: false)
        }
        window.presentRequested()
        print("TTT_EVENT surface_shown title=\(window.title) frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible)")
    }

    func hideSurface() {
        surfaceHeldInApp = false
        if PersistentBubblePolicy.convertsFailedDismissalToStandby(
            persistentPreviewEnabled: persistentDestinationPreviewEnabled, phase: phase) {
            bubbleStandbyOverride = true
            if destinationPreviewSuspended {
                compactWindow()?.dismissRequested()
            } else {
                compactWindow()?.presentRequested()
            }
            return
        }
        compactWindow()?.dismissRequested()
    }

    /// True when Tokens is the active app and one of its own Home windows is key, on screen.
    var tokensWindowIsFrontmost: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow,
              Self.isTokensHomeWindow(identifier: key.identifier?.rawValue) else { return false }
        return key.isVisible && !key.isMiniaturized
    }

    /*
    Tokens' own Home windows: the main window, and the Settings window that Cmd-, opens (a SwiftUI
    Settings scene showing the same Home). Talking in either keeps the bubble back and the words
    in the app, with no pop-up (build 81: the Settings window was missed, so a "couldn't paste"
    pop-up opened on top of Tokens itself). The bubble, the pop-up and other panels never count.
    */
    static func isTokensHomeWindow(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == "TTTStyleChooser" || identifier.hasPrefix("com_apple_SwiftUI_Settings_window")
    }

    /**
    Talk and stop-gate entry point for the bubble. With the Tokens window in front the
    bubble is held back (Home shows the live talk); it appears the moment the user
    switches away while the talk is still capturing or finalizing. Recovery and proof
    routes call showSurface directly and are never held.
    */
    func showTalkSurface() {
        let renderingPreview = ProcessInfo.processInfo.arguments.contains("--render-preview-frames")
        guard publicTokens, !renderingPreview, !isSyntheticRun, tokensWindowIsFrontmost else {
            surfaceHeldInApp = false
            showSurface()
            return
        }
        if !surfaceHeldInApp { Diagnostics.event("surface_held_in_app phase=\(phase)") }
        surfaceHeldInApp = true
        if surfaceHeldInAppObserver == nil {
            surfaceHeldInAppObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, surfaceHeldInApp else { return }
                    surfaceHeldInApp = false
                    guard self.phase == .capturing || self.phase == .finalizing else { return }
                    Diagnostics.event("surface_released_on_app_switch phase=\(self.phase)")
                    self.showSurface()
                }
            }
        }
    }

}

