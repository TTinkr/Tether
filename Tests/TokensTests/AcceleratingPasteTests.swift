import Foundation
import Testing
@testable import Tokens

struct AcceleratingPasteTests {
    static let footer = "\n\n---\n\n# Metadata\n\n> *final counts*"
    static let body = "The blue notebook is beside the lamp and the green pencil rests on the table."
    static let prompt = "# π\n" + body + footer

    @Test func openingGrowsFromFragmentIntoLargerWordGroups() throws {
        let plan = try #require(AcceleratingPaste.plan(Self.prompt))
        #expect(plan.steps[0] == "# π\n")
        #expect(plan.steps[1] == "The ")
        #expect(plan.steps[2] == "blue ")
        #expect(plan.steps[3] == "notebook is beside ")
        #expect(plan.steps[4] == "the lamp and the green pencil ")
        #expect(plan.steps[5] == "rests on the table." + Self.footer)
        #expect(plan.steps.joined() == Self.prompt)
        #expect(!plan.steps.dropLast().joined().contains("# Metadata"))
    }

    @Test func longAndUnicodeTextReassembleExactlyWithBoundedWrites() throws {
        let bodies = [Self.body, Self.body + "\n*[pause 1.2500]* Café 👩🏽‍💻 e\u{301} repeated repeated.\n",
                      String(repeating: "one two three four five six seven eight ", count: 800)]
        for prefix in ["# π\n", " # π\n"] {
            for body in bodies {
                let text = prefix + body + Self.footer
                let plan = try #require(AcceleratingPaste.plan(text))
                #expect(plan.steps.count <= AcceleratingPaste.maximumPieces)
                #expect(plan.steps.joined() == text)
                #expect(plan.steps.last?.hasSuffix(Self.footer) == true)
            }
        }
    }

    @Test func stopPrefixKeepsTheAcceleratingBoundaries() throws {
        let plan = try #require(AcceleratingPaste.plan(Self.prompt))
        for prefix in ["# π", plan.steps[0], plan.steps.prefix(2).joined()] {
            let rest = try #require(StopStream.remainderSteps(prefix: prefix, payload: Self.prompt))
            #expect(prefix + rest.joined() == Self.prompt)
            #expect(rest.last == plan.steps.last)
            #expect(rest.count >= 3)
        }
        #expect(AcceleratingPaste.remainder(prefix: "# π\nDifferent", payload: Self.prompt) == nil)
    }

    @Test func waitsShrinkOnlyAfterAcknowledgementAndDoNotCollapseTheReveal() throws {
        let plan = try #require(AcceleratingPaste.plan(Self.prompt))
        var text = "", time: TimeInterval = 0
        var posts: [String] = [], delays: [UInt32] = []
        let result = StagedPasteDriver.run(pieces: plan.steps, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, expected in
                if let expected { #expect(expected == text) }
                posts.append(piece); text += piece; time += 0.03; return nil
            }, read: { text }, sleep: { delay in
                #expect(text == posts.joined())
                delays.append(delay); time += Double(delay) / 1_000_000
            }, now: { time }, minimumAcknowledgedPieces: plan.steps.count - 1,
            interPieceHolds: AcceleratingPaste.gapsMicroseconds,
            budgetSeconds: AcceleratingPaste.deliveryBudgetSeconds)
        #expect(result == .posted(acknowledged: plan.steps.count - 1))
        #expect(posts == plan.steps)
        #expect(delays == [30_000, 45_000, 25_000, 10_000])
        #expect(text == Self.prompt)
    }

    @Test func targetChangeDuringFirstSlowGapStopsWithoutReplaying() throws {
        let plan = try #require(AcceleratingPaste.plan(Self.prompt))
        var text = "", moved = false, posts: [String] = []
        let result = StagedPasteDriver.run(pieces: plan.steps, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                if moved { return "target_changed_between_steps" }
                posts.append(piece); text += piece; return nil
            }, read: { text }, sleep: { _ in moved = true }, now: { 0 },
            minimumAcknowledgedPieces: plan.steps.count - 1,
            interPieceHolds: AcceleratingPaste.gapsMicroseconds,
            budgetSeconds: AcceleratingPaste.deliveryBudgetSeconds)
        #expect(result == .failedPartway("target_changed_between_steps", posted: 1))
        #expect(posts == [plan.steps[0]])
    }

    @Test func missingAcknowledgementNeverEarnsAVisualWaitOrAnotherWrite() throws {
        let plan = try #require(AcceleratingPaste.plan(Self.prompt))
        var posts: [String] = [], sleeps: [UInt32] = []
        let result = StagedPasteDriver.run(pieces: plan.steps, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in posts.append(piece); return nil },
            read: { "" }, sleep: { sleeps.append($0) }, now: { 0 },
            minimumAcknowledgedPieces: plan.steps.count - 1,
            interPieceHolds: AcceleratingPaste.gapsMicroseconds,
            budgetSeconds: AcceleratingPaste.deliveryBudgetSeconds)
        #expect(result == .failedPartway("unacknowledged", posted: 1))
        #expect(posts.count == 1)
        #expect(sleeps.allSatisfy { $0 == 8_000 || $0 == 250_000 })
    }
    @Test func slowEditorCollapsesOnlyVerifiedRemainderAtBudget() throws {
        let plan = try #require(AcceleratingPaste.plan(Self.prompt))
        var text = "", time: TimeInterval = 0, posts: [String] = []
        let result = StagedPasteDriver.run(pieces: plan.steps, initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, expected in
                if let expected { #expect(expected == text) }
                posts.append(piece); text += piece; time += 0.15; return nil
            }, read: { text }, sleep: { time += Double($0) / 1_000_000 }, now: { time },
            interPieceHolds: AcceleratingPaste.gapsMicroseconds,
            budgetSeconds: AcceleratingPaste.deliveryBudgetSeconds)
        #expect(result == .posted(acknowledged: 2))
        #expect(posts == [plan.steps[0], plan.steps[1], plan.steps.dropFirst(2).joined()])
        #expect(text == Self.prompt)
    }

    @Test func annotationsAndGraphemesStayWholeInFinalPhase() throws {
        for span in ["*[pause 1.2345]*", "<num>1 2 3</num>", "<char>R I L E Y</char>", "👩🏽‍💻"] {
            let text = "# π\nThe blue " + span + " notebook stays here." + Self.footer
            let plan = try #require(AcceleratingPaste.plan(text))
            #expect(plan.steps.joined() == text)
            #expect(plan.steps.last?.contains(span) == true)
            #expect(!plan.steps.dropLast().joined().contains(span))
        }
    }

    @Test func richRedrawWaitsWithoutAcceptingOrReposting() {
        #expect(PasteAcknowledgement.waitsForReadback(.textMismatch, richComposer: true))
        #expect(!PasteAcknowledgement.waitsForReadback(.textMismatch, richComposer: false))
        #expect(!PasteAcknowledgement.waitsForReadback(.verified, richComposer: true))
        var text = "", pending: String?, redraw = true, posts: [String] = []
        let result = StagedPasteDriver.run(pieces: ["# π\n", "The blue"], initial: "",
            selection: NSRange(location: 0, length: 0), post: { piece, _ in
                #expect(pending == nil)
                posts.append(piece); pending = piece; return nil
            }, read: {
                if redraw { return nil }
                if let piece = pending { text += piece; pending = nil }
                return text
            }, sleep: { _ in redraw = false }, now: { 0 })
        #expect(result == .posted(acknowledged: 1))
        #expect(posts == ["# π\n", "The blue"])
    }

}
