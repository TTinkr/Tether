


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension AppDelegate {


    // The main window — makeStyleWindow(), resizeStyleWindow()


    /*
    Builds the main window. Size depends on the build: the public Tokens build uses a 1040 by 720
    sidebar layout (content under a clear title bar), except for the compact proof render. The
    content view is chosen by build flags: standalone, public Tokens, or the older product shell.
    */
    func makeStyleWindow() -> NSWindow {
        let compactPublicPreview = publicTokens
            && ProcessInfo.processInfo.arguments.contains("--render-preview-frames")
            && ProcessInfo.processInfo.arguments.contains("--public-preview-compact")
        let minimumPublicPreview = publicTokens
            && ProcessInfo.processInfo.arguments.contains("--render-preview-frames")
            && ProcessInfo.processInfo.arguments.contains("--public-preview-minimum")
        var size = NSSize(
            width: compactPublicPreview ? 420 : styleWindowWidth,
            height: compactPublicPreview ? 280 : publicTokens ? styleCollapsedContentHeight : (model.historyExpanded
                ? styleExpandedContentHeight
                : styleCollapsedContentHeight)
        )
        if publicTokens && !compactPublicPreview {
            // 1040 × 720 by default; proof renders may ask for the minimum or an exact size.
            size = minimumPublicPreview ? Self.publicMinimumSize
                : Self.publicPreviewSize(ProcessInfo.processInfo.arguments) ?? Self.publicDefaultSize
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title      = appName
        window.identifier = NSUserInterfaceItemIdentifier("TTTStyleChooser")
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: 420, height: 280)
        if publicTokens && !compactPublicPreview {
            // Sidebar layout: the content runs under a clear title bar.
            window.contentMinSize             = Self.publicMinimumSize
            window.titleVisibility            = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
        window.isReleasedWhenClosed = false
        window.delegate             = self
        /*
        The model calls these when the product or the product drawer changes: retitle and resize
        the window; widen it (at least 760) when the drawer opens, shifting left if that would
        push it off the screen. Resizing is skipped while the window is full screen.
        */
        model.onProductChange = { [weak self, weak window] in
            guard let self, let window else { return }
            window.title = self.model.selectedProduct == "Tokens" ? appName : self.model.selectedProduct
            self.resizeStyleWindow(expanded: self.model.historyExpanded)
            if self.model.selectedProduct == "Tincture" {
                self.model.setProductDrawerExpanded(false)
                if !ProcessInfo.processInfo.arguments.contains("--controls-preview"), !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
        model.onProductDrawerChange = { [weak window] expanded in
            guard let window else { return }
            window.contentMinSize.width = 420
            guard expanded, !window.styleMask.contains(.fullScreen) else { return }
            var frame        = window.frame
            frame.size.width = max(760, frame.width)
            if let screen = window.screen, frame.maxX > screen.visibleFrame.maxX {
                frame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - frame.width)
            }
            window.setFrame(frame, display: true, animate: false)
        }
        if standalone { window.contentView = hostingView(StandaloneRoot(model: model), size: size) }
        else if publicTokens { window.contentView = hostingView(TokensHome(model: model), size: size) }
        else { window.contentView = hostingView(ProductShell(model: model), size: size) }
        window.center()
        // The View menu's zoom items; idempotent, and re-checked whenever the window is shown.
        installViewMenu()
        return window
    }

    /// Public Tokens window: default content size and the smallest size it can be dragged to.
    /// Build 82: one square taller (520 → 576) so the rail's sixth row (Models) fits in every state,
    /// update offer, status line and Dev line together, with Settings still at the bottom.
    static let publicDefaultSize = NSSize(width: 1040, height: 720)
    static let publicMinimumSize = NSSize(width: 760, height: 576)

    /*
    `--public-preview-size WxH` (with --render-preview-frames) sets the proof window's content
    size, e.g. 1440x900. Values below the minimum are raised to it; malformed values are ignored.
    */
    static func publicPreviewSize(_ arguments: [String]) -> NSSize? {
        guard publicTokens, arguments.contains("--render-preview-frames"),
              let flag = arguments.firstIndex(of: "--public-preview-size"), flag + 1 < arguments.count
        else { return nil }
        let parts = arguments[flag + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return NSSize(width: max(publicMinimumSize.width, width), height: max(publicMinimumSize.height, height))
    }

//
// :)
//
//
    // Only ever makes the window taller, and keeps its top edge where it was so it grows downward.
    func resizeStyleWindow(expanded: Bool) {
        /*
        Public Tokens presents history as a focused page; legacy expansion
        must not resize its window behind that navigation.
        */
        guard !publicTokens else { return }
        guard let window = styleWindow, !window.styleMask.contains(.fullScreen) else { return }
        let targetContentHeight = (expanded ? styleExpandedContentHeight : styleCollapsedContentHeight)
            + (model.selectedProduct == "Talk" ? 160 : ["Telescope", "Tincture"].contains(model.selectedProduct) ? 420 : 0)
        let current        = window.frame
        let currentContent = window.contentRect(forFrameRect: current)
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(width: currentContent.width, height: targetContentHeight)
            )
        ).size
        guard targetFrameSize.height > current.height + 0.5 else { return }
        let target = NSRect(
            x: current.minX,
            y: current.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        window.setFrame(target, display: true, animate: false)
        print(
            "TTT_EVENT prompt_history_window expanded=\(expanded) " +
            "content_height=\(Int(targetContentHeight)) frame=\(NSStringFromRect(target))"
        )
    }


}

