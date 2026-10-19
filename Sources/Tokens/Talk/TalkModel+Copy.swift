


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Copy


extension TalkModel {

    /// Clipboard write for an explicit user action (a Copy button). Returns false, and
    /// shows no feedback, if the clipboard refused the text.
    private func explicitlyCopy(_ text: String, key: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else { return false }
        // Confirm success visually; the system alert sounds like a failed copy.
        let revision         = UUID()
        copyFeedbackRevision = revision
        copyFeedbackKey      = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard self?.copyFeedbackRevision == revision else { return }
            self?.copyFeedbackKey = nil
        }
        return true
    }

    // Latest words — what Copy latest copies, and microphone reconnect

    /// What Copy latest copies: held words, then the last words, then history.
    var latestTranscript: String {
        if !retainedFailurePayload.isEmpty { return retainedFailurePayload }
        if !lastTranscriptForCopy.isEmpty { return lastTranscriptForCopy }
        if let latest = promptHistory.first { return historyPresentation(latest) }
        let saved = rows.first?.transcript ?? ""
        return saved
    }

    var effectiveInputDeviceName: String {
        previewInputDeviceName ?? audio.inputDeviceName
    }

    var audioIsConfirmed: Bool {
        previewAudioConfirmed ?? audio.hasReceivedAudio
    }

    /// No microphone reconnect, app restart or relaunch while a talk runs or the lab listens.
    var reconnectDisabled: Bool {
        phase == .capturing || phase == .finalizing || isLabListening
    }

    func copyRecommendedSkill() {
        guard selectedProduct == "Tokens" else { return }
        _ = explicitlyCopy(RecommendedSkill.text, key: "recommended-skill")
    }

    /// Copy the exact payload, including typed trailing spaces and newlines.
    /// Logs only the character count, never the words.
    func copyLatestTranscript() {
        let text = latestTranscript
        guard !text.isEmpty else { return }
        guard explicitlyCopy(text, key: "latest") else { return }
        print("TTT_EVENT latest_transcript_copied characters=\(text.utf16.count)")
    }

    /// How a history entry is shown and copied; returns its text unchanged.
    func historyPresentation(_ entry: PromptHistoryEntry) -> String {
        entry.text
    }

    /*
    What History search looks through (build 81): the words a row shows (its spoken preview,
    TokensHistoryText.preview) and any typed note, never the saved markup. Searching the saved
    text matched "num", "char", "words" or "wpm" on every talk carrying tags or the Metadata
    block, and missed "call 555" when the saved text read "call <num>555 …". Copy and the
    expanded row still use historyPresentation, unchanged.
    */
    static func historySearchText(_ entry: PromptHistoryEntry) -> String {
        let typed = (entry.authored?.typed ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let shown = TokensHistoryText.preview(entry)
        return typed.isEmpty ? shown : shown + " " + typed
    }

    /// A blank query matches every talk; otherwise a locale-aware match ignoring case and accents.
    static func historyMatches(_ entry: PromptHistoryEntry, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || historySearchText(entry).localizedStandardContains(query)
    }

    /// Copies the earlier unsent talk and resolves its journal entry, so it does not return (build 81).
    func copyEarlierRecovery() {
        guard let earlier = earlierRecovery, explicitlyCopy(earlier.text, key: Self.earlierCopyKey(earlier)) else { return }
        // The words are on the clipboard either way; a journal that could not be written keeps the line.
        guard resolveTranscriptRecovery(earlier.id) else {
            earlierRecoveryNote = "Copied · still kept here"
            return
        }
        earlierRecoveryNote = nil
        Diagnostics.event("recognized_text_earlier_copied session=\(earlier.id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.earlierRecovery?.id == earlier.id else { return }
            self.refreshEarlierRecovery()
        }
    }

    /// Forgets the earlier unsent talk on an explicit click: its journal entry is resolved.
    /// If the journal cannot be written the line stays, so Forget never seems to work when it did not.
    func forgetEarlierRecovery() {
        guard let earlier = earlierRecovery else { return }
        guard resolveTranscriptRecovery(earlier.id) else {
            earlierRecoveryNote = "Not forgotten · words kept"
            return
        }
        earlierRecoveryNote = nil
        Diagnostics.event("recognized_text_earlier_forgotten session=\(earlier.id)")
        refreshEarlierRecovery()
    }

    static func earlierCopyKey(_ talk: RecoveredTalk) -> String { "earlier-" + talk.id.uuidString }

    func copyPromptHistoryEntry(_ entry: PromptHistoryEntry) {
        let text = historyPresentation(entry)
        guard !text.isEmpty else { return }
        guard explicitlyCopy(text, key: entry.id.uuidString) else { return }
        print("TTT_EVENT prompt_history_copied id=\(entry.id.uuidString) characters=\(text.utf16.count)")
    }

//
// :)
//
//
    /// Rebuilds the idle audio engine so the current system input device is used.
    func reconnectMicrophone() {
        guard !reconnectDisabled else { return }
        stopInputPreview()
        audio.refreshInputDevice()
        resumeInputPreview()
        Diagnostics.event("microphone_refresh_requested")
    }

    /// Voice "copy" during a talk: copy the words and end without delivery.
    /// Nothing in this class calls it.
    private func copyAndEndCapture(_ rawPayload: String) {
        guard phase == .capturing else { return }
        let payload = BrandVocabulary.apply(
            to: rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !payload.isEmpty else { return }
        _ = audio.stop()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        recordPromptHistory(payload, session: sessionID)
        print("TTT_EVENT voice_copy characters=\(payload.utf16.count)")
        hideSurface()
        resetSession()
    }

}

