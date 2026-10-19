


//
import AVFoundation
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct AudioTapRouterTests {
    @Test static func run() throws {
        let format         = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer         = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        let router         = AudioTapRouter()
        var ambient        = 0
        var prompt         = 0
        router.replace { _ in ambient += 1 }
        router.route(buffer)
        precondition(ambient == 1 && prompt == 0)
        router.replace { _ in prompt += 1 }
        router.route(buffer)
        precondition(ambient == 1 && prompt == 1, "Ambient frames must never leak into prompt consumer")
        router.replace(nil)
        router.route(buffer)
        precondition(ambient == 1 && prompt == 1 && router.sampleAge < 1)

        // Detach waits for the current callback; after it returns no old sink can run.
        let entered  = DispatchSemaphore(value: 0)
        let finish   = DispatchSemaphore(value: 0)
        let detached = DispatchSemaphore(value: 0)
        router.replace { _ in entered.signal(); finish.wait() }
        DispatchQueue.global().async { router.route(buffer) }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async { router.replace(nil); detached.signal() }
        precondition(detached.wait(timeout: .now() + 0.02) == .timedOut)
        finish.signal()
        precondition(detached.wait(timeout: .now() + 2) == .success)
        router.route(buffer) // Must not enter the now-detached blocking callback.
        for _ in 0..<1000 {
            router.replace { _ in prompt += 1 }
            router.route(buffer)
            router.replace(nil)
            router.route(buffer)
        }
        precondition(prompt == 1001)
        print("PASS one tap router: isolated consumers, quiescent detach, no-sink samples, 1000 replacements")
    }
}

