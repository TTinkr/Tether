import AppKit
import ApplicationServices
import CryptoKit

/// Explicit Dev-only reproduction in user-requested native editors. Requires the
/// exact fictional sentinel and end caret; activates only that owned fixture, never sends Return.
enum NativeEditorFixtureProof {
    static let maximumFixtureTextBytes = 64 * 1024
    enum FixtureTextError: String, Error {
        case duplicateFixtureText = "duplicate_fixture_text"
        case missingFixtureTextPath = "missing_fixture_text_path"
        case requiresRawMode = "fixture_text_requires_raw_mode"
        case pathMustBeAbsolute = "fixture_text_path_must_be_absolute"
        case notRegularFile = "fixture_text_not_regular_file"
        case unreadable = "fixture_text_unreadable"
        case tooLarge = "fixture_text_too_large"
        case invalidUTF8 = "fixture_text_invalid_utf8"
        case empty = "fixture_text_empty"
    }
    /// Freeze a bounded, explicitly supplied local fixture before any target action.
    /// No formatter, whitespace trimming, or Unicode normalization changes its bytes.
    static func fixtureText(arguments: [String]) throws -> String? {
        let positions = arguments.indices.filter { arguments[$0] == "--fixture-text" }
        guard let index = positions.first else { return nil }
        guard positions.count == 1 else { throw FixtureTextError.duplicateFixtureText }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw FixtureTextError.missingFixtureTextPath
        }
        guard arguments.contains("--raw-transcript") else { throw FixtureTextError.requiresRawMode }
        let path = arguments[index + 1]
        guard (path as NSString).isAbsolutePath else { throw FixtureTextError.pathMustBeAbsolute }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw FixtureTextError.notRegularFile
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            data = try file.read(upToCount: maximumFixtureTextBytes + 1) ?? Data()
        } catch let error as FixtureTextError { throw error }
        catch { throw FixtureTextError.unreadable }
        guard data.count <= maximumFixtureTextBytes else { throw FixtureTextError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw FixtureTextError.invalidUTF8 }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FixtureTextError.empty }
        return text
    }
    static let bundles: Set<String> = ["com.apple.TextEdit", "com.apple.Notes", "com.tinkr.testpad"]
    static func sentinel(_ id: String) -> String { "Tokens streaming test \(id)\n" }
    static func owned(bundle: String, id: String, value: String?, range: NSRange?) -> Bool {
        guard bundles.contains(bundle), SinglePasteFixtureProof.validFixtureID(id),
              value?.utf16.elementsEqual(sentinel(id).utf16) == true, let range else { return false }
        return range.length == 0 && range.location == sentinel(id).utf16.count
    }
    struct CandidateEvidence {
        let pid: Int32
        let value: String?
        let range: NSRange?
        let secure: Bool
        let windowCount: Int?
        let hasFocusedWindow: Bool
        var identifier: String? = nil
        var title: String? = nil
    }
    static func mayPrepare(bundle: String, id: String, document: String, candidate: CandidateEvidence) -> Bool {
        guard bundle == "com.tinkr.testpad", document.range(of: "^tp-[a-z0-9]{4,12}$", options: .regularExpression) != nil,
              SinglePasteFixtureProof.validFixtureID(id), !candidate.secure, candidate.hasFocusedWindow,
              candidate.windowCount == 1, candidate.identifier == "testpad.target." + document,
              candidate.title?.contains("[" + document + "]") == true,
              candidate.value?.utf16.elementsEqual(sentinel(id).utf16) == true,
              let range = candidate.range else { return false }
        return range.length == 0 && range.location >= 0 && range.location <= sentinel(id).utf16.count
    }
    static func uniqueOwnedIndex(bundle: String, id: String, candidates: [CandidateEvidence], prepareDocument: String? = nil) -> Int? {
        let matches = candidates.indices.filter { index in
            let candidate = candidates[index]
            if let document = prepareDocument {
                return candidate.identifier == "testpad.target." + document
                    && candidate.title?.contains("[" + document + "]") == true
                    && candidate.value?.utf16.elementsEqual(sentinel(id).utf16) == true
            }
            return owned(bundle: bundle, id: id, value: candidate.value, range: candidate.range)
        }
        guard matches.count == 1 else { return nil }
        let selected = candidates[matches[0]]
        guard !selected.secure, selected.hasFocusedWindow, selected.windowCount == 1 else { return nil }
        if let document = prepareDocument,
           !mayPrepare(bundle: bundle, id: id, document: document, candidate: selected) { return nil }
        return matches[0]
    }
    /// Never warm or activate candidates while identifying the owned fixture.
    @MainActor private static func uniqueOwnedTarget(bundle: String, id: String, diagnostics: inout [String: Any], prepareDocument: String? = nil) -> CapturedTarget? {
        var targets: [CapturedTarget] = []
        var evidence: [CandidateEvidence] = []
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }
        diagnostics["bundle_instances"] = applications.count
        var sentinelMatches = 0
        var ranges: [[String: Int]] = []
        for app in applications {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.3)
            guard let window = TargetDelivery.focusedWindow(in: application),
                  let element = TargetDelivery.focusedElement(in: application) else { continue }
            AXUIElementSetMessagingTimeout(element, 0.3)
            let secure = TargetDelivery.isSecure(element)
            guard !secure else { continue }
            let value = TargetDelivery.value(in: element)
            let range = TargetDelivery.selectedRange(in: element)
            let count = TargetDelivery.windowCount(in: application)
            if value?.utf16.elementsEqual(sentinel(id).utf16) == true {
                sentinelMatches += 1
                ranges.append(["location": range?.location ?? -1, "length": range?.length ?? -1,
                    "windows": count ?? -1])
            }
            evidence.append(CandidateEvidence(pid: app.processIdentifier, value: value,
                range: range.map { NSRange(location: $0.location, length: $0.length) },
                secure: secure, windowCount: count, hasFocusedWindow: true,
                identifier: TargetDelivery.stringAttribute(kAXIdentifierAttribute as String, from: element),
                title: TargetDelivery.stringAttribute(kAXTitleAttribute as String, from: window)))
            targets.append(CapturedTarget(id: UUID(), application: app, pid: app.processIdentifier,
                element: element, window: window, screenFrame: nil, selection: range, valueBefore: value,
                windowCount: count, richComposer: TargetDelivery.isRichComposer(element,
                    role: TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: element))))
        }
        diagnostics["exact_sentinel_matches"] = sentinelMatches
        diagnostics["exact_sentinel_ranges"] = ranges
        diagnostics["valid_matches"] = evidence.filter {
            !$0.secure && $0.hasFocusedWindow && $0.windowCount == 1 && owned(bundle: bundle, id: id, value: $0.value, range: $0.range)
        }.count
        guard let index = uniqueOwnedIndex(bundle: bundle, id: id, candidates: evidence, prepareDocument: prepareDocument) else { return nil }
        return targets[index]
    }
    static func run(output: String, id: String, bundle: String, prepareOwnedTestpad: Bool = false, fixtureDocument: String? = nil, completion: @escaping () -> Void) {
        Task { @MainActor in
            await runAsync(output: output, id: id, bundle: bundle, prepareOwnedTestpad: prepareOwnedTestpad, fixtureDocument: fixtureDocument, completion: completion)
        }
    }
    @MainActor private static func runAsync(output: String, id: String, bundle: String, prepareOwnedTestpad: Bool, fixtureDocument: String?, completion: @escaping () -> Void) async {
        var receipt: [String: Any] = ["status": "blocked", "physical_input": false,
            "microphone_used": false, "return_count": 0, "fixture_id": id, "bundle": bundle,
            "synthetic_fixture": true, "stop_to_text_ready": NSNull(),
            "reveal_timing": NSNull(), "first_post_ms": NSNull(),
            "first_ack_ms": NSNull(), "complete_ack_ms": NSNull(),
            "source_commit": Bundle.main.object(forInfoDictionaryKey: "TokensSourceCommit") ?? NSNull(),
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? NSNull(),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? NSNull(),
            "product_bundle": Bundle.main.bundleIdentifier ?? "unavailable",
            "distribution_mode": Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") ?? NSNull()]
        var pending = false
        func finish() {
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
        defer { if !pending { finish(); completion() } }
        let arguments = ProcessInfo.processInfo.arguments
        let rawMode = arguments.contains("--raw-transcript")
        receipt["raw_mode"] = rawMode
        let fileText: String?
        do { fileText = try fixtureText(arguments: arguments) }
        catch let error as FixtureTextError { receipt["failure"] = error.rawValue; return }
        catch { receipt["failure"] = "fixture_text_unreadable"; return }
        guard !rawMode || !arguments.contains("--early-prefix") else {
            receipt["failure"] = "raw_mode_has_no_early_marker"; return
        }
        if let fileText {
            receipt["fixture_text_source"] = "local_utf8_file"
            receipt["fixture_text_bytes"] = fileText.utf8.count
            receipt["fixture_text_sha256"] = SHA256.hash(data: Data(fileText.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard !prepareOwnedTestpad || fixtureDocument != nil else { receipt["failure"] = "missing_fixture_document"; return }
        let prepareDocument = prepareOwnedTestpad ? fixtureDocument : nil
        guard DevChannel.isActive, Bundle.main.bundleIdentifier == "com.tinkr.tokens.community.dev.macos",
              TargetDelivery.accessibilityTrusted(),
              bundles.contains(bundle),
              var first = uniqueOwnedTarget(bundle: bundle, id: id, diagnostics: &receipt, prepareDocument: prepareDocument),
              (prepareDocument != nil || owned(bundle: bundle, id: id, value: first.valueBefore,
                    range: first.selection.map { NSRange(location: $0.location, length: $0.length) })),
              !TargetDelivery.isSecure(first.element) else {
            receipt["failure"] = "requires_dev_existing_trust_focused_exact_owned_sentinel_and_caret"; return
        }
        let app = first.application
        // Only the exact owned fixture validated above can be activated, matching the
        // existing Testpad Dev proof route. Recheck the whole lease after activation.
        _ = app.activate(options: [])
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
              ProcessInfo.processInfo.systemUptime < activationDeadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              TargetDelivery.exactWindow(first), TargetDelivery.exactFocus(first),
              TargetDelivery.exactValue(first), TargetDelivery.exactSelection(first),
              let element = first.element, !TargetDelivery.isSecure(element),
              TargetDelivery.value(in: element)?.utf16.elementsEqual(sentinel(id).utf16) == true,
              TargetDelivery.windowCount(in: AXUIElementCreateApplication(first.pid)) == 1 else {
            receipt["failure"] = "owned_fixture_not_frontmost"; return
        }
        if let document = prepareDocument {
            let evidence = CandidateEvidence(pid: first.pid, value: TargetDelivery.value(in: element),
                range: TargetDelivery.selectedRange(in: element).map { NSRange(location: $0.location, length: $0.length) },
                secure: TargetDelivery.isSecure(element), windowCount: TargetDelivery.windowCount(in: AXUIElementCreateApplication(first.pid)),
                hasFocusedWindow: TargetDelivery.exactWindow(first),
                identifier: TargetDelivery.stringAttribute(kAXIdentifierAttribute as String, from: element),
                title: first.window.flatMap { TargetDelivery.stringAttribute(kAXTitleAttribute as String, from: $0) })
            guard mayPrepare(bundle: bundle, id: id, document: document, candidate: evidence),
                  TargetDelivery.exactFocus(first), TargetDelivery.exactSelection(first) else {
                receipt["failure"] = "prepare_lease_changed"; return
            }
            var end = CFRange(location: sentinel(id).utf16.count, length: 0)
            guard let value = AXValueCreate(.cfRange, &end),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                receipt["failure"] = "prepare_caret_failed"; return
            }
            first.selection = end
            guard TargetDelivery.exactWindow(first), TargetDelivery.exactFocus(first),
                  TargetDelivery.exactSelection(first), !TargetDelivery.isSecure(element),
                  owned(bundle: bundle, id: id, value: TargetDelivery.value(in: element),
                    range: TargetDelivery.selectedRange(in: element).map { NSRange(location: $0.location, length: $0.length) }) else {
                receipt["failure"] = "prepare_readback_failed"; return
            }
            receipt["caretaker_prepared"] = true
            receipt["caret_preparation_is_paste_proof"] = false
        }
        try? Data("ready".utf8).write(to: URL(fileURLWithPath: output + ".ready"), options: .atomic)
        // Explicit bounded observation window for a selected-window recorder.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 10))
        receipt["rich_composer"] = first.richComposer
        var expected = sentinel(id)
        var calibrations = 0
        // Earn history through actual verified pastes, never by setting a trust counter.
        while (calibrations == 0 || !PasteAckHistory.allowsStaging(bundle: bundle, richComposer: first.richComposer)), calibrations < 3 {
            guard let target = TargetDelivery.capture(application: app), target.valueBefore == expected else {
                receipt["failure"] = "calibration_target_changed"; return
            }
            let piece = "Fictional calibration \(calibrations + 1).\n"
            let outcome = await TargetDelivery.insert(piece, into: target)
            guard outcome == .verified else { receipt["failure"] = "calibration_not_verified"; return }
            expected += TargetDelivery.preparedText(piece, for: target)
            calibrations += 1
        }
        receipt["calibration_pastes"] = calibrations
        guard let target = TargetDelivery.capture(application: app), target.valueBefore == expected,
              PasteAckHistory.allowsStaging(bundle: bundle, richComposer: target.richComposer) else {
            receipt["failure"] = "staging_not_eligible"; return
        }
        let raw = "The blue notebook is beside the lamp and the green pencil rests on the table. My name is R I L E Y. Keep 1234567910 and café 👩🏽‍💻 exactly."
        let parts = fileText.map { TokensPromptParts(marker: "", body: $0, metadata: "") } ?? (rawMode
            ? TokensOutputOptions.parts(TokensOutputOptions.body(raw, characterTags: false, numberTags: false), metadata: false)
            : TokensPromptParts(marker: "# π\n",
                body: "The blue notebook is beside the lamp and the green pencil rests on the table. This fictional transcript checks that all words survive.",
                metadata: "\n\n---\n\n# Metadata\n\n> Fictional streaming fixture."))
        let payload = parts.text
        let plan = parts.revealPlan(spokenWordCount: parts.body.split(whereSeparator: { $0.isWhitespace }).count)
        receipt["reveal_target_ms"] = Int(plan.duration * 1000)
        let start = ProcessInfo.processInfo.systemUptime
        func recordTiming(_ timing: RevealDeliveryTiming) {
            if let data = try? JSONEncoder().encode(timing),
               let object = try? JSONSerialization.jsonObject(with: data) {
                receipt["reveal_timing"] = object
            }
            receipt["first_post_ms"] = timing.firstPostMS.map { $0 as Any } ?? NSNull()
            receipt["first_ack_ms"] = timing.firstAcknowledgedMS.map { $0 as Any } ?? NSNull()
            receipt["complete_ack_ms"] = timing.completeAcknowledgedMS.map { $0 as Any } ?? NSNull()
        }
        func record(_ outcome: DeliveryOutcome) {
            receipt["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            receipt["outcome"] = String(describing: outcome)
            receipt["staged_path_used"] = TargetDelivery.stagedSubmissionPID == target.pid
            receipt["exact_after"] = TargetDelivery.capture(application: app)?.valueBefore?.utf16.elementsEqual(expected.utf16) == true
            receipt["expected_text"] = expected
            receipt["status"] = outcome == .verified && receipt["exact_after"] as? Bool == true
                && receipt["staged_path_used"] as? Bool == true ? "passed" : "failed"
        }
        expected += TargetDelivery.preparedText(payload, for: target, preservingTrailingWhitespace:
            arguments.contains("--early-prefix"), preservingWhitespace: fileText != nil)
        if ProcessInfo.processInfo.arguments.contains("--early-prefix") {
            pending = true
            TargetDelivery.beginStopPrefix("# π\n", into: target, isCurrent: { true }) { result in
                Task { @MainActor in
                defer { finish(); completion() }
                guard case .verified(let continuationTarget) = result,
                      let pieces = StopStream.remainderSteps(prefix: "# π\n", payload: payload) else {
                    receipt["failure"] = "early_prefix_not_verified"; return
                }
                receipt["early_prefix_verified"] = true
                record(await TargetDelivery.insert(pieces.joined(), into: continuationTarget,
                    threeSteps: true, exactContinuation: true, continuationPieces: pieces, revealPlan: plan.removingMarker(),
                    textReadyUptime: start, revealObserver: recordTiming))
                }
            }
        } else {
            record(await TargetDelivery.insert(payload, into: target, threeSteps: true, revealPlan: plan,
                textReadyUptime: start, revealObserver: recordTiming))
        }

    }
}
