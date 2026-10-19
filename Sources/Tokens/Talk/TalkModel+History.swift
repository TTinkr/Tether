


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// TalkModel — History


extension TalkModel {

    func togglePromptHistory() {
        setPromptHistoryExpanded(!historyExpanded)
    }

    func setPromptHistoryExpanded(_ expanded: Bool) {
        guard historyExpanded != expanded else { return }
        historyExpanded = expanded
        onHistoryExpansionChange?(expanded)
    }

    // Prompt history — saved prompts and repairing their storage

    /// Adds one entry per talk, newest first, and saves the whole list. When storage is
    /// paused (a file that would not load or save), entries stay in memory only.
    func recordPromptHistory(_ rawText: String, session: UUID?) {
        let spoken = BrandVocabulary.apply(to: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        recordPromptHistory(AuthoredPrompt(transcript: spoken, spokenText: spoken), session: session)
    }

    /// The delivery path supplies provenance before any generated presentation is
    /// appended. Typed text is neither trimmed nor brand-corrected on this path.
    /// `targetApp` is the app in front at the stop when one was captured; saved locally only.
    func recordPromptHistory(_ authored: AuthoredPrompt, session: UUID?, targetApp: PromptTargetApp? = nil) {
        guard !isSyntheticRun, !authored.isEmpty else { return }
        if let session, !historyRecordedSessionIDs.insert(session).inserted { return }
        let entry = PromptHistoryEntry(id: UUID(), createdAt: Date(), authored: authored, targetApp: targetApp)
        // The journal's pointer to this row; only a confirmed save lets the journal rely on it (build 81).
        if let session { historyRowIDs[session] = entry.id }
        promptHistory.insert(entry, at: 0)
        historyStorageNotice = ""
        guard historyStoreWritable else {
            historyStorageError = historyRecoveryRequired
                ? "History file needs repair. New prompts remain in memory; the original file was not replaced."
                : "History storage is paused. New prompts remain in memory."
            Diagnostics.event("prompt_history_save_skipped_preserving_source")
            return
        }
        do {
            try PromptHistoryStore.save(promptHistory)
            historyStorageError = ""
            finishClearingRecoveryJournal()
            Diagnostics.event("prompt_history_saved count=\(promptHistory.count)")
        } catch {
            historyStoreWritable    = false
            historyRecoveryRequired = false
            historyStorageError     = "History could not be saved. This prompt remains available until the app closes."
            Diagnostics.event("prompt_history_save_failed")
        }
    }

    /// Clears saved history and recovered launch words, while preserving a live checkpoint
    /// or words still held from a failed paste in this run. An unreadable source is preserved.
    func clearPromptHistory() {
        guard !isSyntheticRun, !historyRecoveryRequired else { return }
        historyStorageNotice = ""
        let requestedAt = Date()
        let spared: Set<UUID>
        do {
            // Detect a damaged journal before deleting history. Each file is atomic, but the
            // two-file operation is not; a later journal write failure is reported below.
            let entries = try transcriptRecovery.recover()
            spared = sessionsSparedByHistoryClear(entries: entries)
            try PromptHistoryStore.save([])
        } catch {
            historyStorageError = "History could not be cleared. Nothing was deleted."
            Diagnostics.event("prompt_history_clear_failed")
            return
        }

        // The saved history file is empty now, even if the second write fails. Keep memory
        // aligned with that fact and never tell the person that all cleanup succeeded early.
        promptHistory = []
        historyRecordedSessionIDs.removeAll()
        historyRowIDs.removeAll()
        historyStoreWritable = true
        recoveryClearRequestedAt = requestedAt
        recoveryClearExempt = spared
        finishClearingRecoveryJournal()
    }

    /// Retry remains reachable when history is already empty. A failed journal write must
    /// keep its error and request, rather than report success after saving an empty list.
    @discardableResult
    func finishClearingRecoveryJournal() -> Bool {
        guard let requestedAt = recoveryClearRequestedAt else { return true }
        let hasSurvivingCopy: Bool
        do {
            let entries = try transcriptRecovery.recover()
            let keeping = recoveryClearExempt.union(sessionsSparedByHistoryClear(entries: entries))
            try transcriptRecovery.clearForHistory(requestedAt: requestedAt, keeping: keeping)
            // A later talk can be available under Copy latest before it has a history row.
            // Keep a matching spared/new checkpoint, while still forgetting the original
            // recovered launch payload that this Clear History request was meant to delete.
            let cutoff = requestedAt.timeIntervalSince1970.rounded(.down)
            hasSurvivingCopy = entries.contains {
                $0.id != restoredRecoveryID && $0.text == lastTranscriptForCopy
                    && (keeping.contains($0.id) || $0.createdAt.timeIntervalSince1970 >= cutoff)
            }
        } catch {
            historyStorageNotice = ""
            historyStorageError = "Saved history was cleared, but recovery data could not be cleared. Retry to finish deleting it."
            Diagnostics.event("recognized_text_clear_failed")
            return false
        }

        recoveryClearRequestedAt = nil
        recoveryClearExempt.removeAll()
        earlierRecovery = nil
        let held = retainedFailurePayload
        let keepHeld = !held.isEmpty && restoredRecoveryID == nil
        let hasNewHistory = promptHistory.contains { $0.createdAt >= requestedAt }
        restoredRecoveryID = nil
        if !keepHeld {
            // Copy latest prefers this payload over history. Forgetting only the journal or
            // lastTranscriptForCopy would leave deleted launch words available to copy.
            retainedFailurePayload = ""
            retainedFailureText = ""
            retainedSendReturn = false
            clearHeldWords()
        }
        if keepHeld {
            lastTranscriptForCopy = held
        } else if !hasNewHistory && !hasSurvivingCopy {
            lastTranscriptForCopy = ""
        }
        historyStorageError = ""
        historyStorageNotice = hasNewHistory ? "Earlier history cleared." : "History cleared."
        Diagnostics.event("prompt_history_cleared")
        return true
    }

    /// Capture and current failed-paste words are outside a history-clear request. Fall
    /// back to exact held text only when there is no session identity available.
    private func sessionsSparedByHistoryClear(entries: [TranscriptRecoveryEntry]) -> Set<UUID> {
        var spared: Set<UUID> = []
        if (phase == .capturing || phase == .finalizing), let sessionID {
            spared.insert(sessionID)
        }
        if !retainedFailurePayload.isEmpty && restoredRecoveryID == nil {
            if let sessionID {
                spared.insert(sessionID)
            } else {
                spared.formUnion(entries.filter { $0.text == retainedFailurePayload }.map(\.id))
            }
        }
        return spared
    }

//
// :)
//
//
    /// Saves again; if the file needed repair, merges what is on disk first.
    func retryPromptHistoryStorage() {
        guard !isSyntheticRun else { return }
        historyStorageNotice = ""
        do {
            var merged = promptHistory
            if historyRecoveryRequired {
                let diskEntries = try PromptHistoryStore.load()
                merged          = mergePromptHistory(merged, with: diskEntries)
            }
            try PromptHistoryStore.save(merged)
            promptHistory           = merged
            historyStoreWritable    = true
            historyRecoveryRequired = false
            historyStorageError     = ""
            historyStorageNotice    = "History storage restored."
            finishClearingRecoveryJournal()
            Diagnostics.event("prompt_history_retry_succeeded count=\(merged.count)")
        } catch {
            historyStoreWritable = false
            historyStorageError  = historyRecoveryRequired
                ? "History is still unreadable. Preserve the original and start a new history."
                : "History storage is still unavailable. New prompts remain in memory."
            Diagnostics.event("prompt_history_retry_failed")
        }
    }

    /// Copies the unreadable history file aside (PromptHistoryStore names the copy), then
    /// saves the in-memory history as a fresh file.
    func recoverPromptHistoryStorage() {
        guard !isSyntheticRun, historyRecoveryRequired else { return }
        historyStorageNotice = ""
        do {
            let preservedURL        = try PromptHistoryStore.recoverPreservingSource(with: promptHistory)
            historyStoreWritable    = true
            historyRecoveryRequired = false
            historyStorageError     = ""
            historyStorageNotice = preservedURL.map {
                "Original preserved as \($0.lastPathComponent)."
            } ?? "History storage restored."
            Diagnostics.event("prompt_history_recovered source_preserved=\(preservedURL != nil)")
        } catch {
            historyStoreWritable = false
            historyStorageError  = "History recovery failed. The original file was not removed."
            Diagnostics.event("prompt_history_recovery_failed")
        }
    }

    /// One entry per id, newest first; on a duplicate id the in-memory entry wins.
    private func mergePromptHistory(
        _ memoryEntries: [PromptHistoryEntry],
        with diskEntries: [PromptHistoryEntry]
    ) -> [PromptHistoryEntry] {
        var seen: Set<UUID> = []
        return (memoryEntries + diskEntries)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

}

