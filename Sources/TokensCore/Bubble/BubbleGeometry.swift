


//
import CoreGraphics

/// Pure placement arithmetic for the bubble window.
public enum BubbleGeometry {
    /// Gap kept between the bubble and the screen edge it is pinned to.
    public static let edgeMargin: CGFloat = 12

    /// A side-center region can stand the compact bubble upright. Corners and the
    /// top/bottom bands stay horizontal; separate entry and exit bounds add drag hysteresis.
    public static func isVertical(at fraction: CGPoint, wasVertical: Bool) -> Bool {
        let x = min(max(fraction.x, 0), 1)
        let y = min(max(fraction.y, 0), 1)
        if wasVertical {
            return (x < 0.30 || x > 0.70) && y > 0.18 && y < 0.82
        }
        return (x <= 0.22 || x >= 0.78) && y >= 0.24 && y <= 0.76
    }

    /// Bottom-left corner of the bubble for a placement, in screen coordinates.
    ///
    /// - Parameters:
    ///   - custom: dragged position as a 0…1 fraction of the free room; used only for `.custom`.
    ///   - visible: the screen area not covered by the menu bar or Dock.
    public static func origin(_ placement: BubblePlacement, custom: CGPoint?,
                              size: CGSize, visible: CGRect) -> CGPoint {
        // On a screen barely larger than the bubble the margin shrinks instead of pushing it off.
        let margin = min(edgeMargin, max(0, min(visible.width - size.width, visible.height - size.height)))
        let roomX  = max(0, visible.width - size.width)
        let roomY  = max(0, visible.height - size.height)
        let point: CGPoint
        switch placement {
        case .bottom: point = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + margin)
        case .top:    point = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - margin)
        case .left:   point = CGPoint(x: visible.minX + margin, y: visible.midY - size.height / 2)
        case .right:  point = CGPoint(x: visible.maxX - size.width - margin, y: visible.midY - size.height / 2)
        case .custom:
            let fraction = custom ?? CGPoint(x: 0.5, y: 0)
            point = CGPoint(x: visible.minX + roomX * min(max(fraction.x, 0), 1),
                            y: visible.minY + roomY * min(max(fraction.y, 0), 1))
        }
        return CGPoint(x: point.x.rounded(), y: point.y.rounded())
    }

    /// The 0…1 fraction of the free room an origin sits at. The inverse of `.custom`.
    public static func fraction(of origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        let roomX = visible.width - size.width
        let roomY = visible.height - size.height
        return CGPoint(x: roomX > 0 ? min(max((origin.x - visible.minX) / roomX, 0), 1) : 0.5,
                       y: roomY > 0 ? min(max((origin.y - visible.minY) / roomY, 0), 1) : 0)
    }
}

