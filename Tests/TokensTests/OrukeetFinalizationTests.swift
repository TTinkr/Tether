import AVFoundation
import Foundation
import Testing
import TokensCore
@testable import Tokens

private final class ExplicitFinalPipeline: StreamingSpeechPipeline, AbandonableFinish {
    let requiresExplicitFinalization = true
    let finalizationTimeout: TimeInterval = 0.1
    var currentSnapshot = Tokens.TranscriptSnapshot(finalizedText: "Fictional provisional orchard", volatileText: "")
    var failure: String?
    var currentResult: (snapshot: Tokens.TranscriptSnapshot, failure: String?) { (currentSnapshot, failure) }
    var finishCalls = 0
    var callback: ((Tokens.TranscriptSnapshot) -> Void)?
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish(completion: @escaping (Tokens.TranscriptSnapshot) -> Void) { finishCalls += 1; callback = completion }
    var events: [String] = []
    func abandonFinish() { events.append("abandon") }
    func cancel() { events.append("cancel") }
}

private final class FinalizationHardware: AudioHardwareBackend {
    func format() throws -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)! }
    func start(format: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void, current: () -> Bool) throws -> Bool { true }
    func detach(stop: Bool) {}
    func reset() {}
}

@MainActor @Suite(.serialized) struct OrukeetFinalizationTests {
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(predicate())
    }

    private func recording() throws -> (AudioCapture, ExplicitFinalPipeline) {
        let audio = AudioCapture()
        audio.hardwareOwner = AudioHardwareOwner { _ in FinalizationHardware() }
        let began = audio.session.begin()
        let generation = try #require(began)
        let advanced = audio.session.advance(generation, from: .awaitingAccess, to: .recording)
        #expect(advanced)
        let pipeline = ExplicitFinalPipeline()
        audio.streamingPipeline = pipeline
        audio.isRecording = true
        audio.transcript = "Older UI snapshot"
        return (audio, pipeline)
    }

    @Test(arguments: ["immediate", "fast", "quietAdaptive"])
    func everyFastPathRequiresFinalCallback(mode: String) async throws {
        let (audio, pipeline) = try recording()
        var outputs: [String] = []
        let complete: (CompletedSegment) -> Void = { outputs.append($0.transcript) }
        if mode == "quietAdaptive" {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6400))
            silence.frameLength = 6400
            silence.floatChannelData![0].initialize(repeating: 0, count: 6400)
            audio.stopReadiness.observe(buffer: silence, at: ProcessInfo.processInfo.systemUptime)
            #expect(audio.stopReadiness.decision(at: ProcessInfo.processInfo.systemUptime, transcriptFinalized: true).graceSeconds == 0)
            audio.finishAdaptively(completion: complete)
        } else if mode == "fast" { audio.finishForPaste(timing: .fast, completion: complete) }
        else { audio.finishImmediately(completion: complete) }
        try await until { pipeline.finishCalls == 1 }
        #expect(outputs.isEmpty)
        let final = Tokens.TranscriptSnapshot(finalizedText: "Fictional final orchard note", volatileText: "")
        pipeline.currentSnapshot = final
        pipeline.callback?(final)
        pipeline.callback?(final)
        #expect(outputs == [final.text])
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(outputs.count == 1)
        #expect(audio.captureError == nil)
    }

    @Test(arguments: [false, true])
    func failureOrDeadlineKeepsCanonicalTextWithoutCompletion(callbackFailure: Bool) async throws {
        let (audio, pipeline) = try recording()
        var completions = 0
        audio.finishImmediately { _ in completions += 1 }
        try await until { pipeline.finishCalls == 1 }
        let latest = Tokens.TranscriptSnapshot(finalizedText: "Latest fictional recovery words", volatileText: "")
        pipeline.currentSnapshot = latest
        if callbackFailure {
            pipeline.failure = "Fictional model finalization failure"
            pipeline.callback?(latest)
        }
        try await until { audio.captureError != nil }
        #expect(audio.transcript == latest.text)
        #expect(completions == 0)
        #expect(audio.session.id == nil)
        pipeline.callback?(latest)
        #expect(completions == 0)
        #expect(audio.transcript == latest.text)
        // Build 81: only the deadline abandons the late worker, and before cleanup cancels it.
        #expect(pipeline.events == (callbackFailure ? ["cancel"] : ["abandon", "cancel"]))
    }

    @Test func discardFencesLateCallbackFromNextSession() async throws {
        let (audio, pipeline) = try recording()
        var completions = 0
        audio.finishImmediately { _ in completions += 1 }
        try await until { pipeline.finishCalls == 1 }
        audio.discardCapture()
        let began = audio.session.begin()
        let next = try #require(began)
        audio.transcript = "Separate fictional next session"
        pipeline.callback?(Tokens.TranscriptSnapshot(finalizedText: "Stale final result", volatileText: ""))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(completions == 0)
        #expect(audio.session.id == next)
        #expect(audio.transcript == "Separate fictional next session")
        #expect(audio.captureError == nil)
        audio.discardCapture()
    }
}
