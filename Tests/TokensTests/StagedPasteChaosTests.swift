import Foundation
import Testing
@testable import Tokens

/// Deterministic transport experiments: fictional text, injected time and no app,
/// clipboard, microphone or Return events. `.posted` is not final delivery proof.
struct StagedPasteChaosTests {
    private let pieces = ["café ", "👩🏽‍💻 ", "e\u{301} ", "1234567910 ", "終わり\r\n"]

    private struct Seeded {
        var state: UInt64
        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }

    /// A delayed clipboard consumer makes an overlapping post observable. The
    /// last post is settled explicitly by a test; the driver does not ACK it.
    private final class Editor {
        var micros: UInt64 = 0
        var text: String
        var selection: NSRange
        var pending: (piece: String, due: UInt64)?
        var posts: [String] = []
        var applied: [String] = []
        var delays: [UInt64]
        var overlaps = 0
        var stalePreflights = 0

        init(text: String = "", selection: NSRange = NSRange(location: 0, length: 0), delays: [UInt64]) {
            self.text = text; self.selection = selection; self.delays = delays
        }
        func post(_ piece: String, expected: String?) -> String? {
            if pending != nil { overlaps += 1; return "overlapping_post" }
            if let expected, !expected.utf8.elementsEqual(text.utf8) {
                stalePreflights += 1; return "stale_preflight"
            }
            let delay = delays[min(posts.count, delays.count - 1)]
            posts.append(piece)
            pending = (piece, micros + delay)
            return nil
        }
        func read() -> String {
            if let item = pending, micros >= item.due {
                text = (text as NSString).replacingCharacters(in: selection, with: item.piece)
                selection = NSRange(location: selection.location + item.piece.utf16.count, length: 0)
                applied.append(item.piece)
                pending = nil
            }
            return text
        }
        func settleLastPost() {
            if let pending { micros = max(micros, pending.due) }
            _ = read()
        }
    }

    @Test func seededAcknowledgementDelaysPreserveBytesAcrossBudgetCollapse() {
        // Explicit boundary cases plus a repeatable distribution. The same
        // replacement occurs in an empty editor and amid an existing Unicode draft.
        for seed in 1...64 {
            var random = Seeded(state: UInt64(seed))
            let boundaries: [UInt64] = [0, 7_999, 8_000, 8_001, 49_999, 50_001, 399_999, 400_001, 649_000]
            let delays = pieces.indices.map { index in
                index == 0 ? boundaries[seed % boundaries.count] : UInt64(random.next(320_000))
            }
            let initial = seed.isMultiple(of: 2) ? "draft 👩🏽‍💻 REPLACE suffix" : ""
            let selection = initial.isEmpty ? NSRange(location: 0, length: 0) : (initial as NSString).range(of: "REPLACE")
            let expected = (initial as NSString).replacingCharacters(in: selection, with: pieces.joined())
            let editor = Editor(text: initial, selection: selection, delays: delays)
            let outcome = StagedPasteDriver.run(pieces: pieces, initial: initial, selection: selection,
                post: { editor.post($0, expected: $1) }, read: { editor.read() },
                sleep: { editor.micros += UInt64($0) }, now: { Double(editor.micros) / 1_000_000 })
            guard case .posted = outcome else { Issue.record("Seed \(seed): \(outcome)"); continue }
            editor.settleLastPost()
            #expect(editor.text.utf8.elementsEqual(expected.utf8), "Seed \(seed)")
            #expect(editor.posts.joined().utf8.elementsEqual(pieces.joined().utf8))
            #expect(editor.applied == editor.posts)
            #expect(editor.overlaps == 0 && editor.stalePreflights == 0)
        }
    }

    @Test func timedOutWriteCanArriveLaterWithoutReplayOrTail() {
        for lateness in [650_001, 700_000, 1_000_000, 5_000_000] {
            let editor = Editor(delays: [UInt64(lateness)])
            let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
                selection: NSRange(location: 0, length: 0),
                post: { editor.post($0, expected: $1) }, read: { editor.read() },
                sleep: { editor.micros += UInt64($0) }, now: { Double(editor.micros) / 1_000_000 })
            #expect(outcome == .failedPartway("unacknowledged", posted: 1))
            #expect(editor.micros == 650_000)
            #expect(editor.posts == [pieces[0]])
            #expect(editor.text.isEmpty)
            editor.settleLastPost()
            #expect(editor.text == pieces[0])
            #expect(editor.applied == [pieces[0]])
            #expect(editor.overlaps == 0)
        }
    }

    @Test func foreignEditAtEveryAcknowledgementStopsBeforeNextPiece() {
        for attackedWrite in 1..<pieces.count {
            let editor = Editor(delays: [8_000])
            var changed = false
            let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
                selection: NSRange(location: 0, length: 0),
                post: { editor.post($0, expected: $1) }, read: {
                    _ = editor.read()
                    if !changed, editor.applied.count == attackedWrite {
                        editor.text += " foreign edit"; changed = true
                    }
                    return editor.text
                }, sleep: { editor.micros += UInt64($0) },
                now: { Double(editor.micros) / 1_000_000 }, budgetSeconds: 10)
            #expect(outcome == .failedPartway("unexpected_editor_text", posted: attackedWrite))
            #expect(editor.posts == Array(pieces.prefix(attackedWrite)))
            #expect(editor.applied == editor.posts)
            #expect(editor.overlaps == 0)
        }
    }

    @Test func cancellationAtEveryPostBoundaryRetainsOnlyThePostedPrefix() {
        for stopBefore in pieces.indices {
            let editor = Editor(delays: [0])
            let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
                selection: NSRange(location: 0, length: 0), post: { piece, expected in
                    guard editor.posts.count < stopBefore else { return "cancelled" }
                    return editor.post(piece, expected: expected)
                }, read: { editor.read() }, sleep: { editor.micros += UInt64($0) },
                now: { Double(editor.micros) / 1_000_000 }, budgetSeconds: 10)
            let expected: StagedPasteDriver.Outcome = stopBefore == 0
                ? .failedBeforeAnything("cancelled") : .failedPartway("cancelled", posted: stopBefore)
            #expect(outcome == expected)
            #expect(editor.posts == Array(pieces.prefix(stopBefore)))
            #expect(editor.text == pieces.prefix(stopBefore).joined())
            #expect(editor.pending == nil)
        }
    }

    @Test func cancellationDuringAckWaitNeverAuthorizesAnotherWrite() {
        for cancelAt in [UInt64(1), 8_000, 20_000, 63_999] {
            let editor = Editor(delays: [64_000])
            let outcome = StagedPasteDriver.run(pieces: pieces, initial: "",
                selection: NSRange(location: 0, length: 0), post: { piece, expected in
                    guard editor.micros < cancelAt else { return "cancelled" }
                    return editor.post(piece, expected: expected)
                }, read: { editor.read() }, sleep: { editor.micros += UInt64($0) },
                now: { Double(editor.micros) / 1_000_000 })
            #expect(outcome == .failedPartway("cancelled", posted: 1))
            #expect(editor.posts == [pieces[0]])
            #expect(editor.text == pieces[0])
            #expect(editor.overlaps == 0)
        }
    }
}
