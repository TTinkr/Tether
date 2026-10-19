


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkStyleView


struct TalkStyleView: View {
    let style: TalkStyle
    let text: String
    let phase: TalkPhase
    let energy: Double

    var body: some View {
        Group {
            switch style {
            case .flow:
                HStack(spacing: 10) {
                    FlowWave(energy: energy)
                        .frame(width: 86)
                    Text(latestWords(48))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 12)
            case .ribbon:
                HStack(spacing: 10) {
                    RibbonSine(energy: energy)
                        .frame(width: 34)
                    Text(latestWords(72))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PixelDissolve(energy: energy)
                        .frame(width: 38)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
            case .subtitle:
                TinyTranscript(text: text, phase: phase)
                    .padding(.horizontal, 4)
            case .terminal:
                TerminalStream(text: text, phase: phase, pauseRevision: 0)
            case .ink:
                HStack(alignment: .top, spacing: 9) {
                    WavePi(amplitude: energy)
                        .stroke(Color(red: 0.38, green: 0.20, blue: 0.75), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .frame(width: 20, height: 18)
                    Text(latestWords(82))
                        .font(.system(size: 12.5, weight: .medium, design: .serif).italic())
                        .foregroundStyle(Color(red: 0.30, green: 0.16, blue: 0.62))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.title) live dictation")
        .accessibilityValue(text)
    }

    private func latestWords(_ limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "listening…" : String(clean.suffix(limit))
    }
}


// StandaloneRoot


struct StandaloneRoot: View {

//
// :)
//
//
    @ObservedObject var model: TalkModel
    @AppStorage("tinkr.onboarding.complete") private var completed = false
    @State private var page = 0
    private var preview: Bool { ProcessInfo.processInfo.arguments.contains("--render-preview-frames") && !ProcessInfo.processInfo.arguments.contains("--onboarding-preview") }
    var body: some View {
        Group {
            if completed || preview {
                ScrollView { StyleChooser(model: model) }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    Text("π Talk").font(.system(size: 30, design: .serif))
                    Text(["Talk to your agent.", "A little bubble. Your words.", "Finish. Send. Keep going."][page])
                        .font(.system(size: 24, design: .serif))
                    Text(["Focus your agent’s text field. Press \(model.shortcutName) to start. In Hold mode, keep it pressed while talking.",
                          "Talk naturally. Drag the bubble from its middle. × discards the take; ✓ finishes and sends it.",
                          "In Tap mode, press \(model.shortcutName) again. In Hold mode, release it. Talk inserts your words and presses Enter. Allow Microphone, Speech Recognition and Accessibility when macOS asks."][page])
                        .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("\(page + 1) / 3").foregroundStyle(.secondary)
                        Spacer()
                        if page > 0 { Button("Back") { page -= 1 } }
                        Button(page == 2 ? "Start talking" : "Next") {
                            if page < 2 { page += 1 }
                            else { completed = true; model.startMonitoring() }
                        }.buttonStyle(.borderedProminent).tint(academicRed)
                    }
                }.padding(28).frame(maxWidth: .infinity,maxHeight: .infinity,alignment:.topLeading)
                    .background(AcademicGraphPaper())
            }
        }.preferredColorScheme(.light)
    }
}

