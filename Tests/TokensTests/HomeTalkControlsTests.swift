
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tokens

private func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

/// The text of one function, from its signature to the first closing brace at its own indent.
private func body(of signature: String, in text: String) throws -> String {
    let start = try #require(text.range(of: signature))
    let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
    return String(text[start.lowerBound..<end.upperBound])
}

/// Each needle appears, in this order.
private func inOrder(_ needles: [String], in text: String) -> Bool {
    var from = text.startIndex
    for needle in needles {
        guard let found = text.range(of: needle, range: from..<text.endIndex) else { return false }
        from = found.upperBound
    }
    return true
}

private let everyPhase: [TalkPhase] = [.idle, .capturing, .finalizing, .delivered, .failed]

/// A journal folder that cannot be written: every save fails, reads still work (failure injection).
private final class UnwritableFolder: FileManager {
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@Suite struct HomeTalkControlsTests {
    @Test func homeLinksFollowThePhase() {
        #expect(TokensHomeLiveControls.shown(phase: .capturing, audioConfirmed: true, heldByKey: false)
                == TokensHomeLiveControls(stop: true, discard: true))
        // Before the first audio: Discard only.
        #expect(TokensHomeLiveControls.shown(phase: .capturing, audioConfirmed: false, heldByKey: false)
                == TokensHomeLiveControls(stop: false, discard: true))
        // The key holds the talk: any click is already the chord discard.
        for audio in [true, false] {
            #expect(TokensHomeLiveControls.shown(phase: .capturing, audioConfirmed: audio, heldByKey: true) == .none)
        }
        for phase in everyPhase where phase != .capturing {
            for audio in [true, false] {
                for held in [true, false] {
                    #expect(TokensHomeLiveControls.shown(phase: phase, audioConfirmed: audio, heldByKey: held) == .none)
                }
            }
        }
    }

    @Test func heldKeyTalkRule() {
        let session = UUID(), old = UUID()
        // The key that began this talk is still down (tap or hold mode alike): a click is a chord.
        #expect(TalkModel.isHeldKeyTalk(phase: .capturing, keyBeganSession: session, sessionID: session, startingPressHeld: true))
        // Released (a tap talk after its tap): the links may show.
        #expect(!TalkModel.isHeldKeyTalk(phase: .capturing, keyBeganSession: session, sessionID: session, startingPressHeld: false))
        // A menu-started talk, an older key talk, no talk, or finishing.
        #expect(!TalkModel.isHeldKeyTalk(phase: .capturing, keyBeganSession: nil, sessionID: session, startingPressHeld: true))
        #expect(!TalkModel.isHeldKeyTalk(phase: .capturing, keyBeganSession: old, sessionID: session, startingPressHeld: true))
        #expect(!TalkModel.isHeldKeyTalk(phase: .capturing, keyBeganSession: nil, sessionID: nil, startingPressHeld: true))
        #expect(!TalkModel.isHeldKeyTalk(phase: .finalizing, keyBeganSession: session, sessionID: session, startingPressHeld: true))
    }

    /// The monitor's view of "the starting press is still down" matches its chord rule exactly.
    @Test @MainActor func startingPressIsHeldFollowsTheKey() async {
        let monitor = GlobalKeyMonitor()
        #expect(!monitor.startingPressIsHeld)
        #expect(monitor.injectQAEdge(down: true))          // a press that begins a talk (not a stop edge)
        #expect(monitor.startingPressIsHeld)
        #expect(monitor.injectQAEdge(down: false))         // the tap is released
        #expect(!monitor.startingPressIsHeld)
        monitor.isStopEdge = { _ in true }                  // a press that stops the talk is never "starting"
        #expect(monitor.injectQAEdge(down: true))
        #expect(!monitor.startingPressIsHeld)
        #expect(monitor.injectQAEdge(down: false))
        try? await Task.sleep(nanoseconds: 50_000_000)
        monitor.finishReturnReservation()
        let source = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Tokens/Keyboard/GlobalKeyMonitor.swift"), encoding: .utf8)
        #expect(source?.contains("var startingPressIsHeld: Bool { held && pressStartedTalk && !chordReported }") == true)
        #expect(source?.contains("guard held, pressStartedTalk, !chordReported else { return }") == true)
        // The release redraws Home, even when no audio is arriving to redraw it.
        let shortcuts = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Tokens/Talk/TalkModel+Shortcuts.swift"), encoding: .utf8)
        #expect(shortcuts.map { inOrder(["func routeRightOption(pressed: Bool) {",
            "if !pressed, phase == .capturing, sessionID != nil, keyBeganSession == sessionID { objectWillChange.send() }",
            "let sessionMode"], in: $0) } == true)
    }

    @Test func finishKeepsWordsOnlyWithNoTargetPinned() {
        var target = StopTarget<Int>()
        #expect(!TalkModel.finishKeepsWords(phase: .finalizing, stopTarget: target))
        target.capture { nil }
        #expect(TalkModel.finishKeepsWords(phase: .finalizing, stopTarget: target))
        #expect(!TalkModel.finishKeepsWords(phase: .capturing, stopTarget: target))
        // StopTarget keeps its first answer: a later capture cannot add a target.
        target.capture { 2 }
        #expect(target.value == nil)
        #expect(TalkModel.finishKeepsWords(phase: .finalizing, stopTarget: target))
        var pasting = StopTarget<Int>()
        pasting.capture { 1 }
        #expect(!TalkModel.finishKeepsWords(phase: .finalizing, stopTarget: pasting))
    }

    @Test func finishingCaptionSaysWhereTheWordsGo() {
        let key = "Right Option"
        let lines = [
            TokensHomeLiveCard.stopLine(phase: .finalizing, mode: .tap, keyName: key, keepsInApp: true),
            TokensHomeLiveCard.stopLine(phase: .finalizing, mode: .tap, keyName: key, keepsInApp: false),
            TokensHomeLiveCard.stopLine(phase: .capturing, mode: .tap, keyName: key, keepsInApp: false),
            TokensHomeLiveCard.stopLine(phase: .capturing, mode: .hold, keyName: key, keepsInApp: false),
        ]
        #expect(lines == ["Your words will be saved to History.", "Your words will paste when ready.",
                          "Press Right Option to stop.", "Release Right Option to stop."])
        #expect(lines.allSatisfy { !$0.lowercased().contains("dictat") })
    }

    @Test func homeStopPinsNoTargetAndSendsNoReturn() throws {
        let stop = try body(of: "func stopTalkFromHome() {", in: source("Sources/Tokens/Talk/TalkModel+Controls.swift"))
        #expect(inOrder([
            "guard !bubbleInteractivePreview, phase == .capturing, audioIsConfirmed, let sessionID else { return }",
            "stopTarget.capture {",
            "capture_target_unavailable reason=home_stop session=",
            "return nil",
            "guard stopTarget.value == nil else { return }",
            "finish(sendReturn: false)",
        ], in: stop))
        for forbidden in ["targets.capture", "captureAtPointer", "captureStopTarget()", "finishAtSpeedOfSound",
                          "pressToTalkEnd", "toggle()", "finishBubbleCapture", "NSApp.terminate", "delivery_held"] {
            #expect(!stop.contains(forbidden), "stopTalkFromHome must not call \(forbidden)")
        }
        // An explicit false wins over Auto-send: a Home Stop never sends Return.
        #expect(TokensPrompt.requestsReturn(product: "Tokens", explicit: false, autoSendAfterPasting: true) == false)
    }

    @Test func homeDiscardNeverDeliversOrSaves() throws {
        let controls = try source("Sources/Tokens/Talk/TalkModel+Controls.swift")
        let discard = try body(of: "func discardTalkFromHome() {", in: controls)
        #expect(discard.contains("func discardTalkFromHome() {\n        guard !bubbleInteractivePreview, phase == .capturing, let sessionID else { return }"))
        #expect(inOrder(["deferredTalkPress.cancel()", "capture_discarded reason=home session=", "discardRunningCapture()"], in: discard))
        for forbidden in ["finish(", "complete(", "deliver(", "recordPromptHistory", "retainForRecovery",
                          "pressToTalkBegin", "discardBubbleCapture", "NSApp.terminate"] {
            #expect(!discard.contains(forbidden), "discardTalkFromHome must not call \(forbidden)")
        }
        let running = try body(of: "private func discardRunningCapture() {", in: controls)
        #expect(inOrder(["resolveTranscriptRecovery(", "hideSurface()", "resetSession()", "audio.discardCapture()"], in: running))
    }

    /// a discard the journal could not record is said on Home, never silent.
    @Test func anUnrecordedDiscardIsShownOnHome() throws {
        let talk = UUID()
        #expect(TalkModel.unresolvedDiscardLine(session: talk, resolved: true, journalText: "words") == nil)
        #expect(TalkModel.unresolvedDiscardLine(session: talk, resolved: false, journalText: nil) == nil)
        #expect(TalkModel.unresolvedDiscardLine(session: talk, resolved: false, journalText: "") == nil)
        #expect(TalkModel.unresolvedDiscardLine(session: talk, resolved: false, journalText: "words")
                == RecoveredTalk(id: talk, text: "words"))
        #expect(TalkModel.discardKeptNote == "Not discarded · words kept")

        let controls = try source("Sources/Tokens/Talk/TalkModel+Controls.swift")
        let running = try body(of: "private func discardRunningCapture() {", in: controls)
        #expect(inOrder(["let resolved = discarded.map { resolveTranscriptRecovery($0) } ?? true", "hideSurface()",
                         "resetSession()", "audio.discardCapture()",
                         "if let discarded, !resolved { keepUnresolvedDiscard(discarded) }"], in: running))
        let keep = try body(of: "private func keepUnresolvedDiscard(_ session: UUID) {", in: controls)
        #expect(inOrder(["capture_discard_unresolved session=", "transcriptRecovery.copyCandidate(sessionID: session)",
                         "earlierRecovery     = line", "earlierRecoveryNote = Self.discardKeptNote"], in: keep))
        for forbidden in ["finish(", "deliver(", "recordPromptHistory", "explicitlyCopy", "NSPasteboard", "retainForRecovery"] {
            #expect(!keep.contains(forbidden), "an unrecorded discard must not \(forbidden)")
        }
    }

    /// Failure injection: the journal folder cannot be written when Discard resolves the talk.
    @Test func journalWriteFailureKeepsTheWordsAndForgetCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeDiscardJournal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let talk = UUID(), words = "Fictional violet lantern words."
        let journal = TranscriptRecoveryStore(directory: directory)
        #expect(try journal.checkpoint(sessionID: talk, text: words, state: .capturing))

        let failing = TranscriptRecoveryStore(directory: directory, fileManager: UnwritableFolder())
        #expect(throws: (any Error).self) { try failing.resolve(sessionID: talk) }
        // Still on disk, so it would come back after a relaunch: Home must show it now.
        let left = try failing.copyCandidate(sessionID: talk)
        #expect(left == words)
        #expect(try journal.recover().contains { $0.id == talk })
        #expect(TalkModel.unresolvedDiscardLine(session: talk, resolved: false, journalText: left)
                == RecoveredTalk(id: talk, text: words))

        // Forget on that line tries again; with a writable folder the words are gone for good.
        #expect(try journal.resolve(sessionID: talk))
        #expect(try journal.copyCandidate(sessionID: talk) == nil)
    }

    @Test func discardForgetsTheRememberedPress() {
        var press = DeferredTalkPress()
        _ = press.note(pressed: true, mode: .tap, at: 100)
        #expect(press.isArmed)
        press.cancel()
        #expect(!press.isArmed)
        #expect(press.take(now: 100.1, landing: .landed, keyDown: false) == .none)
    }

    @Test func liveLinksAreLabelledAndIdentified() throws {
        typealias Card = TokensHomeLiveCard
        #expect([Card.stopTitle, Card.stopHelp, Card.stopLabel, Card.stopHint] ==
                ["Stop", "Stop and keep the words in History", "Stop talk", "Keeps the words in History. Nothing is pasted."])
        #expect([Card.discardTitle, Card.discardHelp, Card.discardLabel, Card.discardHint] ==
                ["Discard", "End this talk without pasting or saving the words", "Discard talk",
                 "Ends this talk. The words are not pasted or saved."])
        for promise in [Card.stopTitle, Card.stopLabel, Card.stopHelp] { #expect(!promise.lowercased().contains("paste")) }
        let strings = [Card.stopTitle, Card.stopHelp, Card.stopLabel, Card.stopHint, Card.discardTitle,
                       Card.discardHelp, Card.discardLabel, Card.discardHint, Card.keptCaption]
        #expect(strings.allSatisfy { !$0.lowercased().contains("dictation") })

        let home = try source("Sources/Tokens/Features/Home/TokensHomeDashboard.swift")
        let cardStart = try #require(home.range(of: "struct TokensHomeLiveCard: View {"))
        // Build 83: the red band became TokensChalkWave (defined earlier); the card now ends the page section.
        let cardEnd = try #require(home.range(of: "struct TokensHomeEngine: Equatable {", range: cardStart.upperBound..<home.endIndex))
        let card = String(home[cardStart.lowerBound..<cardEnd.lowerBound])
        #expect(inOrder(["Spacer(minLength: 12)", "tokens.home.live-stop", "tokens.home.live-discard"], in: card))
        // Each link calls its own action: a swap would throw away words behind a "Stop" (review of 5e881ef).
        #expect(inOrder(["if controls.stop {", "Button(Self.stopTitle, action: stop)", "tokens.home.live-stop",
                         "if controls.discard {", "Button(Self.discardTitle, action: discard)", "tokens.home.live-discard"], in: card))
        #expect(card.components(separatedBy: "action: stop)").count == 2)
        #expect(card.components(separatedBy: "action: discard)").count == 2)
        // Build 83: the live block moved from homePage into homeColumn (Ready Home is one sentence).
        let page = try body(of: "func homePage(inner: CGFloat) -> some View {", in: home)
            + body(of: "private func homeColumn(", in: home)
        for wiring in ["let confirmed = fixture == nil ? model.audioIsConfirmed : detail != .arming",
                       "heldByKey: fixture == nil && model.talkIsHeldByKey)",
                       "controls: controls,",
                       "keepsInApp: fixture == nil ? model.finishKeepsWordsInApp : detail == .kept,",
                       "stop: fixture == nil ? { model.stopTalkFromHome() } : {},",
                       "discard: fixture == nil ? { model.discardTalkFromHome() } : {})"] {
            #expect(page.contains(wiring), "homePage must keep: \(wiring)")
        }
        #expect(card.contains("tokens.home.live-center"))
        #expect(card.contains(".accessibilityElement(children: .contain)"))
        for loud in [".keyboardShortcut(", "TokensPrimaryButtonStyle", "tone: .accent"] {
            #expect(!card.contains(loud), "the live links stay quiet: no \(loud)")
        }
        #expect(try source("Sources/Tokens/Features/Bubble/Bubble.swift").contains("label: \"Discard talk\""))
    }

    @Test func globalShortcutSemanticsUnchanged() throws {
        let app = try source("Sources/Tokens/App/TokensApp.swift")
        let menu = try #require(app.range(of: "CommandMenu(\"Talk\") {"))
        let menuEnd = try #require(app.range(of: "\n                }\n            }", range: menu.upperBound..<app.endIndex))
        let talkMenu = String(app[menu.lowerBound..<menuEnd.upperBound])
        #expect(talkMenu.components(separatedBy: "Button(").count == 2)
        #expect(inOrder(["Button(\"Start / Finish Talk\")", "appDelegate.model.toggle()",
                         ".keyboardShortcut(.space, modifiers: [.control, .option])"], in: talkMenu))
        #expect(try body(of: "func toggle() {", in: source("Sources/Tokens/Talk/TalkModel+Controls.swift"))
            .contains("case .finalizing:\n            break"))
        let monitor = try source("Sources/Tokens/Keyboard/GlobalKeyMonitor.swift")
        #expect(monitor.components(separatedBy: "keyCode == 53").count == 2)
        #expect(inOrder(["if let onHeldWordsKey {", "keyCode == 53"], in: monitor))
        let home = try source("Sources/Tokens/Features/Home/TokensHomeDashboard.swift")
        #expect(!home.contains(".cancelAction") && !home.contains(".defaultAction"))
        let keyboard = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Tokens/Keyboard")
        for file in try FileManager.default.contentsOfDirectory(atPath: keyboard.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: keyboard.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("stopTalkFromHome") && !text.contains("discardTalkFromHome"))
        }
        // The talk key's own truth table is untouched.
        typealias A = RightOptionMode.Action
        let expected: [RightOptionMode: [A]] = [
            // (pressed, capturing, finalizing) for pressed in [t,f], capturing in [t,f], finalizing in [t,f]
            .tap:  [.ignore, .finish, .ignore, .begin, .ignore, .ignore, .ignore, .ignore],
            .hold: [.ignore, .ignore, .ignore, .begin, .ignore, .finish, .ignore, .ignore],
        ]
        for mode in RightOptionMode.allCases {
            var got: [A] = []
            for pressed in [true, false] { for capturing in [true, false] { for finalizing in [true, false] {
                got.append(mode.action(pressed: pressed, capturing: capturing, finalizing: finalizing))
            } } }
            #expect(got == expected[mode])
        }
    }
}

/// Draws the live block offscreen: the links sit on the title rule and add no square.
private struct LiveCardHost: View {
    let controls: TokensHomeLiveControls
    let phase: TalkPhase
    let keepsInApp: Bool
    let width: CGFloat
    var body: some View {
        TokensHomeLiveCard(hint: TokensDictationHint(phase: phase, mode: .tap), keyName: "Right Option",
                           text: "Fictional green notebook.", samples: TokensHomePreview.liveSamples,
                           confirmed: true, controls: controls, keepsInApp: keepsInApp)
            .frame(width: width)
            .background(Color.white)
    }
}

@Suite(.serialized) @MainActor struct HomeTalkControlsRenderTests {
    @Test func liveLinksAddNoSquare() throws {
        _ = NSApplication.shared
        let states: [(String, TokensHomeLiveControls, TalkPhase, Bool)] = [
            ("both", TokensHomeLiveControls(stop: true, discard: true), .capturing, false),
            ("discard", TokensHomeLiveControls(stop: false, discard: true), .capturing, false),
            ("none", .none, .capturing, false),
            ("finishing-kept", .none, .finalizing, true),
        ]
        for width in [560, 320] as [CGFloat] {
            var capturingHeights: [CGFloat] = []
            var bitmaps: [String: Data] = [:]
            for (name, controls, phase, kept) in states {
                let host = NSHostingView(rootView: LiveCardHost(controls: controls, phase: phase, keepsInApp: kept, width: width))
                let fit = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host; host.frame = NSRect(origin: .zero, size: fit)
                host.layoutSubtreeIfNeeded()
                if phase == .capturing { capturingHeights.append(fit.height) }
                #expect(fit.height.truncatingRemainder(dividingBy: TokensUI.paperCell / 2) == 0,
                        "\(name) at \(width): \(fit.height) is off the 28 pt pitch")
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(data.count > 500)
                bitmaps[name] = try #require(bitmap.representation(using: .tiff, properties: [:]))
                if let out = ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"] {
                    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("home-live-\(name)-\(Int(width)).png"))
                }
            }
            #expect(Set(capturingHeights).count == 1, "the links changed the live block's height at \(width): \(capturingHeights)")
            // The links are really drawn: each state's pixels differ from the others.
            #expect(bitmaps["both"] != bitmaps["discard"] && bitmaps["discard"] != bitmaps["none"] && bitmaps["both"] != bitmaps["none"])
        }
    }
}
