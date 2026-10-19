


//
/*
AudioCapture+Demo.swift

Owns: Synthetic demonstration signal and the per-talk reset shared by real capture.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Hardware.swift
         AudioCapture+Signal.swift
         AudioCapture+Recognition.swift
         AudioCapture+Finish.swift
         AudioCapture+Measurement.swift
         AudioCapture+Features.swift
Port provenance: Sources/Audio/TTTAudioCapture.swift, donor 2ac14df.
*/


import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech


extension AudioCapture {


    // Demo mode — synthetic level and words for screen recordings (--demo), no microphone


    /*
    A fixed sentence and a made-up level every 55 ms. For the first 7 s no sound class is
    shown; then each benchmark sound class shows for 0.72 s of every 0.92 s. At 17.4 s one
    completed segment is published and the demo stops.
    */
    func startDemo() {
        resetSession()
        startedAt         = Date()
        isRecording       = true
        permissionMessage = "demo signal · no microphone claim"
        transcript        = "TTT arrow chord proof lands exactly once."
        var tick          = 0
        let demoClasses   = Candidate.benchmarkClasses
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.055, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            let phase    = Double(tick) * 0.41
            let envelope = 0.22 + 0.66 * abs(sin(phase * 0.23))
            let rms      = -42 + envelope * 27 + sin(phase) * 3.5
            let peak     = min(-2, rms + 8)
            let zcr      = 0.055 + abs(sin(phase * 0.57)) * 0.075
            let duration = Date().timeIntervalSince(self.startedAt ?? Date())
            /*
            ScreenCaptureKit takes several seconds to attach to a new native window.
            Keep proof mode quiet long enough that its watched recording includes class one.
            */
            let demoElapsed          = max(0, duration - 7.0)
            let demoSlot             = Int(demoElapsed / 0.92)
            let slotProgress         = demoElapsed.truncatingRemainder(dividingBy: 0.92)
            let candidate: Candidate = duration >= 7.0 && demoSlot < demoClasses.count && slotProgress < 0.72
                ? demoClasses[demoSlot]
                : .silence
            let frame = AudioFeatures(
                rmsDBFS: rms,
                peakDBFS: peak,
                zeroCrossingRate: zcr,
                brightness: 0.10 + abs(cos(phase)) * 0.18,
                modulation: 3.8 + abs(sin(phase * 0.31)) * 5.2,
                durationSeconds: duration
            )
            self.aggregateCount += 1
            let n = self.aggregateCount
            self.aggregate = AudioFeatures(
                rmsDBFS: self.aggregate.rmsDBFS + (frame.rmsDBFS - self.aggregate.rmsDBFS) / n,
                peakDBFS: max(self.aggregate.peakDBFS, frame.peakDBFS),
                zeroCrossingRate: self.aggregate.zeroCrossingRate + (frame.zeroCrossingRate - self.aggregate.zeroCrossingRate) / n,
                brightness: self.aggregate.brightness + (frame.brightness - self.aggregate.brightness) / n,
                modulation: max(self.aggregate.modulation, frame.modulation),
                durationSeconds: duration
            )
            self.features      = frame
            self.liveCandidate = candidate
            self.waveform.removeFirst(6)
            var demoSamples: [Double] = []
            for sample in 0..<6 {
                let wave  = abs(sin(phase + Double(sample) * 0.7))
                let value = min(1.0, envelope * (0.35 + 0.65 * wave))
                demoSamples.append(value)
            }
            self.waveform.append(contentsOf: demoSamples)
            self.isSignalActive = candidate != .silence
            if duration >= 17.4 && !self.emittedDemoSegment {
                self.emittedDemoSegment = true
                self.completedSegment = CompletedSegment(
                    id: UUID(),
                    features: self.aggregate,
                    transcript: self.transcript
                )
                self.demoTimer?.invalidate()
                self.demoTimer         = nil
                self.isRecording       = false
                self.permissionMessage = ""
                self.liveCandidate     = .silence
                self.isSignalActive    = false
            }
        }
    }

//
// :)
//
//
    // Reset — clear every per-talk value before a new talk or after a discard


    func resetSession() {
        startedAt = nil
        stopReadiness.reset()
        thinking.reset()
        thinkingAnchors          = ThinkingArrivalAnchors()
        timedWords               = []
        legacyTranscript         = .init()
        hasReceivedAudio         = false
        stopRequestedAt          = nil
        stopDecision             = nil
        displayQuietStart        = nil
        displayPauseEmitted      = false
        displayLastAudioEnd      = 0
        requiresLocalRecognition = false
        signalSession            = false
        labSession               = false
        labCommands              = LabCommandTracker()
        labCommand               = nil
        utterances               = CommandUtteranceTracker()
        transcriptChangedAt      = .distantPast
        voiceCommandsAvailable   = false
        captureError             = nil
        completedSegment         = nil
        transcript               = ""
        stableWordCount          = 0
        waveform                 = Array(repeating: 0.0, count: 96)
        inputMeter               = InputMeter()
        inputLevel               = 0
        features                 = .silence
        rmsHistory               = []
        aggregateCount           = 0
        aggregate                = .silence
        segmentStartedAt         = nil
        lastSignalAt             = nil
        isSignalActive           = false
        liveCandidate            = .silence
        displayedCandidate       = .silence
        candidateHoldUntil       = .distantPast
        previousRMSDB            = -80
        emittedDemoSegment       = false
    }


}

