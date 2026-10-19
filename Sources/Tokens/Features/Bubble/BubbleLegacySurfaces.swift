


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// VoiceMemoWaveform — mirrored level history with a 'now' line in the middle (old shell only)


// Only the old shell (Unreached/OldShell.swift) uses this.
struct VoiceMemoWaveform: View {
    let samples: [Double]
    let currentLevel: Double
    let active: Bool
    var body: some View {
        Canvas { context, size in
            /*
            Meter values already use a dB/power curve. Do not amplify and clip them again.
            When idle, a row of zeros. When active, the newest 48 samples with the last one replaced by
            the current level.
            */
            var levels = active ? Array(samples.suffix(48)) : Array(repeating: 0.0, count: 48)
            if !levels.isEmpty { levels[levels.count - 1] = active ? currentLevel : 0 }
            let midY     = size.height / 2
            let nowX     = size.width / 2
            let steps    = max(2, Int(nowX))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(academicPencil.opacity(0.18)), lineWidth: 0.7)
            var now = Path()
            now.move(to: CGPoint(x: nowX, y: 8))
            now.addLine(to: CGPoint(x: nowX, y: size.height - 8))
            context.stroke(now, with: .color(academicRed.opacity(0.16)), lineWidth: 0.6)
            var upper: [CGPoint] = []
            var lower: [CGPoint] = []
            /*
            The waveform itself fills only the left half of the view, up to the "now" line in the
            middle. Between samples the level is blended with a cosine curve for a smooth shape, and
            the upper and lower outlines mirror each other around the centre line.
            */
            for i in 0...steps {
                let x        = Double(i) / Double(steps)
                let position = x * Double(max(0, levels.count - 1))
                let left     = Int(position)
                let fraction = position - Double(left)
                let blend    = (1 - cos(fraction * .pi)) / 2
                let level    = levels.isEmpty ? 0 : levels[left] * (1 - blend)
                    + levels[min(left + 1, levels.count - 1)] * blend
                let height = min(1, max(0, level)) * size.height * 0.46
                upper.append(CGPoint(x: x * nowX, y: midY - height))
                lower.append(CGPoint(x: x * nowX, y: midY + height))
            }
            if levels.contains(where: { $0 > 0 }) {
                var fill = Path()
                fill.addLines(upper + lower.reversed())
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [academicRed.opacity(0.02), academicRed.opacity(0.10)]),
                    startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: nowX, y: midY)))
                for points in [upper, lower] {
                    var contour = Path()
                    contour.addLines(points)
                    context.stroke(contour, with: .color(academicRed.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("Microphone activity")
        .accessibilityValue("\(Int(min(1, max(0, currentLevel)) * 100)) percent")
    }
}

//
// :)
//
//
// TinyTranscript — two-line live transcript with a blinking caret (old shell only)


// Only the old shell (Unreached/OldShell.swift) uses this.
struct TinyTranscript: View {
    let text: String
    let phase: TalkPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reveal = WordRevealState()

    var body: some View {
        /*
        The view's width decides how the text is cut to its last two lines (twoLineTail). The timeline
        refreshes every 0.42 s, and while capturing the caret is on for about 0.42 s then off for the
        same time, so it blinks.
        */
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.42)) { timeline in
                let tail = twoLineTail(reveal.visibleText, width: proxy.size.width)
                let caret = phase == .capturing && Int(timeline.date.timeIntervalSinceReferenceDate * 2.38).isMultiple(of: 2)
                    ? "▏" : " "
                Text(tail + caret)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .lineSpacing(1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { reveal.ingest(text, phase: phase, reduceMotion: effectiveReduceMotion) }
        .onChange(of: text) { _, updated in
            reveal.ingest(updated, phase: phase, reduceMotion: effectiveReduceMotion)
        }
        .onChange(of: phase) { _, updated in
            reveal.ingest(text, phase: updated, reduceMotion: effectiveReduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase == .delivered ? "\(appName) text delivered" : "\(appName) live transcript")
        .accessibilityValue(text)
    }

    /*
    Reduce Motion counts unless the TTTAnimateTranscript.v1 setting is on; the launch argument
    --reduced-motion-preview forces it on regardless.
    */
    private var effectiveReduceMotion: Bool {
        (reduceMotion && !UserDefaults.standard.bool(forKey: "TTTAnimateTranscript.v1")) ||
            ProcessInfo.processInfo.arguments.contains("--reduced-motion-preview")
    }
}

