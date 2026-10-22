


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Transcript


extension TalkModel {

    // Live words — the bubble text and the Tokens thinking layout

    /// Every recognizer update lands here. Idle listeners keep their words to themselves.
    /// During a talk: checkpoint for recovery, feed the formatters, update the bubble.
    func observeTranscript(_ text: String, stableWordCount: Int) {
        if tinctureOwnsCapture {
            tinctureVoiceTranscript = text; tinctureStableWords = stableWordCount
            return
        }
        if ambientOwnsCapture {
            ambientTranscript = String(text.suffix(900))
            return // No formatter, recovery journal, history, command or delivery path.
        }
        guard phase == .capturing else { return }
        scheduleCaptureCheckpoint(text)
        let branded = BrandVocabulary.apply(to: text)
        if !isSyntheticRun { localFormatter.ingest(branded) }
        if thinkingMetadataEnabled, thinkingFormatter.enabled {
            ingestThinking(raw: text, stableWordCount: stableWordCount)
        }
        displayText = renderTranscript(
            branded,
            durationSeconds: audio.recordingDurationSeconds,
            includePlainMetadata: false,
            includeCharacterMarkers: true
        )
        displayStableWordCount = min(
            stableWordCount,
            branded.split(whereSeparator: { $0.isWhitespace }).count
        )
    }

    /// Lab Tokens only; the standalone Talk build keeps its original envelope.
    var thinkingExperience: Bool { selectedProduct == "Tokens" && !standalone }

    /// Output extras never select the capture bubble or change its geometry.
    /// The thinking layout (pause notes, receipt) runs when either output switch needs it (build 88).
    var thinkingMetadataEnabled: Bool { thinkingExperience && (metadataEnabled || thinkingTracesEnabled) }

    /// Only paragraphs made wholly of finalized words are offered for layout;
    /// the growing tail waits until recognition has settled it.
    private func ingestThinking(raw: String, stableWordCount: Int) {
        // Spelled-out letters (protected spans) skip this live layout entirely.
        guard stableWordCount > 0, !CharacterTalk.render(raw).hasProtectedSpan else { return }
        let segments = ThinkingComposer.segments(raw: raw, words: audio.timedWords, pauses: audio.thinkingPauses)
        var eligible: [String] = []
        var consumed = 0
        /*
        Walk the segments counting words: a segment wholly inside the settled count is
        eligible; in the first one that crosses it, only whole paragraphs inside the count
        are, and never its last paragraph. Stop there.
        */
        for segment in segments {
            let start = consumed
            consumed += segment.text.split(whereSeparator: { $0.isWhitespace }).count
            let paragraphs = Self.thinkingParagraphs(segment.text)
            if consumed <= stableWordCount { eligible += paragraphs; continue }
            var used = start
            for paragraph in paragraphs.dropLast() {
                used += paragraph.split(whereSeparator: { $0.isWhitespace }).count
                guard used <= stableWordCount else { break }
                eligible.append(paragraph)
            }
            break
        }
        thinkingFormatter.ingest(
            paragraphs: eligible,
            finalizedText: BrandVocabulary.apply(to: StagedPrompt.stablePrefix(raw, wordCount: stableWordCount))
        )
    }

//
// :)
//
//
    /// Paragraphs of one segment, with brand names applied.
    private static func thinkingParagraphs(_ segment: String) -> [String] {
        ParagraphFormatter.format(BrandVocabulary.apply(to: segment))
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Use the same vocabulary for each placed segment and its fidelity reference.
    /// Otherwise a correction such as tinker → tinkr would discard valid pause placement.
    static func thinkingSegmentText(_ text: String) -> String {
        let branded = BrandVocabulary.apply(to: text)
        let talk    = CharacterTalk.render(branded)
        return talk.hasProtectedSpan ? talk.markdownText : branded
    }

    /// Tokens payload: separate title, measured-silence notes at recognized
    /// word boundaries, and validated layout where it already exists. Never
    /// waits for a model; any doubt falls back to the literal words.
    func thinkingPayload(raw: String, segment: CompletedSegment,
                                 durationSeconds: TimeInterval, titleOverride: String? = nil) -> String {
        let pauses        = segment.thinkingPauses
        let branded       = BrandVocabulary.apply(to: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let characterTalk = CharacterTalk.render(branded)
        let outputBody = TokensOutputOptions.body(branded, characterTags: characterTagsEnabled,
                                                 numberTags: numberTagsEnabled)
        let placement = ThinkingComposer.placement(raw: raw, words: segment.timedWords, pauses: pauses,
                                                      anchors: segment.thinkingAnchors)
        // Spelled-character spans keep their own rendering inside a segment.
        let composed = ThinkingComposer.body(placement.segments, unplaced: placement.unplaced,
                                            paragraphs: { TokensOutputOptions.body(BrandVocabulary.apply(to: $0), characterTags: self.characterTagsEnabled,
                                                                                   numberTags: self.numberTagsEnabled) })
        var body = composed
        if !LexicalFidelity.preservesWords(raw: outputBody,
                                              formatted: ThinkingComposer.removingAnnotations(composed)) {
            // Any doubt: literal words, with every measured pause reported unplaced.
            body = [outputBody, ThinkingComposer.unplacedSummary(pauses.map(\.duration))]
                .compactMap { $0 }.joined(separator: "\n\n")
        }
        Diagnostics.event("thinking_placement pauses=\(pauses.count) unplaced=\(placement.unplaced.count) timed_words=\(segment.timedWords.filter(\.hasTiming).count) anchors=\(segment.thinkingAnchors.updates.count) aligned=\(placement.wordTimesAligned) by_word_times=\(placement.placedByWordTimes) by_arrival=\(placement.placedByArrival)")
        return ThinkingPrompt.format(
            /*
            The live workspace first; then the tiny model; then the speaker's own repeated words.
            Each is re-checked against the final words.
            */
            title: titleOverride ?? ThinkingTitle.best([pauseAsides.latestWorkspaceTitle, thinkingFormatter.title],
                                         transcript: characterTalk.deliveryText)
                ?? ThinkingTitle.keywords(transcript: characterTalk.deliveryText),
            body: body, durationSeconds: durationSeconds,
            countTranscript: characterTalk.deliveryText, pauses: pauses.map(\.duration),
            speechGapEstimate: segment.thinkingPausesAreSpeechEstimates
        )
    }

    /// Re-renders the live words after a setting or formatter change (only while capturing).
    func rerenderActiveTranscript() {
        guard phase == .capturing else { return }
        observeTranscript(audio.transcript, stableWordCount: audio.stableWordCount)
    }

    // Rendering — final text layouts; also voice commands and capture errors

    /// Renders words for the bubble or for delivery, after the local formatter's accepted
    /// chunks (localFormatter.rendered) and spelled-letter handling (CharacterTalk):
    ///   Tokens            → the display text; with includePlainMetadata, TokensPrompt.format
    ///   others, plain     → paragraphs, plus the receipt when on and includePlainMetadata
    ///   others, Markdown  → MarkdownFormatter, with the receipt when on
    /// includeCharacterMarkers picks CharacterTalk's display form (for the bubble).
    func renderTranscript(
        _ raw: String,
        durationSeconds: TimeInterval,
        includePlainMetadata: Bool,
        includeCharacterMarkers: Bool = false
    ) -> String {
        if selectedProduct == "Tokens" {
            // Clean mode bypasses layout/model/Markdown transformations entirely.
            let body = TokensOutputOptions.body(raw, characterTags: characterTagsEnabled && !includeCharacterMarkers,
                                               numberTags: numberTagsEnabled && !includeCharacterMarkers)
            guard metadataEnabled && includePlainMetadata else { return body }
            return TokensPrompt.format(body, durationSeconds: durationSeconds,
                                       countTranscript: CharacterTalk.render(raw).deliveryText)
        }
        let characterTalk = CharacterTalk.render(localFormatter.rendered(raw))
        switch markdownEnabled ? TranscriptRenderMode.markdown : .plain {
        case .plain:
            let transcript = includeCharacterMarkers
                ? characterTalk.displayText
                : characterTalk.deliveryText
            let body = ParagraphFormatter.format(transcript)
            return metadataEnabled && includePlainMetadata
                ? Receipt.append(
                    to: body,
                    durationSeconds: durationSeconds,
                    transcript: transcript
                )
                : body
        case .markdown:
            let transcript = includeCharacterMarkers
                ? characterTalk.displayText
                : characterTalk.markdownText
            return MarkdownFormatter.format(
                transcript,
                durationSeconds: durationSeconds,
                metadataEnabled: metadataEnabled,
                metadataTranscript: characterTalk.deliveryText
            )
        }
    }

//
// :)
//
//
    /// Voice commands from finished segments. Only "copy" acts, and only while words are
    /// held and recovery listening owns the microphone, which this class never turns on.
    func observeCompletedSegment(_ segment: CompletedSegment) {
        guard observedSegmentIDs.insert(segment.id).inserted else { return }
        guard audio.isCurrentCommandSegment(segment),
              let utterance = segment.commandUtterance,
              let command = VoiceCommandParser.standaloneCommand(in: utterance) else { return }
        switch command {
        case .copyTalk where phase == .failed && recoveryOwnsCommandCapture:
            copyRetainedByVoice()
        default:
            break
        }
    }

    /// Lab voice commands; they act only while the lab is open and listening in idle.
    func observeLabCommand(_ event: LabCommandEvent) {
        guard phase == .idle, isLabOpen, isLabListening,
              audio.isCurrentLabCommand(event) else { return }
        switch event.command {
        case .stopListening:
            pauseLab(source: "voice_stop")
        case .labSound(let candidate):
            setLabSoundPreview(candidate, source: "voice")
        case .minimize, .fullScreen, .restoreSize, .closeWindow:
            onVoiceCommand?(event.command)
        case .copyTalk, .paste, .send:
            break
        }
    }

    /// A microphone or recognizer error. Lab: pause it. During a talk: hold any words for
    /// Copy latest, or show the error when there are none. Otherwise ignored.
    func observeCaptureError(_ message: String, transcript: String) {
        cancelStartupDeadline()
        Diagnostics.event("capture_failure phase=\(phase) session=\(sessionID?.uuidString ?? "none")")
        if phase == .idle, isLabOpen, isLabListening {
            isLabListening       = false
            labOwnsSignalCapture = false
            print("TTT_EVENT lab_paused source=capture_error stopped_signal=true")
            return
        }
        guard phase == .capturing || phase == .finalizing else { return }
        let recoverableText = transcript.isEmpty ? displayText : transcript
        if recoverableText.isEmpty {
            showAccessFailure(message)
        } else {
            retainForRecovery(recoverableText)
        }
    }

}

