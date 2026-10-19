


//
/*
CoreTests+CaptureAndCommands.swift
Tokens · Tests

Owns: key gates, capture commands and shortcut preferences
Never: changes the assertion order or weakens checks.
See: CoreTests.swift (ordered suite entry point).
*/


import Foundation
import Testing
@testable import Tokens


extension CoreTests {
    static func captureAndCommands() throws {
        precondition(VisualSentenceBatch.target(canonical: "Not finished yet", visible: "") == "")
        precondition(VisualSentenceBatch.target(canonical: "Complete. Still speaking", visible: "") == "Complete.")
        precondition(CharacterTalk.render("C-LA-U-D and then").markdownText == "*<char>CLAUD</char>* and then")
        precondition(CharacterTalk.render("CLA-UD").markdownText == "*<char>CLAUD</char>*")
        var returnGate = DeliveryReturnGate()
        precondition(VisualSentenceBatch.target(canonical: "One. Two! Three?", visible: "") == "One. Two!")
        precondition(VisualSentenceBatch.target(canonical: "One. Two! Three?", visible: "One. Two!") == "One. Two! Three?")
        precondition(VisualSentenceBatch.target(canonical: "Changed", visible: "Old") == "Changed")
        precondition(!returnGate.handle(keyCode: 36, down: true))
        returnGate.begin()
        precondition(returnGate.handle(keyCode: 36, down: true))
        precondition(returnGate.requested)
        precondition(!returnGate.handle(keyCode: 49, down: true))
        returnGate.finish()
        precondition(!returnGate.requested)
        precondition(returnGate.handle(keyCode: 36, down: false))
        precondition(!returnGate.handle(keyCode: 36, down: true))
        precondition(CharacterTalk.render("So, ABCD, FGH, H, JKLMNOP.").markdownText == "So, *<char>ABCDFGHHJKLMNOP</char>*.")
        precondition(CharacterTalk.render("Use API SDK and HTTP today.").markdownText == "Use API SDK and HTTP today.")
        print("PASS: reserved Enter cannot race insertion; grouped alphabet spelling receives TC tags")
        let defaults = UserDefaults(suiteName: "TTTSpeedOfSoundTests-\(UUID().uuidString)")!
        precondition(SpeedOfSoundPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: SpeedOfSoundPreference.key)
        precondition(!SpeedOfSoundPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: SpeedOfSoundPreference.key)
        precondition(SpeedOfSoundPreference.isEnabled(in: defaults))
        var fastChord = FastFinishChord()
        precondition(fastChord.keyDown(keyCode: 36, rightOptionHeld: true, enabled: true) == .finish)
        precondition(fastChord.keyDown(keyCode: 36, rightOptionHeld: true, enabled: true) == .consume)
        precondition(fastChord.keyDown(keyCode: 76, rightOptionHeld: true, enabled: true) == .consume)
        fastChord.optionReleased()
        precondition(fastChord.keyDown(keyCode: 76, rightOptionHeld: true, enabled: true) == .finish)
        fastChord = FastFinishChord()
        precondition(fastChord.keyDown(keyCode: 36, rightOptionHeld: false, enabled: true) == .passThrough)
        precondition(fastChord.keyDown(keyCode: 36, rightOptionHeld: true, enabled: false) == .passThrough)
        precondition(fastChord.keyDown(keyCode: 49, rightOptionHeld: true, enabled: true) == .passThrough)
        print("PASS: Speed of Sound defaults on, persists off/on, and only intercepts Return while Right Option is held")

        var readiness = StopReadiness()
        precondition(readiness.decision(at: 0, transcriptFinalized: true).graceSeconds == 0.45)
        readiness.observe(rmsDB: -20, at: 1, duration: 0.02)
        precondition(readiness.decision(at: 1, transcriptFinalized: true).reason == "recent_signal")
        for tick in 1...16 { readiness.observe(rmsDB: -70, at: 1 + Double(tick) * 0.02, duration: 0.02) }
        precondition(readiness.decision(at: 1.33, transcriptFinalized: true).graceSeconds == 0)
        precondition(readiness.decision(at: 1.33, transcriptFinalized: false).reason == "pending_recognition")
        precondition(readiness.decision(at: 2, transcriptFinalized: true).reason == "unconfirmed_audio")
        readiness.observe(rmsDB: -52, at: 1.34, duration: 0.02) // Quiet whisper breaks silence.
        precondition(readiness.decision(at: 1.35, transcriptFinalized: true).graceSeconds == 0.45)
        readiness.observe(rmsDB: -70, at: 3, duration: 0.02) // Missing buffers are not silence.
        precondition(readiness.decision(at: 3, transcriptFinalized: true).graceSeconds == 0.45)
        print("PASS: adaptive stop quiet-finalized, pending tail, whispers, stale and dropped buffers")
        // Lab navigation accepts settled partials without authorizing delivery.
        for phrase in ["Stop Tinkr", "Stop Tinker!", "Tinkr stop", "Tinker pause"] {
            precondition(VoiceCommandParser.standaloneLabCommand(in: phrase) == .stopListening)
            precondition(VoiceCommandParser.standaloneCommand(in: phrase) == nil)
        }
        precondition(VoiceCommandParser.standaloneLabCommand(in: "Tinkr clothes") == .closeWindow)
        precondition(VoiceCommandParser.standaloneCommand(in: "Tinkr clothes") == nil)
        for phrase in ["please Stop Tinkr", "I said Tinkr close", "“Stop Tinkr”", "Tinkr paste", "Tinkr send", "copy talk"] {
            precondition(VoiceCommandParser.standaloneLabCommand(in: phrase) == nil)
        }
        var lab = LabCommandTracker()
        lab.observe("Tinker", at: 0)
        precondition(lab.poll(at: 0.3) == nil)
        lab.observe("Tinker clothes", at: 0.4)
        precondition(lab.poll(at: 0.9) == nil)
        precondition(lab.poll(at: 1.1) == .closeWindow)
        precondition(lab.poll(at: 2) == nil) // exactly one event per settled chunk
        lab.observe("Tinker clothes Stop Tinkr", at: 2.1)
        precondition(lab.poll(at: 2.8) == .stopListening)
        /*
        Historical installed-microphone regression, replayed here with text/time fixtures:
        ASR paused >650ms between Stop and Tinker; the prefix must survive a settled poll.
        */
        var delayedLab = LabCommandTracker()
        delayedLab.observe("Every word stays here.", at: 0)
        precondition(delayedLab.poll(at: 1) == nil)
        delayedLab.observe("Every word stays here. Stop", at: 2)
        precondition(delayedLab.poll(at: 3) == nil)
        delayedLab.observe("Every word stays here. Stop Tinker", at: 4)
        precondition(delayedLab.poll(at: 5) == .stopListening)
        precondition(delayedLab.poll(at: 6) == nil)
        var delayedClose = LabCommandTracker()
        delayedClose.observe("Tinker", at: 0)
        precondition(delayedClose.poll(at: 1) == nil)
        delayedClose.observe("Tinker close", at: 2)
        precondition(delayedClose.poll(at: 3) == .closeWindow)
        var literalPrefix = LabCommandTracker()
        literalPrefix.observe("Stop", at: 0)
        precondition(literalPrefix.poll(at: 1) == nil)
        literalPrefix.observe("Stop making this change", at: 2)
        precondition(literalPrefix.poll(at: 3) == nil)
        var punctuatedLab = LabCommandTracker()
        punctuatedLab.observe("hello there", at: 0)
        precondition(punctuatedLab.poll(at: 1) == nil)
        punctuatedLab.observe("Hello there. Tinker close.", at: 2)
        precondition(punctuatedLab.poll(at: 3) == .closeWindow)
        var revisedLab = LabCommandTracker()
        revisedLab.observe("ordinary words", at: 0)
        precondition(revisedLab.poll(at: 1) == nil)
        revisedLab.observe("corrected words Tinkr close", at: 2)
        precondition(revisedLab.poll(at: 3) == nil) // revised prefix fails closed
        revisedLab.observe("corrected words Tinkr close Stop Tinker", at: 4)
        precondition(revisedLab.poll(at: 5) == .stopListening)

    }
}

