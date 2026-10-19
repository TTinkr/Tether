import AVFoundation
import Foundation
import Testing
@testable import Tokens

private final class BlockedHardware: AudioHardwareBackend {
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var blockFormat = true
    var blockDetach = false
    private var events: [String] = []
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return events }
    private func record(_ value: String) {
        lock.lock(); events.append(value + (Thread.isMainThread ? "-main" : "")); lock.unlock()
    }
    func format() throws -> AVAudioFormat {
        record("format")
        if blockFormat { release.wait() }
        return AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }
    func start(format: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void,
               current: () -> Bool) throws -> Bool {
        record("start"); release.wait()
        sink(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!)
        record(current() ? "current" : "stale")
        return true
    }
    func detach(stop: Bool) { record(stop ? "stop" : "detach"); if blockDetach { release.wait() } }
    func reset() { record("reset") }
}

@MainActor @Suite struct AudioHardwareOwnerTests {
    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(predicate(), "owner operation did not complete within one second")
    }

    @Test func stalledFormatQuarantinesRetryAndSuppressesLateSuccess() async throws {
        let fake = BlockedHardware()
        let owner = AudioHardwareOwner { _ in fake }
        let generation = UUID()
        var delivered = false
        #expect(owner.prepare(generation: generation) { _ in delivered = true })
        defer { fake.release.signal() }
        try await until { fake.recorded.contains("format") }
        var cleaned = false
        owner.stop(stopHardware: true, reset: true) { cleaned = true }
        #expect(!owner.isCurrent(generation))
        #expect(!owner.prepare(generation: UUID()) { _ in })
        #expect(fake.recorded == ["format"])
        // Main remains runnable while the hardware operation is blocked.
        await Task.yield()
        #expect(!cleaned)
        fake.release.signal()
        try await until { cleaned }
        #expect(!delivered)
        #expect(fake.recorded == ["format", "stop", "reset"])
        #expect(!owner.isBusy)
        var retried = false
        fake.blockFormat = false
        #expect(owner.prepare(generation: UUID()) { _ in retried = true })
        try await until { retried }
        owner.stop(stopHardware: true)
    }

    @Test func stalledStartCannotDeliverAudioOrSuccessAfterCancellation() async throws {
        let fake = BlockedHardware(); fake.blockFormat = false
        let owner = AudioHardwareOwner { _ in fake }
        let generation = UUID()
        var format: AVAudioFormat?
        #expect(owner.prepare(generation: generation) { format = try? $0.get() })
        try await until { format != nil }
        var buffers = 0, successes = 0
        #expect(owner.start(generation: generation, format: try #require(format), sink: { _ in buffers += 1 }) {
            if (try? $0.get()) != nil { successes += 1 }
        })
        defer { fake.release.signal() }
        try await until { fake.recorded.contains("start") }
        var cleaned = false
        owner.stop(stopHardware: false)
        owner.stop(stopHardware: true, reset: true) { cleaned = true }
        #expect(fake.recorded == ["format", "start"])
        #expect(!owner.prepare(generation: UUID()) { _ in })
        fake.release.signal()
        try await until { cleaned }
        #expect(buffers == 0)
        #expect(successes == 0)
        #expect(fake.recorded == ["format", "start", "stale", "stop", "reset"])
        #expect(owner.isQuiescent)
    }

    @Test func startupDeadlineFailsWithoutWaitingForStalledHardware() async throws {
        let fake = BlockedHardware()
        let audio = AudioCapture()
        audio.hardwareOwner = AudioHardwareOwner { _ in fake }
        audio.hardwareStartupTimeout = 0.03
        let began = audio.session.begin()
        let generation = try #require(began)
        _ = audio.session.advance(generation, from: .awaitingAccess, to: .starting)
        var ready = false
        audio.prepareHardware(generation: generation) { _ in ready = true }
        defer { fake.release.signal() }
        try await until { fake.recorded.contains("format") }
        try await until { audio.captureError != nil }
        #expect(audio.session.id == nil)
        #expect(!audio.isRecording)
        #expect(audio.hardwareOwner.isBusy)
        #expect(!ready)
        fake.release.signal()
        try await until { !audio.hardwareOwner.isBusy }
        #expect(!ready)
        #expect(!audio.isRecording)
    }

    @Test func finishWaitsForBlockedDetachWithoutBlockingMain() async throws {
        let fake = BlockedHardware(); fake.blockFormat = false
        let audio = AudioCapture()
        audio.hardwareOwner = AudioHardwareOwner { _ in fake }
        let began = audio.session.begin()
        let generation = try #require(began)
        var format: AVAudioFormat?
        #expect(audio.hardwareOwner.prepare(generation: generation) { format = try? $0.get() })
        try await until { format != nil }
        fake.release.signal()
        var started = false
        #expect(audio.hardwareOwner.start(generation: generation, format: try #require(format), sink: { _ in }) { _ in started = true })
        try await until { started }
        fake.blockDetach = true
        var completed = false
        audio.finishImmediately { _ in completed = true }
        defer { fake.release.signal() }
        try await until { fake.recorded.contains("stop") }
        #expect(!completed)
        #expect(audio.session.id == generation)
        await Task.yield()
        fake.blockDetach = false
        fake.release.signal()
        try await until { completed }
        #expect(audio.session.id == nil)
    }

    @Test func quiescentStopAllowsImmediateNextCapture() async throws {
        let fake = BlockedHardware(); fake.blockFormat = false
        let owner = AudioHardwareOwner { _ in fake }
        var accepted = false, prepared = false
        owner.stop(stopHardware: true) {
            accepted = owner.prepare(generation: UUID()) { _ in prepared = true }
        }
        #expect(accepted)
        try await until { prepared }
        owner.stop(stopHardware: true)
    }
}
