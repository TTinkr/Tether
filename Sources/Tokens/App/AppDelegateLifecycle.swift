


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension AppDelegate {


    // App and window callbacks — hide, unhide, reopen, close, minimize, quit


    /*
    Closing every window does not quit: the app keeps listening for the talk key, and in the
    public build keeps its menu-bar item.
    */
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidHide(_ notification: Notification) {
        model.pauseLab(source: "application_hidden")
        model.setInputPreviewVisible(false)
    }

    // Dock/relaunch is an explicit request to show Home; consent and permissions remain separate.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if bubbleInteractivePreview {
            bubblePreviewStage?.makeKeyAndOrderFront(nil)
            return true
        }
        if shouldPresentHomeOnReopen { showStyleChooser() }
        return true
    }

    /*
    Windows are told apart by their identifiers. The main window ("TTTStyleChooser") closes after
    hiding the input preview. The lab window ("TTTVoiceLab") is never closed here: the answer is
    false and the model is asked to close the lab itself, which then hides it. Others close.
    */
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bubbleInteractivePreview { NSApp.terminate(nil); return true }
        if sender.identifier?.rawValue == "TTTStyleChooser" {
            model.setInputPreviewVisible(false)
            return true
        }
        guard sender.identifier?.rawValue == "TTTVoiceLab" else { return true }
        model.closeLab()
        return false
    }

    /*
    windowDidDeminiaturize, applicationDidUnhide and windowDidMiniaturize (and applicationDidHide
    above) keep the main window's live input preview in step with whether the window can be
    seen (minimized or app hidden: off; back again: on), except while the first-run card is
    still pending.
    */
    func windowDidDeminiaturize(_ notification: Notification) {
        if (notification.object as? NSWindow)?.identifier?.rawValue == "TTTStyleChooser" {
            if !tokensFirstRunPending { model.setInputPreviewVisible(true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.stopAmbientForQuit() }

    func applicationDidUnhide(_ notification: Notification) {
        if styleWindow?.isVisible == true, !tokensFirstRunPending { model.setInputPreviewVisible(true) }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if (notification.object as? NSWindow)?.identifier?.rawValue == "TTTStyleChooser" {
            model.setInputPreviewVisible(false)
            return
        }
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "TTTVoiceLab" else { return }
        model.pauseLab(source: "window_minimized")
    }

//
// :)
//
//
    // Only the copy whose process id matches the one in the message reacts; any other copy ignores it.
    @objc func handleReopenNotification(_ notification: Notification) {
        guard let targetPID = notification.userInfo?["target_pid"] as? NSNumber,
              targetPID.int32Value == ProcessInfo.processInfo.processIdentifier else { return }
        if shouldPresentHomeOnReopen { showStyleChooser() }
    }


}

