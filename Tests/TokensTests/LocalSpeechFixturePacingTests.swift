import Foundation
import Testing
@testable import Tokens

struct LocalSpeechFixturePacingTests {
    @Test func fiveMinuteReplayDoesNotAccumulateWakeupOverhead() {
        let rate = 16000.0
        let totalFrames = 4_910_599
        let origin = 100.0
        let schedule = LocalSpeechFixturePacing(startedAt: origin, sampleRate: rate)
        var fedFrames = 0
        var now = origin
        var relativeSleepClock = origin
        while fedFrames < totalFrames {
            let frames = min(2048, totalFrames - fedFrames)
            let next = fedFrames + frames
            // Model a40ms late wakeup for every one of2398 chunks. Relative sleeps
            // exceed the old proof deadline; absolute deadlines remain on-clock.
            now += schedule.delay(afterFrames: next, now: now) + 0.04
            relativeSleepClock += Double(frames) / rate + 0.04
            #expect(schedule.admits(afterFrames: next, now: now))
            fedFrames = next
        }
        #expect(fedFrames == totalFrames)
        #expect(abs(now - origin - Double(totalFrames) / rate - 0.04) < 0.000001)
        #expect(relativeSleepClock - origin > Double(totalFrames) / rate + 90)
    }
    @Test func bufferIsNotSubmittedBeforeItsFramesExist() {
        let schedule = LocalSpeechFixturePacing(startedAt: 10, sampleRate: 16000)
        #expect(schedule.targetTime(afterFrames: 2048) == 10.128)
        #expect(abs(schedule.delay(afterFrames: 2048, now: 10) - 0.128) < 0.000001)
        #expect(schedule.delay(afterFrames: 2048, now: 10.2) == 0)
    }
    @Test func longStallFailsInsteadOfDumpingQueuedAudio() {
        let schedule = LocalSpeechFixturePacing(startedAt: 10, sampleRate: 16000)
        let target = schedule.targetTime(afterFrames: 2048)
        #expect(schedule.admits(afterFrames: 2048, now: target + 0.74))
        #expect(!schedule.admits(afterFrames: 2048, now: target + 0.76))
        #expect(!schedule.admits(afterFrames: 2048, now: target + 30))
        // Max permitted catch-up plus one admitted buffer is below the pipeline's
        //2s conversion-admission ceiling, even at its lowest supported8kHz rate.
        #expect(LocalSpeechFixturePacing.maximumLag + 2048.0 / 8000 < 2)
    }
    @Test func invalidClockOrFormatCannotAdmitReplay() {
        let invalid = LocalSpeechFixturePacing(startedAt: 10, sampleRate: 0)
        let valid = LocalSpeechFixturePacing(startedAt: 10, sampleRate: 16000)
        #expect(!invalid.admits(afterFrames: 2048, now: 10))
        #expect(!valid.admits(afterFrames: -1, now: 10))
        #expect(!valid.admits(afterFrames: 2048, now: .nan))
    }
}
