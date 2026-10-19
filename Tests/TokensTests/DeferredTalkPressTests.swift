
import Darwin
import Foundation
import Testing
@testable import Tokens

@Suite struct DeferredTalkPressTests {
    /// The finalizing guard itself is unchanged: begin() must never run mid-delivery.
    @Test func actionStillIgnoresEveryEdgeWhileFinishing() {
        for mode in RightOptionMode.allCases {
            for pressed in [true, false] {
                #expect(mode.action(pressed: pressed, capturing: false, finalizing: true) == .ignore)
            }
        }
    }

    @Test func tapPressWhileFinishingStartsTheNextTalkWhenTheLastOneLands() {
        var slot = DeferredTalkPress()
        var changed = slot.note(pressed: true, mode: .tap, at: 10)
        #expect(changed)
        changed = slot.note(pressed: false, mode: .tap, at: 10.1)
        #expect(!changed)
        #expect(slot.isArmed)
        var outcome = slot.take(now: 11, landing: .landed, keyDown: false)
        #expect(outcome == .begin)
        #expect(!slot.isArmed)
        outcome = slot.take(now: 11, landing: .landed, keyDown: false)
        #expect(outcome == .none)
    }

    /// Taps count in order: stop, start, stop means no new talk.
    @Test func aSecondTapWhileFinishingTakesTheStartBack() {
        var slot = DeferredTalkPress()
        slot.note(pressed: true, mode: .tap, at: 10)
        let changed = slot.note(pressed: true, mode: .tap, at: 10.4)
        #expect(changed)
        #expect(!slot.isArmed)
        var outcome = slot.take(now: 11, landing: .landed, keyDown: false)
        #expect(outcome == .none)
        // A third tap starts one again.
        slot.note(pressed: true, mode: .tap, at: 10.6)
        outcome = slot.take(now: 11, landing: .landed, keyDown: false)
        #expect(outcome == .begin)
    }

    @Test func holdStartsOnlyWhileTheKeyIsStillDown() {
        var slot = DeferredTalkPress()
        slot.note(pressed: true, mode: .hold, at: 10)
        var outcome = slot.take(now: 30, landing: .landed, keyDown: true)
        #expect(outcome == .begin)

        slot.note(pressed: true, mode: .hold, at: 10)
        let changed = slot.note(pressed: false, mode: .hold, at: 10.5)
        #expect(changed)
        outcome = slot.take(now: 11, landing: .landed, keyDown: false)
        #expect(outcome == .none)

        // A lost key-up: the slot is still full but the key is not down.
        slot.note(pressed: true, mode: .hold, at: 10)
        outcome = slot.take(now: 11, landing: .landed, keyDown: false)
        #expect(outcome == .dropped("released"))
    }

    @Test func staleTapsFailuresAndRunningTalksDropThePress() {
        var slot = DeferredTalkPress()
        slot.note(pressed: true, mode: .tap, at: 10)
        var outcome = slot.take(now: 10 + DeferredTalkPress.maximumAge + 0.1, landing: .landed, keyDown: false)
        #expect(outcome == .dropped("stale"))
        slot.note(pressed: true, mode: .tap, at: 10)
        outcome = slot.take(now: 11, landing: .needsAttention, keyDown: true)
        #expect(outcome == .dropped("needs_attention"))
        slot.note(pressed: true, mode: .hold, at: 10)
        outcome = slot.take(now: 11, landing: .busy, keyDown: true)
        #expect(outcome == .dropped("busy"))
        #expect(!slot.isArmed)
    }

    /// The talk key used as a modifier (Option+Arrow) while finishing is never a talk.
    @Test func aChordCancelsTheRememberedPress() {
        var slot = DeferredTalkPress()
        slot.note(pressed: true, mode: .hold, at: 10)
        slot.cancel()
        let outcome = slot.take(now: 11, landing: .landed, keyDown: true)
        #expect(outcome == .none)
    }

    /*
    Build 81 review (Codex): tap to stop, tap again while it finishes, then lock the Mac, sleep
    or switch user before delivery lands. Delivery still lands (its target was taken at Stop),
    and the remembered tap used to start a talk that recorded the room behind the lock screen.
    */
    @Test func lockSleepOrUserSwitchWhileFinishingNeverStartsTheRememberedTalk() {
        let landed: [(TalkPhase, Bool)] = [(.idle, false), (.delivered, false), (.failed, true)]
        for (phase, keptInApp) in landed {
            // Unlocked, the same ending starts the remembered talk, so the lock is what stops it.
            #expect(DeferredTalkPress.landing(phase: phase, keptInApp: keptInApp, suspended: false) == .landed)
            let landing = DeferredTalkPress.landing(phase: phase, keptInApp: keptInApp, suspended: true)
            #expect(landing == .suspended)
            for mode in RightOptionMode.allCases {
                var slot = DeferredTalkPress()
                slot.note(pressed: true, mode: mode, at: 10)
                // Fresh, and the hold key still down: only the lock can drop it.
                #expect(slot.take(now: 10.5, landing: landing, keyDown: true) == .dropped("locked"))
                #expect(!slot.isArmed)
            }
        }
    }

    /// The phase rules TalkModel used before landing() moved here are unchanged.
    @Test func landingKeepsThePhaseRules() {
        #expect(DeferredTalkPress.landing(phase: .idle, keptInApp: false, suspended: false) == .landed)
        #expect(DeferredTalkPress.landing(phase: .delivered, keptInApp: false, suspended: false) == .landed)
        #expect(DeferredTalkPress.landing(phase: .failed, keptInApp: true, suspended: false) == .landed)
        #expect(DeferredTalkPress.landing(phase: .failed, keptInApp: false, suspended: false) == .needsAttention)
        #expect(DeferredTalkPress.landing(phase: .capturing, keptInApp: false, suspended: false) == .busy)
        #expect(DeferredTalkPress.landing(phase: .finalizing, keptInApp: false, suspended: false) == .busy)
    }

    /*
    A remembered tap must age while the lid is closed. mach_continuous_time counts sleep and
    systemUptime (mach_absolute_time) does not; the age clock has to agree with the first.
    */
    @Test func theAgeClockCountsSleep() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let continuous = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        #expect(abs(DeferredTalkPress.now() - continuous) < 0.5)
        // A tap remembered before an eight-hour lid close is stale on wake.
        var slot = DeferredTalkPress()
        slot.note(pressed: true, mode: .tap, at: 10)
        #expect(slot.take(now: 10 + 8 * 3600, landing: .landed, keyDown: false) == .dropped("stale"))
    }

    /*
    Source guards for the TalkModel wiring a unit test cannot drive: the lock/sleep/user-switch
    handler forgets the press in every phase (not only while capturing), a press made while
    locked is not remembered, the landing check reads the suspensions, and no deferred-press
    path still measures age with systemUptime.
    */
    @Test func lockSleepAndUserSwitchWiringForgetsTheRememberedPress() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
        }
        let consent = try source("Talk/TalkModel+ListeningConsent.swift")
        let suspendedBranch = try #require(consent.range(of: "if suspended {"))
        let resumedBranch   = try #require(consent.range(of: "} else {", range: suspendedBranch.upperBound..<consent.endIndex))
        let branch = consent[suspendedBranch.upperBound..<resumedBranch.lowerBound]
        let cancel = try #require(branch.range(of: "self.deferredTalkPress.cancel()"))
        let capturingOnly = try #require(branch.range(of: "if reason != .sleep, self.phase == .capturing {"))
        #expect(cancel.lowerBound < capturingOnly.lowerBound)
        #expect(!branch[..<cancel.lowerBound].contains("self.phase"))

        let shortcuts = try source("Talk/TalkModel+Shortcuts.swift")
        #expect(shortcuts.contains("suspended: !backgroundConsent.suspensions.isEmpty"))
        let defer_ = try #require(shortcuts.range(of: "func deferTalkKeyEdge(pressed: Bool) {"))
        let note = try #require(shortcuts.range(of: "deferredTalkPress.note(", range: defer_.upperBound..<shortcuts.endIndex))
        #expect(shortcuts[defer_.upperBound..<note.lowerBound].contains("guard backgroundConsent.suspensions.isEmpty else"))
        #expect(!shortcuts.contains("systemUptime"))
        #expect(shortcuts.contains("deferredTalkPress.take(now: DeferredTalkPress.now()"))
    }
}
