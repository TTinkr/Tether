


//
import AppKit
import Testing
import TokensCore
@testable import Tokens

@MainActor private final class PlacementOnlyPanel: CaptureBubblePanel {
    var orders = 0
    override func orderFrontRegardless() { orders += 1 }
}

@Suite(.serialized) @MainActor struct BubbleWindowPlacementTests {
    @Test func everyPresetMovesTheSameUnshownPanelWithoutPresentingIt() {
        let window = PlacementOnlyPanel(contentRect: NSRect(x: 9000, y: 9000, width: 272, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let oldVertical = BubbleLayout.shared.vertical
        let oldExpanded = BubbleLayout.shared.expanded
        BubbleLayout.shared.expanded = false
        defer { window.close(); BubbleLayout.shared.vertical = oldVertical; BubbleLayout.shared.expanded = oldExpanded }
        let screen = NSRect(x: -1512, y: 24, width: 1512, height: 920)
        var frames: [NSRect] = []
        for preset in BubblePlacement.presets {
            BubbleWindowPlacement.apply(preset, to: window, visible: screen)
            #expect(screen.contains(window.frame))
            #expect(window.frame.size == (preset.isVerticalPreset ? BubbleLayout.compactVerticalSize : panelDefaultSize))
            #expect(window.orders == 0 && !window.presentationRequested && !window.isVisible)
            #expect(!window.canBecomeKey && !window.canBecomeMain)
            frames.append(window.frame)
        }
        #expect(frames[0].midY < screen.midY && frames[2].midY > screen.midY)
        #expect(frames[1].midX < screen.midX && frames[3].midX > screen.midX)
        BubbleWindowPlacement.apply(.custom, to: window, visible: screen)
        #expect(window.frame == frames[0])
    }
}

