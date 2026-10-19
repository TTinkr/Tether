


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// HeldWordsSurface — words with nowhere to paste, shown selected until copied or a new talk begins


/// Held words remain selected and visible until explicit copy or dismissal.
struct HeldWordsSurface: View {


    // What the capsule shows


    @ObservedObject var model: TalkModel
    @State private var fading             = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        /*
        Paper and held words with an explicit copy hint; no expiry hides recovery.
        */
        BubbleHeldWordsReadout(text: TalkModel.heldWordsDisplay(model.retainedFailurePayload), copied: model.heldWordsCopied)
        .opacity(fading ? 0 : 1)
        /*
        A click anywhere on the capsule copies. Within this file only the click is handled; the
        the visible state resets whenever new words are held (heldWordsRevision changes).
        */
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { model.copyHeldWords() }
        .onAppear { fading = false }
        .onChange(of: model.heldWordsRevision) { _, _ in fading = false }
        .onChange(of: model.heldWordsCopied) { _, copied in
            guard copied else { return }
            // Hold "Copied" briefly, then fade with the 0.7 s dismissal.
            var reset                = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { fading = false }
            withAnimation(.easeIn(duration: 0.3).delay(0.4)) { fading = true }
        }
        .help("Click to copy · close the recovery window to dismiss")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Held words, not pasted")
        .accessibilityValue(TalkModel.heldWordsDisplay(model.retainedFailurePayload))
        .accessibilityHint("Click to copy. The separate recovery window contains the full text.")
        .accessibilityAddTraits(.isButton)
    }

//
// :)
//
//
    // The countdown and fade


}


/// Supplied text only: proof renders never instantiate a recorder or read saved history.
struct BubbleHeldWordsReadout: View {
    let text: String
    let copied: Bool

    var body: some View {
        GeometryReader { proxy in
            let vertical = proxy.size.height > proxy.size.width
            ZStack {
                NativeBubbleMaterial().allowsHitTesting(false)
                let axis = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                axis {
                    VStack(alignment: vertical ? .center : .leading, spacing: 2) {
                        Text("Saved · not pasted")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(academicRed)
                            .lineLimit(vertical ? 2 : 1)
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(academicInk)
                            .lineLimit(vertical ? 3 : 1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: vertical ? .center : .leading)
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(academicRed)
                        .fixedSize()
                }
                .padding(.horizontal, vertical ? 12 : 20)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
