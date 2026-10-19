


//
/*
AudioCapture+Hardware.swift

Owns: Input-device changes, engine setup, tap routing, and hardware teardown.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Signal.swift
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


extension AudioCapture {


    // Device changes — end the talk and rebuild the engine when the system input changes


    // Several change notices in a row become one: each new notice restarts a 100 ms wait.
    func scheduleInputChange() {
        routeChangeWork?.cancel()
        let work        = DispatchWorkItem { [weak self] in self?.handleInputChange() }
        routeChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }


    /*
    A device change ends the current talk (no paste; the latest words stay visible for
    copying) and rebuilds the engine for the new input. Ignored while asleep.
    */
    private func handleInputChange() {
        routeChangeWork = nil
        guard !suspended else { return }
        interruptCapture(message: "Microphone changed. Copy latest, then tap to resume.")
        refreshInputDevice()
        Diagnostics.event("microphone_route_changed")
    }


    func interruptCapture(message: String) {
        stopEngineCapture(force: true)
        if let generation = session.id {
            // Recover the latest canonical words; changing devices never pastes.
            if let snapshot = streamingPipeline?.currentSnapshot {
                timedWords      = snapshot.timedWords
                transcript      = snapshot.text
                stableWordCount = snapshot.stableWordCount
            }
            fail(message, generation: generation)
        }
    }


    /*
    Always disconnects the current talk from the tap. The hardware itself is stopped and
    the tap removed only when forced, or when the mic is not being kept open.
    */
    func stopEngineCapture(force: Bool = false, completion: (() -> Void)? = nil) {
        hardwareStartupDeadline?.cancel()
        hardwareStartupDeadline = nil
        if force || !keepMicrophoneOpen { hardwareRunning = false }
        let alreadyQuiescent = hardwareOwner.isQuiescent
        hardwareOwner.stop(stopHardware: force || !keepMicrophoneOpen,
                           completion: alreadyQuiescent ? nil : completion)
        if alreadyQuiescent { completion?() }
    }

    /// Startup deadline never queries, stops, or waits for hardware on main.
    func prepareHardware(generation: UUID, ready: @escaping (AVAudioFormat) -> Void) {
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.session.id == generation, self.session.phase == .starting else { return }
            self.fail("Microphone startup timed out. Copy latest; retry when the device is ready.", generation: generation)
        }
        hardwareStartupDeadline?.cancel()
        hardwareStartupDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + hardwareStartupTimeout, execute: deadline)
        let accepted = hardwareOwner.prepare(generation: generation) { [weak self] result in
            guard let self, self.session.id == generation, self.session.phase == .starting else { return }
            switch result {
            case .success(let format): ready(format)
            case .failure: self.fail("Microphone unavailable. Tap to retry.", generation: generation)
            }
        }
        if !accepted { fail("Microphone is still finishing a hardware operation. Tap to retry later.", generation: generation) }
    }

    /// Finish reads canonical words only after the previous audio consumer is quiescent.
    /// A stuck consumer fails closed after a bounded wait; it can never emit a late segment.
    func quiesceForFinish(_ body: @escaping () -> Void) {
        guard let generation = session.id, quiescingGeneration == nil else { return }
        quiescingGeneration = generation
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.session.id == generation, self.quiescingGeneration == generation else { return }
            self.quiescingGeneration = nil
            self.fail("Microphone did not stop in time. Copy latest.", generation: generation)
        }
        quiescenceDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
        stopEngineCapture { [weak self] in
            guard let self, self.session.id == generation, self.quiescingGeneration == generation else { return }
            self.quiescenceDeadline?.cancel(); self.quiescenceDeadline = nil
            self.quiescingGeneration = nil
            body()
        }
    }

//
// :)
//
//
    /*
    Does nothing while a talk is active. A fresh AVAudioEngine is made so it binds to the
    current default input; its configuration-change notice also leads to scheduleInputChange.
    */
    /// Rebuild the idle engine so the next capture picks up the current system input.
    /// Merely querying the device does not start microphone capture.
    func refreshInputDevice() {
        guard session.id == nil else { return }
        routeChangeWork?.cancel()
        routeChangeWork = nil
        stopEngineCapture(force: true)
        hardwareOwner.stop(stopHardware: true, reset: true)
        inputMeter      = InputMeter()
        inputLevel      = 0
        waveform        = Array(repeating: 0, count: 96)
        // Device-name IPC can stall too. Coalesce it away from main; never use it
        // to authorize hardware startup or an engine-format assumption.
        if !deviceNameReadPending {
            deviceNameReadPending = true
            let revision = UUID(); deviceNameRevision = revision
            deviceNameQueue.async { [weak self] in
                let name = Self.defaultInputName()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.deviceNameRevision == revision else { return }
                    self.deviceNameReadPending = false
                    self.inputDeviceName = name
                }
            }
        }
        Diagnostics.event("microphone_refreshed")
    }


    static func defaultInputName() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size   = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return "No microphone connected" }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return "System microphone" }
        return name.takeRetainedValue() as String
    }


    // Engine start — connect the tap; feed the recognizer, pause trackers and level analysis


    /*
    Last checks before the microphone goes live: still this talk, still starting, and the
    input format still the one the recognizer was built for. A changed format ends the
    talk ("Tap to retry") and rebuilds the engine.
    */
    func startEngine(
        format: AVAudioFormat,
        pipeline: StreamingSpeechPipeline?,
        request: SFSpeechAudioBufferRecognitionRequest? = nil,
        generation: UUID
    ) {
        guard session.id == generation, session.phase == .starting else {
            pipeline?.cancel()
            return
        }

        // One audio buffer feeds recognition, pause timing and the display


        /*
        This closure runs on the audio thread for every buffer. audioElapsed is this talk's
        audio clock: seconds of audio since the talk was connected to the tap. Stop
        readiness, thinking pauses and the recognizer get every buffer, in that order.
        Level analysis then takes a copy if the analysis slot is free (see analysisSlot),
        measures it on the analysis queue, and applies the result on main; the slot is
        released on main once that is done.
        */
        let classifySounds = labSession
        var audioElapsed   = 0.0
        let sink: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            audioElapsed += Double(buffer.frameLength) / buffer.format.sampleRate
            let audioEnd = audioElapsed
            let arrived  = ProcessInfo.processInfo.systemUptime
            self?.stopReadiness.observe(buffer: buffer, at: arrived)
            self?.thinking.observe(buffer: buffer, end: audioEnd, host: arrived)
            request?.append(buffer)
            pipeline?.append(buffer)
            /*
            Recognition and pause timing already received this buffer above. If display
            analysis is still busy, skip only that extra analysis; never wait here and hold
            up the real-time microphone callback. A copied buffer can outlive this callback.
            */
            guard let self, self.analysisSlot.wait(timeout: .now()) == .success else { return }
            guard let copy = ModernAudioBuffer.copy(buffer) else { self.analysisSlot.signal(); return }
            self.analysisQueue.async { [weak self] in
                guard let self else { return }
                let measurement = Self.measure(copy, includePitch: classifySounds)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.analysisSlot.signal() }
                    guard self.session.id == generation, self.session.phase == .recording,
                          let measurement else { return }
                    self.hasReceivedAudio = true
                    self.consume(measurement)
                    /*
                    speechPauseRevision: a quiet run (under -48 dB) longer than 1 s bumps it
                    once. A jump in the audio clock (a gap over 0.1 s, or going backwards)
                    starts the run over, since missing audio is not silence.
                    */
                    let audioStart = audioEnd - Double(copy.frameLength) / copy.format.sampleRate
                    if audioStart - self.displayLastAudioEnd > 0.1 || audioEnd < self.displayLastAudioEnd {
                        self.displayQuietStart   = nil
                        self.displayPauseEmitted = false
                    }
                    self.displayLastAudioEnd = audioEnd
                    if measurement.rmsDB < -48 {
                        if self.displayQuietStart == nil { self.displayQuietStart = audioStart }
                        if !self.displayPauseEmitted, audioEnd - (self.displayQuietStart ?? audioEnd) > 1 {
                            self.displayPauseEmitted = true
                            self.speechPauseRevision += 1
                        }
                    } else {
                        self.displayQuietStart   = nil
                        self.displayPauseEmitted = false
                    }


                }
            }
        }


        /*
        The engine is started only if it is not already running; a kept-open microphone
        reuses the running engine and its tap. Any old tap is removed before installing.
        */
        let accepted = hardwareOwner.start(generation: generation, format: format, sink: sink) { [weak self] result in
            guard let self, self.session.id == generation, self.session.phase == .starting else { return }
            switch result {
            case .success(let didStart):
                self.hardwareStartupDeadline?.cancel(); self.hardwareStartupDeadline = nil
                if didStart { self.hardwareStarts += 1 }
                self.hardwareRunning = true
                self.startedAt = Date()
                _ = self.session.advance(generation, from: .starting, to: .recording)
                self.isRecording = true
                self.voiceCommandsAvailable = pipeline != nil || request != nil
                if self.voiceCommandsAvailable { self.startLabCommandPolling(generation: generation) }
                Diagnostics.event("capture_format sample_rate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
                self.permissionMessage = pipeline.map { "live · \($0.engineIdentity == "orukeet" ? "Orukeet" : "Apple SpeechTranscriber fast")" }
                    ?? (request != nil ? "live · Apple speech fallback" : "live · voice lab")
                Diagnostics.event("recognition_started engine=\(pipeline?.engineIdentity ?? (request != nil ? "apple_legacy" : "signal"))")
            case .failure:
                self.fail("Microphone startup failed. Tap to retry.", generation: generation)
            }
        }
        if !accepted { fail("Microphone is still finishing a hardware operation. Tap to retry later.", generation: generation) }
    }


}

