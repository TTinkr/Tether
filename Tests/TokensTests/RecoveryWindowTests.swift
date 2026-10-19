import AppKit
import SwiftUI
import Testing
import Vision
@testable import Tokens

struct RecoveryWindowTests {
    @Test func recoveryExplanationDoesNotMislabelUnconfirmedOrPartialDelivery() {
        let failed = RecoveryPresentation(message: "Paste unavailable · Copy latest")
        #expect(failed.headline == "We couldn’t paste your words.")
        #expect(failed.caution == nil)
        #expect(!failed.headline.contains("find a place"))
        let unconfirmed = RecoveryPresentation(message: "Paste sent · not confirmed · Copy latest")
        #expect(unconfirmed.headline == "We couldn’t confirm your paste.")
        #expect(unconfirmed.caution != nil)
        let partial = RecoveryPresentation(message: "Partial text inserted · Copy latest")
        #expect(partial.headline == "Only part of your words pasted.")
        #expect(partial.caution != nil)
        #expect(RecoveryPresentation(message: "No destination found").headline == "We couldn’t find a place to paste.")
        #expect(RecoveryPresentation(message: "Text inserted · Send unavailable · Copy latest").headline == "Your words pasted, but weren’t sent.")
    }

    @Test @MainActor func longUnicodePayloadSurvivesAnotherTalkAndExplicitCopy() throws {
        _ = NSApplication.shared
        let controller = RecoveryWindowController()
        let long = String(repeating: "Fictional five-minute talk 👩🏽‍💻 — café 中文.\n", count: 900) + "  exact ending  \n"
        let firstID = UUID()
        let first = controller.present(id: firstID, text: long, message: "Paste sent · not confirmed", show: false)
        let second = controller.present(id: UUID(), text: "Second fictional talk", message: "Paste unavailable", show: false)
        defer { first.close(); second.close() }
        let content = try #require(first.contentView as? RecoveryContent)
        content.layoutSubtreeIfNeeded()
        #expect(content.textView?.string == long)
        #expect(content.textView?.isSelectable == true)
        #expect(content.textView?.isEditable == false)
        #expect(!first.isVisible)
        #expect(first !== second)
        #expect(controller.present(id: firstID, text: long, message: "Paste sent", show: false) === first)
        let pasteboard = NSPasteboard(name: .init("tokens-recovery-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        #expect(content.copyAll(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == long)
        #expect(content.copyTitle == "Copied")
        // Closing one recovery window cannot mutate the second talk's payload.
        first.close()
        second.contentView?.layoutSubtreeIfNeeded()
        #expect((second.contentView as? RecoveryContent)?.textView?.string == "Second fictional talk")
    }

    @Test func destinationLabelsNeverClaimAnUnknownOrProtectedFieldIsReady() {
        #expect(DestinationPreview.label(app: "Safari", role: "AXTextArea", secure: false) == "Safari · text area")
        #expect(DestinationPreview.label(app: "Cursor", role: nil, secure: false) == "Cursor · no text box detected")
        #expect(DestinationPreview.label(app: "Safari", role: "AXTextField", secure: true) == "Safari · protected field")
    }

    @Test @MainActor func firstTwoTranscriptLinesAreVisibleImmediatelyAtMinimumSize() throws {
        _ = NSApplication.shared
        let controller = RecoveryWindowController()
        let panel = controller.present(id: UUID(), text: String(repeating: "Saved words stay here.\n", count: 100),
            message: "Paste sent · not confirmed · Copy latest", show: false)
        defer { panel.close() }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: panel.minSize), display: false)
        let content = try #require(panel.contentView as? RecoveryContent)
        content.layoutSubtreeIfNeeded()
        let textView = try #require(content.textView)
        let scroll = try #require(textView.enclosingScrollView)
        let layout = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layout.ensureLayout(for: container)
        // AppKit may trim a few blank inset points while sizing the scroll view;
        // the invariant is that the first two baselines remain visible immediately.
        let firstBaseline = textView.textContainerOrigin.y + layout.location(forGlyphAt: 0).y
            - scroll.contentView.bounds.minY
        #expect(firstBaseline > 0 && firstBaseline <= 40)
        #expect(scroll.contentSize.height >= firstBaseline + 2 * 18)
        #expect(textView.isSelectable && !textView.isEditable)
    }

    /*
    Codex RC3 (build 81): at the pop-up's minimum size the copy button read "Copy to clip…".
    Every copy title the pop-up can show must fit its button whole: the full title at the
    default size, the shorter one at the minimum size. Widths are measured in the pop-up's own
    button style against the button width its layout gives.
    */
    @Test @MainActor func everyCopyTitleFitsItsButtonAtMinimumAndDefaultSizes() {
        _ = NSApplication.shared
        let narrow = RecoveryLayout.buttonWidth(contentWidth: RecoveryWindowController.minimumSize.width)
        let wide = RecoveryLayout.buttonWidth(contentWidth: RecoveryWindowController.defaultSize.width)
        // The full title does not fit the minimum width: this is what cut it to "Copy to clip…".
        #expect(Self.copyButtonWidthNeeded(for: "Copy to clipboard") > narrow)
        for title in ["Copy to clipboard", "Try copying again", "Copied"] {
            let compact = RecoveryDocument.compactTitle(for: title)
            #expect(Self.copyButtonWidthNeeded(for: compact) <= narrow,
                    "\(compact) needs \(Self.copyButtonWidthNeeded(for: compact)) of \(narrow)")
            // The default size keeps the full title, as before.
            #expect(Self.copyButtonWidthNeeded(for: title) <= wide,
                    "\(title) needs \(Self.copyButtonWidthNeeded(for: title)) of \(wide)")
        }
    }

    /*
    The same check on pixels, as Codex looked at them: render the real pop-up at both sizes and
    read its words back. At the minimum size the button says "Copy words", never a cut-off title.
    */
    @Test @MainActor func renderedCopyButtonReadsWholeAtMinimumAndDefaultSizes() async throws {
        _ = NSApplication.shared
        let message = "Paste sent · not confirmed · Copy latest"
        let small = Self.laidOut(size: RecoveryWindowController.minimumSize, message: message)
        defer { small.close() }
        let minimum = try await Self.recognizedText(in: try #require(small.contentView))
        #expect(minimum.contains { $0.contains("Copy words") }, "\(minimum)")
        #expect(!minimum.contains { $0.contains("Copy to clip") || $0.contains("…") || $0.contains("...") }, "\(minimum)")
        let large = Self.laidOut(size: RecoveryWindowController.defaultSize, message: message)
        defer { large.close() }
        let standard = try await Self.recognizedText(in: try #require(large.contentView))
        #expect(standard.contains { $0.contains("Copy to clipboard") }, "\(standard)")
        #expect(!standard.contains { $0.contains("…") || $0.contains("...") }, "\(standard)")
    }

    @Test func compactCopyTitlesStillSayTheWholeAction() {
        #expect(RecoveryDocument.compactTitle(for: "Copy to clipboard") == "Copy words")
        #expect(RecoveryDocument.compactTitle(for: "Try copying again") == "Copy again")
        #expect(RecoveryDocument.compactTitle(for: "Copied") == "Copied")
        let document = RecoveryDocument(payload: "Fictional")
        #expect(document.copyTitle == "Copy to clipboard" && document.compactCopyTitle == "Copy words")
        let pasteboard = NSPasteboard(name: .init("tokens-recovery-compact-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        #expect(document.copyAll(to: pasteboard))
        #expect(document.compactCopyTitle == "Copied")
    }

    /// Width the copy button needs to show `title` whole, in the pop-up's own button style.
    @MainActor private static func copyButtonWidthNeeded(for title: String) -> CGFloat {
        let host = NSHostingView(rootView: Button(action: {}) { RecoveryCopyLabel(title: title) }
            .buttonStyle(TokensPrimaryButtonStyle(size: .large)))
        return host.fittingSize.width
    }

    /// The pop-up's content in an offscreen window that the caller keeps until it has rendered.
    @MainActor private static func laidOut(size: NSSize, message: String) -> NSWindow {
        let content = RecoveryContent(text: "Fictional words that may or may not have landed.", message: message)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame.size = size
        content.layoutSubtreeIfNeeded()
        return window
    }

    /// Lines of text Vision reads from the rendered view (on this Mac, no network). The view is
    /// rendered on main; the OCR runs off main, because Vision's synchronous perform on main
    /// deadlocked full parallel runs while other suites' defaults notifications waited for main.
    @MainActor private static func recognizedText(in view: NSView) async throws -> [String] {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    @Test @MainActor func recoveryWindowRendersLongTextAtMinimumAndDefaultSizes() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_RECOVERY_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, size) in [("default", RecoveryWindowController.defaultSize), ("minimum", RecoveryWindowController.minimumSize)] {
            let content = RecoveryContent(text: String(repeating: "Your fictional long prompt remains here. 👩🏽‍💻 中文\n", count: 100), message: "Paste sent · not confirmed · Copy latest")
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = content
            content.frame.size = size
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("recovery-\(name).png"))
            #expect(content.textView?.isSelectable == true)
        }
    }
}
