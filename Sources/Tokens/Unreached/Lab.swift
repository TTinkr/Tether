


//
import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Speech
import SwiftUI


// FlowWave


struct FlowWave: View {
    let energy: Double
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let mid  = size.height / 2
            for index in 0...32 {
                let x        = size.width * CGFloat(index) / 32
                let envelope = sin(.pi * CGFloat(index) / 32)
                let y        = mid + sin(CGFloat(index) * 0.92) * envelope * (4 + 17 * energy)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
        }
    }
}


// RibbonSine


struct RibbonSine: View {
    let energy: Double
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for index in 0...24 {
                let y = size.height * CGFloat(index) / 24
                let x = size.width / 2 + sin(CGFloat(index) * 0.72) * (4 + 7 * energy)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}


// PixelDissolve


struct PixelDissolve: View {
    let energy: Double
    var body: some View {
        Canvas { context, size in
            for index in 0..<12 {
                let column = CGFloat(index % 4)
                let row = CGFloat(index / 4)
                let side = CGFloat(1.6 + Double(index % 3) * 0.7 + energy * 1.8)
                let rect = CGRect(x: column * size.width / 4 + row * 2, y: row * size.height / 3 + column, width: side, height: side)
                context.fill(Path(rect), with: .color(.black.opacity(0.25 + Double(index % 4) * 0.14)))
            }
        }
    }
}


// NoiseLab


struct NoiseLab: View {

//
// :)
//
//
    @ObservedObject var model: TalkModel
    @ObservedObject private var audio: AudioCapture
    let onDictate: () -> Void

    init(model: TalkModel, onDictate: @escaping () -> Void) {
        self.model     = model
        _audio         = ObservedObject(wrappedValue: model.audio)
        self.onDictate = onDictate
    }

    var body: some View {
        ZStack {
            GraphPaper()
            VStack(spacing: 0) {
                labHeader
                Spacer(minLength: 32)
                LabPi(
                    energy: audio.features.normalizedEnergy,
                    active: labIsActive,
                    listening: model.isLabListening,
                    candidate: activeCandidate,
                    onToggleListening: model.toggleLabListening
                )
                Spacer(minLength: 44)
                classRow
                    .padding(.horizontal, 34)
                    .padding(.bottom, 30)
            }
            liveTranscript
        }
        .frame(minWidth: 820, minHeight: 560)
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
    }

    private var labHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if statusIsFailure || ProcessInfo.processInfo.arguments.contains("--demo") {
                    Text(statusText)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusIsFailure ? LabPalette.purple : Color.black.opacity(0.38))
                        .lineLimit(1)
                } else if audio.voiceCommandsAvailable {
                    Text("“Stop Tinkr”   “Tinkr minimize”   “Tinkr full screen”   “Tinkr resize”   “Tinkr close”")
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.36))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onDictate) {
                HStack(spacing: 7) {
                    Text("← + →")
                    Text("DICTATE")
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(height: 28)
            }
            .buttonStyle(.plain)
            .help("Return to the compact panel and begin dictating")
            .accessibilityLabel("Begin dictating")
        }
        .padding(.top, 34)
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var liveTranscript: some View {
        if model.isLabListening {
            VStack {
                Spacer()
                Text(liveTranscriptText)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(LabPalette.purple)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 28)
            .padding(.bottom, 126)
            .allowsHitTesting(false)
            .accessibilityLabel("Live transcript")
        }
    }

//
// :)
//
//
    private var liveTranscriptText: String {
        let transcript = audio.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return audio.isRecording ? "listening…" : "starting…" }
        return String(transcript.suffix(140))
    }

    private var classRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Candidate.benchmarkClasses, id: \.rawValue) { candidate in
                LabClass(
                    candidate: candidate,
                    active: activeCandidate == candidate && labIsActive,
                    revision: model.labPreviewRevision,
                    onPreview: { model.previewLabSoundFromControl(candidate) }
                )
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusText: String {
        if let error = audio.captureError, !error.isEmpty { return error.uppercased() }
        if audio.permissionMessage.contains("denied") || audio.permissionMessage.contains("failed") ||
            audio.permissionMessage.contains("unavailable") {
            return audio.permissionMessage.uppercased()
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            return "DEMO SIGNAL / NO MICROPHONE CLAIM"
        }
        return ""
    }

    private var statusIsFailure: Bool {
        audio.captureError != nil || audio.permissionMessage.contains("denied") ||
            audio.permissionMessage.contains("failed") || audio.permissionMessage.contains("unavailable")
    }

    private var activeCandidate: Candidate {
        model.labPreviewCandidate ?? audio.liveCandidate
    }

    private var labIsActive: Bool {
        model.isLabListening || model.labPreviewCandidate != nil
    }
}

