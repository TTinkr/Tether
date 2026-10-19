import AVFoundation
import Foundation
import Testing
@testable import Tokens

private final class OrukeetFixtureDecoder: OrukeetDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(Int, (Result<OrukeetDecodedAudio, Error>) -> Void)] = []
    private var counts: [Int] = []
    private var latestSamples: [Float] = []
    private var stops = 0
    var automatic: ((Int) -> OrukeetDecodedAudio)?
    func decode(_ samples: [Float], completion: @escaping (Result<OrukeetDecodedAudio, Error>) -> Void) {
        lock.lock(); counts.append(samples.count); latestSamples = samples
        let response = automatic?(samples.count)
        if response == nil { pending.append((samples.count, completion)) }
        lock.unlock()
        if let response { completion(.success(response)) }
    }
    var requests: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    var finalSamples: [Float] { lock.lock(); defer { lock.unlock() }; return latestSamples }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var shutdowns: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func respond(_ result: Result<OrukeetDecodedAudio, Error>) {
        lock.lock(); let next = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock()
        next?.1(result)
    }
    func shutdown() { lock.lock(); stops += 1; lock.unlock() }
}
private final class OrukeetFixtureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite(.serialized) struct OrukeetPipelineTests {
    private static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
    private static func buffer(rate: Double = 16000, frames: UInt32 = 9600, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }
    private static func decoded(_ text: String, timed: Bool = true) -> OrukeetDecodedAudio {
        .init(text: text, words: timed ? text.split(separator: " ").enumerated().map {
            .init(text: String($0.element), startMS: Double($0.offset) * 100, endMS: Double($0.offset + 1) * 100)
        } : [])
    }
    @Test func requestFrameIsExactLittleEndianAndBounded() throws {
        let frame = try OrukeetWorker.frame(samples: [1, -0.5], requestID: 0x0102030405060708)
        #expect(Array(frame.prefix(20)) == [79,82,75,49,8,7,6,5,4,3,2,1,128,62,0,0,2,0,0,0])
        #expect(Array(frame.suffix(8)) == [0,0,128,63,0,0,0,191])
        #expect(throws: (any Error).self) { try OrukeetWorker.frame(samples: [], requestID: 1) }
        #expect(throws: (any Error).self) { try OrukeetWorker.frame(samples: [.nan], requestID: 1) }
        #expect(throws: (any Error).self) { try OrukeetWorker.frame(samples: [0], requestID: 0) }
        #expect(throws: (any Error).self) { try OrukeetWorker.frame(samples: [Float](repeating: 0, count: 480001), requestID: 1) }
    }
    @Test func responseMustMatchExactIDAndAudioFrame() throws {
        var object: [String: Any] = ["type":"result", "request_id":"18446744073709551615", "sample_rate":16000,
            "sample_count":9600, "mode":"offline", "is_final":true, "text":"Hello.",
            "words":[["text":"hello", "start_ms":0, "end_ms":200]]]
        let result = try OrukeetWorker.result(object, requestID: .max, samples: 9600)
        #expect(result.text == "Hello.")
        #expect(throws: (any Error).self) { try OrukeetWorker.result(object, requestID: 1, samples: 9600) }
        #expect(throws: (any Error).self) { try OrukeetWorker.result(object, requestID: .max, samples: 9599) }
        object["request_id"] = UInt64.max
        #expect(throws: (any Error).self) { try OrukeetWorker.result(object, requestID: .max, samples: 9600) }
        object["request_id"] = String(UInt64.max); object["is_final"] = false
        #expect(throws: (any Error).self) { try OrukeetWorker.result(object, requestID: .max, samples: 9600) }
    }
    @Test func quietBoundaryPreservesTailUntilCommit() throws {
        var windows = OrukeetAudioWindows(sampleRate: 100)
        try windows.append([Float](repeating: 0.25, count: 1990))
        try windows.append([Float](repeating: 0, count: 40))
        #expect(windows.boundary == 2010)
        #expect(windows.samples.count == 2030 && windows.originSamples == 0)
        windows.commit(2010)
        #expect(windows.samples.count == 20 && windows.originSamples == 2010)
    }
    /// Build 81: a breath after 10 s no longer closes the window mid-sentence (a stray ". X").
    @Test func softCloseWaitsForASentencePauseUntilTwentySeconds() throws {
        var windows = OrukeetAudioWindows(sampleRate: 100)
        try windows.append([Float](repeating: 0.25, count: 1050))    // 10.5 s of speech
        try windows.append([Float](repeating: 0, count: 25))         // 0.25 s breath mid-sentence
        try windows.append([Float](repeating: 0.25, count: 300))
        #expect(windows.boundary == nil)
        try windows.append([Float](repeating: 0, count: 45))         // 0.45 s sentence break
        #expect(windows.boundary == 1415)                            // closes once 0.4 s is quiet

        var long = OrukeetAudioWindows(sampleRate: 100)
        for _ in 0..<7 {                                             // 3 s phrases, 0.3 s breaths
            try long.append([Float](repeating: 0.25, count: 300))
            try long.append([Float](repeating: 0, count: 30))
        }
        // No 0.4 s pause before 20 s; the first breath after 20 s closes it after 0.2 s of quiet.
        #expect(long.boundary == 2300)
    }
    /// Build 81: a window of room noise is never decoded, so no invented "Fair play." is pasted.
    @Test func quietWindowsAreRecognisedByTheirVoicedAudio() throws {
        var windows = OrukeetAudioWindows(sampleRate: 100)
        try windows.append([Float](repeating: 0.001, count: 1100))     // 11 s of hum
        let boundary = try #require(windows.boundary)
        #expect(windows.isQuiet(boundary))
        try windows.append([Float](repeating: 0.25, count: 10))        // 0.1 s of speech: still too little
        #expect(windows.isQuiet(windows.samples.count))
        try windows.append([Float](repeating: 0.25, count: 10))        // 0.2 s: speech
        #expect(!windows.isQuiet(windows.samples.count))
    }
    @Test func silentTalkNeverReachesTheModel() async throws {
        let decoder = OrukeetFixtureDecoder(); let callbacks = OrukeetFixtureCounter()
        let pcm = Self.buffer(value: 0)
        let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder)
        pipeline.append(pcm)
        pipeline.finish { _ in callbacks.add() }
        #expect(await Self.wait { callbacks.count == 1 })
        #expect(decoder.requests.isEmpty)
        #expect(pipeline.currentSnapshot.finalizedText.isEmpty)
    }
    @Test func voiceOnTheSecondChannelIsHeard() async throws {
        let decoder = OrukeetFixtureDecoder(); let callbacks = OrukeetFixtureCounter()
        decoder.automatic = { _ in Self.decoded("heard") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let stereo = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 28800)!
        stereo.frameLength = 28800
        stereo.floatChannelData![0].update(repeating: 0, count: 28800)       // left: silent
        stereo.floatChannelData![1].update(repeating: 0.25, count: 28800)    // right: the mic
        let pipeline = try OrukeetSpeechPipeline(naturalFormat: format, decoder: decoder)
        pipeline.append(stereo)
        pipeline.finish { _ in callbacks.add() }
        #expect(await Self.wait { callbacks.count == 1 })
        #expect(!decoder.requests.isEmpty)
        #expect(decoder.finalSamples.contains { abs($0) > 0.05 })
    }
    @Test func twelveContiguousWindowsExceedFiveMinutesWithoutDroppingSamples() throws {
        var windows = OrukeetAudioWindows(sampleRate: 100)
        var output: [Float] = []; var input: [Float] = []
        for index in 1...12 {
            let chunk = [Float](repeating: Float(index), count: 3000)
            input += chunk; try windows.append(chunk)
            #expect(windows.boundary == 3000)
            output += windows.samples.prefix(3000)
            windows.commit(3000)
        }
        #expect(output == input)
        #expect(windows.originSamples == 36000 && windows.samples.isEmpty)
    }
    @Test func overloadAndInvalidAudioDoNotDiscardExistingPCM() throws {
        var windows = OrukeetAudioWindows(sampleRate: 100)
        try windows.append([Float](repeating: 0.5, count: 6000))
        #expect(throws: (any Error).self) { try windows.append([1]) }
        #expect(throws: (any Error).self) { try windows.append([.infinity]) }
        #expect(windows.samples.count == 6000 && windows.originSamples == 0)
    }
    @Test func prefixRemainsVolatileAndFinishRevisesExactlyOnce() async throws {
        let decoder = OrukeetFixtureDecoder(); let callbacks = OrukeetFixtureCounter()
        let pcm = Self.buffer(); let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder)
        pipeline.append(pcm)
        #expect(await Self.wait { decoder.pendingCount == 1 })
        decoder.respond(.success(Self.decoded("early guess")))
        #expect(await Self.wait { pipeline.currentSnapshot.text == "early guess" })
        #expect(pipeline.currentSnapshot.finalizedText.isEmpty)
        pipeline.finish { _ in callbacks.add() }; pipeline.finish { _ in callbacks.add() }
        #expect(await Self.wait { decoder.pendingCount == 1 })
        decoder.respond(.success(Self.decoded("Final words.")))
        #expect(await Self.wait { callbacks.count == 1 })
        #expect(pipeline.currentSnapshot.finalizedText == "Final words.")
        #expect(pipeline.currentSnapshot.volatileText.isEmpty)
        #expect(pipeline.currentSnapshot.timedWords.allSatisfy { $0.isFinal })
        #expect(decoder.requests == [9600, 9600])
    }
    @Test func finishWaitsForInflightPrefixThenDecodesWholeFinalWindow() async throws {
        let decoder = OrukeetFixtureDecoder(); let callbacks = OrukeetFixtureCounter()
        let pcm = Self.buffer(); let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder)
        pipeline.append(pcm); #expect(await Self.wait { decoder.pendingCount == 1 })
        pipeline.finish { _ in callbacks.add() }
        #expect(callbacks.count == 0)
        decoder.respond(.success(Self.decoded("unstable")))
        #expect(await Self.wait { decoder.requests.count == 2 })
        #expect(pipeline.currentSnapshot.finalizedText.isEmpty)
        decoder.respond(.success(Self.decoded("settled")))
        #expect(await Self.wait { callbacks.count == 1 })
        #expect(pipeline.currentSnapshot.finalizedText == "settled")
    }
    @Test func canceledGenerationRejectsDelayedSuccess() async throws {
        let decoder = OrukeetFixtureDecoder(); let callbacks = OrukeetFixtureCounter(); let updates = OrukeetFixtureCounter()
        let pcm = Self.buffer(); let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder, onUpdate: { _ in updates.add() })
        pipeline.append(pcm); #expect(await Self.wait { decoder.pendingCount == 1 })
        pipeline.finish { _ in callbacks.add() }; pipeline.cancel()
        decoder.respond(.success(Self.decoded("must never appear")))
        #expect(await Self.wait { decoder.shutdowns == 1 })
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(pipeline.currentSnapshot.text.isEmpty && callbacks.count == 0 && updates.count == 0)
    }
    @Test func failurePreservesBestVolatileSnapshotWithoutFinalAuthority() async throws {
        let decoder = OrukeetFixtureDecoder(); let failures = OrukeetFixtureCounter(); let callbacks = OrukeetFixtureCounter()
        let pcm = Self.buffer(); let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder, onFailure: { _ in failures.add() })
        pipeline.append(pcm); #expect(await Self.wait { decoder.pendingCount == 1 })
        decoder.respond(.success(Self.decoded("recover these words")))
        #expect(await Self.wait { pipeline.currentSnapshot.text == "recover these words" })
        pipeline.finish { _ in callbacks.add() }; #expect(await Self.wait { decoder.pendingCount == 1 })
        decoder.respond(.failure(OrukeetFailure.workerExited))
        #expect(await Self.wait { failures.count == 1 })
        #expect(pipeline.currentResult.failure != nil && pipeline.currentSnapshot.finalizedText.isEmpty)
        #expect(pipeline.currentSnapshot.text == "recover these words" && callbacks.count == 0)
    }
    @Test(arguments: [44100.0, 48000.0]) func converterDrainsTailAndNeverSendsInputSampleRateToWorker(rate: Double) async throws {
        let decoder = OrukeetFixtureDecoder(); decoder.automatic = { _ in Self.decoded("converted") }
        let pcm = Self.buffer(rate: rate, frames: UInt32(rate), value: 0)
        // A final pulse exposes a missing converter tail instead of merely
        // counting duration with an all-zero input. No real microphone is used.
        // 0.2 s long: build 81 never decodes a window with under 0.15 s of sound.
        pcm.floatChannelData![0].advanced(by: Int(rate * 0.8)).update(repeating: 0.75, count: Int(rate * 0.2))
        let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder)
        let callbacks = OrukeetFixtureCounter()
        pipeline.append(pcm); pipeline.finish { _ in callbacks.add() }
        #expect(await Self.wait { callbacks.count == 1 || pipeline.currentResult.failure != nil })
        #expect(pipeline.currentResult.failure == nil && callbacks.count == 1)
        // Normal priming flushes the resampler tail into the exact1s audio clock.
        #expect(abs((decoder.requests.last ?? 0) - 16000) <= 1)
        let lastFiveMS = decoder.finalSamples.suffix(80)
        #expect(lastFiveMS.count == 80)
        #expect(lastFiveMS.reduce(0, +) / 80 > 0.6)
        #expect(decoder.requests.allSatisfy { $0 <= 480000 })
    }
    @Test func mixedWindowTimingDoesNotPretendToCoverWholeTranscript() async throws {
        let decoder = OrukeetFixtureDecoder()
        decoder.automatic = { count in count == 480000 ? Self.decoded("First.") : Self.decoded("Second.", timed: false) }
        let pcm = Self.buffer(frames: 16000)
        let pipeline = try OrukeetSpeechPipeline(naturalFormat: pcm.format, decoder: decoder)
        for _ in 0..<30 { pipeline.append(pcm); try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(await Self.wait { pipeline.currentSnapshot.text == "First." })
        // A closed window is never decoded again: it is settled while still recording.
        #expect(pipeline.currentSnapshot.finalizedText == "First.")
        #expect(pipeline.currentSnapshot.stableWordCount == 1)
        pipeline.append(pcm)
        #expect(await Self.wait { pipeline.currentSnapshot.volatileText == "Second." })
        #expect(pipeline.currentSnapshot.finalizedText == "First.")
        #expect(pipeline.currentSnapshot.text == "First. Second.")
        pipeline.append(Self.buffer(frames: 3200))
        let callbacks = OrukeetFixtureCounter(); pipeline.finish { _ in callbacks.add() }
        #expect(await Self.wait { callbacks.count == 1 })
        #expect(pipeline.currentSnapshot.finalizedText == "First. Second.")
        #expect(pipeline.currentSnapshot.timedWords.isEmpty)
        #expect(decoder.requests.allSatisfy { $0 <= 480000 })
    }
    @Test func nativeOffsetsAreShiftedButNeverInventedOrClipped() {
        let decoded = Self.decoded("Hello there.")
        let shifted = OrukeetSpeechPipeline.timedWords(decoded, origin: 30, duration: 1, final: true)
        #expect(shifted.map(\.start) == [30, 30.1])
        #expect(shifted.allSatisfy { $0.isFinal })
        let invalid = OrukeetDecodedAudio(text: "bad", words: [.init(text: "bad", startMS: 0, endMS: 1001)])
        #expect(OrukeetSpeechPipeline.timedWords(invalid, origin: 30, duration: 0.5, final: true).isEmpty)
        #expect(OrukeetSpeechPipeline.alignedWords(shifted, text: "Hello missing there.").isEmpty)
    }
}
