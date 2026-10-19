/*
Explicit preview-only native UI fixture. Both windows use production views;
only the words, destination label and waveform are fictional. The real Copy all
button remains usable for an operator-owned Testpad check. No capture, target
lookup, global shortcuts, paste, or Return is started by this adapter.
*/
import AppKit
import SwiftUI

enum NativeRecoveryUIProof {
    static let fixtureID = "tokens-native-recovery-fictional"
    static let payload = SinglePasteFixtureProof.payload(fixtureID: fixtureID)
    static let destination = "Safari · text area"

    /// Reuse the existing early-return synthetic startup, including inert menu shortcuts. Only an
    /// explicit developer build ("dev") may run it; ordinary community and release builds never do.
    static func allowed(arguments: [String], distributionMode: String?) -> Bool {
        ProofRoutes.allowed(distributionMode: distributionMode)
            && arguments.contains("--recovery-ui-proof")
            && arguments.contains("--bubble-interactive-preview")
            && arguments.contains("--bubble-preview-production")
    }

    /// minSize is a production window-frame constraint, not a content-size constraint.
    static func applyMinimumSize(to window: NSWindow) {
        var frame = window.frame
        frame.size = window.minSize
        window.setFrame(frame, display: false)
    }

    static func writeExpectedText(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: directory.appendingPathComponent("expected-recovery.txt"), options: .atomic)
    }

    static func manifest(recovery: NSWindow, bubble: NSWindow, minimum: Bool) -> [String: Any] {
        ["status": "native_fixture_presented_not_verified", "fixture_id": fixtureID,
         "physical_input": false, "microphone_started": false, "global_shortcuts_started": false,
         "automatic_paste_count": 0, "return_count": 0,
         "copy_interaction_verified": false, "watched": false,
         "destination_label_is_fictional": true, "destination_label": destination,
         "recovery_size": minimum ? "minimum" : "default",
         "payload_utf16_count": payload.utf16.count, "payload_sha256": SinglePasteFixtureProof.digest(payload),
         "expected_file": "expected-recovery.txt",
         "recovery_window_id": recovery.windowNumber, "bubble_window_id": bubble.windowNumber,
         "recovery_frame_width": recovery.frame.width, "recovery_frame_height": recovery.frame.height,
         "bubble_frame_width": bubble.frame.width, "bubble_frame_height": bubble.frame.height]
    }
}

extension AppDelegate {
    func runRecoveryUIProof(directoryPath: String, minimum: Bool) {
        guard ProofRoutes.isAllowed, model.isSyntheticRun, bubbleInteractivePreview,
              NativeRecoveryUIProof.allowed(arguments: ProcessInfo.processInfo.arguments,
                distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String) else { return }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        do { try NativeRecoveryUIProof.writeExpectedText(to: directory) }
        catch { Diagnostics.event("native_recovery_proof_fixture_write_failed"); NSApp.terminate(nil); return }

        NSApp.setActivationPolicy(.regular)
        model.runInteractiveBubblePreview()
        model.destinationLabel = NativeRecoveryUIProof.destination
        BubbleLayout.shared.vertical = false
        let bubble = CaptureBubblePanel(contentRect: NSRect(origin: .zero, size: panelDefaultSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble.title = "Tokens Recovery UI Proof · Fictional destination"
        bubble.identifier = NSUserInterfaceItemIdentifier("TTTCompactPanel")
        bubble.contentView = hostingView(
            TokensThinkingBubble(model: model, audio: model.audio).preferredColorScheme(.light), size: panelDefaultSize)
        surfaceWindow = bubble
        configureCompactWindow(bubble)

        let recovery = model.recoveryWindows.present(id: UUID(), text: NativeRecoveryUIProof.payload,
            message: "Paste sent · not confirmed · Copy latest", show: false)
        if minimum { NativeRecoveryUIProof.applyMinimumSize(to: recovery) }
        recovery.center()
        recovery.orderFrontRegardless()
        bubble.presentRequested()
        do {
            let data = try JSONSerialization.data(withJSONObject:
                NativeRecoveryUIProof.manifest(recovery: recovery, bubble: bubble, minimum: minimum),
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("native-ui-fixture.json"), options: .atomic)
        } catch { Diagnostics.event("native_recovery_proof_manifest_write_failed") }
    }
}
