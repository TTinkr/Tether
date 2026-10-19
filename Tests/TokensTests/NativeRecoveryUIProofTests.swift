import AppKit
import Testing
@testable import Tokens

struct NativeRecoveryUIProofTests {
    let arguments = ["Tokens", "--recovery-ui-proof", "/tmp/fictional-proof",
                     "--bubble-interactive-preview", "--bubble-preview-production"]

    @Test func routeRequiresDeveloperBuildAndEarlySyntheticStartupFlags() {
        #expect(NativeRecoveryUIProof.allowed(arguments: arguments, distributionMode: "dev"))
        for mode in [nil, "preview", "distribution", "local", "development"] as [String?] {
            #expect(!NativeRecoveryUIProof.allowed(arguments: arguments, distributionMode: mode))
        }
        for flag in ["--recovery-ui-proof", "--bubble-interactive-preview", "--bubble-preview-production"] {
            #expect(!NativeRecoveryUIProof.allowed(arguments: arguments.filter { $0 != flag }, distributionMode: "dev"))
        }
    }

    @Test func expectedFileKeepsCompleteUnicodeAndTrailingWhitespace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try NativeRecoveryUIProof.writeExpectedText(to: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("expected-recovery.txt"))
        #expect(data == Data(NativeRecoveryUIProof.payload.utf8))
        #expect(NativeRecoveryUIProof.payload.utf16.count > 8000)
        #expect(NativeRecoveryUIProof.payload.hasSuffix("  Exact fictional ending.  \n"))
    }

    @Test @MainActor func productionWindowSizesAndReceiptDoNotClaimAnInteraction() throws {
        _ = NSApplication.shared
        let controller = RecoveryWindowController()
        let recovery = controller.present(id: UUID(), text: NativeRecoveryUIProof.payload,
            message: "Paste sent · not confirmed · Copy latest", show: false)
        let bubble = NSWindow(contentRect: NSRect(origin: .zero, size: panelDefaultSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        bubble.isReleasedWhenClosed = false
        defer { recovery.close(); bubble.close() }
        #expect(recovery.contentRect(forFrameRect: recovery.frame).size == RecoveryWindowController.defaultSize)
        #expect(!recovery.isVisible && !bubble.isVisible)
        NativeRecoveryUIProof.applyMinimumSize(to: recovery)
        #expect(recovery.frame.size == recovery.minSize)
        #expect(recovery.frame.size == RecoveryWindowController.minimumSize)
        let content = try #require(recovery.contentView as? RecoveryContent)
        #expect(content.payload == NativeRecoveryUIProof.payload)
        let manifest = NativeRecoveryUIProof.manifest(recovery: recovery, bubble: bubble, minimum: true)
        #expect(manifest["copy_interaction_verified"] as? Bool == false)
        #expect(manifest["watched"] as? Bool == false)
        #expect(manifest["automatic_paste_count"] as? Int == 0)
        #expect(manifest["return_count"] as? Int == 0)
        #expect(manifest["bubble_frame_height"] as? CGFloat == panelDefaultSize.height)
        #expect(manifest["payload_sha256"] as? String == SinglePasteFixtureProof.digest(content.payload))
    }
}
