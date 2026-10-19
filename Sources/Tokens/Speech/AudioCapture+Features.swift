


//
/*
AudioCapture+Features.swift

Owns: Measured feature publication, level history, and sound-segment tracking.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Hardware.swift
         AudioCapture+Signal.swift
         AudioCapture+Recognition.swift
         AudioCapture+Finish.swift
         AudioCapture+Demo.swift
         AudioCapture+Measurement.swift
Port provenance: Sources/Audio/TTTAudioCapture.swift, donor 2ac14df.
*/


import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech


extension AudioCapture {


    // Feature update — on main for each measured buffer: features, sound segments, meter


    /*
    Turns one measurement into the published features, the running averages for the
    current sound segment, the lab sound class, sound-segment ends, and the meter and
    waveform. onset is the rise in level since the previous buffer; modulation is the
    spread of level over the last 24 buffers.
    */
    func consume(_ measurement: Measurement) {
        let rmsDB     = measurement.rmsDB, peakDB = measurement.peakDB
        let zcr       = measurement.zcr, brightness = measurement.brightness
        let crest     = measurement.crest, pitch = measurement.pitch
        let duration  = Date().timeIntervalSince(startedAt ?? Date())
        let onset     = previousRMSDB > -79 ? max(0, rmsDB - previousRMSDB) : 0
        previousRMSDB = rmsDB
        rmsHistory.append(rmsDB)
        if rmsHistory.count > 24 { rmsHistory.removeFirst(rmsHistory.count - 24) }
        let mean     = rmsHistory.reduce(0, +) / Double(max(1, rmsHistory.count))
        let variance = rmsHistory.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(1, rmsHistory.count))
        let frame = AudioFeatures(
            rmsDBFS: rmsDB,
            peakDBFS: peakDB,
            zeroCrossingRate: zcr,
            brightness: brightness,
            modulation: sqrt(variance),
            durationSeconds: duration,
            crestFactor: crest,
            pitchHz: pitch.hz,
            pitchConfidence: pitch.confidence,
            onsetStrength: onset
        )


        /*
        Running means for level, zero crossings, brightness and crest; peak, modulation,
        onset and pitch confidence keep their highest value. Pitch is kept only when
        confidence is above 0.45.
        */
        aggregateCount += 1
        let n = aggregateCount
        aggregate = AudioFeatures(
            rmsDBFS: aggregate.rmsDBFS + (frame.rmsDBFS - aggregate.rmsDBFS) / n,
            peakDBFS: max(aggregate.peakDBFS, frame.peakDBFS),
            zeroCrossingRate: aggregate.zeroCrossingRate + (frame.zeroCrossingRate - aggregate.zeroCrossingRate) / n,
            brightness: aggregate.brightness + (frame.brightness - aggregate.brightness) / n,
            modulation: max(aggregate.modulation, frame.modulation),
            durationSeconds: duration,
            crestFactor: (aggregate.crestFactor ?? frame.crestFactor ?? 1) + ((frame.crestFactor ?? 1) - (aggregate.crestFactor ?? frame.crestFactor ?? 1)) / n,
            pitchHz: pitch.confidence > 0.45 ? pitch.hz : aggregate.pitchHz,
            pitchConfidence: max(aggregate.pitchConfidence ?? 0, pitch.confidence),
            onsetStrength: max(aggregate.onsetStrength ?? 0, onset)
        )


        /*
        Lab sound class shown on screen: a newly heard class stays up at least 0.52 s
        before a different class or silence may replace it.
        */
        let now          = Date()
        let rawCandidate = labSession ? Interpreter.interpret(frame).candidate : .silence
        if rawCandidate != .silence {
            if displayedCandidate == .silence || rawCandidate == displayedCandidate || now >= candidateHoldUntil {
                displayedCandidate = rawCandidate
                candidateHoldUntil = now.addingTimeInterval(0.52)
            }
        } else if now >= candidateHoldUntil {
            displayedCandidate = .silence
        }
        let candidateForUI = displayedCandidate
        /*
        Sound segments: one starts at the first buffer above -48 dB (and restarts the
        averages). It ends after more than 0.9 s without sound, if it lasted over 0.35 s,
        once every word is final or after 2.5 s of quiet regardless. Voice command words
        are attached only when all words are final and unchanged for 0.3 s.
        */
        if frame.rmsDBFS > -48 {
            if segmentStartedAt == nil {
                segmentStartedAt = now
                aggregateCount   = 1
                aggregate        = frame
            }
            lastSignalAt = now
        }
        let signalActive = lastSignalAt.map { now.timeIntervalSince($0) < 0.28 } ?? false
        if let segmentStart = segmentStartedAt,
           let lastSignal = lastSignalAt,
           now.timeIntervalSince(lastSignal) > 0.90,
           now.timeIntervalSince(segmentStart) > 0.35,
           (stableWordCount >= transcript.split(whereSeparator: { $0.isWhitespace }).count
                || now.timeIntervalSince(lastSignal) > 2.5) {
            let utterance     = utterances.consume(transcript)
            let hasFinalWords = stableWordCount >= transcript.split(whereSeparator: { $0.isWhitespace }).count
            let commandReady  = hasFinalWords && now.timeIntervalSince(transcriptChangedAt) > 0.30
            let completed = CompletedSegment(
                id: UUID(),
                features: aggregate,
                transcript: transcript,
                commandUtterance: commandReady ? utterance?.text : nil,
                transcriptBeforeCommand: commandReady ? utterance?.precedingTranscript : nil,
                captureGeneration: session.id
            )
            segmentStartedAt = nil
            lastSignalAt     = nil
            aggregateCount   = 0
            aggregate        = .silence
            completedSegment = completed
            isSignalActive   = false
        }


        features             = frame
        isSignalActive       = signalActive
        liveCandidate        = candidateForUI
        let waveformCapacity = waveform.count
        /*
        One RMS point per analyzed audio buffer: an actual history across time,
        rather than repeatedly replacing the graph with a decorative sine.
        */
        waveform.removeFirst(min(1, waveformCapacity))
        inputLevel = inputMeter.observe(rmsDBFS: frame.rmsDBFS, at: ProcessInfo.processInfo.systemUptime)
        waveform.append(inputLevel)
    }


}

