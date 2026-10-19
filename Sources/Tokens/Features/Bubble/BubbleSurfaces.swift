


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// CopyFeedbackLabel — a 'Copy' label that turns into 'Copied to clipboard' (old shell only)


/*
Only the old shell (Unreached/OldShell.swift) uses this. `revision` is passed in but not read
inside this view.
*/
struct CopyFeedbackLabel: View {
    let title: String
    let copied: Bool
    let revision: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        /*
        The hidden "Copied to clipboard" text keeps its space, so the label is as wide as the longer
        text and does not change width when it swaps between the two words.
        */
        ZStack(alignment: .trailing) {
            Text("Copied to clipboard").hidden()
            Text(copied ? "Copied to clipboard" : title)
        }
        .font(.system(size: 14, design: .serif))
        .foregroundStyle(copied ? academicRed : academicInk.opacity(0.86))
        // No fade or slide on the text swap itself.
        .transaction { $0.animation = nil }
        /*
        A dotted red π behind the label: invisible until copied, then it fades in to 38% opacity, slides
        a little and straightens. Under Reduce Motion it jumps there instead of animating.
        */
        .background(alignment: .center) {
            CopyPi()
                .stroke(academicRed.opacity(copied ? 0.38 : 0), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [1, 2.5]))
                .frame(width: 23, height: 20)
                .offset(x: copied ? 4 : -10, y: 4)
                .rotationEffect(.degrees(copied ? -6 : -18))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.55), value: copied)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copied ? "Copied to clipboard" : title)
    }
}


// TinyEnvelope — Recent measured input levels, newest on the right


/*
The tiny bubble's red-pen envelope (restoring the pre-c53422e TinyEnvelope):
a stroke that travels from left to right, like a red pen.
Every analysed audio buffer is one fine red stroke centred on a faint chalk baseline; the newest
sits at the right edge and older ones slide off the left, so speech writes itself across the pill
like a pen. Silence is the bare baseline (it keeps scrolling during pauses, so speech and pauses
never swap shapes). Upright on a side edge the same envelope runs top to bottom, newest at the
bottom. Pure drawing from measured levels; no decoration, smoothing or springs.
*/
struct TinyEnvelope: View {
    let samples: [Double]
    var vertical = false

    /// The red pen on the slate pill (coral, the same ink as the finish tick and caught-words dots).
    static let ink = Color(red: 0.94, green: 0.40, blue: 0.36)
    /// Fine pen pitch: about one stroke per 1.35 pt, as dense as the original 56 strokes over 78 pt.
    static let pitch: CGFloat = 1.35
    static let lineWidth: CGFloat = 1.1

    /// How many of the newest samples fit along `length` (at least two, at most the original 56).
    static func sampleCount(along length: CGFloat) -> Int {
        max(2, min(56, Int(length / pitch) + 1))
    }

    /// The span the strokes occupy along the bar: the whole readout, oldest edge at 0.
    static func track(along length: CGFloat) -> (start: CGFloat, length: CGFloat) { (0, max(0, length)) }

    /// Stroke half-lengths as a fraction of the half height (0...1), oldest first. Zero draws nothing.
    static func reaches(samples: [Double], along length: CGFloat) -> [Double] {
        let count = sampleCount(along: length)
        let recent = Array(samples.suffix(count))
        // Right-align: a short history (just started) begins at the newest edge, not the oldest.
        let padding = Array(repeating: 0.0, count: count - recent.count)
        return (padding + recent).map { level in
            guard level.isFinite, level > 0 else { return 0 }
            return min(1, level * 1.25)
        }
    }

    var body: some View {
        Canvas { context, size in
            // "along" is the time axis (left→right, or top→bottom upright); "across" is the level.
            let along = vertical ? size.height : size.width
            let across = vertical ? size.width : size.height
            let mid = across / 2
            func point(_ a: CGFloat, _ c: CGFloat) -> CGPoint { vertical ? CGPoint(x: c, y: a) : CGPoint(x: a, y: c) }
            var baseline = Path()
            baseline.move(to: point(0, mid))
            baseline.addLine(to: point(along, mid))
            context.stroke(baseline, with: .color(Color(red: 0.91, green: 0.93, blue: 0.90).opacity(0.22)), lineWidth: 0.6)
            let reaches = Self.reaches(samples: samples, along: along)
            guard reaches.count > 1, reaches.contains(where: { $0 > 0 }) else { return }
            let step = along / CGFloat(reaches.count - 1)
            // Leave room for the round caps so loud speech touches, but never crosses, the readout edge.
            let room = max(0, mid - 1)
            var trace = Path()
            for (index, reach) in reaches.enumerated() where reach > 0 {
                let a = CGFloat(index) * step
                let half = max(0.6, CGFloat(reach) * room)
                trace.move(to: point(a, mid - half))
                trace.addLine(to: point(a, mid + half))
            }
            context.stroke(trace, with: .color(Self.ink.opacity(0.92)),
                           style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
        }
        .accessibilityLabel("Microphone activity")
    }
}

