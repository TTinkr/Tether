import AppKit
import ApplicationServices
import Foundation

/// Explicit Dev-only coordinate measurement. Never activates an app or presses Return.
enum ClaudeCaretFixtureProof {
    static func exact(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    static let payload = ".quartz"
    static func fixture(_ id: String) -> String? {
        switch id {
        case "two-lines": return "Fictional amber meadow.\nFictional violet lantern."
        case "blank-line-emoji": return "Fictional 🪁 meadow.\n\nFictional violet lantern."
        default: return nil
        }
    }
    static func permits(id: String, value: String, range: CFRange) -> Bool {
        guard let expected = fixture(id), exact(value, expected),
              range.length == 0, range.location >= 0, range.location <= value.utf16.count else { return false }
        // Foundation can represent a zero-length range within a UTF16 surrogate;
        // reject that split explicitly before constructing Swift indices.
        let units = Array(value.utf16)
        if range.location < units.count && (0xDC00...0xDFFF).contains(units[range.location]) { return false }
        // Reject a caret inside a surrogate pair.
        return Range(NSRange(location: range.location, length: 0), in: value) != nil
    }
    static func comparisons(before: String, location: Int, after: String, caret: CFRange?) -> [String: Any] {
        func insertion(_ index: Int) -> String? {
            guard let range = Range(NSRange(location: index, length: 0), in: before) else { return nil }
            var copy = before; copy.replaceSubrange(range, with: payload); return copy
        }
        let units = Array(before.utf16)
        var count = 0, skip = 0
        while skip < units.count && count < location {
            if units[skip] != 10 { count += 1 }
            skip += 1
        }
        while skip < units.count && units[skip] == 10 { skip += 1 }
        let identity = insertion(location), skipped = count == location ? insertion(skip) : nil
        var projected = 0, inverseCount = 0
        for boundary in 0...units.count {
            if projected == location { inverseCount += 1 }
            if boundary < units.count && units[boundary] != 10 { projected += 1 }
        }
        func matches(_ expected: String?) -> Bool { expected.map { exact($0, after) } ?? false }
        return ["identity_value": matches(identity), "skip_lf_right_biased_diagnostic_value": matches(skipped),
            "skip_lf_inverse_boundary_count": inverseCount, "skip_lf_mapping_ambiguous": inverseCount > 1,
            "append_value": exact(before + payload, after),
            "identity_caret": caret?.length == 0 && caret?.location == location + payload.utf16.count,
            "skip_lf_diagnostic_caret": caret?.length == 0 && caret?.location == location + payload.utf16.count,
            "append_identity_caret": caret?.length == 0 && caret?.location == before.utf16.count + payload.utf16.count,
            "append_skip_lf_caret": caret?.length == 0 && caret?.location == before.utf16.filter { $0 != 10 }.count + payload.utf16.count,
            "after_utf16": after.utf16.count, "after_location": caret?.location ?? -1,
            "after_length": caret?.length ?? -1]
    }
    @MainActor static func run(fixtureID: String, output: String) async {
        guard fixture(fixtureID) != nil,
              let receipt = LocalSpeechFixtureProof.reserveReceipt(input: "/__tokens_claude_fixture_no_input__", output: output) else { return }
        var report: [String: Any] = ["fixture_id": fixtureID, "status": "refused", "run_id": UUID().uuidString,
            "physical_input": false, "return_sent": false, "app_activated": false]
        func write() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: receipt, options: .atomic)
            }
        }
        defer { write() }
        guard ProofRoutes.isAllowed, Bundle.main.bundleIdentifier == "com.tinkr.tokens.community.dev.macos",
              TargetDelivery.accessibilityTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.anthropic.claudefordesktop" else { return }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.3)
        guard let window = TargetDelivery.focusedWindow(in: appAX),
              let element = TargetDelivery.focusedElement(in: appAX) else { return }
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard !TargetDelivery.isSecure(element),
              let before = TargetDelivery.value(in: element),
              let selection = TargetDelivery.selectedRange(in: element),
              permits(id: fixtureID, value: before, range: selection) else { return }
        let target = CapturedTarget(id: UUID(), application: app, pid: app.processIdentifier,
            element: element, window: window, screenFrame: nil, selection: selection,
            valueBefore: before, richComposer: TargetDelivery.isRichComposer(element, role: TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: element)))
        guard TargetDelivery.exactWindow(target), TargetDelivery.exactFocus(target),
              TargetDelivery.exactSelection(target), TargetDelivery.exactValue(target),
              !TargetDelivery.isSecure(element) else { return }
        report["before_utf16"] = before.utf16.count
        report["before_location"] = selection.location; report["before_length"] = selection.length
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let outcome = await TargetDelivery.insert(payload, into: target, isCurrent: {
            ProcessInfo.processInfo.systemUptime < deadline && TargetDelivery.exactWindow(target)
                && TargetDelivery.exactFocus(target) && !TargetDelivery.isSecure(element)
        })
        report["status"] = "attempted"
        report["outcome"] = String(describing: outcome)
        report["deadline_exceeded"] = ProcessInfo.processInfo.systemUptime >= deadline
        guard TargetDelivery.exactWindow(target), TargetDelivery.exactFocus(target),
              !TargetDelivery.isSecure(element), let after = TargetDelivery.value(in: element) else {
            report["readback_lease"] = false; return
        }
        report["readback_lease"] = true
        report["comparisons"] = comparisons(before: before, location: selection.location, after: after,
            caret: TargetDelivery.selectedRange(in: element))
    }
}
