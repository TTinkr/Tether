


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Startup


extension TalkModel {

    /// Offers the newest unresolved talk for explicit Copy latest. Every other checkpoint
    /// remains on disk until verified delivery or an explicit clear/discard action, except that
    /// only the newest 50 sent-but-unconfirmed talks already saved in History are kept
    /// (build 81; sentEntryLimit, HistoryRowsOnDisk).
    func restoreTranscriptRecovery() {
        do {
            if let saved = try transcriptRecovery.latestCopyEntry(),
               !Self.offersAtLaunch(saved.updatedAt, newestHistory: promptHistory.map(\.createdAt).max()) {
                /*
                A newer talk is in History: these words stay reachable on Home as an earlier talk
                with their own Copy and Forget, and never outrank the newest talk under Copy latest
                (build 81: hiding them made them unreachable).
                */
                earlierRecovery = RecoveredTalk(id: saved.id, text: saved.text)
                Diagnostics.event("recognized_text_recovered_earlier session=\(saved.id)")
            } else if let saved = try transcriptRecovery.latestCopyEntry() {
                retainedFailurePayload = saved.text
                lastTranscriptForCopy = saved.text
                retainedFailureText = "Recovered transcript · Copy latest"
                restoredRecoveryID = saved.id
                Diagnostics.event("recognized_text_recovered session=\(saved.id)")
            }
        } catch {
            historyStorageError = "Recovery journal needs attention; its original file is preserved."
        }
    }

    /*
    Whether held words are the latest talk, offered under Copy latest at launch (build 81): only
    while newer than every talk in History (held words saved for an update restart are). Older
    ones are offered as an earlier talk instead (earlierRecovery); nothing is hidden by age.
    */
    static func offersAtLaunch(_ updatedAt: Date, newestHistory: Date?) -> Bool {
        guard let newestHistory else { return true }
        return newestHistory <= updatedAt
    }

    /// Completes startup after every stored property has been initialized.
    /// The interactive preview return exits only this final setup step.
    func configureStartup() {
        if !isSyntheticRun { configureListeningPrivacy() }
        /*
        Correct only structurally identified speech; legacy text and literal
        typing stay intact. Unreadable History is preserved for explicit repair.
        */
        if isSyntheticRun {
            rows          = []
            promptHistory = []
        } else {
            rows = []
            do {
                promptHistory = try PromptHistoryStore.load().map { entry in
                    entry.correctingSpoken(BrandVocabulary.apply(to:))
                }
            } catch {
                historyStoreWritable    = false
                historyRecoveryRequired = true
                historyStorageError     = "History could not be loaded. The original file is preserved."
                Diagnostics.event("prompt_history_load_failed")
            }
        }
        /*
        Real launches start as Tokens: receipt and Markdown off, Speed of Sound on, no
        formatting model. Talk's own settings load when switching to it (selectProduct).
        seedTelepathyPreferences does nothing in the Tokens and Tokens Dev bundles.
        */
        if !isSyntheticRun {
            seedTelepathyPreferences()
            metadataEnabled     = preferences.bool(forKey: TokensOutputOptions.metadataKey)
            thinkingTracesEnabled = preferences.bool(forKey: TokensOutputOptions.thinkingKey)
            characterTagsEnabled = TokensOutputOptions.characterTags(in: preferences)
            numberTagsEnabled   = TokensOutputOptions.numberTags(in: preferences)
            markdownEnabled     = false
            speedOfSoundEnabled = true
            localFormatter.switchPreferences(to: .standard, allowModel: false)
        }
        // Reading recovery never deletes older unresolved talks or replays a delivery.
        if !isSyntheticRun { restoreTranscriptRecovery() }
        // The interactive bubble harness never starts services, reads history, or writes preferences.
        if bubbleInteractivePreview {
            shortcutName    = bubblePreviewProduction ? "Right Option" : "Left Option"
            rightOptionMode = .tap
            return
        }
        refreshDailyAllowance()
        /*
        The model starts as Tokens, so the thinking formatter is on unless this is a
        synthetic run or the standalone build.
        */
        thinkingFormatter.setActive(thinkingMetadataEnabled && !isSyntheticRun)
        thinkingFormatter.probe()
        /*
        An update may restart idle/delivered work, or a terminal failed paste after exact
        held words survive durable readback. Never restart active capture or lab listening.
        */
        updater.canRestart = { [weak self] in
            guard let self else { return false }
            return Updater.canSafelyRestart(phase: self.phase,
                                           microphoneBusy: self.reconnectDisabled || self.recoveryOwnsCommandCapture,
                                           retainedText: self.retainedFailurePayload) {
                do { return try self.transcriptRecovery.preserveForUpdateRestart(self.retainedFailurePayload) }
                catch {
                    self.historyStorageError = "Update is waiting: pending words could not be saved. Keep Tokens open and use Copy latest."
                    return false
                }
            }
        }
        updater.restartHoldExplanation = { [weak self] in
            guard let self else { return "Update downloaded · waiting to restart" }
            if self.phase == .capturing || self.phase == .finalizing {
                return "Update downloaded · finish talking to restart"
            }
            if self.isLabListening { return "Update downloaded · stop microphone test to restart" }
            if self.phase == .failed {
                return "Update waiting · save pending words with Copy latest on Home"
            }
            return "Update downloaded · waiting for an idle moment"
        }
        // Optional, encouraged updates: quiet startup and roughly one-minute checks (no-op until a feed is configured).
        if !isSyntheticRun, !Self.tokensFirstRunPending {
            updater.startBackgroundChecks()
        }
        // A formatter result re-renders the live words.
        localFormatter.onUpdate = { [weak self] in self?.rerenderActiveTranscript() }
        if !isSyntheticRun && localFormatter.enabled { localFormatter.probe() }
        /*
        Key monitor → model. onPress/onRelease are talk key edges; onFastFinish is Return
        pressed while the talk key is held (Speed of Sound). isStopEdge tells the monitor
        which edge will stop the talk, so it starts holding back Return from that edge.
        */
        input.onPress      = { [weak self] in self?.routeRightOption(pressed: true) }
        input.onRelease    = { [weak self] in self?.routeRightOption(pressed: false) }
        input.onFastFinish = { [weak self] in self?.finishAtSpeedOfSound() }
        input.onChord      = { [weak self] in self?.handleTalkKeyChord() }
        // Dev builds also take talk-key edges from `--qa-talk` (live QA without the physical key).
        if !isSyntheticRun {
            qaTalkObserver = QATalkTrigger.listen { [weak self] edge, reply in self?.handleQATalk(edge, reply: reply) }
        }
        input.isStopEdge = { [weak self] pressed in
            guard let self, self.phase == .capturing else { return false }
            return (self.activeSessionMode ?? self.rightOptionMode).action(
                pressed: pressed, capturing: true, finalizing: false
            ) == .finish
        }
        // The Return chord counts only when Speed of Sound is on and a talk is recording.
        input.speedOfSoundEnabled = { [weak self] in self?.speedOfSoundEnabled ?? false }
        input.speedOfSoundReady = { [weak self] in
            guard let self else { return false }
            return self.phase == .capturing && self.sessionID != nil && self.audio.isRecording
        }
        // The event tap was refused or lost: show the key access failure.
        input.onUnavailable = { [weak self] message in
            guard let self else { return }
            self.shortcutAccessGranted       = false
            self.showShortcutAccessFailure(message)
        }
        /*
        Each audio-features update, received on main. Background listening feeds its own
        notes. During a talk it feeds the π thinking panel, then the live notes, unless the
        panel's reflection is using the shared model.
        */
        audio.$features
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.thinkingExperience, !self.isSyntheticRun else { return }
                if self.ambientOwnsCapture {
                    self.ambientReflection.observe(pauseSeconds: nil, transcript: self.ambientTranscript)
                    return
                }
                // Public capture keeps measured audio/bubble updates, without live model suggestions.
                guard self.phase == .capturing, !publicTokens else { return }
                self.pauseAsides.observe(pauseSeconds: self.audio.thinkingOpenPauseSeconds, transcript: self.audio.transcript)
            }.store(in: &subscriptions)
        /*
        The Tinkering panel's hosting view observes pauseAsides itself. Model
        refreshes never order the window: only an explicit capture start or
        the setting does, so a panel the user hid stays hidden.
        */

        // First audio of a talk proves the microphone works: cancel the 8 s startup deadline.
        audio.$hasReceivedAudio
            .removeDuplicates()
            .sink { [weak self] confirmed in
                guard let self, confirmed else { return }
                guard self.phase == .capturing else { return }
                self.cancelStartupDeadline()
                Diagnostics.event("capture_audio_confirmed session=\(self.sessionID?.uuidString ?? "none")")
            }
            .store(in: &subscriptions)
        // Every recognizer update (words, and how many are settled) → observeTranscript.
        audio.$transcript
            .combineLatest(audio.$stableWordCount)
            .sink { [weak self] text, stableWordCount in
                self?.observeTranscript(text, stableWordCount: stableWordCount)
            }
            .store(in: &subscriptions)
        // Finished segments may carry voice commands; lab commands go to the lab.
        audio.$completedSegment
            .compactMap { $0 }
            .sink { [weak self] segment in self?.observeCompletedSegment(segment) }
            .store(in: &subscriptions)
        audio.$labCommand
            .compactMap { $0 }
            .sink { [weak self] event in self?.observeLabCommand(event) }
            .store(in: &subscriptions)
        // Microphone or recognizer errors.
        audio.$captureError
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self else { return }
                if self.inputPreviewOwnsCapture {
                    self.stopInputPreview()
                    return // Input preview errors stay in the microphone status, never paste recovery.
                }
                self.observeCaptureError(message, transcript: self.audio.transcript)
            }
            .store(in: &subscriptions)
    }

}

