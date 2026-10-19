


//
/*
AudioCapture+Recognition.swift

Owns: Permission startup, model prewarm, and current/legacy speech recognition.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Hardware.swift
         AudioCapture+Signal.swift
         AudioCapture+Finish.swift
         AudioCapture+Demo.swift
         AudioCapture+Measurement.swift
         AudioCapture+Features.swift
Port provenance: Sources/Audio/TTTAudioCapture.swift, donor 2ac14df.
*/


import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech
import TokensCore


extension AudioCapture {


    // Starting a talk — permissions, the lifecycle proof, and speech model prewarm


    /*
    Starts a talk: microphone permission, then speech permission, then start(). Each
    answer arrives later, so each step first checks the talk is still this one and still
    waiting for access. Does nothing while asleep or while another talk is active.
    personalVocabulary becomes recognizer hints; localOnly requires on-device recognition.
    */
    func requestAccessAndStart(
        personalVocabulary: [String] = [],
        localOnly: Bool = false
    ) {
        /*
        localOnly is the idle/background listener. It never takes the Orukeet lease: that
        would make every key press cancel it (and wait or cold-load) and rotate the model
        every 60 s. It stays on Apple's on-device path when Speech access already exists,
        otherwise level only. It never asks for Speech access itself.
        */
        // A local-model user without Apple's permission gets level only in the optional
        // background listener, never a Speech prompt from the background.
        let idleEngine = localOnly ? Self.idleListenerEngine(selected: SpeechEngineChoice.intended(),
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized) : nil
        if localOnly && idleEngine == nil {
            requestAccessAndStartSignal(voiceCommands: false, labMode: false)
            return
        }
        guard !suspended, let generation = session.begin() else { return }
        resetSession()
        sessionSpeechEngine = idleEngine ?? SpeechEngineChoice.load()
        // The Orukeet model loads behind the running tap (pre-roll), with its own
        // load deadline, so the hardware guard covers only the microphone.
        hardwareStartupTimeout = 8
        requiresLocalRecognition = localOnly
        recognitionHints         = PersonalDictionary.recognitionHints(personalVocabulary)
        if demoMode {
            _ = session.advance(generation, from: .awaitingAccess, to: .recording)
            startDemo()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.session.id == generation,
                      self.session.phase == .awaitingAccess else { return }
                guard granted else {
                    self.fail("microphone permission denied", generation: generation)
                    return
                }
                if self.sessionSpeechEngine == .orukeet {
                    self.start(generation: generation)
                    return
                }
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async {
                        guard self.session.id == generation,
                              self.session.phase == .awaitingAccess else { return }
                        guard status == .authorized else {
                            self.fail("speech recognition permission unavailable", generation: generation)
                            return
                        }
                        self.start(generation: generation)
                    }
                }
            }
        }
    }


    /*
    Checks that the kept-open microphone starts the hardware once, keeps delivering
    samples between talks and after a finish, and stops when keeping it open is turned
    off. Passes only when all seven checks ran and passed.
    */
    /// Explicit local microphone proof: writes lifecycle booleans/counts only.
    @MainActor func runAmbientLifecycleProof(output: String) async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            let result: [String: Any] = ["passed": false, "skipped": true,
                "reason": "existing microphone and speech permissions required; no prompt requested"]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            return
        }
        var checks: [String: Bool] = [:]
        func ready() async -> Bool {
            for _ in 0..<100 {
                if captureError != nil { return false }
                if isRecording && hasReceivedAudio && hasRecentHardwareSamples { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        keepMicrophoneOpenWhileIdle(true)
        requestAccessAndStart(localOnly: true)
        checks["initial_samples"] = await ready()
        let initialStarts         = hardwareStarts
        if checks["initial_samples"] == true {
            discardCapture()
            try? await Task.sleep(nanoseconds: 200_000_000)
            checks["samples_between_recognizers"] = hasRecentHardwareSamples
            requestAccessAndStart(localOnly: true)
            checks["replacement_samples"] = await ready()
            checks["one_hardware_start"]  = hardwareStarts == initialStarts && initialStarts == 1
            if isRecording {
                var finished = false
                finishImmediately { _ in finished = true }
                for _ in 0..<50 {
                    if finished || captureError != nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                checks["samples_after_finalization"]    = finished && captureError == nil && hasRecentHardwareSamples
                checks["no_hardware_restart_at_finish"] = finished && captureError == nil && hardwareStarts == initialStarts
            }
        }
        keepMicrophoneOpenWhileIdle(false)
        discardCapture()
        var confirmedStopped = false
        hardwareOwner.stop(stopHardware: true) { confirmedStopped = true }
        for _ in 0..<30 {
            if confirmedStopped { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        checks["pause_stops_hardware"] = confirmedStopped
        let error = captureError
        let result: [String: Any] = ["checks": checks, "passed": checks.count == 7 && checks.values.allSatisfy { $0 },
                                    "hardware_starts": hardwareStarts, "error": error ?? "",
                                    "scope": "actual microphone lifecycle; no transcript or audio stored; no destination delivery"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

//
// :)
//
//
    /*
    macOS 26 only: get the speech model ready ahead of time so the first talk does not
    wait for it. Logs the result; a failure here does not block talking.
    */
    func prewarmRecognition() {
        guard session.id == nil else { return }
        speechPrewarmTask?.cancel()
        let choice = SpeechEngineChoice.load()
        if choice == .orukeet, SpeechEngineChoice.waitingForOrukeet() {
            speechEngineStatus = "\(LocalSpeechModelName.current) · waiting for model"
            return
        }
        speechEngineStatus = choice == .orukeet ? "Loading \(LocalSpeechModelName.current) on this Mac…" : "Apple · on this Mac"
        speechPrewarmTask = Task { @MainActor [weak self] in
            do {
                if choice == .orukeet {
                    do { try await OrukeetSpeechPipeline.prewarm() }
                    catch OrukeetFailure.canceled where !Task.isCancelled && SpeechEngineChoice.load() == .orukeet {
                        /*
                        A newer pick replaced this load (a second model chosen while the first
                        loaded). Wait for that load and report it, instead of "unavailable ·
                        canceled" for a model that is fine (build 81).
                        */
                        try await OrukeetSpeechPipeline.prewarm()
                    }
                } else {
                    await OrukeetSpeechPipeline.unloadIfIdle()
                    if #available(macOS 26.0, *) { try await ModernSpeechPipeline.prepareAssets() }
                }
                guard !Task.isCancelled, SpeechEngineChoice.load() == choice else { return }
                self?.speechEngineStatus = choice == .orukeet ? "\(LocalSpeechModelName.current) · ready on this Mac" : "Apple · on this Mac"
                Diagnostics.event("speech_prewarm_ready engine=\(choice.rawValue)")
            } catch {
                guard !Task.isCancelled, SpeechEngineChoice.load() == choice else { return }
                self?.speechEngineStatus = choice == .orukeet ? "\(LocalSpeechModelName.current) unavailable · \(error.localizedDescription)" : "Apple speech unavailable"
                Diagnostics.event("speech_prewarm_failed engine=\(choice.rawValue)")
            }
        }
    }

    /// The idle listener's recognizer: never Orukeet; nil means level only (no words).
    static func idleListenerEngine(selected: SpeechEngineChoice, speechAuthorized: Bool) -> SpeechEngineChoice? {
        selected == .apple || speechAuthorized ? .apple : nil
    }

    func refreshSpeechEngineStatus() {
        speechEngineStatus = SpeechEngineChoice.load() == .orukeet
            ? "\(LocalSpeechModelName.current) · local model" : "Apple · on this Mac"
    }


    // Recognizers — the fast macOS 26 pipeline first, the older recognizer as fallback


    /*
    Reads the microphone format once; the recognizer is built for it and startEngine
    checks it has not changed in the meantime.
    */
    func start(generation: UUID) {
        guard session.advance(generation, from: .awaitingAccess, to: .starting) else { return }
        prepareHardware(generation: generation) { [weak self] format in
            guard let self, self.session.id == generation, self.session.phase == .starting else { return }
            self.startRecognition(format: format, generation: generation)
        }
    }

    private func startRecognition(format: AVAudioFormat, generation: UUID) {
        /*
        Orukeet: the tap attaches now, never after the model load (about 8 s cold).
        Speech during the load is held as a bounded pre-roll and replayed once the
        worker is ready; releasing the key meanwhile still finishes with every word.
        A load failure ends the talk explicitly; Apple is never substituted.
        */
        if sessionSpeechEngine == .orukeet {
            do {
                let pipeline = try OrukeetSpeechPipeline.start(naturalFormat: format,
                    onFailure: { [weak self] message in
                        guard let self, self.session.id == generation else { return }
                        let starting = message.hasPrefix("\(LocalSpeechModelName.current) could not start")
                        if starting {
                            let reason = message.replacingOccurrences(of: "\(LocalSpeechModelName.current) could not start. ", with: "")
                            self.speechEngineStatus = "\(LocalSpeechModelName.current) unavailable · \(reason)"
                        }
                        self.speechModelLoading = false
                        self.fail(starting ? message : "\(LocalSpeechModelName.current) recognition failed: \(message)", generation: generation)
                    }, onUpdate: { [weak self] snapshot in
                        guard let self, self.session.id == generation else { return }
                        self.timedWords = snapshot.timedWords
                        self.transcript = snapshot.text
                        self.stableWordCount = snapshot.stableWordCount
                    }, onLoaded: { [weak self] in
                        guard let self, self.session.id == generation else { return }
                        self.speechModelLoading = false
                        self.speechEngineStatus = "\(LocalSpeechModelName.current) · ready on this Mac"
                    })
                streamingPipeline = pipeline
                speechModelLoading = pipeline.isLoading
                if speechModelLoading { speechEngineStatus = "Loading \(LocalSpeechModelName.current) on this Mac…" }
                startEngine(format: format, pipeline: pipeline, generation: generation)
            } catch {
                speechEngineStatus = "\(LocalSpeechModelName.current) unavailable · \(error.localizedDescription)"
                fail(OrukeetSpeechPipeline.startFailureMessage(error), generation: generation)
            }
            return
        }

        /*
        Building the pipeline takes time (it may load the speech model). The talk can be
        stopped or replaced meanwhile, so after the wait the generation and phase are
        checked again and an unwanted pipeline is cancelled. Any setup error falls back to
        the older recognizer. A recognizer error mid-talk ends the talk, except while
        finishing, when the drain deadline delivers the words instead.
        */
        if #available(macOS 26.0, *) {
            permissionMessage = "loading fast on-device speech"
            startupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let pipeline = try await ModernSpeechPipeline.make(
                        naturalFormat: format,
                        contextualStrings: self.labSession ? VoiceCommandParser.labRecognitionHints : self.recognitionHints,
                        ambientBufferLimit: self.requiresLocalRecognition ? 32 : nil,
                        onFailure: { [weak self] message in
                            guard let self, self.session.id == generation else { return }
                            self.fail("speech recognition failed: \(message)", generation: generation)
                        }
                    ) { [weak self] snapshot in
                        guard let self, self.session.id == generation else { return }
                        self.timedWords      = snapshot.timedWords
                        self.transcript      = snapshot.text
                        self.stableWordCount = snapshot.stableWordCount
                    }
                    guard self.session.id == generation, self.session.phase == .starting else {
                        pipeline.cancel()
                        return
                    }
                    self.startupTask       = nil
                    self.streamingPipeline = pipeline
                    self.startEngine(
                        format: format,
                        pipeline: pipeline,
                        generation: generation
                    )
                } catch {
                    guard self.session.id == generation,
                          self.session.phase == .starting else { return }
                    print("TTT_EVENT modern_speech_fallback error=\(error)")
                    self.startupTask = nil
                    self.startLegacy(format: format, generation: generation)
                }
            }
            return
        }


        startLegacy(format: format, generation: generation)
    }

//
// :)
//
//
    /*
    The older SFSpeechRecognizer route (macOS 14 and 15, or when the new engine fails to
    start). With no recognizer, a signal session still runs (level only) and a real talk fails.
    Every talk requires on-device recognition; a Mac without it gets a clear failure instead.
    */
    private func startLegacy(
        format: AVAudioFormat,
        generation: UUID
    ) {
        guard let recognizer, recognizer.isAvailable else {
            if signalSession {
                startEngine(format: format, pipeline: nil, generation: generation)
                return
            }
            fail("speech recognition unavailable", generation: generation)
            return
        }
        /*
        Theorem: speech is recognised on this Mac, for every talk, or not at all.
        Trap:    the older recognizer quietly sends audio to Apple's servers when this Mac has no
                 on-device model for the language, unless on-device is required. Before
                 2026-10-04 only background listening required it; a key-press talk could leave
                 the Mac on macOS 14 and 15. The launch promise (README, PRIVACY.md) is on-device.
        */
        guard recognizer.supportsOnDeviceRecognition else {
            fail(requiresLocalRecognition ? "On-device speech unavailable · ambient listening paused"
                                          : "On-device speech unavailable on this Mac",
                 generation: generation)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        /*
        Ask the recognizer to resolve sentence boundaries during recognition,
        without adding a separate model wait to stop-and-paste.
        */
        request.addsPunctuation   = true
        request.taskHint          = .dictation
        request.contextualStrings = labSession ? VoiceCommandParser.labRecognitionHints : recognitionHints
        request.requiresOnDeviceRecognition = true
        speechRequest = request
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text    = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            /*
            The recognizer's own segment times (request audio clock, which
            starts with the tap). Partials often report zero: never used then.
            */
            let timed: [TimedWord] = (result?.bestTranscription.segments ?? []).map {
                TimedWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration, isFinal: isFinal)
            }
            DispatchQueue.main.async {
                guard let self, self.session.id == generation else { return }
                if let text {
                    let beforeCount = self.transcript.split(whereSeparator: { $0.isWhitespace }).count
                    // The tap records every measured pause even when UI meter updates
                    // are coalesced. Do not depend on the display pause counter here.
                    let pauseRevision = self.thinking.snapshot().pausesIncludingCurrent.count
                    let hadAmbiguousReset = self.legacyTranscript.hasAmbiguousReset
                    self.legacyTranscript.apply(text, isFinal: isFinal, words: timed.map {
                        TokensCore.TimedWord(text: $0.text, start: $0.start, end: $0.end, isFinal: $0.isFinal)
                    }, pauseRevision: pauseRevision)
                    if self.legacyTranscript.hasAmbiguousReset && !hadAmbiguousReset {
                        Diagnostics.event("legacy_ambiguous_reset preserve_fragments=true auto_send_suppressed=true")
                    }
                    let snapshot = self.legacyTranscript.snapshot
                    self.timedWords = snapshot.timedWords.map {
                        TimedWord(text: $0.text, start: $0.start, end: $0.end, isFinal: $0.isFinal)
                    }
                    self.transcript = snapshot.text
                    // Legacy partials may revise any word, not just the last.
                    self.stableWordCount = snapshot.stableWordCount
                    Diagnostics.event("legacy_result prior_words=\(beforeCount) incoming_words=\(text.split(whereSeparator: { $0.isWhitespace }).count) retained_words=\(snapshot.text.split(whereSeparator: { $0.isWhitespace }).count) timed=\(timed.contains { $0.end > $0.start }) final=\(isFinal) pause_revision=\(pauseRevision) recovery=\(self.legacyTranscript.failure != nil)")
                    if let failure = self.legacyTranscript.failure {
                        self.fail(failure, generation: generation)
                        return
                    }
                }
                /*
                While finishing, a final result or any error completes the talk with the
                words so far. An error while still recording ends the talk as failed.
                */
                if self.session.phase == .finalizing, isFinal || error != nil {
                    self.finishSegment(generation: generation)
                } else if let error {
                    self.fail("speech recognition failed: \(error.localizedDescription)", generation: generation)
                }
            }
        }


        startEngine(
            format: format,
            pipeline: nil,
            request: request,
            generation: generation
        )
    }


}

