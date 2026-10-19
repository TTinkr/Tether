


//
import AppKit
import SwiftUI

struct BubblePresetArea: NSViewRepresentable {
    // Compact status/countdown surfaces keep their existing size while moving.
    var rotatesLayout = true
    func makeNSView(context: Context) -> BubblePresetButton {
        let view = BubblePresetButton()
        view.rotatesLayout = rotatesLayout
        return view
    }
    func updateNSView(_ view: BubblePresetButton, context: Context) { view.rotatesLayout = rotatesLayout }
}

/// A real accessibility button behind the two independent action buttons.
/// Space/Return and accessibility press share the same placement-only action.
final class BubblePresetButton: NSButton {
    var rotatesLayout = true
    var defaults: UserDefaults = .standard
    var onPlacement: ((BubblePlacement) -> Void)?
    private var previewPlacement: BubblePlacement = .bottom

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; isBordered = false
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(advance)
        identifier = NSUserInterfaceItemIdentifier("bubble.cycle-position")
        setAccessibilityLabel("Move bubble to next screen edge")
        setAccessibilityHelp("Cycles bottom, left, top, right. Does not finish or send your talk.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.keyCode == 49 || event.keyCode == 36 { advance() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        advance()
        return true
    }
    override func mouseDragged(with event: NSEvent) {} // no free-position path

    @objc func advance() {
        let placement = (bubbleInteractivePreview ? previewPlacement : BubblePlacement.loadPreset(from: defaults)).nextPreset
        if bubbleInteractivePreview { previewPlacement = placement }
        else { BubblePlacement.save(placement, to: defaults) }
        setAccessibilityValue(placement.rawValue.capitalized)
        onPlacement?(placement)
        guard let window else { return }
        let layout = BubbleLayout.shared
        if rotatesLayout { layout.vertical = placement.isVerticalPreset }
        let size = rotatesLayout ? layout.size : window.frame.size
        if bubbleInteractivePreview {
            var ancestor = superview
            while let view = ancestor {
                if view.identifier?.rawValue == "TTTPreviewBubbleHost", let parent = view.superview {
                    view.frame = NSRect(origin: BubbleGeometry.origin(placement, custom: nil, size: size, visible: parent.bounds), size: size)
                    return
                }
                ancestor = view.superview
            }
            // The native proof uses the safe preview actions without a stage host.
            // Let its real panel move; ordinary staged previews stay inside their canvas.
            if !ProofRoutes.nativeBubblePreview { return }
        }
        guard let screen = window.screen else { return }
        // Use the display already containing this bubble, never the pointer's other display.
        window.minSize = panelMinimumSize
        window.maxSize = panelMaximumSize
        window.setFrame(NSRect(origin: BubbleGeometry.origin(placement, custom: nil,
            size: size, visible: screen.visibleFrame), size: size), display: false)
    }
}

