


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// NonactivatingPanel — A panel that can never become the key or main window


/*
With both answers false, clicking the bubble does not move keyboard focus to this app. The
panel is also created with the .nonactivatingPanel style (see AppDelegate), which keeps the
app from being activated by a click.
*/
final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// compactWindow() — Finds the bubble window by its identifier


// "TTTCompactPanel" is the identifier AppDelegate gives the bubble when it creates it.
func compactWindow() -> CaptureBubblePanel? {
    NSApp.windows.first(where: { $0.identifier?.rawValue == "TTTCompactPanel" }) as? CaptureBubblePanel
}


// Constants — Bubble size, saved-frame names, and sizes of the other windows


/*
The horizontal capture bubble is 124 by 26 (a tiny bubble with just a little bit of
the wave); retained-word and legacy surfaces expand for readability.
The *FrameName strings are the names AppKit saves window positions under on people's Macs, so
they stay as they are; the older bubble name is only a fallback when nothing is saved under the current one.
*/
let panelDefaultSize = NSSize(width: 124, height: 26)
let panelMinimumSize = NSSize(width: 32, height: 26)
let panelMaximumSize = NSSize(width: 272, height: 148)
let panelFrameName = "TTTGlassCapsule.v3"
let panelLegacyFrameName = "TTTGlassCapsule.v2"
let labFrameName = "TTTVoiceLab.v1"
let styleWindowWidth: CGFloat = 560
let styleCollapsedContentHeight: CGFloat = 300
let styleExpandedContentHeight: CGFloat = 480
let mainWaveformHeight: CGFloat = 84


// placeSurfaceWindow() — Puts the bubble at the right edge of a screen, vertically centred


/*
Chooses the screen that overlaps `screenFrame` the most (the main screen if none is given),
then sets the window's origin 14 points in from the right edge of that screen's visible area,
halfway up. Visible area excludes the menu bar and Dock.
*/
func placeSurfaceWindow(_ window: NSWindow, near screenFrame: NSRect? = nil) {
    let targetScreen = screenFrame.flatMap { target in
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(target).width * lhs.frame.intersection(target).height
                < rhs.frame.intersection(target).width * rhs.frame.intersection(target).height
        }
    } ?? NSScreen.main ?? NSScreen.screens.first
    guard let visibleFrame = targetScreen?.visibleFrame else { return }
    window.setFrameOrigin(NSPoint(
        x: visibleFrame.maxX - window.frame.width - 14,
        y: visibleFrame.midY - window.frame.height / 2
    ))
}

//
// :)
//
//
// Bubble lock — Whether the model has taken over the bubble's position


/// Lab Tokens bubble: fixed bottom centre of the target screen's visible
/// (Dock- and menu-bar-aware) area. While set, the drag area is inert.
/*
TalkModel.showSurface sets `surfaceLocked` when it places the bubble itself (using
BubblePlacement) and keeps the position the bubble had before in `unlockedSurfaceFrame`, so it
can put the bubble back where the user left it when the lock ends. Design/WindowDrag.swift
ignores drags while the lock is on.
*/
var surfaceLocked = false
var unlockedSurfaceFrame: NSRect?
/// Set while a talk runs with the Tokens window in front: Home already shows the live
/// words, so the floating bubble waits until the user switches to another app.
var surfaceHeldInApp = false
var surfaceHeldInAppObserver: NSObjectProtocol?


// tokensTargetScreen() — The screen that overlaps a given frame the most


/*
Falls back to the main screen, then to the first screen. Same screen choice as
placeSurfaceWindow(), written out a second time.
*/
func tokensTargetScreen(for screenFrame: NSRect?) -> NSScreen? {
    screenFrame.flatMap { target in
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(target).width * lhs.frame.intersection(target).height
                < rhs.frame.intersection(target).width * rhs.frame.intersection(target).height
        }
    // NSScreen.main is the screen holding the window with keyboard focus.
    } ?? NSScreen.main ?? NSScreen.screens.first
}


// hostingView() — Wraps a SwiftUI view for use as a window's content


/*
The view fills the window and follows its size (autoresizing); it does not size the window
itself (sizingOptions is empty). It is a FirstMouseHostingView so the first click counts.
*/
func hostingView<Content: View>(_ rootView: Content, size: NSSize) -> NSHostingView<Content> {
    let view              = FirstMouseHostingView(rootView: rootView)
    view.sizingOptions    = []
    view.frame            = NSRect(origin: .zero, size: size)
    view.autoresizingMask = [.width, .height]
    return view
}


// FirstMouseHostingView — Accepts the first click even when another app is in front


/// Floating nonactivating panels must accept the first click from another app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}


// saveSurfaceFrame() — Saves the bubble's position under its saved-frame name


// Does nothing in the interactive bubble preview, which must not write settings.
func saveSurfaceFrame(_ window: NSWindow) {
    guard !bubbleInteractivePreview else { return }
    window.saveFrame(usingName: panelFrameName)
}


// clampSurfaceFrame() — Keeps a frame inside the visible area of its screen


/*
Size is limited to the bubble's minimum and maximum (and to the screen), then the position is
moved just enough to fit inside the screen's visible area.
*/
func clampSurfaceFrame(_ frame: NSRect, on screen: NSScreen?) -> NSRect {

//
// :)
//
//
    guard let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return frame }
    let width  = min(max(frame.width, panelMinimumSize.width), min(panelMaximumSize.width, visible.width))
    let height = min(max(frame.height, panelMinimumSize.height), min(panelMaximumSize.height, visible.height))
    let x      = min(max(frame.minX, visible.minX), visible.maxX - width)
    let y      = min(max(frame.minY, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
}


// resizeSurfaceFramePreservingCenter() — Gives a saved frame the current size, same centre


// Used when an older saved position is restored (see AppDelegate.configureCompactWindow).
func resizeSurfaceFramePreservingCenter(_ frame: NSRect) -> NSRect {
    NSRect(
        x: frame.midX - panelDefaultSize.width / 2,
        y: frame.midY - panelDefaultSize.height / 2,
        width: panelDefaultSize.width,
        height: panelDefaultSize.height
    )
}

