import Foundation
import AVFoundation
import Testing
@testable import Tokens

/// Exercises the real capture stop paths without opening a microphone or pasting.
@MainActor @Suite struct PasteStopModeTests {
    @Test func legacyAmbiguityReachesBothFallbackAndCompletedSegment() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        _ = try #require(started)
        audio.legacyTranscript.apply("Earlier words", isFinal: false, words: [])
        audio.legacyTranscript.apply("Later words", isFinal: false, words: [], pauseRevision: 1)
        audio.transcript = audio.legacyTranscript.snapshot.text
        #expect(audio.deliverySnapshot().requiresReview)
        #expect(audio.stopStreamingSnapshot().segment.requiresReview)
        var delivered: CompletedSegment?
        audio.finishImmediately { delivered = $0 }
        #expect(delivered?.requiresReview == true)
        #expect(delivered?.transcript == "Earlier words Later words")
    }

    @Test func legacyFastHelperCannotSendARejectedSnapshot() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        _ = try #require(started)
        let pipeline = RejectedRangePipeline()
        audio.streamingPipeline = pipeline
        audio.isRecording = true
        var delivered = false
        audio.finishForPaste(timing: .fast) { _ in delivered = true }
        #expect(!delivered)
        #expect(audio.captureError != nil)
        #expect(audio.transcript == pipeline.recovery.text)
        #expect(pipeline.resultReads == 1)
    }
    @Test func rejectedSpeechCannotBecomeAnImmediateSuccessfulDelivery() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        _ = try #require(started)
        let pipeline = RejectedRangePipeline()
        audio.streamingPipeline = pipeline
        audio.isRecording = true
        var delivered = false
        audio.finishImmediately { _ in delivered = true }
        #expect(!delivered)
        #expect(audio.captureError == "Speech range could not be reconciled")
        #expect(audio.transcript == pipeline.recovery.text)
        #expect(pipeline.resultReads == 1)
        #expect(pipeline.snapshotReads == 0)
    }

    @Test func rejectedSpeechCannotBecomeAnAdaptiveSuccessfulDelivery() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        _ = try #require(started)
        let pipeline = RejectedRangePipeline()
        audio.streamingPipeline = pipeline
        audio.isRecording = true
        var delivered = false
        audio.finishAdaptively { _ in delivered = true }
        #expect(!delivered)
        #expect(audio.captureError != nil)
        #expect(audio.transcript == pipeline.recovery.text)
    }

    @Test func rejectedSpeechAtDeadlineIsHeldForRecovery() async throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        _ = try #require(started)
        let pipeline = RejectedRangePipeline()
        audio.streamingPipeline = pipeline
        audio.isRecording = true
        var delivered = false
        audio.finish(after: 0.1) { _ in delivered = true }
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(!delivered)
        #expect(audio.captureError != nil)
        #expect(audio.transcript == pipeline.recovery.text)
        #expect(pipeline.resultReads == 1)
    }

    @Test func fastCompletesOnTheStopStackAndIgnoresLateResults() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        let generation = try #require(started)
        audio.transcript = "The blue notebook"
        audio.isRecording = true
        audio.stableWordCount = 0
        var results: [String] = []
        audio.finishForPaste(timing: .fast) { results.append($0.transcript) }
        #expect(results == ["The blue notebook"])
        #expect(!audio.isRecording)
        #expect(audio.session.id == nil)
        audio.transcript = "The blue notebook is here"
        audio.finishSegment(generation: generation)
        #expect(results.count == 1)
    }

    @Test func fastFreezesOneCanonicalSnapshotBeforeVolatileRetraction() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        _ = try #require(started)
        let pipeline = RetractingPipeline()
        audio.streamingPipeline = pipeline
        audio.transcript = "stale published words"
        audio.isRecording = true
        var result: String?
        audio.finishForPaste(timing: .fast) { result = $0.transcript }
        #expect(result == "The blue notebook")
        #expect(pipeline.reads == 1)
        #expect(pipeline.cancelled)
    }

    @Test func earlyStreamReadsStableAndVolatileWordsFromOneRevision() {
        let audio = AudioCapture()
        let pipeline = StreamingRevisionPipeline()
        audio.streamingPipeline = pipeline
        audio.transcript = "stale published words"
        audio.stableWordCount = 999
        let snapshot = audio.stopStreamingSnapshot()
        #expect(pipeline.reads == 1)
        #expect(snapshot.segment.transcript == "The fictional blue notebook")
        #expect(snapshot.stableText == "The fictional")
        #expect(!snapshot.stableText.contains("blue"))
        audio.streamingPipeline = nil
    }

    @Test func settledWaitsForFinalWordsWithoutAnExtraCountdown() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        let generation = try #require(started)
        audio.transcript = "The blue"
        audio.isRecording = true
        audio.stableWordCount = 0
        var results: [String] = []
        audio.finishForPaste(timing: .slow) { results.append($0.transcript) }
        #expect(results.isEmpty)
        #expect(audio.session.phase == .finalizing)
        audio.transcript = "The blue notebook"
        audio.finishSegment(generation: generation)
        #expect(results == ["The blue notebook"])
        audio.finishSegment(generation: generation)
        #expect(results.count == 1)
    }

    @Test func fastWithNoRecognizedWordsStillDrainsTheUtterance() throws {
        let audio = AudioCapture()
        let started = audio.session.begin()
        let generation = try #require(started)
        audio.transcript = "  "
        audio.isRecording = true
        var results: [String] = []
        audio.finishForPaste(timing: .fast) { results.append($0.transcript) }
        #expect(results.isEmpty)
        audio.transcript = "Hello"
        audio.finishSegment(generation: generation)
        #expect(results == ["Hello"])
    }
}

private final class RejectedRangePipeline: StreamingSpeechPipeline {
    let recovery = TranscriptSnapshot(finalizedText: "", volatileText: "Earlier words\n\n[Unmerged recognition fragment]\nLater words")
    var snapshotReads = 0
    var resultReads = 0
    var currentSnapshot: TranscriptSnapshot {
        snapshotReads += 1
        return TranscriptSnapshot(finalizedText: "stale words", volatileText: "")
    }
    var currentResult: (snapshot: TranscriptSnapshot, failure: String?) {
        resultReads += 1
        return (recovery, "Speech range could not be reconciled")
    }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish(completion: @escaping (TranscriptSnapshot) -> Void) {}
    func cancel() {}
}

private final class RetractingPipeline: StreamingSpeechPipeline {
    var reads = 0
    var cancelled = false
    var currentSnapshot: TranscriptSnapshot {
        reads += 1
        return TranscriptSnapshot(finalizedText: "", volatileText: reads == 1 ? "The blue notebook" : "")
    }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish(completion: @escaping (TranscriptSnapshot) -> Void) {}
    func cancel() { cancelled = true }
}

private final class StreamingRevisionPipeline: StreamingSpeechPipeline {
    var reads = 0
    var currentSnapshot: TranscriptSnapshot {
        reads += 1
        return reads == 1
            ? TranscriptSnapshot(finalizedText: "The fictional", volatileText: "blue notebook")
            : TranscriptSnapshot(finalizedText: "Entirely changed", volatileText: "later revision")
    }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish(completion: @escaping (TranscriptSnapshot) -> Void) {}
    func cancel() {}
}
