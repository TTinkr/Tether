
import Foundation
import Testing
@testable import Tokens

struct PasteReadbackWatchTests {
    @Test func containerValuesDoNotTriggerFalseRecoveryWindows() {
        var result = PasteReadbackWatch.Outcome(reason: "textMismatch", observedRead: true)
        for role in [nil, "AXGroup", "AXWebArea", "AXButton"] {
            #expect(!result.insertionNotObserved(role: role, hasSelection: false))
        }
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            #expect(result.insertionNotObserved(role: role, hasSelection: false))
        }
        #expect(result.insertionNotObserved(role: nil, hasSelection: true))
        result.observedChange = true
        #expect(!result.insertionNotObserved(role: "AXTextArea", hasSelection: true))
        result.observedChange = false
        result.reason = "focus_changed"
        #expect(!result.insertionNotObserved(role: "AXTextArea", hasSelection: true))
    }
    @Test func delayedLongUnicodeInsertionsWithinGraceAreVerifiedExactlyOnce() {
        let payload = String(repeating: "Fictional long prompt 👩🏽‍💻 café 中文\n", count: 900)
        for arrival in stride(from: 25, through: 1500, by: 25) {
            var elapsed = 0
            let result = PasteReadbackWatch.run(before: "", selection: NSRange(location: 0, length: 0),
                inserted: payload, elementAvailable: true, wait: { elapsed += $0 },
                windowCurrent: { true }, focusCurrent: { true }, read: {
                    .init(after: elapsed >= arrival ? payload : "",
                          caret: NSRange(location: elapsed >= arrival ? payload.utf16.count : 0, length: 0))
                }, maximumWaitAttempts: 60)
            #expect(result.verified)
            #expect(elapsed == arrival)
        }
    }

    @Test func readableFieldWithoutSelectionStillDetectsAMissWithoutConfirming() {
        for after in ["", "opaque inserted text"] {
            var elapsed = 0
            let result = PasteReadbackWatch.run(before: "", selection: nil,
                inserted: "opaque inserted text", elementAvailable: true, wait: { elapsed += $0 },
                windowCurrent: { true }, focusCurrent: { true },
                read: { .init(after: after, caret: nil) }, maximumWaitAttempts: 60)
            #expect(!result.verified)
            #expect(result.reason == "unreadable_selection")
            #expect(result.observedRead && result.observedChange == !after.isEmpty)
            #expect(elapsed == (after.isEmpty ? 1500 : 500))
        }
    }

    @Test func noInsertionGetsGraceButObservedPartialTextIsNeverConfirmed() {
        for after in ["", "part"] {
            var elapsed = 0
            let result = PasteReadbackWatch.run(before: "", selection: NSRange(location: 0, length: 0),
                inserted: "partial prompt", elementAvailable: true, wait: { elapsed += $0 },
                windowCurrent: { true }, focusCurrent: { true },
                read: { .init(after: after, caret: NSRange(location: after.count, length: 0)) },
                maximumWaitAttempts: 60)
            #expect(!result.verified)
            #expect(result.observedRead)
            #expect(result.observedChange == !after.isEmpty)
            #expect(elapsed == (after.isEmpty ? 1500 : 500))
        }
    }
    private let caret = NSRange(location: 2, length: 0)
    private let initialSelection = NSRange(location: 0, length: 0)

    @Test func exactUTF16AcknowledgementAt300And450Milliseconds() {
        for arrival in [300, 450] {
            var elapsed = 0, reads = 0
            let result = PasteReadbackWatch.run(before: "", selection: initialSelection,
                inserted: "🌱", elementAvailable: true, wait: { elapsed += $0 },
                windowCurrent: { true }, focusCurrent: { true }, read: {
                    reads += 1
                    return .init(after: elapsed >= arrival ? "🌱" : "", caret: elapsed >= arrival ? caret : initialSelection)
                })
            #expect(result.verified && result.reason == "verified")
            #expect(elapsed == arrival && reads == arrival / 25 && result.attempts == reads)
            #expect(result.verifiedSnapshot?.caret == caret)
        }
    }

    @Test func arrivalAfter500MillisecondsRemainsUnconfirmed() {
        var elapsed = 0, reads = 0
        let result = PasteReadbackWatch.run(before: "", selection: initialSelection,
            inserted: "🌱", elementAvailable: true, wait: { elapsed += $0 },
            windowCurrent: { true }, focusCurrent: { true }, read: {
                reads += 1
                return .init(after: elapsed >= 550 ? "🌱" : "", caret: initialSelection)
            })
        #expect(!result.verified && result.verifiedSnapshot == nil && result.reason == "textMismatch")
        #expect(elapsed == 500 && reads == 20 && result.attempts == 20)
    }

    @Test func changedWindowOrFocusStopsBeforeAnotherRead() {
        for changedWindow in [true, false] {
            var elapsed = 0, reads = 0
            let result = PasteReadbackWatch.run(before: "", selection: initialSelection,
                inserted: "🌱", elementAvailable: true, wait: { elapsed += $0 },
                windowCurrent: { !changedWindow || elapsed < 350 },
                focusCurrent: { changedWindow || elapsed < 350 }, read: {
                    reads += 1
                    return .init(after: elapsed >= 450 ? "🌱" : "", caret: initialSelection)
                })
            #expect(!result.verified && result.verifiedSnapshot == nil)
            #expect(result.reason == (changedWindow ? "window_changed" : "focus_changed"))
            #expect(elapsed == 350 && reads == 13)
        }
    }

    @Test func destinationChangeDuringAXReadCannotConfirmExactText() {
        for changedWindow in [true, false] {
            var changed = false
            let result = PasteReadbackWatch.run(before: "", selection: initialSelection,
                inserted: "🌱", elementAvailable: true, wait: { _ in },
                windowCurrent: { !changedWindow || !changed },
                focusCurrent: { changedWindow || !changed }, read: {
                    changed = true
                    return .init(after: "🌱", caret: caret)
                })
            #expect(!result.verified && result.verifiedSnapshot == nil)
            #expect(result.reason == (changedWindow ? "window_changed" : "focus_changed"))
            #expect(result.attempts == 1)
        }
    }

    @Test func missingCapturedPrestateEndsAfterOneLookWithoutReading() {
        for missing in [0, 2] {
            var elapsed = 0
            let result = PasteReadbackWatch.run(before: missing == 0 ? nil : "",
                selection: missing == 1 ? nil : initialSelection, inserted: "🌱",
                elementAvailable: missing != 2, wait: { elapsed += $0 },
                windowCurrent: { true }, focusCurrent: { true }, read: {
                    Issue.record("Missing captured evidence must never read or confirm a later editor")
                    return .init(after: "🌱", caret: caret)
                })
            #expect(!result.verified && result.reason == "unreadable_target")
            #expect(elapsed == 25 && result.attempts == 1)
        }
    }

    @Test func transientUnreadableValueCanBecomeExactWithoutEarlySuccess() {
        var elapsed = 0, unreadableReads = 0
        let result = PasteReadbackWatch.run(before: "", selection: initialSelection,
            inserted: "🌱", elementAvailable: true, wait: { elapsed += $0 },
            windowCurrent: { true }, focusCurrent: { true }, read: {
                if elapsed < 400 { unreadableReads += 1; return .init(after: nil, caret: nil) }
                return .init(after: "🌱", caret: caret)
            })
        #expect(result.verified && elapsed == 400 && unreadableReads == 15)
    }

    @Test func exactTextWithoutExactCaretNeverConfirms() {
        for actualCaret in [nil, NSRange(location: 1, length: 0), NSRange(location: 2, length: 1)] as [NSRange?] {
            var elapsed = 0
            let result = PasteReadbackWatch.run(before: "", selection: initialSelection,
                inserted: "🌱", elementAvailable: true, wait: { elapsed += $0 },
                windowCurrent: { true }, focusCurrent: { true },
                read: { .init(after: "🌱", caret: actualCaret) })
            #expect(!result.verified && result.verifiedSnapshot == nil && elapsed == 500)
            #expect(result.reason == (actualCaret == nil ? "unreadableCaret" : "caretMismatch"))
        }
    }
}
