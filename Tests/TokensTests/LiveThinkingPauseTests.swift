


import Foundation
import Testing
@testable import Tokens

@Suite("Live pause feedback keeps transcript evidence separate")
struct LiveThinkingPauseTests {
    @Test func quickDisplayDoesNotAnnotateShortPauses() throws {
        var t = ThinkingPauseTracker()
        t.observe(rmsDB: -24, start: 0, end: 1, host: 10)
        t.observe(rmsDB: -70, start: 1, end: 1.15, host: 10.15)
        #expect(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 0, host: 10.15) == nil)
        let shown = try #require(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 0, host: 10.21))
        #expect(!shown.estimated)
        #expect(abs(shown.seconds - 0.21) < 0.0001)
        t.observe(rmsDB: -24, start: 1.15, end: 1.25, host: 10.25)
        #expect(t.pauses.isEmpty)
        #expect(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 0, host: 10.25) == nil)
    }

    @Test func threeSpeechPauseCycles() throws {
        var t = ThinkingPauseTracker()
        for cycle in 0..<3 {
            let start = Double(cycle) * 2
            t.observe(rmsDB: -24, start: start, end: start + 0.5, host: 100 + start + 0.5)
            #expect(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 0, host: 100 + start + 0.5) == nil)
            t.observe(rmsDB: -70, start: start + 0.5, end: start + 2, host: 100 + start + 2)
            let shown = try #require(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 0, host: 100 + start + 2))
            #expect(shown == LiveThinkingPause(seconds: 1.5, estimated: false))
        }
        #expect(t.pausesIncludingCurrent.map(\.duration) == [1.5, 1.5, 1.5])
        let body = InlineTalkMarkdown.render("Green notebook.\n\nTHINK (1.5000s)\n\nBlue pencil.\n\nTHINK (1.5000s)\n\nWhite paper.\n\nTHINK (1.5000s)")
        let formatted = ThinkingPrompt.format(title: "Pause fixture", body: body, durationSeconds: 6,
            countTranscript: "Green notebook. Blue pencil. White paper.", pauses: t.pausesIncludingCurrent.map(\.duration))
        #expect(formatted.components(separatedBy: "*[pause 1.5000]*").count == 4)
        #expect(formatted.contains("3x thinking (4.5000s)"))
        if let output = ProcessInfo.processInfo.environment["TOKENS_PAUSE_FIXTURE_DIR"] {
            try formatted.write(toFile: output + "/measured-fixture.md", atomically: true, encoding: .utf8)
        }
    }

    @Test func noiseRoomEstimateSurvivesWithoutBecomingMeasuredSilence() throws {
        var t = ThinkingPauseTracker()
        t.observe(rmsDB: -40, start: 0, end: 2.2, host: 20)
        let words = [TimedWord(text: "notebook", start: 0.2, end: 1, isFinal: true)]
        let shown = try #require(LiveThinkingPause.resolve(recording: true, measured: t, words: words, revisionAge: 1, host: 20))
        #expect(shown.estimated)
        #expect(abs(shown.seconds - 1.2) < 0.0001)
        #expect(t.pausesIncludingCurrent.isEmpty)
        #expect(LiveThinkingPause.resolve(recording: true, measured: t, words: words, revisionAge: 0, host: 20) == nil)
    }


    @Test func noisyEstimateReleasesOnSpeechBeforeRecognition() throws {
        var t = ThinkingPauseTracker()
        var display = LiveThinkingPauseDisplay()
        let words = [TimedWord(text: "notebook", start: 0.2, end: 1, isFinal: true)]
        t.observe(rmsDB: -40, start: 0, end: 2.2, host: 20)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 1, host: 20)?.estimated == true)
        t.observe(rmsDB: -24, start: 2.2, end: 2.3, host: 20.1)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 1.1, host: 20.1) == nil)
        t.observe(rmsDB: -40, start: 2.3, end: 2.4, host: 20.2)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 1.2, host: 20.2) == nil)
        let newer = [TimedWord(text: "pencil", start: 2.2, end: 2.3, isFinal: true)]
        t.observe(rmsDB: -40, start: 2.4, end: 3.5, host: 21.3)
        #expect(display.read(recording: true, measured: t, words: newer, revisionAge: 1.1, host: 21.3)?.estimated == true)
    }

    @Test func quietRoomSpeechDoesNotBecomeStaleEstimatedThinking() throws {
        var t = ThinkingPauseTracker()
        var display = LiveThinkingPauseDisplay()
        let words = [TimedWord(text: "notebook", start: 0.2, end: 1, isFinal: true)]
        t.observe(rmsDB: -24, start: 0, end: 1, host: 10)
        t.observe(rmsDB: -70, start: 1, end: 2.2, host: 11.2)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 1, host: 11.2)?.estimated == false)
        t.observe(rmsDB: -24, start: 2.2, end: 2.3, host: 11.3)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 1.1, host: 11.3) == nil)
        #expect(display.read(recording: false, measured: t, words: words, revisionAge: 1.2, host: 11.4) == nil)
    }

    @Test func missingSpeechStoppedSessionAndStalledTap() throws {
        var t = ThinkingPauseTracker()
        t.observe(rmsDB: -70, start: 0, end: 1, host: 10)
        #expect(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 3, host: 10) == nil)
        t.observe(rmsDB: -24, start: 1, end: 1.5, host: 10.5)
        t.observe(rmsDB: -70, start: 1.5, end: 2, host: 11)
        let capped = try #require(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 3, host: 100))
        #expect(capped.seconds == 0.75)
        #expect(LiveThinkingPause.resolve(recording: false, measured: t, words: [], revisionAge: 3, host: 11) == nil)
        t.observe(rmsDB: -70, start: 4, end: 4.05, host: 13.05)
        #expect(LiveThinkingPause.resolve(recording: true, measured: t, words: [], revisionAge: 0, host: 13.05) == nil)
    }
    @Test func noisyRelativeDropIsFastEstimatedAndResumesBeforeNewWords() throws {
        var t = ThinkingPauseTracker(), display = LiveThinkingPauseDisplay()
        let words = [TimedWord(text: "notebook", start: 0.1, end: 0.8, isFinal: true)]
        t.observe(rmsDB: -22, start: 0, end: 0.8, host: 10)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 0, host: 10) == nil)
        t.observe(rmsDB: -24, start: 0.8, end: 0.9, host: 10.1)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 0.1, host: 10.1) == nil)
        for i in 1...3 {
            let start = 0.9 + Double(i - 1) * 0.1
            t.observe(rmsDB: -40, start: start, end: start + 0.1, host: 10.1 + Double(i) * 0.1)
            let shown = display.read(recording: true, measured: t, words: words,
                revisionAge: 0.1 + Double(i) * 0.1, host: 10.1 + Double(i) * 0.1)
            if i == 1 { #expect(shown == nil) }
            if i == 3 { #expect(shown?.estimated == true); #expect(abs((shown?.seconds ?? 0) - 0.3) < 0.0001) }
        }
        #expect(t.pausesIncludingCurrent.isEmpty)
        t.observe(rmsDB: -24, start: 1.2, end: 1.3, host: 10.5)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 0.5, host: 10.5) == nil)
        t.observe(rmsDB: -40, start: 1.3, end: 1.7, host: 10.9)
        #expect(display.read(recording: true, measured: t, words: words, revisionAge: 0.9, host: 10.9) == nil)
    }

    @Test func briefFluctuationConstantNoiseAndStalledTapCannotAdvanceQuickEstimate() {
        var t = ThinkingPauseTracker(), quick = NoisyBubblePause()
        let words = [TimedWord(text: "notebook", start: 0.1, end: 0.8, isFinal: true)]
        for i in 1...12 {
            let start = Double(i - 1) * 0.1
            t.observe(rmsDB: -35, start: start, end: start + 0.1, host: 10 + Double(i) * 0.1)
            #expect(quick.read(recording: true, measured: t, words: words, revisionAge: 1, host: 10 + Double(i) * 0.1) == nil)
        }
        t.observe(rmsDB: -20, start: 1.2, end: 1.3, host: 11.3)
        _ = quick.read(recording: true, measured: t, words: words, revisionAge: 1, host: 11.3)
        t.observe(rmsDB: -40, start: 1.3, end: 1.4, host: 11.4)
        #expect(quick.read(recording: true, measured: t, words: words, revisionAge: 1, host: 11.4) == nil)
        #expect(quick.read(recording: true, measured: t, words: words, revisionAge: 1, host: 20) == nil)
        #expect(quick.read(recording: false, measured: t, words: words, revisionAge: 1, host: 20) == nil)
    }

    @Test func noisyCandidateNeverCountsMissingAudioOrUnrecognizedSound() {
        var t = ThinkingPauseTracker(), quick = NoisyBubblePause()
        let words = [TimedWord(text: "notebook", start: 0.1, end: 0.8, isFinal: true)]
        t.observe(rmsDB: -22, start: 0, end: 0.8, host: 10)
        #expect(quick.read(recording: true, measured: t, words: [], revisionAge: 1, host: 10) == nil)
        _ = quick.read(recording: true, measured: t, words: words, revisionAge: 0, host: 10)
        t.observe(rmsDB: -40, start: 0.8, end: 0.9, host: 10.1)
        #expect(quick.read(recording: true, measured: t, words: words, revisionAge: 0.1, host: 10.1) == nil)
        t.observe(rmsDB: -40, start: 1.15, end: 1.2, host: 10.4)
        #expect(quick.read(recording: true, measured: t, words: words, revisionAge: 0.4, host: 10.4) == nil)
        #expect(t.pausesIncludingCurrent.isEmpty)
    }

}

