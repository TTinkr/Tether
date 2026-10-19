


//
import AppKit
import ApplicationServices
import Darwin
import TokensCore


// InputDestinationStamp — front app and front window, stamped at the key edge


/// Cheap foreground stamp taken at the physical key edge, without AX traversal.
struct InputDestinationStamp: Equatable {
    let pid: pid_t?
    let window: UInt32?
    /*
    pid is the front app. window is the window server number of that app's first
    on-screen window at the normal window layer (layer 0) in the list, which is
    ordered front to back, or of its floating panel when it has no such window
    (frontWindow). Either may be nil; callers treat nil as "not current".
    */
    static func current() -> Self {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self(pid: pid, window: frontWindow(in: windows, pid: pid))
    }

    /*
    The app's first normal-layer window, as always. Only when the app has none on screen, its
    first visible floating window below the menu-bar status items: a launcher, a quick-entry
    panel or a companion window with the main window closed. Before, such an app had no window
    here, so every stop in it was held as "Paste unavailable" though focus never moved. An app
    with a normal window still uses that window, so a palette or inspector floating over it
    never stands in for it, and status items, menus and other apps' windows never count (build 81).
    */
    static func frontWindow(in windows: [[String: Any]], pid: pid_t?) -> UInt32? {
        guard let pid else { return nil }
        let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        func layer(_ info: [String: Any]) -> Int? { (info[kCGWindowLayer as String] as? NSNumber)?.intValue }
        func number(_ info: [String: Any]) -> UInt32? { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        if let normal = own.first(where: { layer($0) == 0 }) { return number(normal) }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let floating = own.first { info in
            guard let level = layer(info), level > 0, level < statusLevel,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width > 0, bounds.height > 0 else { return false }
            return true
        }
        return floating.flatMap(number)
    }
}


// CapturedTarget — the app, window, text field, caret and text the words are meant for


/*
Taken at the stop gesture. Delivery compares the live screen against these fields and
refuses to paste if the window, field, caret or text has moved on (TargetDelivery has the
narrow exceptions for terminals and for Codex).
*/
struct CapturedTarget: @unchecked Sendable {
    var id: UUID
    var application: NSRunningApplication
    var pid: pid_t
    // The focused text field (Accessibility element); nil when none could be found.
    var element: AXUIElement?
    var window: AXUIElement?
    // Visible frame of the screen that holds the centre of the target window.
    var screenFrame: NSRect?
    // Caret or selection in the field, and the field's whole text, as they were at capture.
    var selection: CFRange?
    var valueBefore: String?
    // Set only for a pointer target: where the mouse was, and the caret position under it.
    var pointerPosition: CGPoint? = nil
    var pointerRange: CFRange?    = nil
    // How many windows the app had; used to check Codex when it shows no focused field.
    var windowCount: Int? = nil
    // A web rich-text editor at capture (TargetDelivery.isRichComposer); scopes Chromium readback rules.
    var richComposer = false
}


// DeliveryOutcome — verified, posted but unconfirmed, or failed with a reason code


/*
verified:  the field now holds exactly the expected text with the caret right after it.
delivered: Command-V was posted but landing could not be confirmed. Never retry.
failed:    a short reason code. Codes starting "partial_" mean some pieces did land.
*/
enum DeliveryOutcome: Equatable {
    case verified
    case delivered
    /// Paste posted, but the readable field showed no insertion before the deadline. Never retry.
    case notObserved
    case failed(String)
}


// TargetTracker — captures the target at the stop edge; none when Tokens is in front


final class TargetTracker {

//
// :)
//
//
    // Remembers the last ordinary app (not this one) that came to the front.
    private var lastExternalApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.remember(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    // The target is always the app in front right now, never a remembered one.
    func capture() -> CapturedTarget? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let fromTTT   = Self.isTTT(frontmost)
        /*
        A stop from our own menu has no current editor. Never guess by
        activating a stale remembered application; retain/copy the transcript.
        */
        guard !fromTTT, let application = frontmost else {
            Diagnostics.event("capture_target_unavailable reason=own_app_frontmost")
            return nil
        }
        guard !DeliveryTargetPolicy.isProtectedSystemSurface(bundleIdentifier: application.bundleIdentifier) else {
            Diagnostics.event("capture_target_unavailable reason=system_surface")
            return nil
        }
        let captured = TargetDelivery.capture(application: application)
        Diagnostics.event("capture_target bundle=\(application.bundleIdentifier ?? "unknown") restored=\(fromTTT) element=\(captured?.element != nil) range=\(captured?.selection != nil)")
        return captured
    }

    /// Snapshot at the stop gesture, before recognition drains or the mouse moves.
    func captureAtPointer() -> CapturedTarget? {
        TargetDelivery.captureAtPointer()
    }

    private func remember(_ application: NSRunningApplication?) {
        guard let application, !Self.isTTT(application), !application.isTerminated,
              application.activationPolicy == .regular else { return }
        lastExternalApplication = application
    }

    // True for this process itself and for its other channels (see DeliveryTargetPolicy).
    private static func isTTT(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        /*
        The tested policy includes both current channels and old companions;
        a visible rename must never turn our other window into a paste target.
        */
        return DeliveryTargetPolicy.isOwnApplication(
            processID: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }
}

