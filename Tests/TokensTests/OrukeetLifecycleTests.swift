import AVFoundation
import Foundation
import os
import Testing
import TokensCore
@testable import Tokens

/// Lease/lifetime checks with fake workers only: no model, worker process or microphone.
private final class LeaseDecoder: OrukeetDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(Result<OrukeetDecodedAudio, Error>) -> Void] = []
    private var counts: [Int] = []
    private var stops = 0
    private var alive = true
    private var exitHandler: (@Sendable () -> Void)?
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return alive }
    func onUnexpectedExit(_ handler: @escaping @Sendable () -> Void) { lock.lock(); exitHandler = handler; lock.unlock() }
    /// Simulates the worker process dying on its own, with or without the exit notice yet.
    func die(notify: Bool) {
        lock.lock(); alive = false; let handler = notify ? exitHandler : nil; lock.unlock()
        handler?()
    }
    func decode(_ samples: [Float], completion: @escaping (Result<OrukeetDecodedAudio, Error>) -> Void) {
        lock.lock(); counts.append(samples.count); pending.append(completion); lock.unlock()
    }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var requests: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    var shutdowns: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func respond(_ result: Result<OrukeetDecodedAudio, Error>) {
        lock.lock(); let next = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock()
        next?(result)
    }
    func shutdown() { lock.lock(); stops += 1; lock.unlock() }
}
private final class ReleaseLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Bool] = []
    func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class StartCounter: @unchecked Sendable {
    private let lock = NSLock(); private var made: [LeaseDecoder] = []
    func make() -> LeaseDecoder { let value = LeaseDecoder(); lock.lock(); made.append(value); lock.unlock(); return value }
    var workers: [LeaseDecoder] { lock.lock(); defer { lock.unlock() }; return made }
}
/// Holds model loads until opened, so a test can act while a load is still running.
private final class StartGate: @unchecked Sendable {
    private let lock = NSLock(); private var isOpen = false; private var count = 0
    func pass() async {
        lock.withLock { count += 1 }
        while !lock.withLock({ isOpen }) { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
    func open() { lock.withLock { isOpen = true } }
    var entries: Int { lock.withLock { count } }
}

@Suite(.serialized) struct OrukeetLifecycleTests {
    static func wait(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }
    static func buffer(rate: Double = 16000, frames: UInt32 = 9600, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }
    private static func pipeline(_ decoder: LeaseDecoder, _ log: ReleaseLog) throws -> OrukeetSpeechPipeline {
        try OrukeetSpeechPipeline(naturalFormat: buffer().format, decoder: decoder, release: { log.add($0) })
    }

    @Test func cancelWithoutDecodeReturnsWorkerWarm() async throws {
        let decoder = LeaseDecoder(); let log = ReleaseLog()
        let pipeline = try Self.pipeline(decoder, log)
        pipeline.cancel()
        #expect(await Self.wait { log.all == [true] })
        #expect(decoder.shutdowns == 0)
    }

    @Test func cancelDuringDecodeWaitsForAnswerThenReturnsWorkerWarm() async throws {
        let decoder = LeaseDecoder(); let log = ReleaseLog(); let updates = ReleaseLog()
        let pipeline = try OrukeetSpeechPipeline(naturalFormat: Self.buffer().format, decoder: decoder,
                                                 release: { log.add($0) }, onUpdate: { _ in updates.add(true) })
        pipeline.append(Self.buffer())
        #expect(await Self.wait { decoder.pendingCount == 1 })
        pipeline.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(log.all.isEmpty) // Never returned while the worker is still busy.
        decoder.respond(.success(.init(text: "discarded", words: [])))
        #expect(await Self.wait { log.all == [true] })
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(updates.all.isEmpty && pipeline.currentSnapshot.text.isEmpty && decoder.shutdowns == 0)
    }

    /// Build 81: AudioCapture's finish deadline frees a hung worker's lease at once, not after 25 s.
    @Test func abandonedFinishQuarantinesTheHungWorkerAtOnce() async throws {
        let decoder = LeaseDecoder(); let log = ReleaseLog()
        let pipeline = try Self.pipeline(decoder, log)
        pipeline.append(Self.buffer())
        #expect(await Self.wait { decoder.pendingCount == 1 })
        pipeline.finish { _ in Issue.record("an abandoned finish never completes") }
        pipeline.abandonFinish()
        pipeline.cancel()                               // AudioCapture's cleanup right after
        #expect(await Self.wait { log.all == [false] }) // the worker never answered
        decoder.respond(.success(.init(text: "late", words: [])))
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(log.all == [false] && pipeline.currentSnapshot.text.isEmpty)

        // A model still loading at the deadline is not hung: it comes back warm.
        let loadLog = ReleaseLog()
        let loading = try OrukeetSpeechPipeline(naturalFormat: Self.buffer().format, decoder: nil)
        loading.finish { _ in }
        loading.abandonFinish(); loading.cancel()
        loading.attach(LeaseDecoder(), release: { loadLog.add($0) })
        #expect(await Self.wait { loadLog.all == [true] })
    }

    @Test func workerFaultQuarantinesButPipelineOverloadDoesNot() async throws {
        let faulty = LeaseDecoder(); let faultLog = ReleaseLog()
        let first = try Self.pipeline(faulty, faultLog)
        first.append(Self.buffer())
        #expect(await Self.wait { faulty.pendingCount == 1 })
        faulty.respond(.failure(OrukeetFailure.protocolFailure))
        #expect(await Self.wait { faultLog.all == [false] })
        #expect(first.currentResult.failure != nil)

        // A mismatched buffer format is a pipeline-side overload; the worker stays warm.
        let healthy = LeaseDecoder(); let healthyLog = ReleaseLog()
        let second = try Self.pipeline(healthy, healthyLog)
        second.append(Self.buffer(rate: 48000, frames: 4800))
        #expect(await Self.wait { healthyLog.all == [true] })
        #expect(second.currentResult.failure != nil && healthy.requests.isEmpty)
    }

    @Test func poolReusesReleasedWorkerAndRewarmsAfterFaultWithinBound() async throws {
        let starts = StartCounter()
        let pool = OrukeetWorkerPool(start: { starts.make() })
        let first = try await pool.acquire()
        await pool.release(first, reusable: true)
        let again = try await pool.acquire()
        #expect(again === first && starts.workers.count == 1)
        // A fault quarantines the worker and reloads it in the background, unprompted.
        await pool.release(again, reusable: false)
        #expect(starts.workers[0].shutdowns == 1)
        #expect(await Self.wait { await pool.isWarm && starts.workers.count == 2 })
        // Repeated faults without a healthy release stop reloading (crash-loop bound).
        for _ in 0..<2 {
            let leased = try await pool.acquire()
            await pool.release(leased, reusable: false)
            #expect(await Self.wait { await pool.isWarm })
        }
        let last = try await pool.acquire()
        await pool.release(last, reusable: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await !pool.isWarm && starts.workers.count == 4)
    }

    @Test func choosingAnotherModelReplacesTheWarmWorkerButNeverALeasedOne() async throws {
        let starts = StartCounter()
        let chosen = OSAllocatedUnfairLock(initialState: "orukeet")
        let pool = OrukeetWorkerPool(start: { starts.make() }, identity: { chosen.withLock { $0 } })
        let first = try await pool.acquire()
        await pool.release(first, reusable: true)
        // Build 79: a different chosen model drops the idle warm worker and loads the new one.
        chosen.withLock { $0 = "whisper-base.en" }
        let second = try await pool.acquire()
        #expect(second !== first && starts.workers.count == 2 && starts.workers[0].shutdowns == 1)
        // While a talk holds the lease, a change waits: the leased worker is not shut down.
        chosen.withLock { $0 = "parakeet-tdt-0.6b-v2" }
        try await pool.prewarm()
        #expect(starts.workers[1].shutdowns == 0)
        await pool.release(second, reusable: true)
        let third = try await pool.acquire()
        #expect(third !== second && starts.workers.count == 3)
    }

    /*
    Build 81: a model picked while a talk waits on its cold load (a row's Download finishing mid-talk)
    must not cancel that load, or the talk fails "canceled" and loses what was said meanwhile. The
    talk keeps its model; the new pick is warmed once the talk hands the worker back.
    */
    @Test func pickDuringATalksColdLoadNeverCancelsItAndWarmsAfterRelease() async throws {
        let starts = StartCounter(); let gate = StartGate()
        let chosen = OSAllocatedUnfairLock(initialState: "whisper-base.en")
        let pool = OrukeetWorkerPool(start: { await gate.pass(); return starts.make() },
                                     identity: { chosen.withLock { $0 } })
        let talk = Task { try await pool.acquire() }
        #expect(await Self.wait { gate.entries == 1 })
        chosen.withLock { $0 = "parakeet-tdt-0.6b-v2" }
        let warmed = ReleaseLog()
        let warm = Task { try? await pool.prewarm(); warmed.add(true) }
        // Fixed: the prewarm returns at once. Old code started a second load here instead.
        #expect(await Self.wait { warmed.all == [true] || gate.entries == 2 })
        gate.open()
        let leased = try await talk.value // never OrukeetFailure.canceled
        #expect(leased === starts.workers[0] && gate.entries == 1)
        _ = await warm.value
        // Handing the worker back swaps in the newly picked model, so the next talk is warm.
        await pool.release(leased, reusable: true)
        #expect(await Self.wait { await pool.isWarm && starts.workers.count == 2 })
        #expect(starts.workers[0].shutdowns == 1)
        let next = try await pool.acquire()
        #expect(next === starts.workers[1] && starts.workers.count == 2)
        await pool.release(next, reusable: true)
    }

    @Test func deadIdleWorkerIsNeverLeasedAndExitTriggersReload() async throws {
        let starts = StartCounter()
        let pool = OrukeetWorkerPool(start: { starts.make() })
        let first = try await pool.acquire()
        await pool.release(first, reusable: true)
        // Died silently while idle: the next acquire must load a fresh worker.
        starts.workers[0].die(notify: false)
        let second = try await pool.acquire()
        #expect(second !== first && starts.workers.count == 2)
        await pool.release(second, reusable: true)
        // An idle worker's exit notice clears it and reloads in the background.
        starts.workers[1].die(notify: true)
        #expect(await Self.wait { await pool.isWarm && starts.workers.count == 3 })
        let third = try await pool.acquire()
        #expect(third === starts.workers[2])
        // While leased, an exit notice is left to the talk's own failure path.
        starts.workers[2].die(notify: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(starts.workers.count == 3)
        await pool.release(third, reusable: false)
    }

    @Test func acquireWaitsBrieflyForPendingReleaseThenReportsBusy() async throws {
        let starts = StartCounter()
        let pool = OrukeetWorkerPool(start: { starts.make() })
        let first = try await pool.acquire()
        let next = Task { try await pool.acquire() }
        try await Task.sleep(nanoseconds: 150_000_000)
        await pool.release(first, reusable: true)
        let reused = try await next.value
        #expect(reused === first && starts.workers.count == 1)
        // A lease that is never released still fails explicitly, after about a second.
        let began = ContinuousClock.now
        await #expect(throws: OrukeetFailure.self) { _ = try await pool.acquire() }
        #expect(ContinuousClock.now - began >= .milliseconds(900))
        await pool.release(reused, reusable: true)
    }

    @Test func idleListenerNeverSelectsOrukeetOrPromptsForSpeech() {
        #expect(AudioCapture.idleListenerEngine(selected: .orukeet, speechAuthorized: true) == .apple)
        #expect(AudioCapture.idleListenerEngine(selected: .orukeet, speechAuthorized: false) == nil)
        #expect(AudioCapture.idleListenerEngine(selected: .apple, speechAuthorized: true) == .apple)
        // Apple-selected installs keep their existing path (it may ask for Speech as before).
        #expect(AudioCapture.idleListenerEngine(selected: .apple, speechAuthorized: false) == .apple)
    }

    // Cold load (#1): the tap runs before the worker exists; nothing spoken meanwhile is lost.
    private static func loading(_ log: ReleaseLog = ReleaseLog(), failures: ReleaseLog? = nil,
                                loaded: ReleaseLog? = nil) throws -> OrukeetSpeechPipeline {
        try OrukeetSpeechPipeline(naturalFormat: buffer().format, decoder: nil,
                                  onFailure: { _ in failures?.add(false) }, onLoaded: { loaded?.add(true) })
    }

    @Test func preRollCapturedDuringLoadIsReplayedOnAttach() async throws {
        let decoder = LeaseDecoder(); let log = ReleaseLog(); let loaded = ReleaseLog()
        let pipeline = try Self.loading(loaded: loaded)
        #expect(pipeline.isLoading && pipeline.finalizationTimeout > 30)
        for _ in 0..<3 { pipeline.append(Self.buffer()); try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(pipeline.currentResult.failure == nil)
        pipeline.attach(decoder, release: { log.add($0) })
        #expect(await Self.wait { decoder.pendingCount == 1 })
        #expect(decoder.requests == [28800]) // Every pre-roll sample, from the first.
        #expect(await Self.wait { loaded.all == [true] })
        #expect(!pipeline.isLoading)
        pipeline.cancel()
        decoder.respond(.success(.init(text: "x", words: [])))
        #expect(await Self.wait { log.all == [true] })
    }

    @Test func keyReleasedDuringLoadFinishesWithWholeTranscriptOnceLoaded() async throws {
        let decoder = LeaseDecoder(); let log = ReleaseLog(); let done = ReleaseLog()
        let pipeline = try Self.loading()
        for _ in 0..<2 { pipeline.append(Self.buffer()); try await Task.sleep(nanoseconds: 5_000_000) }
        pipeline.finish { _ in done.add(true) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(done.all.isEmpty && pipeline.currentResult.failure == nil)
        pipeline.attach(decoder, release: { log.add($0) })
        #expect(await Self.wait { decoder.pendingCount == 1 })
        #expect(decoder.requests == [19200])
        decoder.respond(.success(.init(text: "Every early word.", words: [])))
        #expect(await Self.wait { done.all == [true] })
        #expect(pipeline.currentSnapshot.finalizedText == "Every early word.")
        #expect(await Self.wait { log.all == [true] })
    }

    @Test func talkCanceledDuringLoadReturnsLateWorkerWarmWithoutDecoding() async throws {
        let decoder = LeaseDecoder(); let log = ReleaseLog()
        let pipeline = try Self.loading()
        pipeline.append(Self.buffer())
        pipeline.cancel()
        pipeline.attach(decoder, release: { log.add($0) })
        #expect(await Self.wait { log.all == [true] })
        #expect(decoder.requests.isEmpty && decoder.shutdowns == 0)
    }

    @Test func loadFailureAndPreRollOverflowAreExplicitStartFailures() async throws {
        let failures = ReleaseLog()
        let failed = try Self.loading(failures: failures)
        failed.loadFailed(OrukeetFailure.assets)
        #expect(await Self.wait { failures.all.count == 1 })
        #expect(failed.currentResult.failure?.hasPrefix("Orukeet could not start.") == true)

        let overflow = try Self.loading()
        // Half-second buffers, paced so the 2 s admission queue never overloads first.
        let half = Self.buffer(frames: 8000, value: 0.1)
        for _ in 0..<72 {
            overflow.append(half)
            try await Task.sleep(nanoseconds: 5_000_000)
            if overflow.currentResult.failure != nil { break }
        }
        #expect(await Self.wait { overflow.currentResult.failure != nil })
        #expect(overflow.currentResult.failure == OrukeetSpeechPipeline.startFailureMessage(OrukeetFailure.startupTimeout))
    }

    @Test func modelVerificationCacheKeyChangesWithFileOrBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orukeet-fingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.gguf")
        try Data(repeating: 1, count: 4096).write(to: file)
        let sha = String(repeating: "a", count: 64)
        let first = try #require(OrukeetAssets.modelFingerprint(path: file.path, expectedSHA256: sha, appVersion: "75"))
        #expect(OrukeetAssets.modelFingerprint(path: file.path, expectedSHA256: sha, appVersion: "75") == first)
        #expect(OrukeetAssets.modelFingerprint(path: file.path, expectedSHA256: sha, appVersion: "76") != first)
        #expect(OrukeetAssets.modelFingerprint(path: file.path, expectedSHA256: String(repeating: "b", count: 64), appVersion: "75") != first)
        // Same size, rewritten in place: a restored modification time cannot hide it (ctime).
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.01)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 2, count: 4096)); try handle.close()
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        #expect(OrukeetAssets.modelFingerprint(path: file.path, expectedSHA256: sha, appVersion: "75") != first)
        #expect(OrukeetAssets.modelFingerprint(path: directory.appendingPathComponent("missing").path,
                                               expectedSHA256: sha, appVersion: "75") == nil)
    }

    @Test func finalDeadlineScalesWithUndecodedAudioAndPendingLoad() async throws {
        #expect(abs(OrukeetSpeechPipeline.finalDecodeBudget(seconds: 1) - 3.2) < 0.001)
        #expect(abs(OrukeetSpeechPipeline.finalDecodeBudget(seconds: 20) - 7) < 0.001)
        #expect(OrukeetSpeechPipeline.finalDecodeBudget(seconds: 30) == 8)
        #expect(OrukeetSpeechPipeline.finalDecodeBudget(seconds: 35) == 10) // Two windows after a pre-roll.
        #expect(OrukeetSpeechPipeline.finalDecodeBudget(seconds: 60) == 15)
        let decoder = LeaseDecoder()
        let ready = try OrukeetSpeechPipeline(naturalFormat: Self.buffer().format, decoder: decoder, release: { _ in })
        #expect(abs(ready.finalizationTimeout - 3) < 0.001)
        ready.append(Self.buffer(frames: 16000))
        #expect(await Self.wait { abs(ready.finalizationTimeout - 3.2) < 0.001 })
        ready.cancel()
        // While the model loads, the remaining load allowance is added on top.
        let loading = try OrukeetSpeechPipeline(naturalFormat: Self.buffer().format, decoder: nil)
        #expect(loading.finalizationTimeout > OrukeetSpeechPipeline.loadAllowance)
        #expect(loading.finalizationTimeout <= OrukeetSpeechPipeline.loadAllowance + 3)
        loading.cancel()
    }
}
