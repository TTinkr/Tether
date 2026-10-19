
import Testing
@testable import Tokens

@Suite("Shortcut error ownership")
struct ShortcutAccessFailureTests {
    @Test("Recovered transcript status returns after the temporary shortcut error")
    func recoveredTranscriptStatus() throws {
        let failure = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "Recovered transcript · Copy latest",
                                            currentPhase: .idle, replacing: nil)
        let restored = try #require(failure.restoredStatus(currentMessage: "Shortcut blocked", currentPhase: .failed))
        #expect(restored.message == "Recovered transcript · Copy latest")
        #expect(restored.phase == .idle)
    }

    @Test("An existing failed delivery remains failed and keeps its exact recovery reason")
    func heldDeliveryReason() throws {
        let failure = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "Paste not confirmed · Copy latest",
                                            currentPhase: .failed, replacing: nil)
        let restored = try #require(failure.restoredStatus(currentMessage: "Shortcut blocked", currentPhase: .failed))
        #expect(restored.message == "Paste not confirmed · Copy latest")
        #expect(restored.phase == .failed)
    }

    @Test("Repeated blocked retries do not save the old shortcut error as the recovery message")
    func repeatedRetries() throws {
        let first = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "Transcript held · Copy latest",
                                          currentPhase: .failed, replacing: nil)
        let retry = ShortcutAccessFailure(message: "Shortcut still blocked", currentMessage: first.message,
                                          currentPhase: .failed, replacing: first)
        let restored = try #require(retry.restoredStatus(currentMessage: retry.message, currentPhase: .failed))
        #expect(restored.message == "Transcript held · Copy latest")
        #expect(restored.phase == .failed)
    }

    @Test("A newer microphone, delivery, or copied status cannot be overwritten by recovery")
    func newerStatusWins() {
        let failure = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "",
                                            currentPhase: .idle, replacing: nil)
        for message in ["Microphone did not start", "Paste not confirmed", "copied"] {
            #expect(failure.restoredStatus(currentMessage: message, currentPhase: .failed) == nil)
        }
    }

    @Test("A fresh error after an intervening status remembers that newer status")
    func retryAfterNewStatus() throws {
        let old = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "",
                                        currentPhase: .idle, replacing: nil)
        let next = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "Microphone did not start",
                                         currentPhase: .failed, replacing: old)
        let restored = try #require(next.restoredStatus(currentMessage: next.message, currentPhase: .failed))
        #expect(restored.message == "Microphone did not start")
        #expect(restored.phase == .failed)
    }

    @Test("An access-only error clears back to the prior quiet phase")
    func quietPhaseReturns() throws {
        for phase: TalkPhase in [.idle, .delivered] {
            let failure = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "",
                                                currentPhase: phase, replacing: nil)
            let restored = try #require(failure.restoredStatus(currentMessage: failure.message, currentPhase: .failed))
            #expect(restored.message.isEmpty)
            #expect(restored.phase == phase)
        }
    }

    @Test("Reconnection never resurrects an interrupted capture or overwrites a newer phase")
    func activePhasesAreNotRestored() throws {
        for active: TalkPhase in [.capturing, .finalizing] {
            let failure = ShortcutAccessFailure(message: "Shortcut blocked", currentMessage: "",
                                                currentPhase: active, replacing: nil)
            let restored = try #require(failure.restoredStatus(currentMessage: failure.message, currentPhase: .failed))
            #expect(restored.phase == .failed)
            let newer = try #require(failure.restoredStatus(currentMessage: failure.message, currentPhase: active))
            #expect(newer.phase == active)
        }
    }
}
