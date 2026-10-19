import AppKit
import ApplicationServices
import Testing
@testable import Tokens

struct DestinationCaretSafetyTests {
    @Test func missingSelectionAndSelectedTextNeverInventAPosition() {
        var queries = 0
        for selection in [nil, CFRange(location: -1, length: 0), CFRange(location: 4, length: 3)] {
            let result = DestinationPreview.caret(selection: selection) { _ in
                queries += 1
                return CGRect(x: 200, y: 100, width: 0, height: 18)
            }
            #expect(result == nil)
        }
        #expect(queries == 0)
    }

    @Test func missingCaretBoundsNeverAskForPreviousCharacterOrFieldCorner() {
        var ranges: [CFRange] = []
        let result = DestinationPreview.caret(selection: CFRange(location: 42, length: 0)) { range in
            ranges.append(range)
            return nil
        }
        #expect(result == nil)
        #expect(ranges.count == 1)
        #expect(ranges[0].location == 42 && ranges[0].length == 0)
    }

    @Test func caretSupportsNegativeDisplaysAndOriginButRejectsFieldSizedOrInvalidRectangles() {
        for rect in [CGRect(x: -900, y: -300, width: 0, height: 18),
                     CGRect(x: 0, y: 0, width: 2, height: 18)] {
            #expect(DestinationPreview.validCaret(rect))
        }
        for rect in [CGRect.zero, CGRect.null, CGRect.infinite,
                     CGRect(x: 10, y: 20, width: 400, height: 200),
                     CGRect(x: 10, y: 20, width: -2, height: 18),
                     CGRect(x: CGFloat.nan, y: 20, width: 0, height: 18),
                     CGRect(x: 10, y: 20, width: 0, height: CGFloat.infinity)] {
            #expect(!DestinationPreview.validCaret(rect))
        }
    }

    @Test func fieldCuesRequireFiniteBoundsAroundTheVerifiedCaret() {
        let caret = CGRect(x: -900, y: 20, width: 0, height: 18)
        let field = CGRect(x: -920, y: 10, width: 300, height: 100)
        #expect(DestinationPreview.validatedFieldFrame(field, containing: caret) == field)
        for invalid in [CGRect.zero, CGRect.null, CGRect.infinite,
                        CGRect(x: 100, y: 20, width: 300, height: 100),
                        CGRect(x: CGFloat.nan, y: 0, width: 300, height: 100)] {
            #expect(DestinationPreview.validatedFieldFrame(invalid, containing: caret) == nil)
        }
        #expect(DestinationPreview.validatedFieldFrame(field, containing: .zero) == nil)
    }

    /*
    Chromium/Electron composers (the Claude desktop app) often give no caret bounds. The marker then
    falls back to the verified text box's own frame, clipped to its window.
    */
    @Test func markerShowsForACaretOrForAVerifiedBoxWithoutOne() {
        #expect(!DestinationPreview.showsMarker(.init(label: "Claude · text area", anchor: nil)))
        #expect(DestinationPreview.showsMarker(.init(label: "Claude · text area", anchor: nil,
                                                     field: CGRect(x: 300, y: 700, width: 640, height: 72))))
        #expect(DestinationPreview.showsMarker(.init(label: "Notes · text area",
                                                     anchor: CGRect(x: 10, y: 10, width: 0, height: 18))))
    }

    @Test func caretlessBoxIsClippedToItsWindowAndRejectsJunk() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let box = CGRect(x: 140, y: 600, width: 700, height: 160)   // runs past the window bottom
        #expect(DestinationPreview.clippedBoxFrame(box, window: window) == CGRect(x: 140, y: 600, width: 700, height: 100))
        #expect(DestinationPreview.clippedBoxFrame(box, window: nil) == box)
        #expect(DestinationPreview.clippedBoxFrame(CGRect(x: 2000, y: 0, width: 300, height: 60), window: window) == nil)
        for junk in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: CGFloat.nan, y: 0, width: 300, height: 60),
                     CGRect(x: 10, y: 10, width: 0, height: 60)] {
            #expect(DestinationPreview.clippedBoxFrame(junk, window: window) == nil)
        }
    }

    @Test func knownTerminalApplicationsAreRejectedBeforeAccessibilityLookup() {
        for identifier in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            #expect(DestinationPreview.isTerminal(identifier))
            let result = DestinationPreview.queue.sync {
                DestinationPreview.reading(pid: -1, name: "Terminal fixture", bundleIdentifier: identifier)
            }
            #expect(result.anchor == nil)
        }
        #expect(!DestinationPreview.isTerminal("com.apple.Safari"))
    }

    @Test func slowOrWrongApplicationRepliesNeverDisplayEvenWithoutAnAXNotification() {
        #expect(DestinationPreview.fresh(requestedAt: 10, now: 10.1, revision: 2, currentRevision: 2, sameApplication: true))
        #expect(!DestinationPreview.fresh(requestedAt: 10, now: 10.5, revision: 2, currentRevision: 2, sameApplication: true))
        #expect(!DestinationPreview.fresh(requestedAt: 10, now: 10.1, revision: 2, currentRevision: 2, sameApplication: false))
        #expect(!DestinationPreview.fresh(requestedAt: 10, now: 9, revision: 2, currentRevision: 2, sameApplication: true))
    }
}

@Suite(.serialized) @MainActor struct DestinationPreviewLifecycleTests {
    @Test func applicationSpaceAndDisplayChangesInvalidateExistingAndPendingGeometry() {
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        let monitor = DestinationPreviewInvalidation(workspace: workspace, application: application)
        var hides = 0
        monitor.start { _ in hides += 1 }
        defer { monitor.stop() }
        for (center, name) in [
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (application, NSApplication.didChangeScreenParametersNotification)
        ] {
            let stale = monitor.revision
            center.post(name: name, object: nil)
            #expect(!DestinationPreview.fresh(requestedAt: 10, now: 10.1,
                revision: stale, currentRevision: monitor.revision, sameApplication: true))
        }
        #expect(hides == 4)
    }

    /// Build 83: typing in the verified box is soft (the box stays); everything else is hard.
    @Test func onlyEditsInsideTheBoxAreSoft() {
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXLayoutChangedNotification] {
            #expect(DestinationPreviewInvalidation.isSoft(name))
        }
        for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                     kAXUIElementDestroyedNotification] {
            #expect(!DestinationPreviewInvalidation.isSoft(name))
        }
        let monitor = DestinationPreviewInvalidation(workspace: NotificationCenter(), application: NotificationCenter())
        var kinds: [Bool] = []
        monitor.start { kinds.append($0) }
        defer { monitor.stop() }
        monitor.invalidate(soft: true)
        monitor.invalidate()
        #expect(kinds == [true, false])
    }

    @Test func focusAndWindowCallbacksInvalidateSamePIDResultsAndCannotResurrectAfterStop() {
        let monitor = DestinationPreviewInvalidation(workspace: NotificationCenter(), application: NotificationCenter())
        var hides = 0
        monitor.start { _ in hides += 1 }
        let beforeFocus = monitor.revision
        monitor.invalidate() // Same callback entry used by focused element/window/selection/move notifications.
        #expect(hides == 1)
        #expect(!DestinationPreview.fresh(requestedAt: 10, now: 10.1,
            revision: beforeFocus, currentRevision: monitor.revision, sameApplication: true))
        let oldTalk = monitor.revision
        monitor.stop()
        monitor.invalidate() // A queued AX callback from the retired observer does nothing.
        #expect(hides == 1)
        monitor.start { _ in hides += 1 }
        #expect(!DestinationPreview.fresh(requestedAt: 10, now: 10.1,
            revision: oldTalk, currentRevision: monitor.revision, sameApplication: true))
        monitor.stop()
    }
}


struct DestinationObservationReadinessTests {
    @Test func everyRequiredFocusAndGeometrySubscriptionMustSucceed() {
        let required = 10 // Both app focus notifications plus window and field invalidation.
        let accepted = [AXError](repeating: .success, count: required)
        #expect(DestinationObservationReadiness.ready(results: accepted, requiredCount: required))
        #expect(DestinationObservationReadiness.ready(
            results: [.notificationAlreadyRegistered] + accepted.dropFirst(), requiredCount: required))
        for index in 0..<required {
            for failure in [AXError.notificationUnsupported, .cannotComplete, .invalidUIElement] {
                var failed = accepted
                failed[index] = failure
                #expect(!DestinationObservationReadiness.ready(results: failed, requiredCount: required))
            }
        }
    }

    /// Build 81: a busy app or spent budget is tried again; only an unsupported notification sticks.
    @Test func onlyUnsupportedNotificationsAreCachedAsNotReady() {
        let required = 10
        let accepted = [AXError](repeating: .success, count: required)
        #expect(!DestinationObservationReadiness.retryable(results: accepted, requiredCount: required))
        #expect(DestinationObservationReadiness.retryable(results: [.cannotComplete] + accepted.dropFirst(), requiredCount: required))
        #expect(DestinationObservationReadiness.retryable(results: [.success, .success], requiredCount: required))
        #expect(!DestinationObservationReadiness.retryable(results: [.notificationUnsupported] + accepted.dropFirst(),
                                                           requiredCount: required))
    }

    @Test func passingMissesKeepTheBoxAndDefinitiveOnesDoNot() {
        for passing in ["slow_read", "budget", "focus_moved", "selection_moved", "observation_unready", "warming"] {
            #expect(DestinationPreview.isPassing(passing))
        }
        for definitive in ["not_text_box", "secure", "no_field", "no_window", "terminal", "no_box"] {
            #expect(!DestinationPreview.isPassing(definitive))
        }
    }

    @Test func deadlineExpiredBeforeAllRegistrationsCannotAdvertiseReadiness() {
        #expect(!DestinationObservationReadiness.ready(results: [.success], requiredCount: 2))
        #expect(!DestinationObservationReadiness.ready(results: [], requiredCount: 2))
        #expect(!DestinationObservationReadiness.ready(results: [], requiredCount: 0))
    }
}
