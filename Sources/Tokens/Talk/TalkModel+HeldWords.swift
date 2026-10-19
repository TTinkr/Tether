


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — HeldWords


extension TalkModel {


    // Held words — words with nowhere to paste, shown until copied or dismissed

    /// The spoken words inside a Tokens prompt, without its heading, stats or pause marks.
    static func heldWordsDisplay(_ payload: String) -> String {
        let fallback = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = payload.hasPrefix("# π\n") ? payload.range(of: "# π\n")
            : payload.range(of: "## Transcript\n") ?? payload.range(of: "## Your words\n")
        guard let start else { return fallback }
        var body = Substring(ThinkingComposer.removingAnnotations(String(payload[start.upperBound...])))
        for end in ["\n---", "\n## "] {
            if let range = body.range(of: end) { body = body[..<range.lowerBound] }
        }
        let words = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
        return words.isEmpty ? fallback : words
    }

    /// Launch-argument proof of the held-words capsule; dictation never calls it.
    func previewHeldWords(_ text: String) {
        retainForRecovery(text, message: "Paste unavailable · Copy latest", shouldRecordHistory: false, holdWords: true)
    }

    /// Only an explicit click copies; no global keyboard event belongs to recovery.
    func presentHeldWords() {
        clearHeldWords()
        heldWordsVisible = true
        heldWordsRevision &+= 1
        // Persistent recovery must never consume another app's Escape or Command-C.
        input.onHeldWordsKey = nil
        // No expiry: a failed paste remains actionable until explicit copy or dismissal.
        Diagnostics.event("held_words_shown characters=\(retainedFailurePayload.utf16.count)")
    }

    /// Copies the held words once, then dismisses 0.7 s later.
    func copyHeldWords() {
        guard heldWordsVisible, !heldWordsCopied, !retainedFailurePayload.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(retainedFailurePayload, forType: .string) else { return }
        heldWordsCopied      = true
        input.onHeldWordsKey = nil
        Diagnostics.event("held_words_copied characters=\(retainedFailurePayload.utf16.count)")
        scheduleHeldWordsDismissal(after: 0.7)
    }

    /// Explicit dismissal or the short post-copy timer also ends a failed talk.
    func dismissHeldWords() {
        guard heldWordsVisible else { return }
        Diagnostics.event("held_words_dismissed copied=\(heldWordsCopied)")
        clearHeldWords()
        hideSurface()
        // The words stay under Copy latest; the failure text never replaces the capsule.
        if phase == .failed {
            if !retainedFailurePayload.isEmpty { lastTranscriptForCopy = retainedFailurePayload }
            resetSession()
        }
    }

//
// :)
//
//
    private func scheduleHeldWordsDismissal(after seconds: TimeInterval) {
        heldWordsTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.dismissHeldWords() }
        RunLoop.main.add(timer, forMode: .common)
        heldWordsTimer = timer
    }

    func clearHeldWords() {
        heldWordsTimer?.invalidate()
        heldWordsTimer       = nil
        input.onHeldWordsKey = nil
        heldWordsVisible     = false
        heldWordsCopied      = false
    }

}

