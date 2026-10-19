


//
import AppKit
import ApplicationServices
import Darwin


extension TargetDelivery {


    // Staged paste proof — a self-test in the dev build against the local test pad app


    /*
    These pure fixtures are shared with offline tests. Creating a receipt is not proof
    of keyboard input; only the guarded live path below may fill its outcome fields.
    */
    static let scratchProofTypedText = "  ask Sam about max_tokens\nReturn keeps this line.  "
    static let scratchProofPayload = "# π Reading lamp\n\n> *Fictional delivery fixture*\n\n## Transcript\n\nThe little reading lamp belongs beside the blue chair and the notebook stays on the table.\n\n## Typed\n\n" + scratchProofTypedText

    static func scratchProofReceipt(documentID: String, trusted: Bool,
                                    isDev: Bool, testpadFrontmost: Bool) -> [String: Any] {
        ["status": "failed", "origin": "Tokens actual Command-V path", "physical_input": false,
         "document": documentID, "accessibility_trusted": trusted,
         "is_dev": isDev, "testpad_frontmost": testpadFrontmost]
    }

    /*
    Runs only in Tokens Dev with the test pad in front, its named empty scratch field
    focused. If this editor has not yet earned staging, three ordinary pastes come first;
    then a fictional prompt is pasted in three steps, Return is sent, and a second Return
    must be refused. Results go to a JSON report at `output`.
    */
    @MainActor static func runStagedScratchProof(output: String, documentID: String) async {
        guard documentID.range(of: "^tp-tokens[0-9A-Za-z_-]+$", options: .regularExpression) != nil else { return }
        /*
        This explicit Dev test route may foreground only its already-open owned scratch note.
        Recording can take focus after Testpad opens; never activate an arbitrary editor.
        */
        if Bundle.main.bundleIdentifier == "com.tinkr.tokens.community.dev.macos", accessibilityTrusted() {
            let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tinkr.testpad").filter { app in
                guard let target = capture(application: app), target.valueBefore == "", target.selection?.length == 0 else { return false }
                return target.window.flatMap { stringAttribute(kAXTitleAttribute as String, from: $0) }?.contains("[\(documentID)]") == true
                    && target.element.flatMap { stringAttribute(kAXIdentifierAttribute as String, from: $0) } == "testpad.target.\(documentID)"
            }
            if candidates.count == 1, let app = candidates.first {
                _            = app.activate(options: [])
                let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                }
            }
        }
        var receipt = scratchProofReceipt(documentID: documentID, trusted: accessibilityTrusted(),
            isDev: Bundle.main.bundleIdentifier == "com.tinkr.tokens.community.dev.macos",
            testpadFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tinkr.testpad")
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
        guard Bundle.main.bundleIdentifier == "com.tinkr.tokens.community.dev.macos",
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.tinkr.testpad",
              let first = capture(application: app), first.valueBefore == "", first.selection?.length == 0,
              first.window.flatMap({ stringAttribute(kAXTitleAttribute as String, from: $0) })?.contains("[\(documentID)]") == true,
              first.element.flatMap({ stringAttribute(kAXIdentifierAttribute as String, from: $0) }) == "testpad.target.\(documentID)" else {
            receipt["failure"] = "requires_focused_empty_named_scratch_and_existing_accessibility"; return
        }
        // Calibration from prior exact ordinary deliveries persists. A fresh editor is used for staging.
        let calibration = PasteAckHistory.trusts(bundle: app.bundleIdentifier) ? [] : ["Calibration one.\n", "Calibration two.\n", "Calibration three.\n"]
        let payload = scratchProofPayload
        var expected = ""
        var outcomes: [String] = []
        for text in calibration {
            guard let target = capture(application: app), target.valueBefore == expected else { receipt["failure"] = "calibration_target_changed"; return }
            let result = await insert(text, into: target)
            outcomes.append(String(describing: result))
            guard result == .verified else { receipt["failure"] = "calibration_not_verified"; receipt["outcomes"] = outcomes
                receipt["window_still_matches"]     = exactWindow(target)
                receipt["focus_still_matches"]      = exactFocus(target)
                receipt["expected_character_count"] = expected.utf16.count + preparedText(text, for: target).utf16.count
                receipt["actual_character_count"]   = target.element.flatMap { value(in: $0)?.utf16.count }
                return }
            expected += preparedText(text, for: target)
            usleep(350_000) // separate ordinary calibration deliveries, as distinct stopped dictations
        }
        guard PasteAckHistory.trusts(bundle: app.bundleIdentifier),
              let target = capture(application: app), target.valueBefore == expected,
              let plan = ThreeStepPaste.plan(preparedText(payload, for: target)) else {
            receipt["failure"] = "calibration_complete_reset_scratch_before_staging"; return
        }
        let result = await insert(payload, into: target, threeSteps: true)
        expected += preparedText(payload, for: target)
        outcomes.append(String(describing: result))
        receipt["outcomes"]              = outcomes
        receipt["planned_staged_pastes"] = plan.steps.count
        receipt["expected_pastes"]       = calibration.count + plan.steps.count
        guard result == .verified, let final = capture(application: app), final.valueBefore == expected else {
            receipt["failure"] = "staged_readback_failed"; return
        }
        receipt["exact_before_send"] = true
        receipt["staged_path_used"]  = stagedSubmissionPID == target.pid
        guard stagedSubmissionPID == target.pid else { receipt["failure"] = "single_paste_is_not_staged_proof"; return }
        let sent = sendReturn(to: target)
        receipt["return_dispatched"] = sent
        receipt["duplicate_return_blocked"] = !sendReturn(to: target)
        usleep(350_000)
        receipt["exact_after_send"] = capture(application: app)?.valueBefore == expected + "\n"
        receipt["expected_text"] = expected + "\n" // fictional fixture only
        receipt["status"] = sent && receipt["exact_after_send"] as? Bool == true && receipt["duplicate_return_blocked"] as? Bool == true ? "passed" : "failed"
    }


}

