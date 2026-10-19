import CoreGraphics
import Foundation
import Testing
import TokensCore
@testable import Tokens

/*
Build 81 safety fixes found by the reliability sweep: Return is never held after a talk that did
not deliver, a talk never records through a locked screen, and the lock screen is never a target.
*/
struct TalkSafetyTests {
    @Test func returnHoldEndsByItselfAfterTheLimit() {
        var gate = DeliveryReturnGate()
        gate.begin(now: 100)
        let limit = DeliveryReturnGate.limit
        let held = gate.handle(keyCode: 36, down: true, now: 101)          // held while delivery is pending
        let heldUp = gate.handle(keyCode: 36, down: false, now: 101)       // its key-up goes with it
        let lateHeld = gate.handle(keyCode: 76, down: true, now: 100 + limit - 1)
        let lateUp = gate.handle(keyCode: 76, down: false, now: 100 + limit - 1)
        // Past the limit the hold has ended: Return reaches the app again.
        let expired = gate.handle(keyCode: 36, down: true, now: 100 + limit + 1)
        #expect(held && heldUp && lateHeld && lateUp)
        #expect(!expired)
        #expect(!gate.pending && !gate.requested)
    }

    @Test func lockScreenAndPasswordPromptsAreNeverTargets() {
        for bundle in ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.SecurityAgent"] {
            #expect(DeliveryTargetPolicy.isProtectedSystemSurface(bundleIdentifier: bundle))
        }
        for bundle in [nil, "com.anthropic.claudefordesktop", "com.openai.codex", "com.google.Chrome"] {
            #expect(!DeliveryTargetPolicy.isProtectedSystemSurface(bundleIdentifier: bundle))
        }
    }

    /// Source guards: failure and empty endings release Return; lock and user switch end a running talk.
    @Test func sourceKeepsTheReleaseAndLockPaths() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
        }
        let model = try source("Talk/TalkModel.swift")
        #expect(model.contains("if oldValue == .capturing || oldValue == .finalizing, phase == .failed || phase == .idle,"))
        #expect(model.contains("input.finishReturnReservation()"))
        let consent = try source("Talk/TalkModel+ListeningConsent.swift")
        #expect(consent.contains("if reason != .sleep, self.phase == .capturing {"))
        #expect(consent.contains("self.audio.interruptCapture("))
        #expect(try source("Delivery/TargetTracker.swift").contains("isProtectedSystemSurface(bundleIdentifier: application.bundleIdentifier)"))
        #expect(try source("Keyboard/GlobalKeyMonitor.swift").contains("self.returnGate      = DeliveryReturnGate()"))
    }

    /// Option+Arrow, Option+Delete, Option+letter: a press that started a talk, then another key.
    @Test @MainActor func aChordOnTheStartingPressDiscardsThatTalkOnce() async throws {
        let monitor = GlobalKeyMonitor()
        var presses = 0, chords = 0
        monitor.onPress = { presses += 1 }
        monitor.onChord = { chords += 1 }
        monitor.isStopEdge = { _ in false }
        let arrow = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        #expect(monitor.injectQAEdge(down: true))
        _ = monitor.handle(type: .keyDown, event: arrow)
        _ = monitor.handle(type: .keyDown, event: arrow)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(presses == 1 && chords == 1)
        #expect(monitor.injectQAEdge(down: false))
        // Typing after the key is let go is not a chord.
        _ = monitor.handle(type: .keyDown, event: arrow)
        // A press that stops a talk is not a chord either: stopping stays instant.
        monitor.isStopEdge = { pressed in pressed }
        #expect(monitor.injectQAEdge(down: true))
        _ = monitor.handle(type: .keyDown, event: arrow)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(chords == 1)
        monitor.finishReturnReservation()
    }

    @Test func otherModifiersMeanAShortcutNotATalk() {
        #expect(GlobalKeyMonitor.otherModifiersDown([.maskAlternate, .maskCommand], talkKey: 61))
        #expect(GlobalKeyMonitor.otherModifiersDown([.maskAlternate, .maskShift], talkKey: 58))
        #expect(!GlobalKeyMonitor.otherModifiersDown([.maskAlternate], talkKey: 61))
        #expect(!GlobalKeyMonitor.otherModifiersDown([.maskControl], talkKey: 59))
        #expect(GlobalKeyMonitor.otherModifiersDown([.maskControl, .maskAlternate], talkKey: 59))
        #expect(!GlobalKeyMonitor.otherModifiersDown([.maskCommand], talkKey: 54))
    }
}
