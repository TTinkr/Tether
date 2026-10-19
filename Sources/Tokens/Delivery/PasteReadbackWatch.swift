
import Foundation

enum PasteReadbackWatch {
    static let intervalMilliseconds = 25
    static let maximumAttempts = 20

    struct Observation {
        var after: String?
        var caret: NSRange?
    }
    struct Outcome {
        var reason = "unreadable_target"
        var verifiedSnapshot: Observation?
        var attempts = 0
        var observedRead = false
        var observedChange = false
        var verified: Bool { verifiedSnapshot != nil }

        func insertionNotObserved(role: String?, hasSelection: Bool) -> Bool {
            // Container AXValues can be constant even after a successful browser paste.
            let textLike = hasSelection || ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "")
            return textLike && observedRead && !observedChange
                && reason != "window_changed" && reason != "focus_changed"
        }
    }

    /// The budget counts sleeps; real AX IPC can add wall time.
    static func run(before: String?, selection: NSRange?, inserted: String,
                    elementAvailable: Bool, wait: (Int) -> Void,
                    windowCurrent: () -> Bool, focusCurrent: () -> Bool,
                    read: () -> Observation, maximumWaitAttempts: Int = maximumAttempts, richComposer: Bool = false,
                    caretSkipsLineBreaks: Bool = false,
                    onRead: (Observation) -> Void = { _ in }) -> Outcome {
        var outcome = Outcome()
        for _ in 0..<maximumWaitAttempts {
            wait(intervalMilliseconds)
            outcome.attempts += 1
            guard windowCurrent() else { outcome.reason = "window_changed"; break }
            guard focusCurrent() else { outcome.reason = "focus_changed"; break }
            guard elementAvailable, let before else { break }
            let observation = read()
            if let after = observation.after {
                outcome.observedRead = true
                outcome.observedChange = outcome.observedChange || after != before
            }
            onRead(observation)
            // AX reads can yield; never confirm a snapshot after its destination changed.
            guard windowCurrent() else { outcome.reason = "window_changed"; break }
            guard focusCurrent() else { outcome.reason = "focus_changed"; break }
            guard let selection else {
                outcome.reason = "unreadable_selection"
                if outcome.observedChange && outcome.attempts >= maximumAttempts { break }
                continue
            }
            let result = PasteAcknowledgement.evaluate(before: before, selection: selection,
                inserted: inserted, after: observation.after, caret: observation.caret, richComposer: richComposer, caretSkipsLineBreaks: caretSkipsLineBreaks)
            outcome.reason = result.rawValue
            if result == .verified {
                outcome.verifiedSnapshot = observation
                break
            }
            // Changes are not exact acceptance, but should not create a spurious failure popup.
            if outcome.observedChange && outcome.attempts >= maximumAttempts { break }
        }
        return outcome
    }
}
