import AppKit
import Foundation
import Testing
@testable import Tokens

/*
Build 81 recovery fixes found by the reliability sweep (C28-C32): the pop-up opens on the screen
the talk was meant for, a failure with no words leaves the screen, Tokens' own Settings window
counts as being in the app, an old microphone message never opens the next talk, and the pop-up
names a talk that stopped early or only partly pasted.
*/
@Suite(.serialized)
struct RecoveryReliabilityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
    }

    // C28: the pop-up's screen

    @Test func popUpOriginStaysOnTheGivenScreenEvenASecondDisplay() {
        let size = RecoveryWindowController.defaultSize
        // A secondary display to the right of a 1920-wide primary, menu bar on the primary only.
        let secondary = NSRect(x: 1920, y: 0, width: 2560, height: 1415)
        for cascade in 0..<8 {
            let origin = RecoveryWindowController.origin(size: size, visible: secondary, cascade: cascade)
            let frame = NSRect(origin: origin, size: size)
            #expect(secondary.contains(frame))
        }
        // Centred across and a little above the middle, as center() places a window.
        let first = RecoveryWindowController.origin(size: size, visible: secondary, cascade: 0)
        #expect(abs(first.x + size.width / 2 - secondary.midX) < 0.5)
        #expect(first.y + size.height / 2 > secondary.midY)
        // Each further pop-up steps down and right, so none hides another.
        let second = RecoveryWindowController.origin(size: size, visible: secondary, cascade: 1)
        #expect(second.x == first.x + 24 && second.y == first.y - 24)
        // A display below the primary (negative y) and one smaller than the pop-up keep its title bar on screen.
        let below = NSRect(x: 0, y: -1080, width: 1920, height: 1055)
        #expect(below.contains(NSRect(origin: RecoveryWindowController.origin(size: size, visible: below, cascade: 3), size: size)))
        let tiny = NSRect(x: 100, y: 100, width: 400, height: 300)
        let clamped = RecoveryWindowController.origin(size: size, visible: tiny, cascade: 0)
        #expect(clamped.x == tiny.minX)
        #expect(clamped.y + size.height == tiny.maxY)
    }

    @Test @MainActor func presentOpensOnTheScreenOfTheGivenFrame() throws {
        _ = NSApplication.shared
        let controller = RecoveryWindowController()
        for screen in NSScreen.screens {
            let panel = controller.present(id: UUID(), text: "Fictional words", message: "Paste unavailable · Copy latest",
                                           screenFrame: screen.visibleFrame, show: false)
            defer { panel.close() }
            #expect(screen.visibleFrame.contains(panel.frame))
        }
    }

    @Test func retainForRecoveryPassesTheDestinationOrBubbleScreen() throws {
        let recovery = try source("Talk/TalkModel+Recovery.swift")
        #expect(recovery.contains("screenFrame: target?.screenFrame ?? compactWindow()?.frame)"))
    }

    // C29: a failure with no words leaves the screen; the download line follows the download

    @Test func onlyAWordsFreeFailureLeavesByItself() {
        #expect(TalkModel.failureStatusMayLeave(phase: .failed, heldPayload: "", heldWordsVisible: false, keyAccessFailure: false))
        // Words to copy, held words on the bubble, a key-access error, or a newer talk keep the bubble.
        #expect(!TalkModel.failureStatusMayLeave(phase: .failed, heldPayload: "kept words", heldWordsVisible: false, keyAccessFailure: false))
        #expect(!TalkModel.failureStatusMayLeave(phase: .failed, heldPayload: "", heldWordsVisible: true, keyAccessFailure: false))
        #expect(!TalkModel.failureStatusMayLeave(phase: .failed, heldPayload: "", heldWordsVisible: false, keyAccessFailure: true))
        for phase in [TalkPhase.idle, .capturing, .finalizing, .delivered] {
            #expect(!TalkModel.failureStatusMayLeave(phase: phase, heldPayload: "", heldWordsVisible: false, keyAccessFailure: false))
        }
        #expect((3...8).contains(TalkModel.failureStatusSeconds))
    }

    @Test func failureStatusAndDownloadLineAreWired() throws {
        let recovery = try source("Talk/TalkModel+Recovery.swift")
        // Every words-free failure (mic start, startup deadline, capture error, update restart) arms the hide.
        #expect(recovery.contains("Diagnostics.event(\"access_failure session=\\(sessionID?.uuidString ?? \"none\")\")\n        scheduleFailureStatusHide()"))
        // Only the bubble goes; the line and phase stay for Home and the next press.
        #expect(recovery.contains("Diagnostics.event(\"failure_status_hidden session=\\(session?.uuidString ?? \"none\")\")\n            self.hideSurface()\n        }"))
        // The download line reads the new state, then clears when the model is ready.
        #expect(recovery.contains(".receive(on: DispatchQueue.main)"))
        #expect(recovery.contains("if !SpeechEngineChoice.waitingForOrukeet() {"))
        #expect(recovery.contains("self.hideSurface()\n                        self.resetSession()"))
        let capture = try source("Talk/TalkModel+Capture.swift")
        #expect(capture.contains("showOrukeetWaiting()"))
        #expect(!capture.contains("showAccessFailure(MainActor.assumeIsolated { OrukeetModelDownload.shared.waitingLine })"))
    }

    // C30: Tokens' own Settings window is in the app

    @Test func settingsWindowCountsAsInTheAppButPanelsNeverDo() throws {
        #expect(TalkModel.isTokensHomeWindow(identifier: "TTTStyleChooser"))
        // The SwiftUI Settings scene's window (Cmd-,), which shows the same Home.
        #expect(TalkModel.isTokensHomeWindow(identifier: "com_apple_SwiftUI_Settings_window"))
        for panel in [nil, "TTTCompactPanel", "TTTMachineGuess", "TTTPreviewBubbleHost", "TTTBubblePreviewStage",
                      "TTTVoiceLab", "tokens.recovery.\(UUID().uuidString)", ""] {
            #expect(!TalkModel.isTokensHomeWindow(identifier: panel))
        }
        // Both the held bubble and the no-pop-up delivery read the same check.
        #expect(try source("Talk/TalkModel+Panels.swift").contains("Self.isTokensHomeWindow(identifier: key.identifier?.rawValue)"))
        #expect(try source("Talk/TalkModel+Delivery.swift").contains("let inApp = publicTokens && tokensWindowIsFrontmost"))
    }

    // C31: an old microphone message never opens the next talk

    @Test func staleMicrophoneMessageDoesNotOpenTheNextTalk() {
        for stale in ["Orukeet recognition failed: worker exited", "Microphone unavailable. Tap to retry.",
                      "Microphone startup failed. Tap to retry.", "speech recognition unavailable"] {
            // The next talk is starting: its error was cleared, the old message is still there.
            #expect(TalkBubbleSheet.recoveryText(phase: .capturing, retainedFailureText: "",
                                                 permissionMessage: stale, captureError: nil) == nil)
            // This talk's own error still says so until the failure takes over.
            #expect(TalkBubbleSheet.recoveryText(phase: .capturing, retainedFailureText: "",
                                                 permissionMessage: stale, captureError: stale) == "microphone access unavailable")
        }
        #expect(TalkBubbleSheet.recoveryText(phase: .capturing, retainedFailureText: "",
                                             permissionMessage: "live · Orukeet", captureError: nil) == nil)
        #expect(TalkBubbleSheet.recoveryText(phase: .failed, retainedFailureText: "Microphone did not start.",
                                             permissionMessage: "stopped", captureError: nil) == "Microphone did not start.")
    }

    // C32: the pop-up names a talk that stopped early or only partly pasted

    @Test func popUpNamesATalkThatStoppedEarlyOrOnlyPartlyPasted() throws {
        let neutral = RecoveryPresentation(message: "Something new · Copy latest")
        #expect(neutral.headline == "Your words are ready to copy.")
        for message in ["Talk stopped early · Copy latest", "Transcript held · Copy latest"] {
            let early = RecoveryPresentation(message: message)
            #expect(early.headline == "Your talk stopped before pasting.")
            #expect(early.caution == "Some words may be missing.")
        }
        let retracted = RecoveryPresentation(message: "Final words unavailable · Copy captured words")
        #expect(retracted.headline == "We couldn’t finish pasting your talk.")
        #expect(retracted.caution == "Check the text box before pasting again.")
        // The capture-error path holds words under the talk wording.
        #expect(try source("Talk/TalkModel+Recovery.swift").contains("message: String = \"Talk stopped early · Copy latest\","))
    }

    /*
    Offscreen renders of the copy button in each state at the default and minimum sizes, paper
    and chalkboard, for a look (env-gated). Codex RC3 saw "Copy to clip…" at the minimum size;
    these show "Copy words", "Copy again" and "Copied" there instead (build 81).
    */
    @Test @MainActor func copyButtonRendersWholeInBothThemesAndSizes() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_RECOVERY_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        for theme in [TokensTheme.paper, .chalkboard] {
            TokensTheme.current = theme
            for (state, title) in [("unconfirmed", "Copy to clipboard"), ("retry", "Try copying again"), ("copied", "Copied")] {
                for (sizeName, size) in [("default", RecoveryWindowController.defaultSize),
                                         ("minimum", RecoveryWindowController.minimumSize)] {
                    let content = RecoveryContent(text: "Fictional words that may or may not have landed.",
                                                  message: "Paste sent · not confirmed · Copy latest")
                    content.document.copyTitle = title
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    defer { window.close() }
                    window.contentView = content
                    content.frame.size = size
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("recovery-copy-\(state)-\(sizeName)-\(theme.rawValue).png"))
                }
            }
        }
    }

    /// Offscreen renders of the new lines, paper and chalkboard, for a look (env-gated, like RecoveryWindowTests).
    @Test @MainActor func newLinesRenderInBothThemes() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_RECOVERY_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        let text = String(repeating: "Fictional words from a talk that stopped early. ", count: 12)
        for theme in [TokensTheme.paper, .chalkboard] {
            TokensTheme.current = theme
            for (name, message) in [("early", "Talk stopped early · Copy latest"),
                                    ("retracted", "Final words unavailable · Copy captured words")] {
                for (sizeName, size) in [("default", RecoveryWindowController.defaultSize),
                                         ("minimum", RecoveryWindowController.minimumSize)] {
                    let content = RecoveryContent(text: text, message: message)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                          backing: .buffered, defer: false)
                    window.contentView = content
                    content.frame.size = size
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("recovery-\(name)-\(sizeName)-\(theme.rawValue).png"))
                }
            }
        }
    }
}
