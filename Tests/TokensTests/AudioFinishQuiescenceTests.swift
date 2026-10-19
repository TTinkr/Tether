import AVFoundation
import Foundation
import Testing
@testable import Tokens

/// No microphone, recognizer, or destination. Blocks exactly the first owner detach.
private final class FinishQuiescenceHardware: AudioHardwareBackend {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    var detachEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func format() throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }
    func start(format: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void,
               current: () -> Bool) throws -> Bool { true }
    func detach(stop: Bool) {
        lock.lock()
        let shouldBlock = !entered
        entered = true
        lock.unlock()
        if shouldBlock { _ = release.wait(timeout: .now() + 10) }
    }
    func reset() {}
}

@MainActor @Suite(.serialized) struct AudioFinishQuiescenceTests {
    private func until(timeout: TimeInterval = 1, _ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() && ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(predicate(), "expected lifecycle boundary before timeout")
    }

    private func recording(_ fake: FinishQuiescenceHardware) async throws -> AudioCapture {
        let audio = AudioCapture()
        audio.hardwareOwner = AudioHardwareOwner { _ in fake }
        let began = audio.session.begin()
        let generation = try #require(began)
        let advanced = audio.session.advance(generation, from: .awaitingAccess, to: .recording)
        #expect(advanced)
        var format: AVAudioFormat?
        #expect(audio.hardwareOwner.prepare(generation: generation) { format = try? $0.get() })
        try await until { format != nil }
        var started = false
        #expect(audio.hardwareOwner.start(generation: generation, format: try #require(format), sink: { _ in }) { _ in started = true })
        try await until { started }
        audio.isRecording = true
        return audio
    }

    @Test func finishTimeoutRetainsRecoveryAndRejectsLateCompletion() async throws {
        let fake = FinishQuiescenceHardware()
        defer { fake.release.signal() }
        let audio = try await recording(fake)
        let recovery = "Fictional orchard note retained for recovery."
        audio.transcript = recovery
        var completions = 0
        audio.finishImmediately { _ in completions += 1 }
        try await until { fake.detachEntered }
        // A main-queue tick must run while the owner is blocked, before the real 2s deadline.
        var ticked = false
        DispatchQueue.main.async { ticked = true }
        try await until { ticked }
        #expect(audio.captureError == nil)
        #expect(completions == 0)
        try await until(timeout: 3) { audio.captureError != nil }
        #expect(audio.captureError == "Microphone did not stop in time. Copy latest.")
        #expect(audio.transcript == recovery)
        #expect(audio.session.id == nil)
        #expect(!audio.isRecording)
        #expect(audio.hardwareOwner.isBusy)
        #expect(completions == 0)
        var drained = false
        audio.hardwareOwner.stop(stopHardware: true) { drained = true }
        fake.release.signal()
        try await until { drained }
        #expect(completions == 0)
        #expect(audio.transcript == recovery)
        #expect(audio.captureError != nil)
    }

    @Test func discardDuringQuiescenceCannotCompleteOrMutateNextSession() async throws {
        let fake = FinishQuiescenceHardware()
        defer { fake.release.signal() }
        let audio = try await recording(fake)
        let previous = audio.session.id
        var completions = 0
        audio.finishImmediately { _ in completions += 1 }
        try await until { fake.detachEntered }
        audio.discardCapture()
        #expect(audio.session.id == nil)
        let began = audio.session.begin()
        let next = try #require(began)
        #expect(next != previous)
        let nextText = "A separate fictional next-session note."
        audio.transcript = nextText
        // Hardware admission remains quarantined even though a new logical session exists.
        #expect(!audio.hardwareOwner.prepare(generation: next) { _ in Issue.record("quarantined retry completed") })
        var drained = false
        audio.hardwareOwner.stop(stopHardware: true) { drained = true }
        fake.release.signal()
        try await until { drained }
        #expect(completions == 0)
        #expect(audio.session.id == next)
        #expect(audio.session.phase == .awaitingAccess)
        #expect(audio.transcript == nextText)
        #expect(audio.captureError == nil)
        // Also cross the old deadline: cancellation must prevent its later mutation.
        try await Task.sleep(nanoseconds: 2_100_000_000)
        #expect(completions == 0)
        #expect(audio.session.id == next)
        #expect(audio.transcript == nextText)
        #expect(audio.captureError == nil)
        audio.discardCapture()
    }
}
