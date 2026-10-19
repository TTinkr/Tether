


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// BubbleAction — a small round discard or finish button for the bubble (AppKit button)


/*
AppKit buttons accept the first click without activating the floating panel.
`symbol` is an SF Symbol name ("xmark" for discard, "checkmark" for finish) and is also stored
as the button's identifier, which BubbleActionButton reads to decide which glyph to draw.
`bubble` true draws a white disc behind the glyph (on the paper capsules); false draws a small
clear disc for use inside the glass bubble.
*/
struct BubbleAction: NSViewRepresentable {
    let symbol: String
    let label: String
    var bubble = true
    /// False draws the button fully transparent but still clickable (hover-revealed controls).
    var revealed = true
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    /*
    Holds the latest action closure; updateNSView refreshes it every time SwiftUI updates, so the
    button always calls the current action.
    */
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: NSButton) { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {


        // Bridge a SwiftUI action to an AppKit button


        /*
        SwiftUI creates this NSButton once, then refreshes it through updateNSView.
        AppKit invokes an Objective-C target/action selector, so Coordinator owns the
        closure that forwards the click back to the current TalkModel action.
        */
        let button           = BubbleActionButton()
        button.isBordered    = false
        button.imagePosition = .imageOnly
        button.bezelStyle    = .regularSquare
        button.focusRingType = .none
        button.target        = context.coordinator
        button.action        = #selector(Coordinator.invoke(_:))
        /*
        Apply the same appearance and action refresh used for later SwiftUI updates;
        otherwise the first frame could disagree with every subsequent frame.
        */
        updateNSView(button, context: context)


        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        /*
        Refresh the closure even when the glyph is unchanged. A button can outlive the
        view value that first created it; retaining that old closure would retain old intent.
        */
        context.coordinator.action = action
        button.identifier          = NSUserInterfaceItemIdentifier(symbol)
        (button as? BubbleActionButton)?.drawsBubble = bubble
        button.image               = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isEnabled           = isEnabled
        button.alphaValue          = revealed ? (isEnabled ? 1 : 0.35) : 0
        button.needsDisplay        = true
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.contentTintColor    = .secondaryLabelColor
        button.toolTip             = label
        button.setAccessibilityLabel(label)
    }
}

//
// :)
//
//
// BubbleActionButton — draws its own disc and the ✕ or ✓ glyph


final class BubbleActionButton: NSButton {
    var drawsBubble = true
    override func draw(_ dirtyRect: NSRect) {
        // Explicit strokes also render reliably in offscreen native previews.
        if drawsBubble {
            NSColor.white.withAlphaComponent(0.94).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)).fill()
        } else {
            // Inside the slate bubble: a small chalk disc, so each target reads as a button.
            let diameter = min(18, min(bounds.width, bounds.height) - 2)
            let disc = NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2, width: diameter, height: diameter))
            let accent = identifier?.rawValue == "checkmark" ? NSColor(red: 0.94, green: 0.40, blue: 0.36, alpha: 1)
                : NSColor(red: 0.91, green: 0.93, blue: 0.90, alpha: 1)
            // Revealed controls must read at a glance on the slate: a clear disc and a visible rim.
            accent.withAlphaComponent(isHighlighted ? 0.38 : 0.24).setFill()
            disc.fill()
            NSColor(red: 0.91, green: 0.93, blue: 0.90, alpha: 0.30).setStroke()
            disc.lineWidth = 0.6
            disc.stroke()
        }
        /*
        The finish glyph takes the red accent; discard stays quiet grey.
        The glyph, accessibility label and supplied callback retain their original meaning.
        */
        let ink = !drawsBubble && identifier?.rawValue == "checkmark"
            ? NSColor(red: 0.94, green: 0.40, blue: 0.36, alpha: 1)
            : (drawsBubble ? NSColor.darkGray : NSColor(red: 0.96, green: 0.97, blue: 0.95, alpha: 1))
        ink.setStroke()
        let path          = NSBezierPath()
        path.lineWidth    = drawsBubble ? 1.5 : 1.8
        path.lineCapStyle = .round
        let x             = bounds.midX, y = bounds.midY
        /*
        Cross for "xmark", otherwise the tick. isFlipped flips the tick's vertical offsets so it looks
        the same whichever way the view's y axis points.
        */
        if identifier?.rawValue == "xmark" {
            path.move(to: NSPoint(x: x - 3, y: y - 3))
            path.line(to: NSPoint(x: x + 3, y: y + 3))
            path.move(to: NSPoint(x: x - 3, y: y + 3))
            path.line(to: NSPoint(x: x + 3, y: y - 3))
        } else {
            path.move(to: NSPoint(x: x - 4, y: y))
            path.line(to: NSPoint(x: x - 1, y: y + (isFlipped ? 3 : -3)))
            path.line(to: NSPoint(x: x + 4, y: y + (isFlipped ? -3 : 3)))
        }
        path.stroke()
    }

    // Never takes keyboard focus, and a click works even when the bubble's panel is not yet active.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

