


//
import AppKit
import TokensCore

enum BubbleWindowPlacement {
    static func apply(_ placement: BubblePlacement, to window: NSWindow, visible: NSRect) {
        precondition(Thread.isMainThread)
        let preset = BubblePlacement.presets.contains(placement) ? placement : .bottom
        let layout = BubbleLayout.shared
        layout.vertical = preset.isVerticalPreset
        window.minSize = panelMinimumSize
        window.maxSize = panelMaximumSize
        let size = layout.size
        window.setFrame(NSRect(origin: BubbleGeometry.origin(preset, custom: nil,
            size: size, visible: visible), size: size), display: false)
    }
}

