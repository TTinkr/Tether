


//
/*
ThinkingPanelState.swift
Owns: session question history, user-authored notes, and compact panel sizing.
Never: merge generated questions or typed notes into the faithful transcript.
See: ThinkingPanelView.swift, ThinkingTemple.swift.
*/


import Combine
import Foundation
import TokensCore

@MainActor
final class ThinkingPanelState: ObservableObject {
    struct Batch: Identifiable, Equatable {
        let id: Int
        var text: String
    }

    // Match the donor's 60-question ledger bound, retaining the newest lines.
    static let maximumQuestionLines = 60

    @Published private(set) var batches: [Batch] = []
    @Published var notes = ""
    @Published private(set) var spacingEpoch = 0
    var repairSpacing: ThinkingPadSpacing.Repair?
    func cancelSpacing() { spacingEpoch += 1 }
    @Published var status = "Waiting for a pause"
    @Published var isThinking = false
    @Published var elapsed = 0.0

    var question: String { batches.map(\.text).joined(separator: "\n\n") }

    func beginSession() {
        cancelSpacing()
        batches = []
        // Notes entered between talks belong to the next delivery.
        isThinking = false
        elapsed    = 0
    }

    /// Delivery takes one exact snapshot; a later delivery cannot append it again.
    func consumeNotesForDelivery() -> String {
        cancelSpacing()
        defer { notes = "" }
        return notes
    }

    /// Each generation grows in place; a later pause adds a batch instead of
    /// replacing earlier questions. A cancelled partial may roll back to the
    /// previous generation, so its unfinished text must also leave the page.
    func receive(_ output: TokensThinkingLaneOutput) {
        switch output.state {
        case .idle, .waiting, .unavailable: return
        default: break
        }
        var next = batches.filter { $0.id <= output.generation }
        let earlier = Set(next.filter { $0.id < output.generation }
            .flatMap { $0.text.components(separatedBy: "\n") }.map(Self.key))
        let lines = output.text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !earlier.contains(Self.key($0))
        }
        let text = lines.joined(separator: "\n")
        next.removeAll { $0.id == output.generation }
        if !text.isEmpty { next.append(Batch(id: output.generation, text: text)) }
        next = Self.bounded(next)
        if next != batches { batches = next }
    }

    private static func bounded(_ batches: [Batch]) -> [Batch] {
        var remaining     = maximumQuestionLines
        var kept: [Batch] = []
        for batch in batches.reversed() {
            guard remaining > 0 else { break }
            let lines = batch.text.components(separatedBy: "\n").suffix(remaining)
            remaining -= lines.count
            kept.append(Batch(id: batch.id, text: lines.joined(separator: "\n")))
        }
        return Array(kept.reversed())
    }

//
// :)
//
//
    private static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

enum ThinkingPanelGeometry {
    /// Match the display's proportions at a comfortable, compact reading size.
    /// Manual resizing remains unconstrained, including the tiny collapsed state.
    static func expandedSize(screen: CGSize) -> CGSize {
        let valid   = screen.width.isFinite && screen.height.isFinite && screen.width > 0 && screen.height > 0
        let display = valid ? screen : CGSize(width: 1512, height: 982)
        let width   = min(560, display.width * 0.65)
        return CGSize(width: width, height: width * display.height / display.width)
    }
}

enum ThinkingNotes {
    /// Notes are authored by the user, not spoken words or model output. They
    /// follow the completed transcript in their own Markdown section, verbatim.
    static func appending(_ notes: String, to transcript: String) -> String {
        AuthoredPrompt.appendingTyped(notes, to: transcript)
    }
}

