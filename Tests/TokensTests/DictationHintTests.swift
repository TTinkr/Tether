import Testing
@testable import Tokens

@Suite("Home shortcut instruction follows the real key edges")
struct DictationHintTests {
    @Test(arguments: [RightOptionMode.tap, .hold])
    func recordingInstructionMatchesStopEdge(mode: RightOptionMode) {
        let hint = TokensDictationHint(phase: .capturing, mode: mode)
        #expect(!hint.isFinishing)
        #expect(hint.purpose == "to stop")
        #expect(hint.verb == (mode == .tap ? "Press" : "Release"))
        #expect(mode.action(pressed: hint.verb == "Press", capturing: true, finalizing: false) == .finish)
    }

    @Test(arguments: [RightOptionMode.tap, .hold])
    func finalizingNeverInvitesAnotherKey(mode: RightOptionMode) {
        let hint = TokensDictationHint(phase: .finalizing, mode: mode)
        #expect(hint.isFinishing)
        #expect(mode.action(pressed: true, capturing: false, finalizing: true) == .ignore)
        #expect(mode.action(pressed: false, capturing: false, finalizing: true) == .ignore)
    }

    @Test(arguments: [TalkPhase.idle, .delivered, .failed], [RightOptionMode.tap, .hold])
    func readyPhasesInviteStart(phase: TalkPhase, mode: RightOptionMode) {
        let hint = TokensDictationHint(phase: phase, mode: mode)
        #expect(!hint.isFinishing)
        #expect(hint.purpose == "to talk")
        #expect(hint.verb == (mode == .tap ? "Press" : "Hold"))
        #expect(mode.action(pressed: true, capturing: false, finalizing: false) == .begin)
    }
}
