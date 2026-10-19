


//
/*
ThinkingPanel.swift
Owns: floating window creation, persistent panel visibility, saved placement and native resizing.
Never: change transcript words, call a model, or activate another application.
See: ThinkingPanelState.swift, ThinkingPanelView.swift, ThinkingTemple.swift.
*/


import AppKit
import SwiftUI

@MainActor
final class ThinkingPanelController: NSObject, NSWindowDelegate {


    // Showing and hiding


    let state: ThinkingPanelState
    // The window itself, created the first time it is needed.
    private(set) var panel: NSPanel?
    /*
    expandedSize: the full size to return to (also updated when the person resizes). changingSize
    is true while this class resizes the window, so that windowDidResize ignores its own changes.
    Visibility is a panel-only preference. Beginning another dictation never revokes a user's Hide.
    */
    private var expandedSize = ThinkingPanelGeometry.expandedSize(screen: NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982))
    private var changingSize = false
    private let defaults: UserDefaults
    private let placement: ThinkingPanelPlacement

    init(state: ThinkingPanelState, defaults: UserDefaults = .standard) {
        self.state     = state
        self.defaults  = defaults
        self.placement = ThinkingPanelPlacement(defaults: defaults)
        super.init()
        if let saved = placement.expandedSize { expandedSize = saved }
    }

    var isEnabled: Bool {
        TokensThinkingTemple.launchPanelAvailable
            && (defaults.object(forKey: TokensThinkingTemple.enabledKey) as? Bool ?? true)
    }

    /// Session lifecycle changes content, not the persistent visibility choice. Kept for owner symmetry.
    func beginSession() {}

    /// Hiding from the panel menu persists across sessions and launches. Only the panel setting changes.
    func hideForGood() {
        defaults.set(false, forKey: TokensThinkingTemple.enabledKey)
        hide()
    }

    // orderFrontRegardless puts the panel on screen without making the app the active app.
    func show() {
        guard isEnabled else { return }
        if panel == nil { makePanel() }
        panel?.orderFrontRegardless()
    }

    var isEditingNotes: Bool {
        panel?.isKeyWindow == true && panel?.firstResponder is NSTextView
    }

    func hide() { state.cancelSpacing(); panel?.orderOut(nil) }

    func close() {
        state.cancelSpacing()
        if let panel { placement.save(panel.frame, expanded: expandedSize) }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func collapse() { resize(to: NSSize(width: 88, height: 56), remember: true) }
    func expand() { resize(to: expandedSize, remember: false) }


    // Window setup and sizing


    private func makePanel() {
        /*
        A floating panel that does not take over the screen: .nonactivatingPanel and
        becomesKeyOnlyIfNeeded stop it from taking focus from the app being typed into, hidesOnDeactivate
        is off so it stays when another app is in front, and it floats above normal windows on every
        desktop and over full-screen apps. Its title bar is see-through and its three window buttons are
        hidden; dragging the paper margin moves it and the visible corner grip resizes it.
        */
        let window = ThinkingNativePanel(
            contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.title = "Notes and questions"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.contentMinSize = NSSize(width: 72, height: 52)
        window.contentMaxSize = NSSize(width: 1000, height: 650)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.animationBehavior = .none
        window.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        /*
        The SwiftUI content gets three actions: shrink to the tiny size, grow back, and dismiss (which
        remembers the dismissal and hides the panel).
        */
        let content = ThinkingPanelView(
            state: state,
            collapse: { [weak self] in self?.collapse() },
            expand: { [weak self] in self?.expand() },
            dismiss: { [weak self] in self?.hideForGood() }
        )
        window.contentView = ThinkingPanelHostingView(rootView: content)
        /*
        Restore the last position and collapsed/full size. Pull an off-screen frame onto an available
        display after monitor changes; first use remains low and centred as before.
        */
        if let saved = placement.frame {
            let area = NSScreen.screens.first { $0.visibleFrame.intersects(saved) }?.visibleFrame
                ?? NSScreen.main?.visibleFrame
            let restored = ThinkingPanelPlacement.fitting(saved, in: area)
            window.setFrame(restored, display: false)
            if restored.width > 180, restored.height > 110 { expandedSize = restored.size }
        } else if let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - expandedSize.width / 2,
                                          y: area.minY + 100))
        } else {
            window.center()
        }
        panel = window
    }

//
// :)
//
//
    /*
    Changing size. The size to return to is remembered only when the current window is a full-size
    one (wider than 180 and taller than 110). AppKit's y axis points up, so the origin's y is
    raised by the height lost to keep the top-left corner fixed (the existing comment below says
    the same). The result is then pulled back inside the screen's visible area.
    */
    private func resize(to size: NSSize, remember: Bool) {
        guard let panel else { return }
        if remember && panel.frame.width > 180 && panel.frame.height > 110 {
            expandedSize = panel.frame.size
        }
        changingSize = true
        // Keep the top-left corner stationary, including under Reduce Motion.
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = panel.screen {
            let area       = screen.visibleFrame
            frame.origin.x = max(area.minX, min(frame.minX, area.maxX - frame.width))
            frame.origin.y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        }
        panel.setFrame(frame, display: true, animate: false)
        changingSize = false
        placement.save(panel.frame, expanded: expandedSize)
    }

    func windowDidMove(_ notification: Notification) {
        if let panel { placement.save(panel.frame, expanded: expandedSize) }
    }

    /*
    When the person drags a window edge, remember that size as the full size, but only when it is
    big enough to count as full size (the same 180 by 110 limits the view uses for its tiny layout).
    */
    func windowDidResize(_ notification: Notification) {
        guard !changingSize, let panel else { return }
        if panel.frame.width > 180, panel.frame.height > 110 { expandedSize = panel.frame.size }
        placement.save(panel.frame, expanded: expandedSize)
    }


}


// ThinkingNativePanel — a panel that can take keyboard focus but is never the main window


final class ThinkingNativePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}


// ThinkingPanelPlacement — injectable preferences keep placement checks offscreen and isolated


struct ThinkingPanelPlacement {
    static let frameKey    = "TokensThinkingPanelFrame.v1"
    static let expandedKey = "TokensThinkingPanelExpandedSize.v1"
    let defaults: UserDefaults

    var frame: NSRect? {
        guard let encoded = defaults.string(forKey: Self.frameKey) else { return nil }
        let frame = NSRectFromString(encoded)
        guard Self.valid(frame.size), frame.minX.isFinite, frame.minY.isFinite else { return nil }
        return frame
    }

    var expandedSize: NSSize? {
        guard let encoded = defaults.string(forKey: Self.expandedKey) else { return nil }
        let size = NSSizeFromString(encoded)
        return Self.valid(size) && size.width > 180 && size.height > 110 ? size : nil
    }

//
// :)
//
//
    func save(_ frame: NSRect, expanded: NSSize) {
        guard Self.valid(frame.size), frame.minX.isFinite, frame.minY.isFinite else { return }
        defaults.set(NSStringFromRect(frame), forKey: Self.frameKey)
        if Self.valid(expanded), expanded.width > 180, expanded.height > 110 {
            defaults.set(NSStringFromSize(expanded), forKey: Self.expandedKey)
        }
    }

    /*
    The existing panel constraints also bound restored preferences. Malformed or oversized stored
    values fall back to the normal first-use geometry; never create an unreachable giant window.
    */
    private static func valid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 72 && size.height >= 52
            && size.width <= 1000 && size.height <= 650
    }

    static func fitting(_ frame: NSRect, in area: NSRect?) -> NSRect {
        guard let area, area.width > 0, area.height > 0 else { return frame }
        var fitted         = frame
        fitted.size.width  = min(frame.width, area.width)
        fitted.size.height = min(frame.height, area.height)
        fitted.origin.x    = max(area.minX, min(frame.minX, area.maxX - fitted.width))
        fitted.origin.y    = max(area.minY, min(frame.minY, area.maxY - fitted.height))
        return fitted
    }
}

// A deliberate first click in the nonactivating paper should reach its native editor immediately.
private final class ThinkingPanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

