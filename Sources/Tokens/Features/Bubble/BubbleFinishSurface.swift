


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// FinishCountdownSurface — the send-delay capsule: 'Refining…' with a Send now button


/*
`seconds` is the whole seconds left before delivery is released and `progress` runs 0 to 1
across the countdown (both come from TalkModel). `launching` means delivery has started.
*/
struct FinishCountdownSurface: View {
    let seconds: Int
    let progress: Double
    let launching: Bool
    var canTakeOffNow          = false
    var takeOffNow: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The smile starts partway through the countdown and is full at release.
    private var ignition: Double { launching ? 1 : min(1, max(0, (progress - 0.3) / 0.7)) }

    var body: some View {
        /*
        Layers, bottom to top: paper, a faint progress bar growing from the left, the row (face, text,
        Send now), and a narrow placement button on the left.
        */
        ZStack {
            AcademicGraphPaper()
            GeometryReader { proxy in
                Rectangle()
                    .fill(academicInk.opacity(0.10))
                    .frame(width: proxy.size.width * progress)
            }
            HStack(spacing: 6) {
                /*
                Slot kept at takeoff so the compact layout never jumps.
                Purely decorative and implicit: delivery never waits on it.
                Reduced motion keeps a still face whose smile only grows.
                */
                TokensHappyFace(joy: ignition, ink: academicInk, red: academicRed)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(launching ? "Sending…" : "Refining…")
                        .font(.system(size: launching ? 10.5 : 8.5, weight: .semibold, design: .serif))
                        .foregroundStyle(academicInk.opacity(0.86))
                        .lineLimit(1)
                    if !launching {
                        /*
                        "Send now" delivers whatever transcript is available without waiting for
                        refinement. It is disabled until the model says something is available
                        (canTakeOffNow).
                        */
                        Button(action: takeOffNow) {
                            Text("Send now")
                                .frame(minWidth: 110, minHeight: 24)
                                .contentShape(Rectangle())
                        }
                            .font(.system(size: 11, weight: .semibold, design: .serif))
                            .foregroundStyle(academicRed)
                            .buttonStyle(.plain).focusable(false)
                            .disabled(!canTakeOffNow)
                            .help("Send the transcript available now without waiting for refinement")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            BubblePresetArea(rotatesLayout: false)
                // Keep placement left of the face and Send now button.
                .frame(width: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help("Click to move to the next screen edge")
        }
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(academicPencil.opacity(0.55), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(launching ? "\(appName) sending" : "\(appName) sends in \(seconds) seconds")
    }
}


/// Compact finishing keeps the active edge's shape and independent discard/paste controls.
/// The minimum pause overlaps speech completion; zero does not promise recognition is done.
struct BubbleFinalizingSurface: View {
    let vertical: Bool
    let seconds: Int
    let launching: Bool
    let canTakeOffNow: Bool
    let cancel: () -> Void
    let takeOffNow: () -> Void

    var body: some View {
        BubbleControlSurface(vertical: vertical, cancelLabel: "Discard talk",
            finishLabel: "Paste the words available now", cancel: cancel, finish: takeOffNow,
            cancelEnabled: !launching, finishEnabled: canTakeOffNow && !launching) {
                Text(launching ? (vertical ? "…" : "Pasting…") : seconds > 0 ? "\(seconds)s" : (vertical ? "…" : "Finishing…"))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(academicRed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(launching ? "Pasting" : seconds > 0 ? "Pausing, \(seconds) seconds. \(canTakeOffNow ? "Paste now available" : "Saving words")" : "Finishing your talk")

            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(launching ? "Pasting" : "Finishing your talk")
    }
}
