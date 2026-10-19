


//
/*
AudioCapture+Signal.swift

Owns: Level-only and lab capture entry points and command polling.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Hardware.swift
         AudioCapture+Recognition.swift
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


    // Lab and signal sessions — microphone level and voice commands, never delivery


    // A segment or command counts only if it came from the session that is recording now.
    func isCurrentCommandSegment(_ segment: CompletedSegment) -> Bool {
        segment.captureGeneration != nil && segment.captureGeneration == session.id
            && session.phase == .recording
    }


    func isCurrentLabCommand(_ event: LabCommandEvent) -> Bool {
        labSession && event.captureGeneration == session.id && session.phase == .recording
    }


    // Lab only: every 100 ms, look at the live words for a voice command.
    func startLabCommandPolling(generation: UUID) {
        guard labSession else { return }
        labCommandTimer?.invalidate()
        labCommandTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self, self.session.id == generation, self.session.phase == .recording else { return }
            let now = Date.timeIntervalSinceReferenceDate
            self.labCommands.observe(self.transcript, at: now)
            if let command = self.labCommands.poll(at: now) {
                print("TTT_EVENT lab_command command=\(command.rawValue)")
                self.labCommand = LabCommandEvent(id: UUID(), command: command, captureGeneration: generation)
            }
        }
    }


    /// The lab uses the same capture owner without requiring speech assets or
    /// speech permission. Its observations never authorize dictation delivery.
    func requestAccessAndStartSignal(voiceCommands: Bool = false, labMode: Bool = false) {
        guard !suspended, let generation = session.begin() else { return }
        resetSession()
        sessionSpeechEngine = SpeechEngineChoice.load()
        hardwareStartupTimeout = 8 // An Orukeet load runs behind the tap, not inside this guard.
        signalSession = true
        labSession    = labMode
        if demoMode {
            _ = session.advance(generation, from: .awaitingAccess, to: .recording)
            startDemo()
            return
        }
        permissionMessage = "requesting microphone access"
        /*
        Microphone permission first. Speech permission is asked only for voice commands;
        without it the session still runs, level only.
        */
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.session.id == generation,
                      self.session.phase == .awaitingAccess else { return }
                guard granted else {
                    self.fail("microphone permission denied", generation: generation)
                    return
                }
                if voiceCommands {
                    if self.sessionSpeechEngine == .orukeet {
                        self.start(generation: generation)
                        return
                    }
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async {
                            guard self.session.id == generation, self.session.phase == .awaitingAccess else { return }
                            if status == .authorized { self.start(generation: generation) }
                            else { self.startSignalOnly(generation: generation) }
                        }
                    }
                } else {
                    self.startSignalOnly(generation: generation)
                }
            }
        }
    }

//
// :)
//
//
    private func startSignalOnly(generation: UUID) {
        guard session.advance(generation, from: .awaitingAccess, to: .starting) else { return }
        prepareHardware(generation: generation) { [weak self] format in
            guard let self, self.session.id == generation, self.session.phase == .starting else { return }
            self.startEngine(format: format, pipeline: nil, generation: generation)
        }
    }


}

