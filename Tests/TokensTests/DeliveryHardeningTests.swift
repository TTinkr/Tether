
import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Tokens

struct DeliveryHardeningTests {

    // C18 — bounded Accessibility waits.

    @Test func accessibilityWaitIsBoundedWellBelowTheSystemDefault() {
        // macOS waits about 6 s by default; the bound must stay short but not cut off a healthy big read.
        #expect(TargetDelivery.messagingTimeout >= 0.5 && TargetDelivery.messagingTimeout <= 1.0)
    }

    @Test func onlyAFullWaitThatCouldNotCompleteCountsAsAStuckApp() {
        let bound = Double(TargetDelivery.messagingTimeout)
        #expect(TargetDelivery.requestTimedOut(.cannotComplete, elapsed: bound))
        #expect(TargetDelivery.requestTimedOut(.cannotComplete, elapsed: bound * 0.95))
        // A quick "cannot complete" is an app without the attribute, not a stuck app: fallbacks still run.
        #expect(!TargetDelivery.requestTimedOut(.cannotComplete, elapsed: 0.01))
        // Other errors never stop the fallbacks, however long they took.
        #expect(!TargetDelivery.requestTimedOut(.noValue, elapsed: bound * 3))
        #expect(!TargetDelivery.requestTimedOut(.attributeUnsupported, elapsed: bound * 3))
        #expect(!TargetDelivery.requestTimedOut(.success, elapsed: bound * 3))
        // A request given less than the full bound (the end of a budget) times out at its own wait.
        #expect(TargetDelivery.requestTimedOut(.cannotComplete, elapsed: 0.2, bound: 0.2))
        #expect(!TargetDelivery.requestTimedOut(.cannotComplete, elapsed: 0.05, bound: 0.2))
    }

    // One budget per capture and per delivery, fallbacks included.

    /// A stand-in clock and app: each request "takes" its cost, or its whole wait when it costs more.
    /// (Waits travel as Float, as AXUIElementSetMessagingTimeout takes them, hence the 1e-6 slack below.)
    final class FakeApp {
        var clock = 0.0
        var asked: [String] = []
        var budget: AXWaitBudget!

        init(total: TimeInterval = 1.0) {
            budget = AXWaitBudget(total: total, now: { [unowned self] in self.clock })
        }

        /// One request charged to the budget; logged before the budget decides whether to ask.
        func request<T>(_ name: String, costs cost: TimeInterval, _ error: AXError = .success, _ value: T?) -> T? {
            asked.append(name)
            var answer: T?
            let result = budget.ask { wait in
                if cost >= Double(wait) { clock += Double(wait); return .cannotComplete }
                clock += cost
                answer = value
                return error
            }
            return result == .success ? answer : nil
        }

        /// A system-wide request: fixed wait, asked only while the whole wait fits.
        func systemRequest<T>(_ name: String, costs cost: TimeInterval, _ value: T?) -> T? {
            asked.append(name)
            var answer: T?
            let wait = AXWaitBudget.systemWideWait
            let result = budget.askWhole(wait) {
                if cost >= wait { clock += wait; return .cannotComplete }
                clock += cost
                answer = value
                return .success
            }
            return result == .success ? answer : nil
        }
    }

    @Test func eachRequestWaitsTheSmallerOfItsBoundAndWhatIsLeft() {
        let app = FakeApp(total: 1.5)
        var waits: [Float] = []
        _ = app.budget.ask { wait in waits.append(wait); app.clock += 0.8; return .success }
        _ = app.budget.ask { wait in waits.append(wait); app.clock += 0.1; return .success }
        #expect(waits.count == 2 && waits[0] == 1.0 && abs(waits[1] - 0.7) < 1e-6)
        #expect(!app.budget.stopped)
        #expect(abs(app.budget.remaining - 0.6) < 1e-9)
    }

    @Test func aTimedOutRequestStopsEveryLaterRequest() {
        let app = FakeApp()
        #expect(app.request("focus", costs: 0.01, AXError.success, 1) == 1)
        #expect(app.request("window", costs: 5.0, AXError.success, 2) == nil)
        #expect(app.budget.stop == .timedOut)
        var calledAfterStop = false
        #expect(app.budget.ask { _ in calledAfterStop = true; return .success } == .cannotComplete)
        #expect(app.budget.askWhole(0.01) { calledAfterStop = true; return .success } == .cannotComplete)
        #expect(!calledAfterStop)
        #expect(app.budget.requests == 2)
        #expect(app.clock <= 1.0 + 1e-6)
    }

    @Test func aSlowAppThatAlwaysAnswersStillStopsAtTheTotal() {
        // Every answer takes 0.3 s, under the one-second bound: without a total this never ends.
        let app = FakeApp()
        var answered = 0
        for index in 0..<50 where app.request("read\(index)", costs: 0.3, AXError.success, index) != nil { answered += 1 }
        #expect(app.budget.stopped)
        #expect(answered == 3)
        #expect(app.budget.requests == 4)
        #expect(app.clock <= app.budget.total + 1e-6)
    }

    @Test func aSystemWideRequestRunsOnlyWhileItsWholeWaitFits() {
        let app = FakeApp()
        _ = app.request("focus", costs: 1.0 - AXWaitBudget.systemWideWait / 2, AXError.noValue, 0)
        #expect(!app.budget.stopped)
        var asked = false
        #expect(app.budget.askWhole(AXWaitBudget.systemWideWait) { asked = true; return .success } == .cannotComplete)
        #expect(!asked)
        // Not fitting skips the request; it does not stop a budget that still has room.
        #expect(!app.budget.stopped)
    }

    @Test func budgetsAreSizedPerCaptureStepAndDelivery() {
        #expect(AXWaitBudget.forCapture().total == 1.0)
        #expect(AXWaitBudget.forStep().total == 1.0)
        #expect(AXWaitBudget.forDelivery(characters: 0).total == 3.0)
        #expect(AXWaitBudget.forDelivery(characters: 2_000).total == 5.0)
        #expect(AXWaitBudget.forDelivery(characters: 0).perRequest == Double(TargetDelivery.messagingTimeout))
    }

    // The focus lookup's fallbacks: Codex's exact sequence, then its neighbours.

    func lookup(_ app: FakeApp, appFocus: (TimeInterval, AXError), window: (TimeInterval, AXError),
                windowFocus: (TimeInterval, AXError) = (0.01, .noValue),
                system: TimeInterval = 0.01) -> (element: Int?, unresponsive: Bool) {
        TargetDelivery.focusedElementLookup(budget: app.budget,
            appFocus: { app.request("app", costs: appFocus.0, appFocus.1, 1) },
            focusedWindow: { app.request("window", costs: window.0, window.1, 10) },
            windowFocus: { _ in app.request("windowFocus", costs: windowFocus.0, windowFocus.1, 2) },
            systemFocus: { app.systemRequest("system", costs: system, 3) },
            sameApplication: { _ in true })
    }

    @Test func windowTimeoutAfterAQuickNoValueEndsTheLookupWithoutTheSystemWideTry() {
        // Codex: fast app noValue, then the window read times out at the bound.
        let app = FakeApp()
        let read = lookup(app, appFocus: (0.01, .noValue), window: (5.0, .success))
        #expect(app.asked == ["app", "window"])
        #expect(read.element == nil)
        #expect(read.unresponsive)
        #expect(app.budget.stop == .timedOut)
        #expect(app.clock <= 1.0 + 1e-6)
    }

    @Test func windowFocusTimeoutAlsoEndsTheLookup() {
        let app = FakeApp()
        let read = lookup(app, appFocus: (0.01, .noValue), window: (0.01, .success), windowFocus: (5.0, .success))
        #expect(app.asked == ["app", "window", "windowFocus"])
        #expect(read.element == nil && read.unresponsive)
    }

    @Test func firstFocusTimeoutStopsBeforeAnyFallback() {
        let app = FakeApp()
        let read = lookup(app, appFocus: (5.0, .success), window: (0.01, .success))
        #expect(app.asked == ["app"])
        #expect(read.element == nil && read.unresponsive)
    }

    @Test func quickMissingAnswersStillReachTheSystemWideTry() {
        // An app that merely lacks the attributes is not stuck: the last try still runs and is kept.
        let app = FakeApp()
        let read = lookup(app, appFocus: (0.01, .noValue), window: (0.01, .noValue))
        #expect(app.asked == ["app", "window", "system"])
        #expect(read.element == 3 && !read.unresponsive)
        // A system-wide answer from another app is never kept.
        let other = FakeApp()
        let foreign = TargetDelivery.focusedElementLookup(budget: other.budget,
            appFocus: { other.request("app", costs: 0.01, AXError.noValue, 1) },
            focusedWindow: { other.request("window", costs: 0.01, AXError.noValue, 10) },
            windowFocus: { _ in other.request("windowFocus", costs: 0.01, AXError.noValue, 2) },
            systemFocus: { other.systemRequest("system", costs: 0.01, 3) },
            sameApplication: { _ in false })
        #expect(foreign.element == nil && !foreign.unresponsive)
    }

    @Test func aStuckSystemWideTryWaitsOnlyItsShortWait() {
        let app = FakeApp()
        let read = lookup(app, appFocus: (0.01, .noValue), window: (0.01, .noValue), system: 5.0)
        #expect(read.element == nil && read.unresponsive)
        #expect(app.clock <= 0.02 + AXWaitBudget.systemWideWait + 1e-6)
    }

    // The capture: responsive at first, then stalled. Elements are stand-in numbers.

    func captureReads(_ app: FakeApp, costs: [String: TimeInterval] = [:]) -> TargetDelivery.CaptureReads<Int> {
        func cost(_ name: String) -> TimeInterval { costs[name] ?? 0.002 }
        return TargetDelivery.CaptureReads<Int>(
            focused: {
                let element: Int? = app.request("focus", costs: cost("focus"), AXError.success, 7)
                return (element, app.budget.stopped)
            },
            focusedWindow: { app.request("window", costs: cost("window"), AXError.success, 70) },
            evidence: { _ in
                FocusedEditorWarmup.Evidence(
                    role: app.request("role", costs: cost("role"), AXError.success, "AXTextArea"),
                    subrole: app.request("subrole", costs: cost("subrole"), AXError.success, "AXNone"),
                    hasSelection: app.request("selection", costs: cost("selection"), AXError.success, true) != nil)
            },
            enable: { app.request("enable", costs: cost("enable"), AXError.success, true) != nil },
            frontmost: { true },
            same: { $0 == $1 },
            secure: { _ in
                app.request("secure", costs: cost("secure"), AXError.success, "AXTextArea") == "AXSecureTextField"
                    || app.budget.stopped
            },
            editor: { _ in app.request("editor", costs: cost("editor"), AXError.success,
                                       EditorValueSnapshot(raw: "Hello")) },
            screenFrame: { _ in app.request("frame", costs: cost("frame"), AXError.success, NSRect(x: 0, y: 0, width: 10, height: 10)) },
            selection: { _ in app.request("caret", costs: cost("caret"), AXError.success, CFRange(location: 5, length: 0)) },
            windowCount: { app.request("count", costs: cost("count"), AXError.success, 1) },
            wait: {})
    }

    @Test func captureOfAResponsiveAppReadsEverything() throws {
        let app = FakeApp()
        let reading = try #require(TargetDelivery.readCapture(budget: app.budget, bundle: "test", captureReads(app)))
        #expect(reading.element == 7 && reading.window == 70 && reading.windowCount == 1)
        #expect(reading.editor?.text == "Hello" && reading.selection?.location == 5)
        #expect(!app.budget.stopped)
    }

    @Test func captureStopsWhenTheAppStallsRightAfterAnsweringFocus() {
        // Codex: the initial focus answers, then the window read stalls.
        let app = FakeApp()
        #expect(TargetDelivery.readCapture(budget: app.budget, bundle: "test", captureReads(app, costs: ["window": 5.0])) == nil)
        #expect(app.asked == ["focus", "window"])
        #expect(app.budget.stop == .timedOut)
        #expect(app.clock <= app.budget.total + 1e-6)
    }

    @Test func captureStopsWhenAWarmupOrSnapshotReadStalls() {
        for stalled in ["role", "secure", "editor", "caret"] {
            let app = FakeApp()
            #expect(TargetDelivery.readCapture(budget: app.budget, bundle: "test", captureReads(app, costs: [stalled: 5.0])) == nil)
            #expect(app.budget.stop == .timedOut)
            // Nothing after the stalled read is asked of the app.
            let after = Array(app.asked.drop(while: { $0 != stalled }).dropFirst())
            #expect(app.budget.requests == app.asked.count - after.count, "stalled at \(stalled): \(app.asked)")
            #expect(app.clock <= app.budget.total + 1e-6)
        }
    }

    @Test func captureOfASlowButAnsweringAppStopsAtItsTotal() {
        let slow = ["focus", "window", "role", "subrole", "selection", "secure", "editor", "frame", "caret", "count"]
        let app = FakeApp()
        let costs = Dictionary(uniqueKeysWithValues: slow.map { ($0, 0.3) })
        #expect(TargetDelivery.readCapture(budget: app.budget, bundle: "test", captureReads(app, costs: costs)) == nil)
        #expect(app.budget.requests <= 4)
        #expect(app.clock <= app.budget.total + 1e-6)
    }

    @Test func aStoppedBudgetMakesEveryHelperFailWithoutAskingTheApp() {
        // A real reference to this test process; nothing is ever sent to it because the budget has stopped.
        let app = FakeApp()
        _ = app.request("stall", costs: 5.0, AXError.success, 0)
        #expect(app.budget.stop == .timedOut)
        let element = TargetDelivery.applicationElement(ProcessInfo.processInfo.processIdentifier)
        AXWaitBudget.$current.withValue(app.budget) {
            #expect(TargetDelivery.value(in: element) == nil)
            #expect(TargetDelivery.editorValueSnapshot(in: element) == nil)
            #expect(TargetDelivery.selectedRange(in: element) == nil)
            #expect(TargetDelivery.copyElement(kAXFocusedUIElementAttribute as String, from: element) == nil)
            #expect(TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: element) == nil)
            #expect(TargetDelivery.windowCount(in: element) == nil)
            #expect(TargetDelivery.screenFrame(for: element) == nil)
            #expect(!TargetDelivery.isRichComposer(element, role: "AXTextArea"))
            #expect(!TargetDelivery.enableManualAccessibility(element))
            let read = TargetDelivery.focusedElementRead(in: element)
            #expect(read.element == nil && read.unresponsive)
            // An unanswered secure-field question is never taken as an ordinary field.
            #expect(TargetDelivery.isSecure(element))
        }
        #expect(app.budget.requests == 1)
    }

    @Test func nestedScopesShareTheOneBudgetInForce() {
        #expect(AXWaitBudget.current == nil)
        let outer = AXWaitBudget.forCapture()
        AXWaitBudget.$current.withValue(outer) {
            AXWaitBudget.within(AXWaitBudget.forStep()) { inner in
                #expect(inner === outer)
                #expect(AXWaitBudget.current === outer)
            }
        }
        // With none in force, a scope gets its own and leaves nothing behind.
        AXWaitBudget.within(AXWaitBudget.forStep()) { own in
            #expect(AXWaitBudget.current === own)
        }
        #expect(AXWaitBudget.current == nil)
    }

    // bed0492 review: the paste-target diagnostic asked under the delivery's budget, so one slow
    // answer could stop it and leave the readback unable to confirm a good paste.
    @Test func pasteTargetDiagnosticNeverChargesTheDeliveryBudget() {
        let outer = AXWaitBudget.forDelivery(characters: 10)
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        let target = CapturedTarget(id: UUID(), application: .current, pid: pid, element: app, window: app,
                                    screenFrame: nil, selection: nil, valueBefore: nil)
        let line = AXWaitBudget.$current.withValue(outer) { TargetDelivery.pasteTargetState(target) }
        #expect(outer.requests == 0)
        #expect(outer.spent == 0)
        #expect(!outer.stopped)
        #expect(AXWaitBudget.current == nil)
        #expect(line.contains("total_ms=150"))
    }

    @Test @MainActor func aDeliveryBudgetStaysInForceAcrossItsAwaits() async {
        let budget = AXWaitBudget.forDelivery(characters: 10)
        await AXWaitBudget.$current.withValue(budget) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
            #expect(AXWaitBudget.current === budget)
        }
        #expect(AXWaitBudget.current == nil)
        // Work queued on the main thread meanwhile (a new capture) never sees the delivery's budget.
        let seen: Bool = await withCheckedContinuation { continuation in
            Task {
                await AXWaitBudget.$current.withValue(budget) {
                    DispatchQueue.main.async { continuation.resume(returning: AXWaitBudget.current === budget) }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }
        #expect(!seen)
    }

    // C20 — clipboard-history apps skip Tokens' own paste writes.

    @Test func deliveryWriteCarriesTheWordsAndBothSkipMarkers() throws {
        let pasteboard = NSPasteboard(name: .init("tokens-delivery-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(DeliveryClipboard.write("lo wor", to: pasteboard))
        let types = try #require(pasteboard.types)
        #expect(types.contains(.string))
        #expect(types.contains(DeliveryClipboard.transientType))
        #expect(types.contains(DeliveryClipboard.autoGeneratedType))
        #expect(DeliveryClipboard.transientType.rawValue == "org.nspasteboard.TransientType")
        #expect(DeliveryClipboard.autoGeneratedType.rawValue == "org.nspasteboard.AutoGeneratedType")
        // The destination still pastes exactly these words.
        #expect(pasteboard.string(forType: .string) == "lo wor")
        #expect(pasteboard.data(forType: DeliveryClipboard.transientType)?.isEmpty == true)
        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    @Test func deliveryWriteKeepsUnicodeAndWhitespaceExactly() throws {
        let pasteboard = NSPasteboard(name: .init("tokens-delivery-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let piece = " \t👩🏽‍💻 e\u{301}\r\n  "
        pasteboard.clearContents()
        #expect(DeliveryClipboard.write(piece, to: pasteboard))
        #expect(pasteboard.string(forType: .string)?.utf8.elementsEqual(piece.utf8) == true)
    }

    // C21 — an unconfirmed paste that held back a send says so.

    @Test func unconfirmedStatusNamesAWithheldSend() {
        // Unchanged when no send was asked for.
        #expect(TalkModel.unconfirmedPasteMessage(sendWithheld: false) == "Paste sent · not confirmed · Copy latest")
        let unsent = TalkModel.unconfirmedPasteMessage(sendWithheld: true)
        #expect(unsent.hasPrefix("Not sent"))
        #expect(!unsent.lowercased().contains("dictation"))
        // The recovery pop-up explains it rather than falling back to the generic line.
        let presentation = RecoveryPresentation(message: unsent)
        #expect(presentation.headline == "Not sent. We couldn’t confirm your paste.")
        #expect(presentation.caution == "Check the text box before pasting again.")
        #expect(RecoveryPresentation(message: TalkModel.unconfirmedPasteMessage(sendWithheld: false)).headline
            == "We couldn’t confirm your paste.")
    }

    @Test func aWithheldSendIsStillNeverPressed() {
        // Auto-send or a reserved Return asks for a send; review-required talks never do.
        #expect(TokensAutoSendDelivery.returnRequested(autoSend: true, reservedReturn: false, requiresReview: false))
        #expect(TokensAutoSendDelivery.returnRequested(autoSend: false, reservedReturn: true, requiresReview: false))
        #expect(!TokensAutoSendDelivery.returnRequested(autoSend: true, reservedReturn: true, requiresReview: true))
        // The status names it, but Return still goes only after a confirmed paste.
        for outcome in [DeliveryOutcome.delivered, .notObserved] {
            var sends = 0
            #expect(!TokensAutoSendDelivery.submitIfVerified(outcome, requested: true, reservedReturn: true) {
                sends += 1
                return true
            })
            #expect(sends == 0)
        }
    }

    @Test @MainActor func recoveryWindowRendersTheNotSentHeadline() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_RECOVERY_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, size) in [("default", RecoveryWindowController.defaultSize), ("minimum", RecoveryWindowController.minimumSize)] {
            let content = RecoveryContent(text: "Fictional words that may or may not have landed.\n",
                                          message: TalkModel.unconfirmedPasteMessage(sendWithheld: true))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = content
            content.frame.size = size
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("recovery-not-sent-\(name).png"))
        }
    }

    // C23 — Claude's caret skips line breaks. one exact UTF-16 index,
    // never a space after a line break, and no space whenever the caret cannot be placed exactly.

    func claude(_ before: String, caret: Int, _ raw: String = "words", skips: Bool = true) -> String {
        TargetDelivery.preparedText(raw, valueBefore: before, selection: CFRange(location: caret, length: 0),
                                    caretSkipsLineBreaks: skips)
    }

    /*
    at an ambiguous Claude caret, text after the line breaks means a caret
    inside the draft (end of the line, as builds 78-80 read it: a space, never joined words); only
    line breaks after it means the end of the draft, a fresh line (no space).
    */
    @Test func ambiguousCaretsFollowWhatComesAfterTheLineBreaks() {
        #expect(claude("Hi\nthere", caret: 2) == " words")
        #expect(claude("Hi\n\nthere", caret: 2) == " words")
        #expect(claude("Hi\n", caret: 2) == "words")
        #expect(claude("Hi\n\n", caret: 2) == "words")
        #expect(TargetDelivery.lineBreakSkippingCaretIndex(before: "Hi\n\nthere", caret: 2) == nil)
        #expect(TargetDelivery.claudeSpacingIndex(before: "Hi\n\nthere", caret: 2) == 2)
        #expect(TargetDelivery.claudeSpacingIndex(before: "Hi\n\n", caret: 2) == nil)
        // Ordinary editors count the break, so caret 2 really is the end of "Hi" there.
        #expect(claude("Hi\n", caret: 2, skips: false) == " words")
        #expect(claude("Hi\nthere", caret: 2, skips: false) == " words")
    }

    @Test func anExactCaretKeepsTheOrdinarySpaceRule() {
        // Caret at the end of "I want to" (15 units that are not line breaks): exact, space needed.
        #expect(claude("Thanks\n\nI want to", caret: 15) == " words")
        #expect(TargetDelivery.lineBreakSkippingCaretIndex(before: "Thanks\n\nI want to", caret: 15) == 17)
        #expect(claude("a\nI", caret: 2) == " words")
        // Inside a word on a later line: the exact index, then the ordinary rule.
        #expect(TargetDelivery.lineBreakSkippingCaretIndex(before: "a\nb\ncd", caret: 3) == 5)
        #expect(claude("a\nb\ncd", caret: 4) == " words")
        // After an existing space or an opening bracket: no space, exactly as before.
        #expect(claude("x\nworld ", caret: 7) == "words")
        #expect(claude("a\n(", caret: 2) == "words")
        // Leading punctuation never gets a space.
        #expect(claude("a\nI", caret: 2, ". Done") == ". Done")
    }

    @Test func aSpaceOnlyWhereTheWordsWouldOtherwiseJoinALine() {
        // A space is added only at an exact caret after a non-break, or at an ambiguous caret with
        // more text after its line breaks (the end of that line, as 78-80); never at a draft's end.
        for before in ["Hi\n", "Hi\n\n", "Hi\nthere", "Hi\n\nthere", "a\nb\n", "\nHi"] {
            for caret in 0...(before.utf16.count) {
                let prepared = claude(before, caret: caret)
                guard prepared.hasPrefix(" ") else { continue }
                let index = TargetDelivery.claudeSpacingIndex(before: before, caret: caret)
                #expect(index != nil, "\(before.debugDescription) caret \(caret)")
                if let index {
                    #expect(index > 0 && Array(before.utf16)[index - 1] != 10)
                    #expect(Array(before.utf16)[index...].contains { $0 != 10 } || index == before.utf16.count)
                }
            }
        }
    }

    @Test func whenUnsureTheWordsGoInWithoutASpace() {
        // A caret past the text, a draft with "\r" (outside the measured model) and a selection.
        #expect(claude("a\nb", caret: 3) == "words")
        #expect(TargetDelivery.lineBreakSkippingCaretIndex(before: "a\nb", caret: 3) == nil)
        #expect(claude("ab\r\ncd", caret: 4) == "words")
        #expect(TargetDelivery.preparedText("words", valueBefore: "Hello\nthere", selection: CFRange(location: 5, length: 3),
                                            caretSkipsLineBreaks: true) == "words")
        // A caret that splits a surrogate pair is no caret position at all.
        #expect(TargetDelivery.preparedText("words", valueBefore: "a👍", selection: CFRange(location: 2, length: 0),
                                            caretSkipsLineBreaks: false) == "words")
        // Selections in ordinary editors keep the plain reading.
        #expect(TargetDelivery.preparedText("words", valueBefore: "Hello there", selection: CFRange(location: 5, length: 6),
                                            caretSkipsLineBreaks: false) == " words")
    }

    @Test func draftsWithoutLineBreaksAreUnchanged() {
        for skips in [true, false] {
            #expect(claude("Hello", caret: 5, skips: skips) == " words")
            #expect(claude("Hello ", caret: 6, skips: skips) == "words")
            #expect(claude("Hello", caret: 5, ". Done", skips: skips) == ". Done")
            #expect(claude("Hello", caret: 0, skips: skips) == "words")
        }
        // Emoji count as their UTF-16 units, the same units Claude's caret counts.
        #expect(TargetDelivery.lineBreakSkippingCaretIndex(before: "👍\nok", caret: 4) == 5)
        #expect(claude("👍\nok", caret: 4) == " words")
        // After the emoji, before a line break with more text below: the end of that line (as 78-80).
        #expect(claude("👍\nok", caret: 2) == " words")
    }

    @Test func spacingIndexIsExactOrTheLineEnd() {
        #expect(TargetDelivery.spacingIndex(before: "Hi\nthere", selection: CFRange(location: 2, length: 0), caretSkipsLineBreaks: true) == 2)
        #expect(TargetDelivery.spacingIndex(before: "Hi\n", selection: CFRange(location: 2, length: 0), caretSkipsLineBreaks: true) == nil)
        #expect(TargetDelivery.spacingIndex(before: "a\nb\ncd", selection: CFRange(location: 4, length: 0), caretSkipsLineBreaks: true) == 6)
        #expect(TargetDelivery.spacingIndex(before: "a\nb\ncd", selection: CFRange(location: 4, length: 0), caretSkipsLineBreaks: false) == 4)
        #expect(TargetDelivery.spacingIndex(before: "", selection: CFRange(location: 0, length: 0), caretSkipsLineBreaks: true) == 0)
        #expect(TargetDelivery.spacingIndex(before: "a\nb", selection: CFRange(location: 1, length: 2), caretSkipsLineBreaks: true) == nil)
    }

    /*
    Every physical caret behind one ambiguous reported offset, with the text Claude then holds and
    its readback. No row joins the words to the line above
    any more; the cost left is a leading space when the caret was really at the start of a later
    line inside the draft, which builds 78-80 also gave. A word right after the caret runs on
    ("wordsthere") in every editor: this rule adds no trailing space.
    */
    @Test func everyPhysicalCaretBehindAnAmbiguousOffset() {
        // (draft, reported caret, physical UTF-16 index, text Claude holds after the paste).
        let matrix: [(String, Int, Int, String)] = [
            ("Hi\nthere", 2, 2, "Hi words\nthere"),     // end of a line with a line after it
            ("Hi\nthere", 2, 3, "Hi\n wordsthere"),     // start of the next line (as 78-80)
            ("Hi\n\nthere", 2, 2, "Hi words\n\nthere"), // end of a line above a blank line
            ("Hi\n\nthere", 2, 3, "Hi\n words\nthere"), // the blank line itself (as 78-80)
            ("Hi\n", 2, 3, "Hi\nwords"),                // the fresh line after Shift-Return
            ("Hi\n", 2, 2, "Hiwords\n"),                // end of text above a trailing empty line
        ]
        for (before, caret, physical, after) in matrix {
            let text = claude(before, caret: caret)
            #expect((before as NSString).replacingCharacters(in: NSRange(location: physical, length: 0), with: text) == after,
                    "\(before.debugDescription) at \(physical)")
            #expect(PasteAcknowledgement.evaluate(before: before, selection: NSRange(location: caret, length: 0),
                inserted: text, after: after, caret: NSRange(location: caret + (text as NSString).length, length: 0),
                richComposer: true, caretSkipsLineBreaks: true) == .verified)
        }
    }

    // C14 — an app whose only window is a floating panel is still a destination.

    func window(_ number: UInt32, pid: pid_t, layer: Int, alpha: Double = 1,
                bounds: CGRect = CGRect(x: 10, y: 10, width: 600, height: 80)) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: number), kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary]
    }

    @Test func normalWindowStillWinsOverAFloatingPalette() {
        // Front to back: a palette floats above the app's normal window; the normal window is stamped.
        let list = [window(7, pid: 42, layer: 3), window(8, pid: 42, layer: 0), window(9, pid: 99, layer: 0)]
        #expect(InputDestinationStamp.frontWindow(in: list, pid: 42) == 8)
    }

    @Test func floatingPanelStandsInOnlyWhenThereIsNoNormalWindow() {
        let list = [window(5, pid: 99, layer: 0), window(7, pid: 42, layer: 3), window(6, pid: 42, layer: 8)]
        #expect(InputDestinationStamp.frontWindow(in: list, pid: 42) == 7)
        // Another app's windows never count.
        #expect(InputDestinationStamp.frontWindow(in: [window(5, pid: 99, layer: 3)], pid: 42) == nil)
        #expect(InputDestinationStamp.frontWindow(in: list, pid: nil) == nil)
    }

    @Test func statusItemsMenusAndInvisibleWindowsNeverCount() {
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let popUp = Int(CGWindowLevelForKey(.popUpMenuWindow))
        #expect(InputDestinationStamp.frontWindow(in: [window(1, pid: 42, layer: status)], pid: 42) == nil)
        #expect(InputDestinationStamp.frontWindow(in: [window(2, pid: 42, layer: popUp)], pid: 42) == nil)
        #expect(InputDestinationStamp.frontWindow(in: [window(3, pid: 42, layer: 3, alpha: 0)], pid: 42) == nil)
        #expect(InputDestinationStamp.frontWindow(in: [window(4, pid: 42, layer: 3, bounds: .zero)], pid: 42) == nil)
        #expect(InputDestinationStamp.frontWindow(in: [window(5, pid: 42, layer: -20)], pid: 42) == nil)
        // A visible panel behind those is still found.
        #expect(InputDestinationStamp.frontWindow(in: [window(1, pid: 42, layer: status),
            window(3, pid: 42, layer: 3, alpha: 0), window(6, pid: 42, layer: 3)], pid: 42) == 6)
    }
}
