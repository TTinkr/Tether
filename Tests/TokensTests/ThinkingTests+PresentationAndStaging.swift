


//
/*
ThinkingTests+PresentationAndStaging.swift
Tokens · Tests

Owns: bubble placement/presence, title grounding and staged paste
Never: changes the assertion order or weakens checks.
See: ThinkingTests.swift (ordered suite entry); ScriptedThinking.swift (fixtures).
*/


import Foundation
import Testing
@testable import Tokens


extension ThinkingTests {
    @MainActor static func presentationAndStaging() throws {
        // MARK: locked bubble geometry (second screen, 78 pt Dock)
        let lockedOrigin = BubbleGeometry.lockedOrigin(size: CGSize(width: 246, height: 36),
                                                          visible: CGRect(x: 1440, y: 78, width: 1920, height: 977))
        precondition(lockedOrigin == CGPoint(x: 2277, y: 90))
        print("PASS bubble: bottom centre of the target screen's Dock-aware visible frame")
        let screen = CGRect(x: 1440, y: 78, width: 1920, height: 977), bubbleSize = CGSize(width: 246, height: 36)
        precondition(BubbleGeometry.origin(.top, custom: nil, size: bubbleSize, visible: screen) == CGPoint(x: 2277, y: 1007))
        precondition(BubbleGeometry.origin(.left, custom: nil, size: bubbleSize, visible: screen) == CGPoint(x: 1452, y: 549))
        precondition(BubbleGeometry.origin(.right, custom: nil, size: bubbleSize, visible: screen) == CGPoint(x: 3102, y: 549))
        let dragged  = CGPoint(x: 1800, y: 400)
        let fraction = BubbleGeometry.fraction(of: dragged, size: bubbleSize, visible: screen)
        precondition(BubbleGeometry.origin(.custom, custom: fraction, size: bubbleSize, visible: screen) == dragged)
        let placementDomain   = "TTTBubblePlacementTests.\(UUID().uuidString)"
        let placementDefaults = UserDefaults(suiteName: placementDomain)!
        defer { placementDefaults.removePersistentDomain(forName: placementDomain) }
        precondition(BubblePlacement.load(placementDefaults).0 == .bottom)
        BubblePlacement.save(.custom, custom: fraction, in: placementDefaults)
        precondition(BubblePlacement.load(placementDefaults).0 == .custom && BubblePlacement.load(placementDefaults).1 == fraction)
        print("PASS bubble placement: top/left/right presets, dragged position round-trips and persists")

        // MARK: sticky thinking presence (display only)
        do {
            var presence = ThinkingPresence()
            var t        = 100.0
            // Feed 0.1 s observations; `pause` grows while quiet, nil once the tracker hears sound.
            func run(_ seconds: Double, db: Double, pause: (Double) -> Double?, words: Int, estimated: Bool = false) -> [ThinkingPresence.Transition] {
                var out: [ThinkingPresence.Transition] = []
                for _ in 0..<Int((seconds * 10).rounded()) {
                    t += 0.1
                    if let change = presence.observe(pauseSeconds: pause(t), estimated: estimated, rmsDB: db, words: words, host: t) { out.append(change) }
                }
                return out
            }
            let quietFrom = t
            precondition(run(0.9, db: -60, pause: { $0 - quietFrom }, words: 5).isEmpty && !presence.isThinking)   // 0.35-0.9 s does not latch
            precondition(run(0.2, db: -60, pause: { $0 - quietFrom }, words: 5) == [.entered])
            precondition(abs((presence.display(at: t)?.seconds ?? 0) - 1.1) < 1e-9, "counter starts at the true pause length")
            // A cough: 0.2 s of sound, no words, then quiet again. Stays thinking, counter keeps running.
            precondition(run(0.2, db: -25, pause: { _ in nil }, words: 5).isEmpty && presence.isThinking)
            let resumedQuiet = t
            precondition(run(1.0, db: -60, pause: { $0 - resumedQuiet }, words: 5).isEmpty && presence.isThinking)
            precondition(abs((presence.display(at: t)?.seconds ?? 0) - 2.3) < 1e-9 && presence.display(at: t)?.approximate == true, "counter runs straight through the cough")
            // Room noise hovering just above the threshold for 3 s, no words: never releases.
            precondition(run(3.0, db: -47, pause: { _ in nil }, words: 5).isEmpty && presence.isThinking)
            // A word recognized late while quiet is not new speech.
            precondition(run(2.0, db: -60, pause: { _ in 0.5 }, words: 6).isEmpty)
            precondition(run(0.5, db: -30, pause: { _ in nil }, words: 7).isEmpty && presence.isThinking)
            // Real speech: sound with two new words.
            precondition(run(0.5, db: -30, pause: { _ in nil }, words: 8) == [.released] && presence.display(at: t) == nil)
            /*
            Review 2026-10-02 (P1): a short breath in a quiet room. Sound returns, the recognizer lags, and the
            speech-gap estimate passes 1 s while the speaker is already talking. That is not a pause.
            */
            precondition(run(0.8, db: -60, pause: { _ in nil }, words: 8).isEmpty)
            precondition(run(0.6, db: -25, pause: { _ in 1.2 }, words: 8, estimated: true).isEmpty && !presence.isThinking)
            // Hesitant speech after a real pause: short phrases, words showing up in the gaps. It releases.
            let q4 = t
            precondition(run(1.1, db: -60, pause: { $0 - q4 }, words: 8) == [.entered])
            var changes = run(0.4, db: -28, pause: { _ in nil }, words: 8)        // phrase one
            changes += run(0.5, db: -60, pause: { _ in 0.5 }, words: 10)          // its words arrive in the gap
            changes += run(0.2, db: -28, pause: { _ in nil }, words: 10)
            precondition(changes == [.released], "hesitant speech released: \(changes)")
            /*
            Clear sound with no words while the estimate keeps reporting a gap: still a gap, so it holds
            steadily (a release here would only re-enter a moment later); two recognized words end it.
            */
            let q5 = t
            precondition(run(1.1, db: -60, pause: { $0 - q5 }, words: 10) == [.entered])
            precondition(run(3.0, db: -25, pause: { _ in 3.0 }, words: 10, estimated: true).isEmpty && presence.isThinking)
            precondition(run(0.2, db: -25, pause: { _ in nil }, words: 12) == [.released])
            /*
            Loud room: entered on the estimate, the steady room level is not speech, so late words do not release;
            louder sound with new words does.
            */
            presence.reset()
            precondition(run(3.2, db: -40, pause: { _ in nil }, words: 10).isEmpty)
            precondition(run(0.1, db: -40, pause: { _ in 1.3 }, words: 10, estimated: true) == [.entered])
            precondition(run(1.5, db: -40, pause: { _ in 2.0 }, words: 12, estimated: true).isEmpty && presence.isThinking)
            precondition(run(0.6, db: -28, pause: { _ in nil }, words: 14) == [.released])
            // Unrecognized-sound backstop after a measured entry: 1.5 s clearly loud, no words, no pause.
            let q2 = t
            precondition(run(1.1, db: -60, pause: { $0 - q2 }, words: 8) == [.entered])
            precondition(run(1.4, db: -30, pause: { _ in nil }, words: 8).isEmpty)
            precondition(run(0.2, db: -30, pause: { _ in nil }, words: 8) == [.released])
            // An observation gap resets sound runs; a backwards clock is ignored.
            let q3 = t
            precondition(run(1.1, db: -60, pause: { $0 - q3 }, words: 8) == [.entered])
            precondition(presence.observe(pauseSeconds: nil, estimated: false, rmsDB: -30, words: 20, host: t - 5) == nil && presence.isThinking)
            t += 0.3
            _ = presence.observe(pauseSeconds: nil, estimated: false, rmsDB: -30, words: 20, host: t)
            t += 2.0
            precondition(presence.observe(pauseSeconds: nil, estimated: false, rmsDB: -30, words: 20, host: t) == nil, "a 2 s gap is not 2 s of speech")
            presence.reset()
            precondition(!presence.isThinking && presence.display(at: t) == nil)
            print("PASS thinking presence: latches at 1.0 s, rides out coughs and room noise, ignores late words, releases on speech or loud unrecognized sound")
        }

        // MARK: keyword title fallback
        let spokenAboutBubble = "so the bubble should be clear and then the bubble can move and the timer on the bubble gets stuck and the timer should count"
        precondition(ThinkingTitle.keywords(transcript: spokenAboutBubble) == "Bubble timer", ThinkingTitle.keywords(transcript: spokenAboutBubble) ?? "nil")
        // A label may not flip the meaning, and some words do not belong in a heading.
        precondition(ThinkingTitle.keywords(transcript: "do not delete the production database I repeat do not delete the production database until the backup finishes") == nil)
        precondition(ThinkingTitle.keywords(transcript: "the fucking build keeps crashing and the fucking build keeps crashing again today") == "Build keeps crashing")
        precondition(ThinkingTitle.keywords(transcript: "okay yeah so like") == nil)
        print("PASS keyword title: the speaker's most repeated words, in spoken order; nothing for a few words")

        // MARK: three-step paste plan
        do {
            let prompt = "# π Launch plan\n\n> *12.0000s · 9 words · 45 wpm · 1x thinking (1.5000s)*\n> *Talked, not typed.*\n\n## Transcript\n\nall right, here is the plan for monday.\n\nTHINK (1.5000s)\n\nwe ship it."
            guard let plan = ThreeStepPaste.plan(prompt) else { preconditionFailure("plan") }
            precondition(plan.header.hasSuffix("## Transcript\n\n") && plan.opening == ["all ", "right, ", "here ", "is ", "the ", "plan "])
            precondition(plan.rest.hasPrefix("for monday.") && plan.steps.joined() == prompt)
            precondition(TalkModel.heldWordsDisplay(prompt) == "all right, here is the plan for monday. we ship it.")
            // Trailing newline added for one editor stays in the last piece.
            precondition(ThreeStepPaste.plan(prompt + "\n")?.steps.joined() == prompt + "\n")
            // Markup, notation, a line break or a short opening: one piece.
            precondition(ThreeStepPaste.plan("# π T\n\n> *s*\n\n## Transcript\n\n<TC> R I L E Y </TC> is my name and more words") == nil)
            precondition(ThreeStepPaste.plan("# π T\n\n> *s*\n\n## Transcript\n\nhello\n\nTHINK (2.0000s)\n\nthere friend") == nil)
            precondition(ThreeStepPaste.plan("# π T\n\n> *s*\n\n## Transcript\n\nhello there") == nil)
            precondition(ThreeStepPaste.plan("# π T\n\n> *s*\n\n## Your words\n\nall right, here is the legacy plan for monday.")?.header.hasSuffix("## Your words\n\n") == true)
            precondition(ThreeStepPaste.plan("just some words with no header at all here") == nil)
            // The opening stops before markup; what was cut is still the whole text.
            let partial = "# π T\n\n> *s*\n\n## Transcript\n\nuse the `build` script and then stop"
            precondition(ThreeStepPaste.plan(partial)?.opening == ["use ", "the "] && ThreeStepPaste.plan(partial)?.steps.joined() == partial)
            print("PASS three-step paste plan: header, plain opening words, rest; steps rejoin to the exact text; markup and short prompts stay whole")
        }

        precondition(!ThinkingTitle.everyWordSpoken("Shipment planning", transcript: "ship planning ship planning"))
        precondition(ThinkingTitle.everyWordSpoken("Ship planning", transcript: "ship planning ship planning"))
        precondition(!ThinkingTitle.mostlySpoken("Talk with Johnathan about lamps", transcript: "talk with John about lamps"))

        // MARK: staged paste order (fake editor)
        do {
            final class FakeEditor {
                var text = ""                // what the editor shows
                var pending: [String] = []   // posted but not yet applied
                var applyAfterPolls = 1      // polls until a posted piece shows; Int.max = never during polling
                var polls = 0
                var posts: [(piece: String, expecting: String?)] = []
                var failAt: Int?
                var foreignEditAfterPost: Int?
                var corruptReadback = false
                func post(_ piece: String, _ expecting: String?) -> String? {
                    if let failAt, posts.count == failAt { return "paste_event_failed" }
                    // A foreign edit lands after the driver last read the editor and before its next post.
                    if let edit = foreignEditAfterPost, posts.count == edit { text += "X"; foreignEditAfterPost = nil }
                    if let expecting, expecting != text { return "target_changed_between_steps" }
                    posts.append((piece, expecting)); pending.append(piece); polls = 0
                    return nil
                }
                func read() -> String? {
                    polls += 1
                    if polls >= applyAfterPolls, !pending.isEmpty { text += pending.removeFirst(); if corruptReadback { text += "X" } }
                    return text
                }
            }
            let pieces = ["HEADER\n\n", "one ", "two ", "the rest."]
            // Every piece is seen before the next is posted; the editor ends with the exact text.
            let good = FakeEditor()
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: good.post, read: good.read, sleep: { _ in }, now: { 0 }) == .posted(acknowledged: 3))
            _ = good.read()
            precondition(good.text == pieces.joined() && good.posts.count == 4 && good.posts[0].expecting == nil && good.posts[1].expecting == "HEADER\n\n")
            // The first piece is not seen in time: everything left goes as one piece after the grace wait, in order.
            let slow            = FakeEditor(); slow.applyAfterPolls = StagedPasteDriver.pollsPerPiece + 2
            var slept: [UInt32] = []
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: slow.post, read: slow.read, sleep: { slept.append($0) }, now: { 0 }) == .posted(acknowledged: 0))
            _ = slow.read(); _ = slow.read()
            precondition(slow.posts.map(\.piece) == ["HEADER\n\n", "one two the rest."] && slept.last == StagedPasteDriver.unacknowledgedGraceMicroseconds)
            precondition(slow.posts[1].expecting == "HEADER\n\n", "the late piece was read back after the grace wait")
            // The first piece never shows: its Command-V may not have read the clipboard yet, so nothing more is posted.
            let silent = FakeEditor(); silent.applyAfterPolls = Int.max
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: silent.post, read: silent.read, sleep: { _ in }, now: { 0 })
                         == .failedPartway("unacknowledged", posted: 1) && silent.posts.count == 1)
            let corrupt = FakeEditor(); corrupt.corruptReadback = true
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: corrupt.post, read: corrupt.read, sleep: { _ in }, now: { 0 }) == .failedPartway("unexpected_editor_text", posted: 1))
            precondition(corrupt.posts.count == 1)
            let missing = FakeEditor()
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", post: missing.post, read: missing.read, sleep: { _ in }, now: { 0 }) == .failedBeforeAnything("unreadable_selection"))
            // UTF-16 selection replacement, not append-only acknowledgement (emoji spans two units).
            var middle      = "A😀Z"
            var range       = NSRange(location: 1, length: 2)
            var middlePosts = 0
            let middleResult = StagedPasteDriver.run(pieces: ["one ", "two"], initial: middle, selection: range,
                post: { piece, expecting in
                    if let expecting, expecting != middle { return "changed" }
                    middle = (middle as NSString).replacingCharacters(in: range, with: piece)
                    range  = NSRange(location: range.location + (piece as NSString).length, length: 0)
                    middlePosts += 1
                    return nil
                }, read: { middle }, sleep: { _ in }, now: { 0 })
            precondition(middleResult == .posted(acknowledged: 1) && middle == "Aone twoZ" && middlePosts == 2)
            // Editors earn staging with one exact acknowledged single paste; one miss resets it.
            let ackDomain   = "TTTPasteAckTests.\(UUID().uuidString)"
            let ackDefaults = UserDefaults(suiteName: ackDomain)!
            defer { ackDefaults.removePersistentDomain(forName: ackDomain) }
            precondition(!PasteAckHistory.trusts(bundle: "com.example.editor", in: ackDefaults))
            PasteAckHistory.record(bundle: "com.example.editor", acknowledged: true, in: ackDefaults)
            precondition(PasteAckHistory.trusts(bundle: "com.example.editor", in: ackDefaults) && !PasteAckHistory.trusts(bundle: "com.other", in: ackDefaults))
            PasteAckHistory.record(bundle: "com.example.editor", acknowledged: false, in: ackDefaults)
            precondition(!PasteAckHistory.trusts(bundle: "com.example.editor", in: ackDefaults) && !PasteAckHistory.trusts(bundle: nil, in: ackDefaults))
            // Someone types between pieces: stop, report partway, never post the rest.
            let foreign = FakeEditor(); foreign.foreignEditAfterPost = 2
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: foreign.post, read: foreign.read, sleep: { _ in }, now: { 0 })
                         == .failedPartway("target_changed_between_steps", posted: 2))
            precondition(foreign.posts.count == 2 && !foreign.text.contains("two") && !foreign.text.contains("the rest."))
            // The very first post fails: nothing was touched. A later post fails: partway.
            let first = FakeEditor(); first.failAt = 0
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: first.post, read: first.read, sleep: { _ in }, now: { 0 }) == .failedBeforeAnything("paste_event_failed") && first.text.isEmpty)
            let later = FakeEditor(); later.failAt = 2
            precondition(StagedPasteDriver.run(pieces: pieces, initial: "", selection: NSRange(location: 0, length: 0), post: later.post, read: later.read, sleep: { _ in }, now: { 0 }) == .failedPartway("paste_event_failed", posted: 2))
            // One piece is the single paste it always was.
            let single = FakeEditor()
            precondition(StagedPasteDriver.run(pieces: ["all of it"], initial: "", selection: NSRange(location: 0, length: 0), post: single.post, read: single.read, sleep: { _ in }, now: { 0 }) == .posted(acknowledged: 0) && single.posts.count == 1)
            print("PASS staged paste order: each piece seen before the next, a late editor gets the rest in one piece, a silent one gets nothing more, foreign edits and failures stop it without replay; editors earn staging with 3 acknowledged pastes")
        }

    }
}

