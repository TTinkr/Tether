


//
/*
AudioCapture+Measurement.swift

Owns: Pure buffer measurement and pitch estimation on the analysis queue.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture.swift
         AudioCapture+Hardware.swift
         AudioCapture+Signal.swift
         AudioCapture+Recognition.swift
         AudioCapture+Finish.swift
         AudioCapture+Demo.swift
         AudioCapture+Features.swift
Port provenance: Sources/Audio/TTTAudioCapture.swift, donor 2ac14df.
*/


import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech


extension AudioCapture {


    // Buffer measurement — level, peak and brightness of one buffer, on the analysis queue


    /*
    Runs on the analysis queue with a private copy of the buffer. Measures only the
    loudest channel. Pitch is estimated only in the lab.
    */
    static func measure(_ buffer: AVAudioPCMBuffer, includePitch: Bool) -> Measurement? {
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 1, buffer.format.channelCount > 0 else { return nil }
        // A stereo interface may carry the microphone only on the right channel.
        let loudest = (0..<Int(buffer.format.channelCount)).max { lhs, rhs in
            func energy(_ index: Int) -> Double {
                (0..<count).reduce(0) { $0 + Double(channels[index][$1]) * Double(channels[index][$1]) }
            }
            return energy(lhs) < energy(rhs)
        } ?? 0
        let channel = channels[loudest]


        var sum               = 0.0
        var peak              = 0.0
        var crossings         = 0
        var deltaSum          = 0.0
        var previous          = Double(channel[0])
        var samples: [Double] = []
        let strideSize        = max(1, count / 12)
        for index in 0..<count {
            let value = Double(channel[index])
            sum += value * value
            peak = max(peak, abs(value))
            if (value >= 0) != (previous >= 0) { crossings += 1 }
            deltaSum += abs(value - previous)
            previous = value
            if index % strideSize == 0 { samples.append(min(1, abs(value) * 5)) }
        }
        let rms = sqrt(sum / Double(count))
        let rmsDB = 20 * log10(max(rms, 0.0001))
        let peakDB = 20 * log10(max(peak, 0.0001))
        let zcr = Double(crossings) / Double(count)
        let brightness = min(1, deltaSum / Double(count) * 8)
        let crest = peak / max(rms, 0.0001)
        let pitch: (hz: Double, confidence: Double) = includePitch
            ? estimatePitch(channel: channel, count: count, sampleRate: buffer.format.sampleRate) : (0, 0)


        return Measurement(rmsDB: rmsDB, peakDB: peakDB, zcr: zcr, brightness: brightness,
                           crest: crest, pitch: pitch, samples: samples)
    }

//
// :)
//
//
    struct Measurement {
        let rmsDB: Double
        let peakDB: Double
        let zcr: Double
        let brightness: Double
        let crest: Double
        let pitch: (hz: Double, confidence: Double)
        let samples: [Double]
    }


    // Pitch estimate — lab only; autocorrelation over a quarter-rate copy of the buffer


    /*
    Keeps every 4th sample, removes the average, then finds the lag (roughly 75 to 1800 Hz)
    where the signal best matches a shifted copy of itself. Returns that pitch and the
    match strength (0...1) as confidence, or (0, 0) when no pitch can be found.
    */
    private static func estimatePitch(
        channel: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double
    ) -> (hz: Double, confidence: Double) {
        let decimation  = 4
        let sampleCount = count / decimation
        guard sampleCount >= 96, sampleRate > 0 else { return (0, 0) }


        var values = [Double]()
        values.reserveCapacity(sampleCount)
        for index in stride(from: 0, to: count, by: decimation) {
            values.append(Double(channel[index]))
        }
        let mean = values.reduce(0, +) / Double(values.count)
        for index in values.indices { values[index] -= mean }


        let reducedRate = sampleRate / Double(decimation)
        let minLag      = max(2, Int(reducedRate / 1_800))
        let maxLag      = min(values.count / 2, Int(reducedRate / 75))
        guard maxLag > minLag else { return (0, 0) }


        var bestLag         = 0
        var bestCorrelation = 0.0
        for lag in minLag...maxLag {
            var dot         = 0.0
            var leftEnergy  = 0.0
            var rightEnergy = 0.0
            for index in 0..<(values.count - lag) {
                let left  = values[index]
                let right = values[index + lag]
                dot += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            let denominator = sqrt(leftEnergy * rightEnergy)
            let correlation = denominator > 0 ? dot / denominator : 0
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag         = lag
            }
        }
        guard bestLag > 0 else { return (0, 0) }
        return (reducedRate / Double(bestLag), min(1, max(0, bestCorrelation)))
    }


}

