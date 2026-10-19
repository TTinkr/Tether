


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// MainWordStreamState — reveals the live words a few words at a time, then letter by letter


final class MainWordStreamState: ObservableObject {


    // State and the entry point


    /*
    visibleText is what the view shows. "Canonical" text is the latest full text from the recogniser;
    the reveal target is how far we have decided to show it. The timers below move visibleText
    towards the target one letter at a time. Used only by MainTranscriptStream, which only the old shell
    (Unreached/OldShell.swift) uses.
    */
    @Published private(set) var visibleText = ""
    private var latestCanonicalText         = ""
    private var revealTarget                = ""
    private var batchTimer: Timer?
    private var characterTimer: Timer?
    private var capturing          = false
    private var lastRevisionUptime = ProcessInfo.processInfo.systemUptime
    // wordsPerBatch and catchUpWordsPerBatch are not read anywhere in this file at the moment.
    private let wordsPerBatch                   = 3
    private let catchUpWordsPerBatch            = 5
    private let batchInterval: TimeInterval     = 0.16
    private let characterInterval: TimeInterval = 0.025

    /*
    Called whenever the text or the talk phase changes. No text, a phase other than capturing, or
    Reduce Motion means everything is shown at once (snap). While capturing:
     - if what is on screen is no longer the start of the new text, the recogniser rewrote words that
       were already shown, so the correction is adopted straight away (adoptCorrection);
     - otherwise the batch timer is started so the new text is revealed step by step.
    */
    func ingest(_ canonicalText: String, phase: TalkPhase, reduceMotion: Bool) {
        if latestCanonicalText != canonicalText { lastRevisionUptime = ProcessInfo.processInfo.systemUptime }
        latestCanonicalText = canonicalText
        guard !canonicalText.isEmpty else {
            snap(to: canonicalText)
            return
        }
        guard phase == .capturing, !reduceMotion else {
            snap(to: canonicalText)
            return
        }

        capturing = true
        guard canonicalText.hasPrefix(visibleText) else {
            adoptCorrection(canonicalText)
            Diagnostics.event(
                "main_stream_correction_snap graphemes=\(visibleText.count)"
            )
            return
        }
        if !canonicalText.hasPrefix(revealTarget) {
            /*
            A correction only touched text that had been queued but not yet
            shown. Drop that stale suffix without disturbing visible text.
            */
            revealTarget = visibleText
            stopCharacterTimer()
        }
        startBatchTimerIfNeeded()
    }

    /*
    The batch timer ticks every 0.16 s and stops itself when we are no longer capturing. Timers are
    added in the common run-loop modes so the reveal keeps going while a menu is open or a window
    is being dragged.
    */
    private func startBatchTimerIfNeeded() {
        guard batchTimer == nil, visibleText != latestCanonicalText else { return }
        let timer = Timer(timeInterval: batchInterval, repeats: true) { [weak self] timer in
            guard let self, self.capturing else {
                timer.invalidate()
                self?.batchTimer = nil
                return
            }
            self.commitNextBatch()
        }
        batchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

//
// :)
//
//
    /*
    Each tick, once everything already queued has been shown, choose the next target: the whole
    latest text if it has not changed for 0.7 s, otherwise the next sentence batch chosen by
    VisualSentenceBatch. Then letters are typed out towards it (character timer, every 0.025 s).
    */
    private func commitNextBatch() {
        guard latestCanonicalText.hasPrefix(visibleText) else {
            adoptCorrection(latestCanonicalText)
            Diagnostics.event("main_stream_correction_snap graphemes=\(visibleText.count)")
            return
        }
        if !latestCanonicalText.hasPrefix(revealTarget) {
            revealTarget = visibleText
            stopCharacterTimer()
        }
        guard revealTarget != latestCanonicalText else {
            if visibleText == latestCanonicalText { stopBatchTimer() }
            return
        }

        guard visibleText == revealTarget else { return }
        revealTarget = ProcessInfo.processInfo.systemUptime - lastRevisionUptime >= 0.7
            ? latestCanonicalText
            : VisualSentenceBatch.target(canonical: latestCanonicalText, visible: visibleText)
        startCharacterTimerIfNeeded()
    }

    private func startCharacterTimerIfNeeded() {
        guard characterTimer == nil, visibleText != revealTarget else { return }
        let timer = Timer(timeInterval: characterInterval, repeats: true) { [weak self] timer in
            guard let self, self.capturing else {
                timer.invalidate()
                self?.characterTimer = nil
                return
            }
            self.revealCharacters()
        }
        characterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }


    // Revealing letters, corrections and stopping


    /*
    Shows one more letter per tick. It always cuts visibleText from the latest canonical text (not
    from the older target), so a correction to words not yet shown costs nothing.
    */
    private func revealCharacters() {
        guard latestCanonicalText.hasPrefix(visibleText) else {
            adoptCorrection(latestCanonicalText)
            Diagnostics.event("main_stream_correction_snap graphemes=\(visibleText.count)")
            return
        }
        guard latestCanonicalText.hasPrefix(revealTarget),
              revealTarget.hasPrefix(visibleText) else {
            revealTarget = visibleText
            stopCharacterTimer()
            startBatchTimerIfNeeded()
            return
        }
        guard visibleText != revealTarget else {
            stopCharacterTimer()
            return
        }

        let nextCount = min(revealTarget.count, visibleText.count + 1)
        let end = latestCanonicalText.index(
            latestCanonicalText.startIndex,
            offsetBy: nextCount
        )
        visibleText = String(latestCanonicalText[..<end])
        if visibleText == revealTarget {
            stopCharacterTimer()
            if visibleText == latestCanonicalText { stopBatchTimer() }
        }
    }

//
// :)
//
//
    /*
    The position just after the `maxWords`-th word and the space that follows it; the end of the
    text if there are fewer words than that.
    */
    private func nextBatchEnd(
        in text: String,
        after start: String.Index,
        maxWords: Int
    ) -> String.Index {
        var index      = start
        var words      = 0
        var insideWord = false
        while index < text.endIndex {
            let character = text[index]
            let next      = text.index(after: index)
            if character.isWhitespace {
                if insideWord {
                    insideWord = false
                    if words >= maxWords { return next }
                }
            } else if !insideWord {
                insideWord = true
                words += 1
            }
            index = next
        }
        return text.endIndex
    }

    /*
    The recogniser changed words that are already on screen. Count the words currently shown and
    show the same number of words from the corrected text, so the display jumps to the corrected
    wording without running ahead of itself. Nothing is shown if nothing was shown before.
    */
    private func adoptCorrection(_ canonicalText: String) {
        let displayedWordSlots = visibleText
            .split(whereSeparator: { $0.isWhitespace })
            .count
        let correctedEnd = nextBatchEnd(
            in: canonicalText,
            after: canonicalText.startIndex,
            maxWords: displayedWordSlots
        )
        stopCharacterTimer()
        visibleText = displayedWordSlots == 0
            ? ""
            : String(canonicalText[..<correctedEnd])
        revealTarget = visibleText
        startBatchTimerIfNeeded()
    }

    // Show the full text immediately and stop both timers.
    private func snap(to canonicalText: String) {
        capturing = false
        stopBatchTimer()
        stopCharacterTimer()
        latestCanonicalText = canonicalText
        revealTarget        = canonicalText
        visibleText         = canonicalText
    }

    private func stopBatchTimer() {
        batchTimer?.invalidate()
        batchTimer = nil
    }

    private func stopCharacterTimer() {
        characterTimer?.invalidate()
        characterTimer = nil
    }


}

//
// :)
//
//
// WordRevealState — reveals the live words a sentence at a time, typed out letter by letter


final class WordRevealState: ObservableObject {


    // Taking in text


    /*
    visibleText is what the view shows; correctionRevision goes up each time a correction replaces
    words that were already shown (TerminalStream dips its opacity when it changes). Used by
    TerminalStream and TinyTranscript.
    */
    @Published private(set) var visibleText = ""
    @Published private(set) var correctionRevision = 0
    private var latestCanonicalText = ""
    private var visualTarget = ""
    private var commitWork: DispatchWorkItem?
    private var revealTimer: Timer?
    private var capturing  = false
    private var pauseFlush = false

    /*
    New text from the recogniser is not shown at once: a commit is scheduled 0.25 s later if the
    text ends a sentence (. ? !) and 0.5 s later otherwise, so a run of quick rewrites settles
    before anything is drawn. A scheduled commit is not replaced by a later one.
    */
    func ingest(_ canonicalText: String, phase: TalkPhase, reduceMotion: Bool) {
        latestCanonicalText = canonicalText
        if canonicalText.isEmpty {
            snap(to: canonicalText)
            return
        }
        if phase != .capturing || reduceMotion {
            snap(to: canonicalText)
            return
        }
        capturing = true
        scheduleCommit(after: endsSentence(canonicalText) ? 0.25 : 0.5)
    }

    /*
    Used when a pause is detected: cancel the wait and commit now, showing all of the latest text
    (not just the next sentence batch).
    */
    func flushBuffer(_ canonicalText: String, phase: TalkPhase, reduceMotion: Bool) {
        latestCanonicalText = canonicalText
        guard phase == .capturing, !reduceMotion else {
            snap(to: canonicalText)
            return
        }
        capturing = true
        commitWork?.cancel()
        commitWork = nil
        pauseFlush = true
        commitLatest()
    }

    private func scheduleCommit(after delay: TimeInterval) {
        guard commitWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.commitWork = nil
            self?.commitLatest()
        }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }


    // Committing and typing out


    /*
    Nothing to do unless capturing with new text. If the previous reveal has not finished, try
    again in 0.12 s. If the latest text starts with what is shown, pick the next target (all of
    it after a pause, otherwise the next sentence batch) and start typing. If it does not, the
    recogniser changed shown words, so the new text replaces the old at once.
    */
    private func commitLatest() {
        guard capturing, !latestCanonicalText.isEmpty,
              latestCanonicalText != visualTarget else { return }
        guard visibleText == visualTarget else {
            /*
            A sentence already on screen stays immutable until its steady
            reveal completes; the latest canonical revision remains queued.
            */
            scheduleCommit(after: 0.12)
            return
        }
        if latestCanonicalText.hasPrefix(visibleText) {
            visualTarget = pauseFlush ? latestCanonicalText : VisualSentenceBatch.target(canonical: latestCanonicalText, visible: visibleText)
            pauseFlush = false
            startRevealTimerIfNeeded()
            print(
                "TTT_UI sentence_buffer_committed visible=\(Array(visibleText).count) " +
                "target=\(Array(visualTarget).count)"
            )
        } else if visibleText == visualTarget {
            /*
            A recognizer correction is adopted once at a buffer boundary.
            Never build a hybrid string from two canonical revisions.
            */
            visualTarget = latestCanonicalText
            visibleText  = latestCanonicalText
            correctionRevision &+= 1
            print("TTT_UI sentence_correction_snap graphemes=\(Array(visibleText).count)")
        }
    }

//
// :)
//
//
    /*
    Every 0.025 s add one more letter of the target. When the target is reached (or no longer
    matches what is shown) the timer stops itself and, if newer text is waiting, another commit is
    scheduled 0.08 s later.
    */
    private func startRevealTimerIfNeeded() {
        guard revealTimer == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] timer in
            guard let self, self.capturing else {
                timer.invalidate()
                self?.revealTimer = nil
                return
            }
            let visible = Array(self.visibleText)
            let target  = Array(self.visualTarget)
            if visible.count < target.count,
               target.prefix(visible.count).elementsEqual(visible) {
                self.visibleText.append(target[visible.count])
                return
            }
            timer.invalidate()
            self.revealTimer = nil
            if self.latestCanonicalText != self.visualTarget {
                self.scheduleCommit(after: 0.08)
            }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    private func snap(to canonicalText: String) {
        capturing = false
        commitWork?.cancel()
        commitWork = nil
        revealTimer?.invalidate()
        revealTimer         = nil
        latestCanonicalText = canonicalText
        visualTarget        = canonicalText
        visibleText         = canonicalText
    }


}

