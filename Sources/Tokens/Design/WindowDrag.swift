


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// PanelDragHandle — small π-wave mark that doubles as a place to drag the window


/*
No file other than this one uses PanelDragHandle at the moment; the bubble uses
NativeWindowDragArea directly.
*/
struct PanelDragHandle: View {
    let energy: Double

    var body: some View {
        ZStack {
            WavePi(amplitude: energy)
                .stroke(
                    Color.black.opacity(0.72),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 15, height: 11)
                .allowsHitTesting(false)
            NativeWindowDragArea()
        }
        .frame(width: 38, height: 24)
        .contentShape(Rectangle())
        .help("Drag \(appName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Move \(appName) panel")
    }
}


// PanelResizeHandle — three diagonal ticks in the corner that resize the window


// Also unused outside this file at the moment.
struct PanelResizeHandle: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                let ink = Color.black.opacity(0.40)
                for offset in [CGFloat(0), 4, 8] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: size.width - 3 - offset, y: size.height - 1))
                    tick.addLine(to: CGPoint(x: size.width - 1, y: size.height - 3 - offset))
                    context.stroke(tick, with: .color(ink), lineWidth: 0.9)
                }
            }
            .allowsHitTesting(false)
            NativeWindowResizeArea()
        }
        .frame(width: 25, height: 25)
        .contentShape(Rectangle())
        .help("Resize \(appName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize \(appName) panel")
    }
}


// NativeWindowDragArea — SwiftUI wrapper that places a WindowDragView


struct NativeWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}


// WindowDragView — the AppKit view that moves the whole window while the mouse drags


final class WindowDragView: NSView {

//
// :)
//
//
    private var startingFrame: NSRect?
    private var startingPointer: NSPoint?

    /*
    Returning true means the very click that would first activate the window also starts a drag,
    instead of being used up on activating.
    */
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /*
    Nothing moves yet: remember where the window and the pointer were. The pointer position is
    taken in SCREEN coordinates because the window itself moves under the pointer during the drag,
    so a window-relative position would change underneath us. Ignored while `surfaceLocked` (the
    lab bubble is pinned to the bottom centre of the screen and its drag area is inert).
    */
    override func mouseDown(with event: NSEvent) {
        guard let window, !surfaceLocked else { return }
        startingFrame   = window.frame
        startingPointer = window.convertPoint(toScreen: event.locationInWindow)
    }

    /*
    New frame = the frame at mouse-down, shifted by how far the pointer has moved since then. The
    display chosen is the one containing the new frame's centre (falling back to the window's
    current screen), and clampSurfaceFrame keeps the window inside that display's visible area, so
    it can cross to another monitor but never end up under the menu bar or the Dock.
    */
    override func mouseDragged(with event: NSEvent) {
        guard let window, let frame = startingFrame, let pointer = startingPointer else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let moved = NSRect(
            x: frame.minX + current.x - pointer.x,
            y: frame.minY + current.y - pointer.y,
            width: frame.width,
            height: frame.height
        )
        let center       = NSPoint(x: moved.midX, y: moved.midY)
        let targetScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? window.screen
        window.setFrame(clampSurfaceFrame(moved, on: targetScreen), display: true)
    }

    // Drag finished: save the window position (saveSurfaceFrame) and write a log line.
    override func mouseUp(with event: NSEvent) {
        guard let window, startingFrame != nil else { return }
        saveSurfaceFrame(window)
        print("TTT_UI panel_moved frame=\(NSStringFromRect(window.frame))")
        startingFrame   = nil
        startingPointer = nil
    }

    // Open-hand cursor over the whole area, except while the window is locked in place.
    override func resetCursorRects() {
        guard !surfaceLocked else { return }
        addCursorRect(bounds, cursor: .openHand)
    }
}


// NativeWindowResizeArea — SwiftUI wrapper that places a WindowResizeView


struct NativeWindowResizeArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowResizeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}


// WindowResizeView — the AppKit view that resizes the window from its bottom-right corner


final class WindowResizeView: NSView {
    private var startingFrame: NSRect?
    private var startingPointer: NSPoint?

//
// :)
//
//
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Same bookkeeping as WindowDragView: window frame and pointer position, both in screen terms.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startingFrame   = window.frame
        startingPointer = window.convertPoint(toScreen: event.locationInWindow)
    }

    /*
    The top-left corner stays put and the bottom-right corner follows the pointer. Screen y grows
    upward, so dragging down makes the window taller by subtracting from the starting height, and
    the new origin.y is `maxY - height` to keep the top edge where it was. Width and height are
    kept between panelMinimumSize and the smaller of panelMaximumSize and the room left on the
    screen under the pointer: from the window's left edge to the right edge of the visible area,
    and from its top edge down to the bottom of the visible area.
    Today panelMinimumSize, panelMaximumSize and panelDefaultSize are the same value (App/
    SurfaceWindow.swift), so in practice this always yields that one size.
    */
    override func mouseDragged(with event: NSEvent) {
        guard let window, let frame = startingFrame, let pointer = startingPointer else { return }
        let current        = window.convertPoint(toScreen: event.locationInWindow)
        let pointerScreen  = NSScreen.screens.first { NSMouseInRect(current, $0.frame, false) }
        let visible        = (pointerScreen ?? window.screen ?? NSScreen.main)?.visibleFrame
        let availableWidth = visible.map { max(panelMinimumSize.width, $0.maxX - frame.minX) }
            ?? panelMaximumSize.width
        let availableHeight = visible.map { max(panelMinimumSize.height, frame.maxY - $0.minY) }
            ?? panelMaximumSize.height
        let width = min(max(frame.width + current.x - pointer.x, panelMinimumSize.width),
                        min(panelMaximumSize.width, availableWidth))
        let height = min(max(frame.height - current.y + pointer.y, panelMinimumSize.height),
                         min(panelMaximumSize.height, availableHeight))
        window.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height),
            display: true
        )
    }

    // Resize finished: save the window frame and write a log line.
    override func mouseUp(with event: NSEvent) {
        guard let window, startingFrame != nil else { return }
        saveSurfaceFrame(window)
        print("TTT_UI panel_resized frame=\(NSStringFromRect(window.frame))")
        startingFrame   = nil
        startingPointer = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

