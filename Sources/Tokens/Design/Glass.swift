


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TinyGlassSurface — the bubble's capsule: last words, live stream, mic level, placement button


struct TinyGlassSurface: View {
    let text: String
    let phase: TalkPhase
    let inputLevel: Double
    let pauseRevision: Int
    let audioConfirmed: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        /*
        Layers, bottom to top: graph paper, the words and level meter, and (last, so it is on top) an
        placement-only button, which cycles the bubble between screen edges.
        */
        ZStack {
            AcademicGraphPaper()
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 5) {
                    /*
                    Left half: just the last three words (immediateTail) in small red serif; fully clear
                    while there is no text. The thin divider and the live stream (TerminalStream, compact
                    form) follow.
                    */
                    Text(immediateTail)
                        .font(.system(size: 9, weight: .semibold, design: .serif))
                        .foregroundStyle(academicRed.opacity(text.isEmpty ? 0 : 0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .center)

                    Rectangle()
                        .fill(academicPencil.opacity(0.10))
                        .frame(width: 0.6, height: 19)

                    TerminalStream(
                        text: text,
                        phase: phase,
                        pauseRevision: pauseRevision,
                        splitCompact: true
                    )
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .center)
                }
                /*
                A 5-point-high microphone level bar along the bottom of the capsule. It is told it is
                active only while the phase is capturing.
                */
                InputLevelMeter(
                    level: inputLevel,
                    active: phase == .capturing,
                    confirmed: audioConfirmed
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            // Placement is independent from the finish/cancel controls outside this capsule.
            BubblePresetArea(rotatesLayout: false)
                .contentShape(Capsule())
                .help("Click to move to the next screen edge")
        }
        /*
        Cut everything to the capsule, then add a hairline pencil border (half a screen pixel wide,
        never under 0.25 points) and a soft shadow underneath.
        */
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    academicPencil.opacity(0.55),
                    lineWidth: max(0.25, 0.5 / max(displayScale, 1))
                )
        }
        .shadow(color: academicPencil.opacity(0.13), radius: 9, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(appName) live talk. Click the middle to cycle screen edges.")
    }

//
// :)
//
//
    // The last three whitespace-separated words of the text, joined by single spaces.
    private var immediateTail: String {
        text.split(whereSeparator: { $0.isWhitespace })
            .suffix(3)
            .joined(separator: " ")
    }
}


// NativeBubbleMaterial — a single smooth paper backing with reduced-transparency support


/// One smooth backing for every compact bubble state. A single continuous corner avoids
/// clipping native glass and a second rounded mask against one another at the screen edges.
struct NativeBubbleMaterial: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> NativeBubbleContainer { NativeBubbleContainer() }
    func updateNSView(_ container: NativeBubbleContainer, context: Context) {
        // Chalkboard slate (sheet #1E2321) with a faint chalk rim, whatever the window theme.
        container.layer?.backgroundColor = NSColor(red: 0x1E / 255, green: 0x23 / 255, blue: 0x21 / 255,
                                                   alpha: reduceTransparency ? 1 : 0.94).cgColor
        container.layer?.borderColor = NSColor(red: 0.91, green: 0.93, blue: 0.90, alpha: 0.12).cgColor
        container.layer?.borderWidth = 0.5
        container.needsLayout = true
    }
}

/// The same material follows real panel bounds at every edge and display scale. A fixed
/// 27-point radius exceeded half of the 44-point horizontal panel and was never refreshed.
final class NativeBubbleContainer: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let radius = min(27, min(bounds.width, bounds.height) / 2)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.cornerRadius = radius
        layer?.contentsScale = scale
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

