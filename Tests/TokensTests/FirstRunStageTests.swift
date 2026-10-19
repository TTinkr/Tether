
import AVFoundation
import Speech
import SwiftUI
import Testing
@testable import Tokens

@Suite("First-run ledger")
struct FirstRunStageTests {
    @Test @MainActor func actualMissingPermissionNamesTheNextAction() {
        #expect(TokensHome.accessTitle(trusted: false, monitorReady: true, microphone: true, speech: true) == "Allow Accessibility")
        #expect(TokensHome.accessTitle(trusted: true, monitorReady: false, microphone: true, speech: true) == "Relaunch to finish")
        #expect(TokensHome.accessTitle(trusted: true, monitorReady: true, microphone: false, speech: true) == "Allow Microphone")
        #expect(TokensHome.accessTitle(trusted: true, monitorReady: true, microphone: true, speech: false) == "Allow Speech Recognition")
        #expect(TokensHome.accessTitle(trusted: true, monitorReady: true, microphone: true, speech: true) == "Permissions ready")
    }

    @Test("Accessibility comes first until macOS grants it, then Talk")
    func accessThenTalk() {
        #expect(FirstRunStage.after(accessGranted: false, microphone: .authorized, speech: .authorized) == .access)
        #expect(FirstRunStage.after(accessGranted: true, microphone: .authorized, speech: .authorized)  == .talk)
    }

    @Test("Only both actual audio grants permit readiness across all sixteen combinations")
    func audioPermissionMatrix() {
        let microphones: [AVAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]
        let speeches: [SFSpeechRecognizerAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]
        for microphone in microphones {
            for speech in speeches {
                let expected: FirstRunStage = microphone == .authorized && speech == .authorized ? .talk : .access
                #expect(FirstRunStage.after(accessGranted: true,
                                           microphone: microphone, speech: speech) == expected)
            }
        }
    }

    @Test("Re-evaluated activation or Start snapshot cannot retain stale readiness")
    func revokedGrantAndRelaunch() {
        #expect(FirstRunStage.after(accessGranted: true,
                                   microphone: .authorized, speech: .authorized) == .talk)
        #expect(FirstRunStage.after(accessGranted: true,
                                   microphone: .denied, speech: .authorized) == .access)
        #expect(FirstRunStage.after(accessGranted: true,
                                   microphone: .authorized, speech: .authorized, needsRelaunch: true) == .access)
    }

    @Test("Two numbered steps in order, no Terms step")
    func numbering() {
        #expect(FirstRunStage.allCases.map(\.rawValue) == [1, 2])
        #expect(FirstRunStage.allCases.map(\.title) == ["Allow Accessibility", "Talk"])
    }

    @Test("The setup rail names each step and whether it is done, now or next")
    func railLabels() {
        #expect(FirstRunStage.allCases.map(\.railName) == ["Access", "Talk"])
        #expect(FirstRunStage.allCases.map(\.symbol) == ["hand.raised", "mic"])
        #expect(FirstRunStage.allCases.map { $0.railLabel(current: .access) }
                == ["Step 1 of 2, Access, now", "Step 2 of 2, Talk, next"])
        #expect(FirstRunStage.allCases.map { $0.railLabel(current: .talk) }
                == ["Step 1 of 2, Access, done", "Step 2 of 2, Talk, now"])
    }

    @Test("Set-up headline sits on the grid at the proof sizes")
    func setupGeometry() {
        // 1040 × 720: headline on rule 2. 760 × 520: rule 1.
        #expect(TokensSetupLayout.headlineRule(sheetHeight: 720) == 2)
        #expect(TokensSetupLayout.headlineRule(sheetHeight: 520) == 1)
    }

    @Test("The red ring is deterministic and stays inside its square")
    func ringGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let a    = FirstRunRing(seed: 41).path(in: rect)
        let b    = FirstRunRing(seed: 41).path(in: rect)
        #expect(a.description == b.description)
        #expect(!a.isEmpty)
        let bounds = a.boundingRect
        #expect(bounds.minX >= -2 && bounds.minY >= -2 && bounds.maxX <= 22 && bounds.maxY <= 22)
        #expect(bounds.width > 14 && bounds.height > 14)
    }
}

@Suite("Selected engine permissions")
struct SelectedEnginePermissionTests {
    @Test func orukeetDoesNotRequireOrInventAppleSpeechGrant() {
        for speech in [SFSpeechRecognizerAuthorizationStatus.denied, .restricted, .notDetermined] {
            let snapshot = FirstRunAccessSnapshot(trusted: true, monitorReady: true,
                needsRelaunch: false, microphone: .authorized, speech: speech, speechRequired: false)
            #expect(snapshot.speech == speech)
            #expect(snapshot.guide == nil)
            #expect(FirstRunStage.after(accessGranted: true,
                microphone: .authorized, speech: speech, speechRequired: false) == .talk)
            #expect(FirstRunStage.after(accessGranted: false,
                microphone: .authorized, speech: speech, speechRequired: false) == .access)
            #expect(FirstRunStage.after(accessGranted: true,
                microphone: .denied, speech: speech, speechRequired: false) == .access)
        }
        #expect(TokensHome.accessTitle(trusted: true, monitorReady: true, microphone: true,
            speech: false, speechRequired: false) == "Permissions ready")
    }

    @Test func orukeetStillPromptsOnlyForMissingMicrophone() {
        #expect(FirstRunAccessSnapshot.preview("orukeet-ready")?.guide == nil)
        #expect(FirstRunAccessSnapshot.preview("orukeet-prompt")?.speechRequired == false)
        #expect(FirstRunAccessSnapshot.preview("orukeet-microphone")?.guide == .microphone)
        let snapshot = FirstRunAccessSnapshot(trusted: true, monitorReady: true,
            needsRelaunch: false, microphone: .notDetermined, speech: .denied, speechRequired: false)
        #expect(snapshot.guide == .prompt)
        #expect(TokensFirstRunAccessStep.instruction(.prompt, appName: "Tokens", speechRequired: false)
            == "Click Allow microphone, then choose Allow when macOS asks.")
    }

    /// The ready state must match the stage gate exactly: it reads ready only when Talk would open,
    /// and never for a missing or undecided grant, whichever engine is selected.
    @Test func readyMatchesTheStageGateForEveryReading() {
        let mics: [AVAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]
        let speeches: [SFSpeechRecognizerAuthorizationStatus] = [.authorized, .denied, .restricted, .notDetermined]
        for trusted in [true, false] { for monitor in [true, false] { for relaunch in [true, false] {
            for mic in mics { for speech in speeches { for required in [true, false] {
                let snapshot = FirstRunAccessSnapshot(trusted: trusted, monitorReady: monitor,
                    needsRelaunch: relaunch, microphone: mic, speech: speech, speechRequired: required)
                let gate = FirstRunStage.after(accessGranted: trusted && monitor,
                    microphone: mic, speech: speech, needsRelaunch: relaunch, speechRequired: required)
                #expect(snapshot.allAllowed == (gate == .talk))
                if snapshot.allAllowed { #expect(snapshot.guide == nil) }
            } } }
        } } }
        #expect(FirstRunAccessSnapshot.preview("orukeet-ready")?.allAllowed == true)
        #expect(FirstRunAccessSnapshot.preview("orukeet-prompt")?.allAllowed == false)
        #expect(FirstRunAccessSnapshot.preview("orukeet-microphone")?.allAllowed == false)
    }

    /// Ready copy names only the permissions the engine uses; it never mentions Apple Speech for
    /// Orukeet and never asks for anything.
    @Test func readyNoteNamesOnlyTheEnginesPermissions() {
        let orukeet = TokensFirstRunAccessStep.readyNote(speechRequired: false)
        #expect(orukeet == "Accessibility and Microphone are allowed.")
        #expect(!orukeet.contains("Speech"))
        #expect(TokensFirstRunAccessStep.readyNote(speechRequired: true).contains("Speech Recognition"))
    }

    /// The prompt picture's caption names Speech Recognition only for the Apple engine.
    @Test func promptCaptionFollowsTheEngine() {
        #expect(AccessGuidePane.prompt.caption(speechRequired: false) == "Microphone")
        #expect(AccessGuidePane.prompt.caption() == "Microphone and Speech Recognition")
        for pane in AccessGuidePane.allCases where pane != .prompt {
            #expect(pane.caption(speechRequired: false) == pane.listTitle)
            #expect(pane.caption(speechRequired: true) == pane.listTitle)
        }
    }
}
