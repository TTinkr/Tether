/*
An explicit preview-only adapter for one real production paste into an owned
fictional field. It never activates an app, opens the microphone, retries, or
sends Return. A synthetic insertion receipt is not physical-input proof.
*/
import AppKit
import ApplicationServices
import CryptoKit
import TokensCore

enum SinglePasteFixtureProof {
    static let delaySeconds: TimeInterval = 8
    static let allowedBundles: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.todesktop.230313mzl4w4u92", "com.tinkr.testpad"
    ]

    static func allowed(distributionMode: String?, proofRoutesAllowed: Bool,
                        continuousReveal: Bool = false, devChannel: Bool = false) -> Bool {
        proofRoutesAllowed && (distributionMode == "preview"
            || (distributionMode == "dev" && devChannel && continuousReveal))
    }

    static func sentinel(fixtureID: String) -> String {
        "TOKENS_FICTIONAL_FIXTURE[\(fixtureID)]\n"
    }

    static func payload(fixtureID: String) -> String {
        "Fictional single-paste fixture \(fixtureID).\n"
            + String(repeating: "The fictional blue notebook stays beside the lamp. Café 中文 👩🏽‍💻.\n", count: 120)
            + "  Exact fictional ending.  \n"
    }

    static func validFixtureID(_ id: String) -> Bool {
        (12...80).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    /// Pure ownership checks; they do not replace the production insertion lease.
    static func ownershipFailure(fixtureID: String, targetBundle: String, title: String?,
                                 value: String?, role: String?, secure: Bool,
                                 selection: NSRange?) -> String? {
        guard validFixtureID(fixtureID) else { return "invalid_fixture_id" }
        guard allowedBundles.contains(targetBundle) else { return "target_bundle_not_allowed" }
        guard title?.contains(fixtureID) == true else { return "owned_window_not_focused" }
        guard !secure, ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") else {
            return "requires_unprotected_text_field"
        }
        let initial = sentinel(fixtureID: fixtureID)
        guard value == initial else { return "fixture_value_mismatch" }
        if let selection, selection.length != 0 || selection.location != initial.utf16.count {
            return "fixture_caret_mismatch"
        }
        return nil
    }

    static func fixtureText(_ data: Data) -> String? {
        guard data.count <= 65_536, String(data: data, encoding: .utf8) != nil else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    struct Receipt: Codable {
        var status = "blocked"
        var failure: String?
        var outcome: String?
        var fixtureID: String
        var targetBundle: String
        var physicalInput = false
        var microphoneUsed = false
        var insertInvocations = 0
        var returnInvocations = 0
        var retryInvocations = 0
        var beforeCharacters: Int?
        var beforeSHA256: String?
        var afterCharacters: Int?
        var afterSHA256: String?
        var expectedCharacters: Int?
        var expectedSHA256: String?
        var exactAfter: Bool?
        var targetStillCurrent: Bool?
        var continuousRevealRequested = false
        var revealTiming: RevealDeliveryTiming?
        var singlePasteFallback: Bool?
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The caller owns launch-flag parsing, synthetic initialization, and termination.
    static func schedule(output: String, fixtureID: String, targetBundle: String,
                         completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            Task { @MainActor in
                let arguments = CommandLine.arguments
                let path = arguments.firstIndex(of: "--fixture-text").flatMap { index in
                    index + 1 < arguments.count ? arguments[index + 1] : nil
                }
                await run(output: output, fixtureID: fixtureID, targetBundle: targetBundle,
                    continuousReveal: arguments.contains("--continuous-reveal"), fixtureTextPath: path)
                completion()
            }
        }
    }

    /// Revalidates the complete fixture after the operator's eight-second focus window.
    @MainActor static func run(output: String, fixtureID: String, targetBundle: String,
                              continuousReveal: Bool = false, fixtureTextPath: String? = nil) async {
        var receipt = Receipt(fixtureID: fixtureID, targetBundle: targetBundle)
        receipt.continuousRevealRequested = continuousReveal
        defer {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            do { try encoder.encode(receipt).write(to: URL(fileURLWithPath: output), options: .atomic) }
            catch { Diagnostics.event("single_paste_fixture_receipt_write_failed") }
        }
        guard allowed(distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String,
                      proofRoutesAllowed: ProofRoutes.isAllowed, continuousReveal: continuousReveal,
                      devChannel: DevChannel.isActive) else {
            receipt.failure = "requires_preview_or_explicit_dev_reveal"; return
        }
        guard validFixtureID(fixtureID), allowedBundles.contains(targetBundle) else {
            receipt.failure = "invalid_fixture_arguments"; return
        }
        guard TargetDelivery.accessibilityTrusted() else {
            receipt.failure = "existing_accessibility_required"; return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == targetBundle,
              let target = TargetDelivery.capture(application: app) else {
            receipt.failure = "requested_fixture_app_not_focused"; return
        }
        let title = target.window.flatMap { TargetDelivery.stringAttribute(kAXTitleAttribute as String, from: $0) }
        let role = target.element.flatMap { TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: $0) }
        if let failure = ownershipFailure(fixtureID: fixtureID, targetBundle: targetBundle,
            title: title, value: target.valueBefore, role: role, secure: TargetDelivery.isSecure(target.element),
            selection: target.selection.map { NSRange(location: $0.location, length: $0.length) }) {
            receipt.failure = failure; return
        }
        // All source text here is our exact fictional sentinel. No arbitrary field content is saved.
        let before = sentinel(fixtureID: fixtureID)
        let text: String
        if continuousReveal {
            guard let path = fixtureTextPath, path.hasPrefix("/"),
                  (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = FileHandle(forReadingAtPath: path) else {
                receipt.failure = "requires_absolute_fixture_text"; return
            }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65_537), let decoded = fixtureText(data),
                  !decoded.isEmpty else { receipt.failure = "invalid_or_oversized_utf8_fixture"; return }
            text = decoded
            guard TargetDelivery.preparedText(text, for: target, preservingWhitespace: true).utf8.elementsEqual(text.utf8) else {
                receipt.failure = "fixture_requires_text_preparation"; return
            }
        } else { text = payload(fixtureID: fixtureID) }
        let expected = before + TargetDelivery.preparedText(text, for: target, preservingWhitespace: continuousReveal)
        receipt.beforeCharacters = before.utf16.count
        receipt.beforeSHA256 = digest(before)
        receipt.expectedCharacters = expected.utf16.count
        receipt.expectedSHA256 = digest(expected)
        receipt.insertInvocations = 1
        let frozenPlan = continuousReveal ? TranscriptRevealPlan(marker: "", body: text, metadata: "",
            spokenWordCount: text.split(whereSeparator: { $0.isWhitespace }).count) : nil
        let ready = ProcessInfo.processInfo.systemUptime
        let outcome = await TargetDelivery.insert(text, into: target, threeSteps: continuousReveal,
            revealPlan: frozenPlan, textReadyUptime: ready, revealObserver: { receipt.revealTiming = $0 })
        if continuousReveal {
            if receipt.revealTiming != nil { receipt.singlePasteFallback = false }
            else if outcome == .verified || outcome == .delivered || outcome == .notObserved {
                receipt.singlePasteFallback = true
            }
            // A refusal with no timing receipt does not prove that any paste was posted.
        }
        receipt.outcome = String(describing: outcome)
        receipt.status = outcome == .verified ? "verified" : "unconfirmed"
        if case .failed = outcome { receipt.status = "failed" }
        let current = TargetDelivery.exactWindow(target) && TargetDelivery.exactFocus(target)
            && !TargetDelivery.isSecure(target.element)
        receipt.targetStillCurrent = current
        if current, let element = target.element, let after = TargetDelivery.value(in: element) {
            receipt.afterCharacters = after.utf16.count
            receipt.afterSHA256 = digest(after)
            receipt.exactAfter = after.utf8.elementsEqual(expected.utf8)
        }
        // No activation, second insert, Return, clipboard cleanup, or automatic recovery retry.
    }
}
