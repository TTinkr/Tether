import Foundation
import AppKit
import ApplicationServices
import Testing
@testable import Tokens

struct StopStreamTests {
    static let prompt = "# π Blue notebook\n\n# Metadata\n\n> *3.2100s · 9 words · 168 wpm*\n\n## Transcript\n\nThe fictional blue notebook stays beside the lamp today. 👋"

    @Test func preparedEarlyPrefixAndContinuationMatchCompletePaste() throws {
        let payload = "# π\nThe blue notebook stays beside the lamp.\n\n---\n\n# Metadata\n\n> *final*"
        for before in ["", "Existing words", "Existing words\n", "👋"] {
            let target = CapturedTarget(id: UUID(), application: .current,
                pid: ProcessInfo.processInfo.processIdentifier, element: nil, window: nil,
                screenFrame: nil, selection: CFRange(location: before.utf16.count, length: 0),
                valueBefore: before)
            let prefix = TargetDelivery.preparedText("# π\n", for: target,
                preservingTrailingWhitespace: true)
            let remainder = try #require(StopStream.remainderSteps(prefix: "# π\n", payload: payload))
            #expect(prefix.hasSuffix("π\n"))
            #expect(prefix + remainder.joined() == TargetDelivery.preparedText(payload, for: target))
            #expect(!(prefix + remainder.joined()).contains("πThe"))
        }
    }

    @Test func prefixWhitespacePreservationDoesNotChangeOrdinaryPaste() {
        let target = CapturedTarget(id: UUID(), application: .current,
            pid: ProcessInfo.processInfo.processIdentifier, element: nil, window: nil,
            screenFrame: nil, selection: CFRange(location: 0, length: 0), valueBefore: "")
        #expect(TargetDelivery.preparedText(" # π\n\n", for: target) == "# π")
        #expect(TargetDelivery.preparedText("# π\r\n", for: target,
            preservingTrailingWhitespace: true) == "# π\r\n")
        #expect(TargetDelivery.preparedText(" \n\t", for: target,
            preservingTrailingWhitespace: true).isEmpty)
    }

    @Test func prefixAndRemainingPiecesPreserveEveryCharacter() throws {
        for prefix in [StopStream.prefix, "# π Blue notebook\n\n"] {
            let pieces = try #require(StopStream.remainderSteps(prefix: prefix, payload: Self.prompt))
            #expect(pieces.count == 2)
            #expect(prefix + pieces.joined() == Self.prompt)
            #expect(pieces.allSatisfy { !$0.isEmpty })
        }
        #expect(StopStream.remainderSteps(prefix: "# π Different", payload: Self.prompt) == nil)
    }
    @Test func markerLeavesFinalTitleAndEndingWordsIntact() throws {
        let final = Self.prompt.replacingOccurrences(of: "Blue notebook", with: "The corrected title")
        let pieces = try #require(StopStream.remainderSteps(prefix: StopStream.prefix, payload: final))
        #expect(StopStream.prefix + pieces.joined() == final)
        #expect(pieces.last?.hasSuffix("today. 👋") == true)
        #expect(pieces.first?.hasPrefix(" The corrected title") == true)
    }
    static let tailPrompt = "# π Blue notebook\n\n## Transcript\n\nThe fictional blue notebook stays beside the lamp today. 👋\n\n---\n\n# Metadata\n\n> *3.2100s · 9 words · 168 wpm*"

    @Test func spokenOpeningUsesOnlyStableWordsAndKeepsMetadataForLast() throws {
        let payload = Self.tailPrompt
        let first = try #require(StopStream.spokenOpening(payload: payload, stableText: "The fictional"))
        #expect(first == "# π Blue notebook\n\n## Transcript\n\nThe ficti")
        #expect(!first.contains("# Metadata"))
        #expect(StopStream.spokenOpening(payload: payload, stableText: "The") == nil)
        #expect(StopStream.spokenOpening(payload: payload, stableText: "The different") == nil)
        let tail = try #require(StopStream.remainderSteps(prefix: first, payload: payload))
        #expect(tail.count == 2)
        #expect(first + tail.joined() == payload)
        #expect(tail.last?.hasSuffix("168 wpm*") == true)
        #expect(tail.last?.contains("today. 👋") == true)
    }

    @Test func protectedAndPauseOpeningNeverCommitsAPartialSpan() {
        for body in ["`The fictional` blue notebook stays beside the lamp",
                     "The\n*[pause 1.0000]* fictional blue notebook stays beside the lamp",
                     "<char>R I L E Y</char> has a fictional notebook"] {
            let payload = "# π Test\n\n## Transcript\n\n" + body + "\n\n---\n\n# Metadata\n\n> *final*"
            #expect(StopStream.spokenOpening(payload: payload, stableText: body) == nil)
        }
    }

    @Test func revisedEndingAndExactFinalMetadataRemainInLastPiece() throws {
        let first = try #require(StopStream.spokenOpening(payload: Self.tailPrompt, stableText: "The fictional"))
        let final = Self.tailPrompt.replacingOccurrences(of: "today. 👋", with: "tomorrow afternoon. 👋")
            .replacingOccurrences(of: "9 words", with: "10 words")
        let rest = try #require(StopStream.remainderSteps(prefix: first, payload: final))
        #expect(first + rest.joined() == final)
        #expect(rest.last?.contains("tomorrow afternoon. 👋") == true)
        #expect(rest.last?.contains("10 words") == true)
        #expect(StopStream.remainderSteps(prefix: first, payload: final.replacingOccurrences(of: "The fictional", with: "A revised")) == nil)
    }

    @Test func minimalFormatStreamsWordsThenFinalMetadataExactly() throws {
        let payload = "# π\nThe fictional blue notebook stays beside the lamp today. 👋\n\n---\n\n# Metadata\n\n> *final counts*"
        let first = try #require(StopStream.spokenOpening(payload: payload, stableText: "The fictional blue notebook"))
        #expect(first == "# π\nThe ficti")
        for prefix in [StopStream.prefix, first] {
            let rest = try #require(StopStream.remainderSteps(prefix: prefix, payload: payload))
            #expect(prefix + rest.joined() == payload)
            #expect(!rest[0].contains("# Metadata"))
            #expect(rest.last?.contains("# Metadata") == true)
        }
    }

    @Test func completedPromptAlwaysHasThreeExactPieces() throws {
        for payload in [Self.prompt, Self.tailPrompt] {
            let plan = try #require(ThreeStepPaste.plan(payload))
            #expect(plan.steps.count == 3)
            #expect(plan.steps.joined() == payload)
            #expect(plan.steps[0].hasSuffix("The ficti"))
            #expect(plan.steps[1].hasPrefix("onal "))
        }
    }

    @Test func finalBeforePrefixDoesNotBecomeAnEarlyStream() {
        var gate = StopStreamGate<String>()
        let result1 = gate.hold("already final", session: UUID())
        #expect(!result1)
    }
    @Test func finalDuringPrefixWaitsAndOnlyFirstCompletionIsReleased() {
        var gate = StopStreamGate<String>()
        let session = UUID()
        let result2 = gate.begin(session: session)
        #expect(result2)
        let result3 = gate.begin(session: session)
        #expect(!result3)
        let result4 = gate.hold("all final words", session: session)
        #expect(result4)
        let result5 = gate.hold("duplicate callback", session: session)
        #expect(result5)
        let result6 = gate.finish(session: session)
        #expect(result6 == "all final words")
        let result7 = gate.finish(session: session)
        #expect(result7 == nil)
        let result8 = gate.hold("late", session: session)
        #expect(!result8)
    }
    @Test func acknowledgedPrefixBeforeFinalDoesNotHoldTheFinalResult() {
        var gate = StopStreamGate<String>()
        let session = UUID()
        let result9 = gate.begin(session: session)
        #expect(result9)
        let result10 = gate.finish(session: session)
        #expect(result10 == nil)
        let result11 = gate.hold("final result", session: session)
        #expect(!result11)
    }
    @Test func resetRejectsOldCallbacksWithoutConsumingNewTalk() {
        var gate = StopStreamGate<String>()
        let old = UUID(), current = UUID()
        let result12 = gate.begin(session: old)
        #expect(result12)
        let result13 = gate.hold("old words", session: old)
        #expect(result13)
        gate.reset()
        let result14 = gate.begin(session: current)
        #expect(result14)
        let result15 = gate.hold("stale", session: old)
        #expect(!result15)
        let result16 = gate.finish(session: old)
        #expect(result16 == nil)
        let result17 = gate.hold("new words", session: current)
        #expect(result17)
        let result18 = gate.finish(session: current)
        #expect(result18 == "new words")
    }
    @Test func rapidNewTalkDropsPriorPrefixAndOldFinal() {
        var state = StopStreamState<String>()
        let old = UUID(), current = UUID()
        _ = state.gate.begin(session: old)
        _ = state.gate.hold("old final", session: old)
        state.prefix = StopStream.prefix
        state.frozenTitle = "Old title"
        state.uncertain = true
        state.stoppedText = "old stop words"
        state.reset()
        #expect(state.prefix == nil)
        #expect(state.frozenTitle == nil)
        #expect(state.stoppedText.isEmpty)
        #expect(!state.uncertain)
        let began = state.gate.begin(session: current)
        #expect(began)
        let stale = state.gate.finish(session: old)
        #expect(stale == nil)
        _ = state.gate.hold("new complete payload", session: current)
        let final = state.gate.finish(session: current)
        #expect(final == "new complete payload")
    }

}
