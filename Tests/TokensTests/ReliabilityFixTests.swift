import AppKit
import Foundation
import Testing
@testable import Tokens

/// Build 81 reliability fixes from the sweep: clipboard, launch recovery, recovery pop-up.
struct ReliabilityFixTests {
    /// Only the captured span counts, case and spacing aside.
    @Test func clipboardComesBackOnlyWhenTheCapturedSpanHoldsTheWords() {
        let words = "the fictional plan works"
        func consumed(_ before: String, _ at: Int, _ length: Int = 0, after: String?, changed: Bool = true,
                      inserted: String = words) -> Bool {
            PasteAcknowledgement.pasteConsumed(before: before, selection: NSRange(location: at, length: length),
                                               after: after, observedChange: changed, inserted: inserted)
        }
        // Exact, uppercased, and reflowed insertions inside the captured span.
        #expect(consumed("Note: ", 6, after: "Note: the fictional plan works"))
        #expect(consumed("Note: ", 6, after: "Note: THE FICTIONAL PLAN WORKS"))
        #expect(consumed("Hi  end", 3, after: "Hi the fictional\nplan works end"))
        // Replacing a non-empty selection.
        #expect(consumed("Hi old words end", 3, 9, after: "Hi the fictional plan works end"))
        // An unrelated edit of the same size in the span, or a growth outside it: held.
        #expect(!consumed("Note: ", 6, after: "Note: zzz zzzzzzzzz zzzz zzzzz"))
        #expect(!consumed("Note: ", 6, after: "Note! the fictional plan works"))
        #expect(!consumed("Note: ", 6, after: "Typing elsewhere 1234567. Note: "))
        // A timer or collaborator edit while the paste is still pending: held.
        #expect(!consumed("Note: ", 6, after: "Note: (saved)"))
        // Autocorrect that rewrites words is not attributable: held.
        #expect(!consumed("", 0, after: "the fictitious plan works"))
        // No change, nothing readable, no selection, an out-of-range selection: held.
        #expect(!consumed("Note: ", 6, after: "Note: the fictional plan works", changed: false))
        #expect(!consumed("Note: ", 6, after: nil))
        #expect(!PasteAcknowledgement.pasteConsumed(before: "", selection: nil, after: words, observedChange: true, inserted: words))
        #expect(!consumed("Note", 9, after: "Note the fictional plan works"))
        #expect(!consumed("", 0, after: "x", inserted: "  "))
    }

    /// every saved type must be set before the clipboard is touched; round trip on a private pasteboard.
    @Test func clipboardRestoreIsAllOrNothing() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("tokens-restore-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("ing.keeptinkr.test.custom")
        let first = NSPasteboardItem(); first.setString("fictional one", forType: .string); first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem(); second.setString("fictional two", forType: .string)
        board.clearContents(); board.writeObjects([first, second])
        let snapshot = PasteboardSnapshot(items: (board.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(values: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        })
        board.clearContents(); board.setString("fictional copy made later", forType: .string)
        #expect(snapshot.restore(to: board))
        let items = board.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "fictional one")
        #expect(items.first?.data(forType: custom) == Data([1, 2, 3]))
        #expect(items.last?.string(forType: .string) == "fictional two")
    }

    /// TOK-QA-007: A failed, B succeeded, relaunch: Copy latest is B, and A stays reachable as an earlier talk.
    @Test func olderUnsentWordsStayReachableWithoutOutrankingTheNewestTalk() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let hour: TimeInterval = 3600
        #expect(TalkModel.offersAtLaunch(now - hour, newestHistory: now - 2 * hour))
        #expect(TalkModel.offersAtLaunch(now - hour, newestHistory: nil))
        #expect(TalkModel.offersAtLaunch(now - 30 * hour, newestHistory: nil))          // no age rule
        #expect(!TalkModel.offersAtLaunch(now - 2 * hour, newestHistory: now - hour))  // offered as earlier instead
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let startup = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Talk/TalkModel+Startup.swift"), encoding: .utf8)
        #expect(startup.contains("earlierRecovery = RecoveredTalk(id: saved.id, text: saved.text)"))
        let copy = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Talk/TalkModel+Copy.swift"), encoding: .utf8)
        #expect(copy.contains("resolveTranscriptRecovery(earlier.id)"))
    }

    @Test func recoveryPopUpJoinsTheActiveSpace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Features/Bubble/RecoveryWindow.swift"), encoding: .utf8)
        #expect(source.contains("panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]"))
        #expect(source.contains("panel.level = .floating"))
    }

    /// the Dev HID route never types into an app that is not the target.
    @Test func hidRouteOnlyPostsToTheAppInFront() {
        #expect(PasteRoute.mayPost(viaHID: false, frontPID: 10, targetPID: 20))   // process-addressed, as before
        #expect(PasteRoute.mayPost(viaHID: true, frontPID: 20, targetPID: 20))
        #expect(!PasteRoute.mayPost(viaHID: true, frontPID: 10, targetPID: 20))
        #expect(!PasteRoute.mayPost(viaHID: true, frontPID: nil, targetPID: 20))
    }

    /// the paste-target state line is Dev, proof-route and opt-in only,
    /// and the paste path asks nothing for it unless that gate is on.
    @Test func pasteTargetStateIsADevOptInDiagnostic() throws {
        #expect(PasteRoute.logsTargetState(dev: true, proofRoutes: true, optedIn: true))
        for (dev, proof, opted) in [(false, true, true), (true, false, true), (true, true, false), (false, false, false)] {
            #expect(!PasteRoute.logsTargetState(dev: dev, proofRoutes: proof, optedIn: opted))
        }
        #expect(!PasteRoute.devLogsTargetState)   // the test process is not Dev and has not opted in
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paste = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Delivery/TargetDeliveryPaste.swift"), encoding: .utf8)
        #expect(paste.contains("if PasteRoute.devLogsTargetState {\n                Diagnostics.event(\"paste_target_state \\(pasteTargetState(target))\")"))
        #expect(paste.components(separatedBy: "pasteTargetState(").count == 2)
    }

    /// a failed Copy/Forget is said on the earlier-talk line itself.
    @Test func earlierTalkFailuresShowOnTheirLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let copy = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Talk/TalkModel+Copy.swift"), encoding: .utf8)
        #expect(copy.contains("earlierRecoveryNote = \"Copied · still kept here\""))
        #expect(copy.contains("earlierRecoveryNote = \"Not forgotten · words kept\""))
        let home = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Features/Home/TokensHomeDashboard.swift"), encoding: .utf8)
        #expect(home.contains("model.earlierRecoveryNote ?? \"An earlier talk was not pasted\""))
    }
}
