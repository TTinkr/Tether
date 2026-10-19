


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension AppDelegate {


    // The lab window and voice commands — showLabWindow(), handleVoiceCommand(), makeLabWindow()


    // Showing the lab hides the bubble. The standalone build has no lab.
    func showLabWindow() {
        guard !standalone else { return }
        let window = labWindow ?? makeLabWindow(size: NSSize(width: 1100, height: 720), restoreFrame: true)
        labWindow  = window
        surfaceWindow?.dismissRequested()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        print("TTT_EVENT lab_shown frame=\(NSStringFromRect(window.frame))")
    }

    func hideLabWindow() {
        labWindow?.orderOut(nil)
        print("TTT_EVENT lab_hidden")
    }

    /*
    Spoken window commands. They act only while the lab is open and its window is visible or
    minimized; the other commands in the enum are handled elsewhere, so here they just return.
    */
    func handleVoiceCommand(_ command: VoiceCommand) {
        guard model.isLabOpen, let window = labWindow,
              window.isVisible || window.isMiniaturized else { return }
        switch command {
        case .minimize:
            model.pauseLab(source: "voice_minimize")
            window.miniaturize(nil)
        case .fullScreen:
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .restoreSize:
            // From full screen: leave it first, then reset the size 0.8 s later.
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak window] in
                    if let window { self.restoreLabSize(window) }
                }
            } else {
                restoreLabSize(window)
            }
        case .closeWindow:
            model.closeLab()
        case .copyTalk, .paste, .send, .stopListening, .labSound(_):
            return
        }
        print("TTT_EVENT voice_command_applied command=\(command.rawValue)")
    }

    // Back to 1100 by 720 (smaller if the screen is smaller), centred on the visible area, and saved.
    private func restoreLabSize(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let size = NSSize(
            width: min(1100, visible?.width ?? 1100),
            height: min(720, visible?.height ?? 720)
        )
        let origin = NSPoint(
            x: (visible?.midX ?? size.width / 2) - size.width / 2,
            y: (visible?.midY ?? size.height / 2) - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        window.saveFrame(usingName: labFrameName)
    }

//
// :)
//
//
    /*
    `restoreFrame` true: use the saved position, or fill the visible screen (inset 24) if there
    is none. False (proof renders): a fixed frame at the origin so images come out the same each time.
    */
    func makeLabWindow(size: NSSize, restoreFrame: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(appName) Lab"
        window.identifier = NSUserInterfaceItemIdentifier("TTTVoiceLab")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.delegate = self
        window.contentView = hostingView(
            NoiseLab(model: model, onDictate: model.beginDictationFromLab),
            size: size
        )
        if restoreFrame {
            window.setFrameAutosaveName(labFrameName)
            if !window.setFrameUsingName(labFrameName) {
                let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                window.setFrame(visible?.insetBy(dx: 24, dy: 24) ?? NSRect(origin: .zero, size: size), display: false)
            }
        } else {
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
        }
        return window
    }


}

