


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TinyStatusSurface — capsule showing one short status message, two lines at most


struct TinyStatusSurface: View {
    let text: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        /*
        Same capsule look as TinyGlassSurface (paper, hairline border, soft shadow) around one message,
        with a placement button on top.
        */
        GeometryReader { proxy in
            let vertical = proxy.size.height > proxy.size.width
            ZStack {
                NativeBubbleMaterial().allowsHitTesting(false)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(academicInk)
                    .lineLimit(vertical ? 5 : 2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, vertical ? 12 : 20)
                BubblePresetArea()
                    .help("Click to move to the next screen edge")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(appName) status")
        .accessibilityValue(text)
    }
}


// InputLevelMeter — smooths the microphone level and passes it to InputLevelDrawing


struct InputLevelMeter: View {
    let level: Double
    let active: Bool
    let confirmed: Bool

    // The level actually drawn: the incoming level times 2.4, capped at 1.
    @State private var presentedLevel = 0.0

    var body: some View {
        InputLevelDrawing(level: presentedLevel, active: active, confirmed: confirmed)
        .onAppear { presentedLevel = min(1, max(0, level) * 2.4) }
        /*
        A level of zero, or a meter that is not active or not confirmed, snaps to zero with no
        animation. Otherwise the drawn level springs to the new value.
        */
        .onChange(of: level) { _, newLevel in
            if newLevel <= 0 || !active || !confirmed {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { presentedLevel = 0 }
            } else {
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 23)) {
                    presentedLevel = min(1, newLevel * 2.4)
                }
            }
        }
        .accessibilityLabel(confirmed ? "Microphone audio confirmed" : "Microphone arming")
        .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
    }
}

//
// :)
//
//
// InputLevelDrawing — a flat line when quiet; a red wave whose length follows the level


/*
Animatable on `level`: when InputLevelMeter changes the level inside an animation, SwiftUI
calls body repeatedly with in-between values, so the wave grows and shrinks smoothly.
*/
struct InputLevelDrawing: View, Animatable {
    var level: Double
    let active: Bool
    let confirmed: Bool
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let normalized = min(max(level, 0), 1)
            let centerY    = size.height / 2
            var baseline   = Path()
            baseline.move(to: CGPoint(x: 0, y: centerY))
            baseline.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(
                baseline,
                with: .color(academicPencil.opacity(0.24)),
                style: StrokeStyle(lineWidth: 0.7, lineCap: .round)
            )

            /*
            Wave: it spans `level` of the width, so a louder voice draws a longer wave. Its height is
            16% to 38% of the view height depending on the level, with a 14-point wavelength and a
            point about every 1.5 points. The ends are tapered over up to 5 points and pinned to the
            centre line so it starts and ends on the baseline.
            */
            guard active, confirmed, normalized > 0 else { return }
            let fillWidth           = size.width * CGFloat(normalized)
            let amplitude           = size.height * CGFloat(0.16 + 0.22 * normalized)
            let pointCount          = max(3, Int(ceil(fillWidth / 1.5)))
            let wavelength: CGFloat = 14
            let edgeTaper           = min(5, fillWidth / 2)
            var trace               = Path()
            for index in 0..<pointCount {
                let fraction = CGFloat(index) / CGFloat(max(1, pointCount - 1))
                let x        = fraction * fillWidth
                let carrier  = sin(2 * Double.pi * Double(x / wavelength))
                let taper    = edgeTaper > 0
                    ? min(1, min(x / edgeTaper, (fillWidth - x) / edgeTaper))
                    : 0
                let y = index == 0 || index == pointCount - 1
                    ? centerY
                    : centerY - CGFloat(carrier) * taper * amplitude
                if index == 0 {
                    trace.move(to: CGPoint(x: x, y: y))
                } else {
                    trace.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(
                trace,
                with: .color(academicRed.opacity(0.88)),
                style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

