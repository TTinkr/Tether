


//
import AppKit
import SwiftUI

struct BubbleControlSurface<Readout: View>: View {
    let vertical: Bool
    let cancelLabel: String
    let finishLabel: String
    let cancel: () -> Void
    let finish: () -> Void
    var cancelEnabled = true
    var finishEnabled = true
    /// Offscreen renders cannot hover; they pass true to draw the revealed controls.
    var showsControls = false
    /// The faint ghost while starting or in a real pause. Hovering lifts it, so revealed
    /// discard and finish are never drawn at ghost strength.
    var ghost = false
    @ViewBuilder var readout: () -> Readout
    /// Envelope only until the pointer is over the bubble; then discard and finish appear.
    /// Their places are kept, so the wave never jumps when they appear, and they stay
    /// clickable throughout (a click always arrives after the hover that reveals them).
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            NativeBubbleMaterial().allowsHitTesting(false)
            BubblePresetArea()
            let axis = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 3))
            axis {
                BubbleAction(symbol: "xmark", label: cancelLabel, bubble: false, revealed: hovering || showsControls, action: cancel)
                    .frame(width: 22, height: 22)
                    .disabled(!cancelEnabled)
                readout().frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                BubbleAction(symbol: "checkmark", label: finishLabel, bubble: false, revealed: hovering || showsControls, action: finish)
                    .frame(width: 22, height: 22)
                    .disabled(!finishEnabled)
            }
            .padding(.horizontal, vertical ? 5 : 2)
            .padding(.vertical, vertical ? 3 : 0)
        }
        /*
        A real AppKit tracking area drives the reveal. The bubble is a never-key, non-activating panel
        of an app that is usually inactive, where SwiftUI's .onHover cannot be relied on to fire.
        The tracker never takes clicks (hitTest returns nil), so the presets and buttons behave as before.
        */
        .opacity(ghost && !(hovering || showsControls) ? 0.42 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: ghost)
        .background(BubbleHoverTracker { inside in
            if reduceMotion { hovering = inside } else { withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        })
    }
}

/// Reports pointer enter/exit over its bounds with an `.activeAlways` tracking area, so hover works
/// in a non-activating panel while another app is frontmost. Click-through.
struct BubbleHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> BubbleHoverTrackingView {
        let view = BubbleHoverTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: BubbleHoverTrackingView, context: Context) { view.onChange = onChange }
}

final class BubbleHoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private(set) var inside = false
    static let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]

    override init(frame: NSRect) {
        super.init(frame: frame)
        // .inVisibleRect keeps the rect current as the bubble resizes or turns upright; added once.
        addTrackingArea(NSTrackingArea(rect: .zero, options: Self.trackingOptions, owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }

    /// A bubble that appears under a resting pointer gets no enter event; check where the pointer is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { set(false); return }
        set(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    func set(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        onChange?(value)
    }
}

