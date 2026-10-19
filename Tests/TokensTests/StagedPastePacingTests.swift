import Foundation
import Testing
@testable import Tokens

struct StagedPastePacingTests {
    private let pieces = ["# π Lamp\n\n", "one ", "two ", "last 👋\n"]

    @Test func readyEditorNeedsNoUnconditionalSleep() {
        var text = "", posts: [String] = [], sleeps: [UInt32] = []
        let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, expected in
                if let expected { #expect(expected == text) }
                posts.append(piece); text += piece; return nil
            }, read: { text }, sleep: { sleeps.append($0) }, now: { 0 })
        #expect(outcome == .posted(acknowledged: pieces.count - 1))
        #expect(posts == pieces)
        #expect(text == pieces.joined())
        #expect(sleeps.isEmpty)
    }

    @Test func exhaustedRevealBudgetCombinesOnlyAfterPendingPieceLands() {
        var time: TimeInterval = 0
        var text = "", pending: String?, posts: [String] = [], sleeps: [UInt32] = []
        let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, expected in
                #expect(pending == nil, "The previous clipboard piece must be consumed before replacement")
                if let expected { #expect(expected == text) }
                posts.append(piece); pending = piece; return nil
            }, read: {
                // The budget expires at50ms but the first piece does not arrive until64ms.
                if time >= 0.064, let piece = pending { text += piece; pending = nil }
                return text
            }, sleep: { delay in sleeps.append(delay); time += Double(delay) / 1_000_000 }, now: { time })
        #expect(outcome == .posted(acknowledged: 1))
        #expect(posts == [pieces[0], pieces.dropFirst().joined()])
        #expect(sleeps.allSatisfy { $0 == 8_000 })
        #expect(time >= 0.064 && time < 0.073)
        #expect(text + (pending ?? "") == pieces.joined())
    }

    @Test func budgetIncludesPostAndReadCostEvenWithoutSleep() {
        var time: TimeInterval = 0
        var text = "", posts: [String] = []
        let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                time += 0.06; posts.append(piece); text += piece; return nil
            }, read: { text }, sleep: { _ in Issue.record("No polling sleep needed") }, now: { time })
        #expect(outcome == .posted(acknowledged: 1))
        #expect(posts == [pieces[0], pieces.dropFirst().joined()])
        #expect(text == pieces.joined())
    }

    @Test func expiredBudgetDoesNotReplayOrAppendToAnUnacknowledgedPaste() {
        var time: TimeInterval = 0
        var posts: [String] = [], sleeps: [UInt32] = []
        let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                posts.append(piece); return nil
            }, read: { "" }, sleep: { delay in sleeps.append(delay); time += Double(delay) / 1_000_000 },
            now: { time })
        #expect(outcome == .failedPartway("unacknowledged", posted: 1))
        #expect(posts == [pieces[0]])
        #expect(sleeps.filter { $0 == 8_000 }.count == 50)
        #expect(sleeps.last == 250_000)
        #expect(abs(time - 0.65) < 0.000_001)
    }

    @Test func expiredBudgetDoesNotTreatDifferentTextAsAnAcknowledgement() {
        var time: TimeInterval = 0
        var posts: [String] = []
        let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                posts.append(piece); return nil
            }, read: { time >= 0.056 ? "a different edit" : "" },
            sleep: { time += Double($0) / 1_000_000 }, now: { time })
        #expect(outcome == .failedPartway("unexpected_editor_text", posted: 1))
        #expect(posts == [pieces[0]])
    }

    @Test func unreadableAcknowledgementWaitsRatherThanAdvancingClipboard() {
        var text = "", acknowledged = false
        var posts: [String] = [], sleeps: [UInt32] = []
        let outcome = StagedPasteDriver.run(pieces: ["first ", "last"], initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, expected in
                if expected != nil { #expect(acknowledged) }
                posts.append(piece); text += piece; return nil
            }, read: { acknowledged ? text : nil },
            sleep: { delay in sleeps.append(delay); acknowledged = true }, now: { 0 })
        #expect(outcome == .posted(acknowledged: 1))
        #expect(posts == ["first ", "last"])
        #expect(sleeps == [8_000])
    }
}

struct RichComposerStagingTests {
    @Test func emptyStateAndBlankLineUseObservedTextForEveryNextPiece() {
        for initial in ["Ask anything here\n", "\n", "existing draft\n"] {
            let start = initial == "Ask anything here\n" ? 0 : initial.utf16.count - 1
            var text = initial
            var caret = NSRange(location: start, length: 0)
            var posts: [String] = []
            let pieces = ["# π Lamp\n\n## Transcript\n\nThe bl", "ue notebook ", "is here.\n\n---\n\n# Metadata\n"]
            let outcome = StagedPasteDriver.run(pieces: pieces, initial: initial,
                selection: caret, post: { piece, expected in
                    if let expected { #expect(expected == text) }
                    // Fictional rich editor fills its empty line and exposes actual text.
                    if posts.isEmpty {
                        text = String((text as NSString).substring(to: caret.location)) + piece
                    } else {
                        text = (text as NSString).replacingCharacters(in: caret, with: piece)
                    }
                    caret = NSRange(location: caret.location + piece.utf16.count, length: 0)
                    posts.append(piece)
                    return nil
                }, read: { text }, sleep: { _ in }, now: { 0 },
                accepts: { before, range, piece, after in
                    PasteAcknowledgement.evaluate(before: before, selection: range, inserted: piece,
                        after: after, caret: caret, richComposer: true) == .verified
                })
            #expect(outcome == .posted(acknowledged: 2))
            #expect(posts == pieces)
            #expect(text == (initial as NSString).substring(to: start) + pieces.joined())
        }
    }

    @Test func richComposerWrongCaretOrMissingWordsNeverPostSecondPiece() {
        for wrongCaret in [false, true] {
            var text = "Ask anything here\n", posts: [String] = []
            let outcome = StagedPasteDriver.run(pieces: ["first word ", "last word"], initial: text,
                selection: NSRange(location: 0, length: 0), post: { piece, _ in
                    posts.append(piece); text = wrongCaret ? piece : "first "; return nil
                }, read: { text }, sleep: { _ in }, now: { 0 },
                accepts: { before, range, piece, after in
                    PasteAcknowledgement.evaluate(before: before, selection: range, inserted: piece,
                        after: after, caret: NSRange(location: wrongCaret ? 0 : piece.utf16.count, length: 0),
                        richComposer: true) == .verified
                })
            #expect(outcome == .failedPartway("unexpected_editor_text", posted: 1))
            #expect(posts == ["first word "])
        }
    }

    /// Build 81: a plain field never arms rich composers; a rich app's own rich success does.
    @Test func richComposerTrustComesOnlyFromRichComposerPastes() {
        let suite = "rich-trust-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let slack = "com.tinyspeck.slackmacgap"
        PasteAckHistory.record(bundle: slack, acknowledged: true, in: defaults)               // a plain field
        #expect(PasteAckHistory.allowsStaging(bundle: slack, richComposer: false, in: defaults))
        #expect(!PasteAckHistory.allowsStaging(bundle: slack, richComposer: true, in: defaults))
        PasteAckHistory.record(bundle: slack, acknowledged: true, richComposer: true, in: defaults)
        #expect(PasteAckHistory.allowsStaging(bundle: slack, richComposer: true, in: defaults))
        PasteAckHistory.record(bundle: slack, acknowledged: false, in: defaults)              // any failure resets both
        #expect(!PasteAckHistory.allowsStaging(bundle: slack, richComposer: true, in: defaults))
        #expect(!PasteAckHistory.allowsStaging(bundle: slack, richComposer: false, in: defaults))
    }

    /// Build 83: existing plain-field calibration must not enable a browser omnibox,
    /// another input or another site's rich composer to receive a speculative prefix.
    @Test func browserFieldsKeepOneCompletePasteAfterPlainOrRichCalibration() {
        let suite = "browser-single-final-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for browser in PasteAckHistory.browserBundles {
            for calibratedRich in [false, true] {
                for _ in 0..<3 {
                    PasteAckHistory.record(bundle: browser, acknowledged: true,
                                           richComposer: calibratedRich, in: defaults)
                }
                #expect(PasteAckHistory.trusts(bundle: browser, in: defaults))
                #expect(PasteAckHistory.requiresSingleFinalPaste(bundle: browser))
                for focusedRich in [false, true] {
                    // This is also the gate checked by the stop-prefix transport.
                    #expect(!PasteAckHistory.allowsStaging(bundle: browser, richComposer: focusedRich, in: defaults))
                    for continuation in [false, true] {
                        for trial in [false, true] {
                            let eligibility = PasteAckHistory.deliveryStagingEligibility(bundle: browser,
                                richComposer: focusedRich, exactPlan: true, continuation: continuation,
                                threeSteps: true, stageable: true, boundaryTrial: trial, in: defaults)
                            #expect(!eligibility.historyAllows)
                            #expect(!eligibility.finalRevealAllows)
                            #expect(!eligibility.mayStage)
                        }
                    }
                }
            }
        }
    }

    @Test func browserCannotBypassSinglePasteThroughDirectInsertionOrEarlyPrefix() {
        let suite = "browser-prefix-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for browser in PasteAckHistory.browserBundles {
            PasteAckHistory.record(bundle: browser, acknowledged: true, in: defaults)
            // The public early-prefix entry point refuses this before AX/clipboard work;
            // the inner lease guard independently declines through allowsStaging.
            #expect(PasteAckHistory.requiresSingleFinalPaste(bundle: browser))
            #expect(!PasteAckHistory.allowsStaging(bundle: browser, richComposer: false, in: defaults))
            #expect(!StagedPrompt.allowsDirectInsertion(bundleIdentifier: browser))
        }
        // Preserve native editor opt-in and the native Codex/Claude prefix safeguards.
        PasteAckHistory.record(bundle: "com.apple.TextEdit", acknowledged: true, in: defaults)
        #expect(!PasteAckHistory.requiresSingleFinalPaste(bundle: "com.apple.TextEdit"))
        #expect(PasteAckHistory.allowsStaging(bundle: "com.apple.TextEdit", richComposer: false, in: defaults))
        for native in PasteAckHistory.finalRevealBundles {
            PasteAckHistory.record(bundle: native, acknowledged: true, richComposer: true, in: defaults)
            #expect(!PasteAckHistory.requiresSingleFinalPaste(bundle: native))
            #expect(!PasteAckHistory.allowsStaging(bundle: native, richComposer: true, in: defaults))
        }
    }

    @Test func claudeBuildBreakerCannotBeBypassedByGenericPasteHistory() {
        let suite = "claude-full-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let claude = "com.anthropic.claudefordesktop"
        func gate(_ bundle: String = "com.anthropic.claudefordesktop", build: String = "62",
                  rich: Bool = true, exact: Bool = true, continuation: Bool = false,
                  enabled: Bool = true, stageable: Bool = true) -> Bool {
            PasteAckHistory.deliveryStagingEligibility(bundle: bundle, richComposer: rich,
                exactPlan: exact, continuation: continuation, threeSteps: enabled,
                stageable: stageable, boundaryTrial: false, build: build, in: defaults).mayStage
        }
        #expect(!gate())
        for bundle in [claude, "com.openai.codex", "fictional.native"] {
            PasteAckHistory.record(bundle: bundle, acknowledged: true, in: defaults)
        }
        #expect(gate())
        #expect(!gate(rich: false))
        #expect(!gate(exact: false))
        #expect(!gate(continuation: true))
        #expect(!gate(enabled: false))
        #expect(!gate(stageable: false))
        #expect(!PasteAckHistory.allowsStaging(bundle: claude, richComposer: true, in: defaults))
        #expect(PasteAckHistory.recordCodexFinalRevealFailure(reason: "unacknowledged", bundle: claude,
                                                              build: "62", in: defaults))
        for _ in 0..<3 {
            PasteAckHistory.record(bundle: claude, acknowledged: true, in: defaults)
            #expect(!gate())
            #expect(!PasteAckHistory.allowsStaging(bundle: claude, richComposer: true, in: defaults))
        }
        #expect(gate("com.openai.codex"))
        #expect(gate("fictional.native", rich: false, exact: false))
        #expect(gate(build: "63"))
        #expect(!PasteAckHistory.recordCodexFinalRevealFailure(reason: "clipboard_changed_during_reveal_ack",
            bundle: claude, build: "63", in: defaults))
        #expect(!gate(build: "63"))
        PasteAckHistory.record(bundle: claude, acknowledged: true, in: defaults)
        #expect(gate(build: "63"))
        #expect(!gate(build: "62"))
    }

    @Test func claudeDesktopEarnsFinalRevealSeparatelyFromCodex() {
        let suite = "claude-final-reveal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let claude = "com.anthropic.claudefordesktop"
        func allowed(_ bundle: String) -> Bool {
            PasteAckHistory.allowsCodexFinalReveal(bundle: bundle, richComposer: true,
                exactPlan: true, continuation: false, build: "60", in: defaults)
        }
        #expect(!allowed(claude))
        PasteAckHistory.record(bundle: claude, acknowledged: true, in: defaults)
        PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
        #expect(allowed(claude) && allowed("com.openai.codex"))
        // A transport failure in Claude latches Claude for this build and leaves Codex alone.
        #expect(PasteAckHistory.recordCodexFinalRevealFailure(reason: "final_unacknowledged", bundle: claude,
                                                              build: "60", in: defaults))
        PasteAckHistory.record(bundle: claude, acknowledged: true, in: defaults)
        #expect(!allowed(claude))
        #expect(allowed("com.openai.codex"))
    }

    @Test func codexFinalRevealRequiresTrustedExactPlanAndNeverEnablesEarlyPrefix() {
        let suite = "codex-final-reveal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func allowed(_ bundle: String? = "com.openai.codex", rich: Bool = true,
                     exact: Bool = true, continuation: Bool = false) -> Bool {
            PasteAckHistory.allowsCodexFinalReveal(bundle: bundle, richComposer: rich,
                exactPlan: exact, continuation: continuation, in: defaults)
        }
        #expect(!allowed())
        PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
        #expect(allowed())
        #expect(!allowed(nil))
        #expect(!allowed("fictional.editor"))
        #expect(!allowed(rich: false))
        #expect(!allowed(exact: false))
        #expect(!allowed(continuation: true))
        #expect(!PasteAckHistory.allowsStaging(bundle: "com.openai.codex", richComposer: true, in: defaults))
        PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: false, in: defaults)
        #expect(!allowed())
        PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
        #expect(allowed())
        #expect(!PasteAckHistory.allowsStaging(bundle: "com.openai.codex", richComposer: true, in: defaults))
    }

    @Test func codexFinalRevealFailureStaysDisabledForTheBuildAfterRepeatedFullPastes() {
        let suite = "codex-final-breaker-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func allowed(_ build: String) -> Bool {
            PasteAckHistory.allowsCodexFinalReveal(bundle: "com.openai.codex", richComposer: true,
                exactPlan: true, continuation: false, build: build, in: defaults)
        }
        PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
        #expect(allowed("50"))
        PasteAckHistory.disableCodexFinalReveal(build: "50", in: defaults)
        PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: false, in: defaults)
        for _ in 0..<10 {
            PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
            #expect(!allowed("50"))
        }
        #expect(allowed("51"))
        #expect(!PasteAckHistory.allowsStaging(bundle: "com.openai.codex", richComposer: true, in: defaults))
    }

    @Test func codexInterruptedRevealRequiresFreshSinglePasteThenRecovers() {
        for reason in ["clipboard_changed_during_reveal_ack", "clipboard_changed_during_reveal",
                       "target_changed_during_reveal", "target_changed_during_reveal_ack",
                       "target_or_clipboard_changed_between_steps", "clipboard_changed_between_steps",
                       "target_changed_between_steps", "target_changed_before_clipboard", "target_changed_before_paste",
                       "focus_changed", "window_changed", "cancelled"] {
            let suite = "codex-transient-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            func allowed() -> Bool {
                PasteAckHistory.allowsCodexFinalReveal(bundle: "com.openai.codex", richComposer: true,
                    exactPlan: true, continuation: false, build: "51", in: defaults)
            }
            PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
            #expect(allowed())
            #expect(!PasteAckHistory.recordCodexFinalRevealFailure(reason: reason, build: "51", in: defaults))
            #expect(!allowed())
            #expect(defaults.string(forKey: PasteAckHistory.codexFinalRevealDisabledKey) == nil)
            PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
            #expect(allowed())
            #expect(!PasteAckHistory.allowsStaging(bundle: "com.openai.codex", richComposer: true, in: defaults))
        }
    }

    @Test func codexTransportFailureRemainsLatchedDespiteLaterInterruptionAndSuccessfulPaste() {
        for reason in ["unacknowledged", "unexpected_editor_text", "paste_event_failed",
                       "final_unacknowledged", "unknown_failure"] {
            let suite = "codex-transport-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(PasteAckHistory.recordCodexFinalRevealFailure(reason: reason, build: "51", in: defaults))
            #expect(!PasteAckHistory.recordCodexFinalRevealFailure(reason: "clipboard_changed_during_reveal_ack",
                build: "51", in: defaults))
            PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
            #expect(!PasteAckHistory.allowsCodexFinalReveal(bundle: "com.openai.codex", richComposer: true,
                exactPlan: true, continuation: false, build: "51", in: defaults))
        }
    }

    @Test func codexSuccessfulPastesNeverRearmUnreliableIncrementalDelivery() {
        let suite = "codex-reliability-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Reproduce repeated successes, a failed prefix, and subsequent success.
        // Stored trust is deliberately retained; it must never enable either entry point.
        for acknowledged in [true, true, false, true, true, true, true, true] {
            PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: acknowledged, in: defaults)
            for rich in [false, true] {
                #expect(!PasteAckHistory.allowsStaging(bundle: "com.openai.codex", richComposer: rich, in: defaults))
            }
        }
        // Claude now shares the exclusive final-reveal route, covered above.
        // Build 81: a rich composer is armed by a verified rich-composer paste of that app
        // (browsers never: browserFieldsKeepOneCompletePasteAfterPlainOrRichCalibration).
        for bundle in ["com.apple.Notes", "com.apple.TextEdit", "com.tinyspeck.slackmacgap"] {
            PasteAckHistory.record(bundle: bundle, acknowledged: true, richComposer: true, in: defaults)
            #expect(PasteAckHistory.allowsStaging(bundle: bundle, richComposer: true, in: defaults))
        }
    }

    @Test func readableEditorsNeedOneVerifiedPasteAndFailureResetsTrust() {
        let suite = "staging-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!PasteAckHistory.allowsStaging(bundle: "fictional.rich", richComposer: true, in: defaults))
        PasteAckHistory.record(bundle: "fictional.rich", acknowledged: false, in: defaults)
        #expect(!PasteAckHistory.allowsStaging(bundle: "fictional.rich", richComposer: true, in: defaults))
        // Build 81: a plain-field success no longer arms the rich composer; a rich one does.
        PasteAckHistory.record(bundle: "fictional.rich", acknowledged: true, in: defaults)
        #expect(!PasteAckHistory.allowsStaging(bundle: "fictional.rich", richComposer: true, in: defaults))
        PasteAckHistory.record(bundle: "fictional.rich", acknowledged: true, richComposer: true, in: defaults)
        #expect(PasteAckHistory.allowsStaging(bundle: "fictional.rich", richComposer: true, in: defaults))
        #expect(!PasteAckHistory.allowsStaging(bundle: "fictional.native", richComposer: false, in: defaults))
        PasteAckHistory.record(bundle: "fictional.native", acknowledged: true, in: defaults)
        #expect(PasteAckHistory.allowsStaging(bundle: "fictional.native", richComposer: false, in: defaults))
        PasteAckHistory.record(bundle: "fictional.native", acknowledged: false, in: defaults)
        #expect(!PasteAckHistory.allowsStaging(bundle: "fictional.native", richComposer: false, in: defaults))
    }
}

struct StagedRevealHoldTests {
    @Test func hundredFiftyMillisecondHoldOccursOnlyBeforeFinalPiece() {
        var text = "", sleeps: [UInt32] = [], posts: [String] = []
        let result = StagedPasteDriver.run(pieces: ["first ", "middle ", "last"], initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                if piece == "last" { #expect(sleeps == [150_000]) }
                else { #expect(sleeps.isEmpty) }
                posts.append(piece); text += piece; return nil
            }, read: { text }, sleep: { sleeps.append($0) }, now: { 0 },
            finalRevealHold: StagedPasteDriver.finalRevealHoldMicroseconds)
        #expect(result == .posted(acknowledged: 2))
        #expect(posts == ["first ", "middle ", "last"])
    }

    @Test func targetChangeDuringVisualHoldStopsBeforeFinalPaste() {
        var text = "", changed = false, posts: [String] = []
        let result = StagedPasteDriver.run(pieces: ["middle ", "last"], initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                if changed { return "target_changed_between_steps" }
                posts.append(piece); text += piece; return nil
            }, read: { text }, sleep: { _ in changed = true }, now: { 0 },
            finalRevealHold: StagedPasteDriver.finalRevealHoldMicroseconds)
        #expect(result == .failedPartway("target_changed_between_steps", posted: 1))
        #expect(posts == ["middle "])
    }
}

struct VisibleOpeningPacingTests {
    @Test func slowTitleAcknowledgementStillShowsSixWordsBeforeFinalReveal() throws {
        let payload = "# π Notebook\n\n## Transcript\n\nThe blue notebook is beside the lamp and ready.\n\n---\n\n# Metadata\n"
        let plan = try #require(ThreeStepPaste.plan(payload))
        var text = "", time: TimeInterval = 0
        var posts: [String] = [], holds: [UInt32] = []
        let result = StagedPasteDriver.run(pieces: plan.steps, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                if posts.count == 2 {
                    #expect(text.hasSuffix("The blue notebook is beside the "))
                    #expect(holds == [150_000])
                }
                posts.append(piece); text += piece; time += 0.06; return nil
            }, read: { text }, sleep: { holds.append($0) }, now: { time },
            finalRevealHold: StagedPasteDriver.finalRevealHoldMicroseconds,
            minimumAcknowledgedPieces: plan.steps.count - 1)
        #expect(result == .posted(acknowledged: 2))
        #expect(posts == plan.steps)
        #expect(text == payload)
    }
}
