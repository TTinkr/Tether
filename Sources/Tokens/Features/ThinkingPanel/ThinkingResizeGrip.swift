


//
import AppKit
import SwiftUI

struct ThinkingResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ThinkingResizeHandle { ThinkingResizeHandle() }
    func updateNSView(_ nsView: ThinkingResizeHandle, context: Context) {}
}

final class ThinkingResizeHandle: NSView {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        for length in [7.0, 13.0, 19.0] {
            let line       = NSBezierPath()
            line.lineWidth = 1.3
            line.move(to: NSPoint(x: bounds.maxX - 4 - length, y: 4))
            line.line(to: NSPoint(x: bounds.maxX - 4, y: 4 + length))
            line.stroke()
        }
    }

    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = window.frame
        let start  = window.convertPoint(toScreen: event.locationInWindow)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let pointer = window.convertPoint(toScreen: next.locationInWindow)
            let frame = ThinkingResizeGeometry.frame(original: origin,
                delta: NSSize(width: pointer.x - start.x, height: pointer.y - start.y),
                minimum: window.contentMinSize, maximum: window.contentMaxSize,
                visible: window.screen?.visibleFrame)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

enum ThinkingResizeGeometry {
    /// AppKit coordinates point upward. Dragging down grows height without moving the top-left.
    static func frame(original: NSRect, delta: NSSize, minimum: NSSize, maximum: NSSize,
                      visible: NSRect?) -> NSRect {
        let availableWidth  = visible.map { max(minimum.width, $0.maxX - original.minX) } ?? maximum.width
        let availableHeight = visible.map { max(minimum.height, original.maxY - $0.minY) } ?? maximum.height
        let width           = max(minimum.width, min(original.width + delta.width, maximum.width, availableWidth))
        let height          = max(minimum.height, min(original.height - delta.height, maximum.height, availableHeight))
        return NSRect(x: original.minX, y: original.maxY - height, width: width, height: height)
    }
}

