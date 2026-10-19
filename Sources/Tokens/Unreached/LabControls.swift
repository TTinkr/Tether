


//
import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Speech
import SwiftUI


// LabPalette


enum LabPalette {
    static let paper  = Color(red: 0.955, green: 0.965, blue: 0.969)
    static let grid   = Color(red: 0.55, green: 0.65, blue: 0.69)
    static let purple = Color(red: 0.42, green: 0.19, blue: 0.80)
}


// LabPi


struct LabPi: View {
    let energy: Double
    let active: Bool
    let listening: Bool
    let candidate: Candidate
    let onToggleListening: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            let t    = timeline.date.timeIntervalSinceReferenceDate
            let sway = active ? sin(t * 3.9) * (1.2 + energy * 2.8) : 0
            let lift = active ? -abs(sin(t * 5.1)) * (4.0 + energy * 9.0) : 0
            Button(action: onToggleListening) {
                VStack(spacing: 8) {
                    PencilPi(energy: active ? energy : 0)
                        .frame(width: 190, height: 166)
                        .rotationEffect(.degrees(sway))
                        .offset(y: lift)
                    Text(listening ? "Stop Tinkr" : "Start Tinkr")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(LabPalette.purple)
                }
                .frame(width: 220, height: 206)
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel(listening ? "Stop Tinkr" : "Start Tinkr")
            .accessibilityHint(listening
                ? "Stops microphone capture and pauses the Lab"
                : "Starts microphone capture for the Lab")
            .accessibilityValue(active ? "Pi reacting to \(candidate.displayName)" : "Pi paused")
        }
    }
}


// LabClass


struct LabClass: View {
    let candidate: Candidate
    let active: Bool
    let revision: Int

//
// :)
//
//
    let onPreview: () -> Void
    @State private var popped = false

    var body: some View {
        Button(action: onPreview) {
            VStack(spacing: 5) {
                PencilDoodle(candidate: candidate)
                    .frame(width: 72, height: 72)
                    .scaleEffect(active ? (popped ? 1.15 : 0.86) : 1)
                    .offset(y: active && popped ? -14 : 0)
                Text(candidate.displayName.uppercased())
                    .font(.system(size: 8.5, weight: active ? .bold : .semibold, design: .monospaced))
                    .tracking(0.65)
                    .foregroundStyle(active ? LabPalette.purple : Color.black.opacity(0.47))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("“Tinkr \(candidate.displayName)”")
                    .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.34))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .buttonStyle(InkButtonStyle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onAppear { if active { replay() } }
        .onChange(of: active) { _, isActive in if isActive { replay() } }
        .onChange(of: revision) { _, _ in if active { replay() } }
        .accessibilityLabel("Tinkr \(candidate.displayName)")
        .accessibilityHint("Preview the \(candidate.displayName) ink reaction")
    }

    private func replay() {
        popped = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.43)) { popped = true }
        }
    }
}

