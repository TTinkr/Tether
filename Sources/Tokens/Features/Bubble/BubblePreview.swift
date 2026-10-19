


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// BubblePreviewStage — synthetic desktop backdrop for the interactive bubble preview


/// Synthetic 800-by-480 backdrop for the interactive preview; it draws no live desktop.
/// The capture bubble itself is TokensThinkingBubble, hosted separately by AppDelegate.
struct BubblePreviewStage: View {
    /*
    A blue-grey gradient, a pale tilted ellipse and three lines of caption. It exists so a selected
    window recording of the preview never shows the real desktop.
    */
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.79, green: 0.85, blue: 0.92), Color(red: 0.94, green: 0.95, blue: 0.97)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(Color.white.opacity(0.42)).frame(width: 740, height: 270)
                .rotationEffect(.degrees(-22)).offset(x: 190, y: 155)
            VStack(alignment: .leading, spacing: 8) {
                Text("Tokens").font(.system(size: 24, weight: .semibold))
                Text("Native bubble · interactive preview").font(.system(size: 14, weight: .medium))
                Text("Click the middle to cycle edges. Both controls close this preview.\nSynthetic waveform · no microphone or clipboard access.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(width: 800, height: 480)
        .clipped()
        .preferredColorScheme(.light)
    }
}


// BubbleLayout — wide or upright: the bubble's orientation and size, shared by its views


/// Shared only by the one compact dictation surface. Never affects capture state.
final class BubbleLayout: ObservableObject {
    /*
    One shared instance, read by the sheet, the thinking bubble and placement button, so they all see
    the same orientation.
    */
    static let shared = BubbleLayout()
    // false = wide capsule, true = tall one (stood up against a side of the screen).
    @Published var vertical = false
    // Recovery and retained legacy views keep enough room for their text and actions.
    @Published var expanded = false
    static let compactVerticalSize = NSSize(width: 32, height: 96)
    static let recoveryHorizontalSize = NSSize(width: 272, height: 64)
    static let recoveryVerticalSize = NSSize(width: 104, height: 148)
    var size: NSSize {
        expanded ? (vertical ? Self.recoveryVerticalSize : Self.recoveryHorizontalSize)
            : (vertical ? Self.compactVerticalSize : panelDefaultSize)
    }
    /*
    Only the center bands of the left/right edges stand the bubble upright. Corners,
    top/bottom edges, and screen center remain horizontal. Separate bounds damp boundary jitter.
    */
    static func vertical(at fraction: CGPoint, wasVertical: Bool) -> Bool {
        BubbleGeometry.isVertical(at: fraction, wasVertical: wasVertical)
    }
}

