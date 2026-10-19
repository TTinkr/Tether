
import AppKit
import ApplicationServices
import TokensCore

extension TalkModel {
    /// Standby feedback is read-only; delivery still acquires its own exact target at Stop.
    func setPersistentDestinationPreviewEnabled(_ enabled: Bool) {
        persistentDestinationPreviewEnabled = enabled
        syncDestinationPreview()
    }

    func setDestinationPreviewSuspended(_ suspended: Bool) {
        guard destinationPreviewSuspended != suspended else { return }
        destinationPreviewSuspended = suspended
        syncDestinationPreview()
    }

    var destinationPreviewAllowed: Bool {
        DestinationPreviewPolicy.runs(phase: phase, suspended: destinationPreviewSuspended)
    }

    func syncDestinationPreview() {
        if destinationPreviewAllowed {
            if destinationPreviewGeneration == nil { startDestinationPreview() }
        } else if destinationPreviewGeneration != nil { stopDestinationPreview() }
    }

    /*
    A box already verified stays put through a re-check (UX review's 2026-10-18 recording: typing
    into a verified box swapped its corners for the pointer ring on every keystroke, then back).
    Only a read that finds no box, another app in front, or missing access shows the ring.
    */
    func keepVerifiedBoxOrShowRing() {
        let mode = PasteMarker.shared.mode
        if mode == .field || mode == .caret { return }
        showDestinationCursorFallback()
    }

    func showDestinationCursorFallback() {
        if destinationPreviewAllowed, phase == .capturing, PasteCursorRingPreference.load(), !isSyntheticRun {
            PasteMarker.shared.showCursor()
        } else { PasteMarker.shared.hide() }
    }

    func startDestinationPreview() {
        stopDestinationPreview()
        guard !isSyntheticRun, destinationPreviewAllowed else { return }
        destinationPreviewGeneration = UUID()
        DestinationPreviewInvalidation.shared.start { [weak self] soft in
            guard let self, self.destinationPreviewGeneration != nil else { return }
            // Typing in the box (value, selection, layout) keeps it; focus, window, app, Space
            // or screen changes drop it at once (Codex review of c390905).
            if soft { self.keepVerifiedBoxOrShowRing() } else { self.showDestinationCursorFallback() }
            self.destinationLabel = "Focus changed"
            // Read the new geometry now instead of leaving the box gone until the next tick (build 81).
            self.scheduleDestinationRefresh(after: 0.1)
        }
        refreshDestinationPreview()
        let timer = Timer(timeInterval: DestinationPreviewPolicy.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.destinationPreviewAllowed else { self.stopDestinationPreview(); return }
            self.refreshDestinationPreview()
        }
        destinationPreviewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopDestinationPreview() {
        PasteMarker.shared.hide()
        PasteMarker.shared.resetDiagnostics()
        DestinationPreviewInvalidation.shared.stop()
        DestinationPreview.queue.async { DestinationAXObservation.shared.stop() }
        destinationPreviewTimer?.invalidate()
        destinationPreviewTimer = nil
        destinationPreviewGeneration = nil
        destinationPreviewInFlight = false
        destinationPreviewRefreshPending = false
        destinationPreviewRetries = 0
    }

    /*
    After an invalidation, a slow reply or a passing AX failure, ask for fresh geometry
    before the next regular tick. Several asks while one is pending make one read.
    */
    func scheduleDestinationRefresh(after delay: TimeInterval) {
        guard let generation = destinationPreviewGeneration, !destinationPreviewRefreshPending else { return }
        destinationPreviewRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.destinationPreviewGeneration == generation else { return }
            self.destinationPreviewRefreshPending = false
            guard self.destinationPreviewAllowed else { return }
            if self.destinationPreviewInFlight { self.scheduleDestinationRefresh(after: 0.1) } else { self.refreshDestinationPreview() }
        }
    }

    func refreshDestinationPreview() {
        guard destinationPreviewAllowed, let generation = destinationPreviewGeneration else { return }
        // Both cues off: nothing to read for. Either on: read, so the ring knows when a box is verified.
        guard PasteMarkerPreference.load() || PasteCursorRingPreference.load() else { PasteMarker.shared.hide(); return }
        guard !destinationPreviewInFlight else { return }
        guard AXIsProcessTrusted() else {
            destinationLabel = "Text access unavailable"; showDestinationCursorFallback(); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              !DeliveryTargetPolicy.isOwnApplication(processID: app.processIdentifier,
                 bundleIdentifier: app.bundleIdentifier, currentProcessID: ProcessInfo.processInfo.processIdentifier) else {
            destinationLabel = "Choose a text field"; showDestinationCursorFallback(); return
        }
        destinationPreviewInFlight = true
        let pid = app.processIdentifier
        let name = app.localizedName ?? "App"
        let bundleIdentifier = app.bundleIdentifier
        let revision = DestinationPreviewInvalidation.shared.revision
        let requestedAt = ProcessInfo.processInfo.systemUptime
        DestinationPreview.queue.async { [weak self] in
            let reading = DestinationPreview.reading(pid: pid, name: name, bundleIdentifier: bundleIdentifier)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.destinationPreviewGeneration == generation else { return }
                self.destinationPreviewInFlight = false
                guard self.destinationPreviewAllowed else { PasteMarker.shared.hide(); return }
                let stillFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                let currentRevision = DestinationPreviewInvalidation.shared.revision
                guard DestinationPreview.fresh(requestedAt: requestedAt,
                    now: ProcessInfo.processInfo.systemUptime, revision: revision,
                    currentRevision: currentRevision, sameApplication: stillFront) else {
                    /*
                    A stale reply never draws. Another app in front shows the ring; an invalidation
                    or a slow reply keeps a verified box and asks for a fresh read.
                    */
                    if !stillFront { self.showDestinationCursorFallback() }
                    else if revision == currentRevision { self.retryDestinationPreview("slow_read") }
                    return
                }
                self.destinationLabel = stillFront ? reading.label : "Focus changed"
                if stillFront, DestinationPreview.showsMarker(reading) {
                    self.destinationPreviewRetries = 0
                    // A verified box: its corners when that switch is on, else nothing (no ring).
                    if PasteMarkerPreference.load() {
                        PasteMarker.shared.show(field: reading.field, caret: reading.anchor,
                                                shortcutName: self.shortcutName, role: reading.role)
                    } else { PasteMarker.shared.hide() }
                } else if stillFront, let skip = reading.skip,
                          DestinationPreview.isPassing(skip) {
                    self.retryDestinationPreview(skip)
                } else {
                    self.destinationPreviewRetries = 0
                    if stillFront, PasteMarkerPreference.load() {
                        PasteMarker.shared.note("paste_marker_skipped reason=\(reading.skip ?? "no_box") role=\(reading.role ?? "-")")
                    }
                    self.showDestinationCursorFallback()
                }
            }
        }
    }

    /*
    A passing miss (AX busy, focus moving, Chromium building its tree) keeps a verified box
    (or shows the ring when there is none) and retries shortly. After three misses the ring
    replaces the box and the regular tick takes over.
    */
    private func retryDestinationPreview(_ reason: String) {
        keepVerifiedBoxOrShowRing()
        destinationPreviewRetries += 1
        if destinationPreviewRetries <= DestinationPreview.passingRetries {
            scheduleDestinationRefresh(after: 0.15)
        } else {
            PasteMarker.shared.note("paste_marker_skipped reason=\(reason) retries=\(destinationPreviewRetries - 1)")
            showDestinationCursorFallback()
        }
    }

}

/// Invalidates already displayed geometry immediately; never performs AX IPC on the main thread.
/// App/Space/screen changes cover windows that stop being visible without changing application PID.
final class DestinationPreviewInvalidation {
    static let shared = DestinationPreviewInvalidation()
    private let workspace: NotificationCenter
    private let application: NotificationCenter
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// The argument is true for a soft change: the same box's text, selection or layout.
    private var onChange: ((Bool) -> Void)?
    private(set) var revision: UInt64 = 0

    /// Edits inside the verified box; every other notification is a hard change.
    static let softNotifications: Set<String> = [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                                                 kAXLayoutChangedNotification]
    static func isSoft(_ notification: String) -> Bool { softNotifications.contains(notification) }

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         application: NotificationCenter = .default) {
        self.workspace = workspace
        self.application = application
    }

    func start(onChange: @escaping (Bool) -> Void) {
        stop()
        self.onChange = onChange
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name)
        }
        observe(application, NSApplication.didChangeScreenParametersNotification)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.invalidate()
        }
        tokens.append((center, token))
    }

    func invalidate(soft: Bool = false) {
        guard let onChange else { return }
        revision &+= 1
        onChange(soft)
    }

    func stop() {
        revision &+= 1
        onChange = nil
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { for (center, token) in tokens { center.removeObserver(token) } }
}

/// Both app focus subscriptions are mandatory. Unsupported supplementary layout/value
/// subscriptions use bounded polling; incomplete, timed-out or invalid registrations fail closed.
enum DestinationObservationReadiness {
    static func ready(results: [AXError], requiredCount: Int, mandatoryCount: Int? = nil) -> Bool {
        let mandatory = mandatoryCount ?? requiredCount
        guard requiredCount > 0, mandatory > 0, mandatory <= requiredCount,
              results.count == requiredCount else { return false }
        return results.enumerated().allSatisfy { index, result in
            result == .success || result == .notificationAlreadyRegistered
                || (index >= mandatory && result == .notificationUnsupported)
        }
    }

    /*
    Worth trying again on the next read: nothing the app refused outright, only a busy app or a
    spent budget (build 81: one timed-out registration used to switch the box off for the talk).
    */
    static func retryable(results: [AXError], requiredCount: Int) -> Bool {
        !ready(results: results, requiredCount: requiredCount) && !results.contains(.notificationUnsupported)
    }
}

/// Queue-owned AX subscriptions. The callback has no unmanaged owner pointer and only invalidates:
/// even an already queued callback from a retired observer can never resurrect a marker.
private final class DestinationAXObservation {
    static let shared = DestinationAXObservation()
    private var observer: AXObserver?
    private var pid: pid_t?
    private var field: AXUIElement?
    private var window: AXUIElement?
    private var ready = false

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; pid = nil; field = nil; window = nil; ready = false
    }

    func observe(pid: pid_t, app: AXUIElement, window: AXUIElement, field: AXUIElement) -> Bool {
        if self.pid == pid, let previousField = self.field, let previousWindow = self.window,
           CFEqual(previousField, field), CFEqual(previousWindow, window) { return ready }
        stop()
        // Cache readiness for this exact target: success, and a notification the app does not
        // support. A timeout or busy app is tried again on the next read (build 81).
        self.pid = pid; self.field = field; self.window = window
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, _ in
            // Source is installed on the main run loop; no AX work or content reads here.
            DestinationPreviewInvalidation.shared.invalidate(soft: DestinationPreviewInvalidation.isSoft(notification as String))
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return false }
        let budget = DestinationAXBudget(seconds: 0.12)
        let registrations: [(AXUIElement, [String])] = [
            (app, [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification]),
            (window, [kAXWindowMovedNotification, kAXWindowResizedNotification,
                      kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification]),
            (field, [kAXSelectedTextChangedNotification, kAXValueChangedNotification,
                     kAXLayoutChangedNotification, kAXUIElementDestroyedNotification])
        ]
        var results: [AXError] = []
        registration: for (element, names) in registrations {
            for name in names {
                guard budget.arm(element) else { break registration }
                results.append(AXObserverAddNotification(created, element, name as CFString, nil))
            }
        }
        let required = registrations.reduce(0) { $0 + $1.1.count }
        ready = DestinationObservationReadiness.ready(results: results, requiredCount: required, mandatoryCount: 2)
        guard ready else {
            if results.count != required || results.contains(where: { $0 != .success && $0 != .notificationAlreadyRegistered && $0 != .notificationUnsupported }) { stop() }
            return false
        }
        self.observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        return true
    }
}

/// One whole read deadline, with every AX IPC limited to the smaller remaining budget.
private final class DestinationAXBudget {
    let deadline: TimeInterval
    init(seconds: TimeInterval = 0.22) { deadline = ProcessInfo.processInfo.systemUptime + seconds }
    func arm(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.025))) == .success
    }
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
}

/// Never reads field contents or document titles, and never implies acceptance.
enum DestinationPreview {
    static let queue = DispatchQueue(label: "tokens.destination-preview", qos: .utility)
    /// Apps already asked to build their accessibility tree (two tries each).
    private static var warmAttempts: [pid_t: Int] = [:]
    /// Quick re-reads after a passing miss before the box is taken down.
    static let passingRetries = 3

    /// Misses that say "not yet", not "no box here".
    static func isPassing(_ skip: String) -> Bool {
        ["slow_read", "budget", "focus_moved", "selection_moved", "observation_unready", "warming"].contains(skip)
    }

    struct Reading {
        let label: String
        /// Only verified collapsed-range bounds; no field-corner or previous-character guess.
        /// (With no caret, `field` alone can still place corner cues around the verified box.)
        let anchor: CGRect?
        /// The focused text box's own frame, in the same coordinates, when it reports one.
        var field: CGRect? = nil
        /// The box's AX role and, when no marker can show, why: diagnostics only, never text.
        var role: String? = nil
        var skip: String? = nil
    }

    static func fresh(requestedAt: TimeInterval, now: TimeInterval, revision: UInt64,
                      currentRevision: UInt64, sameApplication: Bool) -> Bool {
        sameApplication && revision == currentRevision && now >= requestedAt && now - requestedAt < 0.4
    }

    static func isTerminal(_ identifier: String?) -> Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"].contains(identifier ?? "")
    }

    static func reading(pid: pid_t, name: String, bundleIdentifier: String?) -> Reading {
        let unavailable = { (skip: String) in Reading(label: label(app: name, role: nil, secure: false), anchor: nil, skip: skip) }
        guard !isTerminal(bundleIdentifier) else {
            DestinationAXObservation.shared.stop()
            return Reading(label: "\(name) · caret unconfirmed", anchor: nil, skip: "terminal")
        }
        let budget = DestinationAXBudget()
        let app = AXUIElementCreateApplication(pid)
        /*
        Chromium and Electron (Claude, Codex, Cursor, Chrome) build their tree only once asked, so
        a read straight after asking finds no box; say "warming" and read again shortly instead of
        losing the first second of the box (build 81). Two tries per app, then read as is.
        */
        if warmAttempts[pid, default: 0] < 2, budget.arm(app) {
            if TargetDelivery.enableManualAccessibility(app, bundleIdentifier: bundleIdentifier) {
                warmAttempts[pid] = 2
                return unavailable("warming")
            }
            warmAttempts[pid, default: 0] += 1
        }
        guard budget.arm(app), let window = TargetDelivery.copyElement(kAXFocusedWindowAttribute as String, from: app) else {
            DestinationAXObservation.shared.stop(); return unavailable("no_window")
        }
        guard let field = focusedField(app: app, window: window, budget: budget) else {
            DestinationAXObservation.shared.stop(); return unavailable("no_field")
        }
        let observationReady = DestinationAXObservation.shared.observe(pid: pid, app: app, window: window, field: field)
        guard budget.arm(field) else { return unavailable("budget") }
        let role = TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: field)
        guard budget.arm(field) else { return unavailable("budget") }
        let subrole = TargetDelivery.stringAttribute(kAXSubroleAttribute as String, from: field)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let resultLabel = label(app: name, role: role, secure: secure)
        func skipped(_ reason: String) -> Reading { Reading(label: resultLabel, anchor: nil, role: role, skip: reason) }
        guard !secure else { return skipped("secure") }
        guard observationReady else { return skipped("observation_unready") }
        let node = AXNode(field, budget: budget)
        guard DestinationFocus.isTextBox(role: role, editable: node.editable) else { return skipped("not_text_box") }
        let selection = budget.arm(field) ? TargetDelivery.selectedRange(in: field) : nil
        var caret = caret(selection: selection) { range in
            guard budget.arm(field) else { return nil }
            return bounds(of: range, in: field)
        }
        /*
        Chromium and Electron composers (the Claude desktop app) often report no caret bounds, or
        an empty rectangle at the screen's corner. Then use the
        focused text box's own AX frame, cut to what is visible of it (its scroll view, its window),
        so the corner cues can still frame it (outside the box, never over its text). A caret that
        lies outside its own box is not a verified caret and is dropped.
        */
        var fieldFrame = boxFrame(of: node, in: window, budget: budget)
        /*
        Chrome's address bar while its suggestion list is open (build 79): the focused
        window can be the list, which clips the bar away. Retry against the field's own window.
        */
        if fieldFrame == nil, budget.arm(field),
           let own = TargetDelivery.copyElement(kAXWindowAttribute as String, from: field), !CFEqual(own, window) {
            fieldFrame = boxFrame(of: node, in: own, budget: budget)
        }
        if let reported = caret, let fieldFrame, validatedFieldFrame(fieldFrame, containing: reported) == nil {
            caret = nil
        }
        // AX focus may change during any IPC, including to a secure field in the same app.
        // Recheck exact identities (and, for a caret, the selection) without reading text; unknown means hide.
        guard caret != nil || fieldFrame != nil else {
            // Sizes only, never text: explains a missed blinking cursor in the next event log.
            let raw = node.frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"
            return skipped("no_caret_no_box(field=\(raw),selection=\(selection != nil))")
        }
        guard budget.arm(app),
              let currentWindow = TargetDelivery.copyElement(kAXFocusedWindowAttribute as String, from: app),
              CFEqual(window, currentWindow),
              let currentField = focusedField(app: app, window: currentWindow, budget: budget),
              CFEqual(field, currentField), !budget.expired else { return skipped("focus_moved") }
        if caret != nil {
            guard let selection, budget.arm(field),
                  let currentSelection = TargetDelivery.selectedRange(in: field),
                  selection.location == currentSelection.location, selection.length == currentSelection.length,
                  !budget.expired else { return skipped("selection_moved") }
        }
        return Reading(label: resultLabel, anchor: caret, field: fieldFrame, role: role)
    }

    /// The marker shows for a verified caret, or for a verified text box when the app gives no caret.
    static func showsMarker(_ reading: Reading) -> Bool { reading.anchor != nil || reading.field != nil }

    /// The focused box's own frame, cut to its scroll view (a long document's text view runs
    /// past it) and to its window; nil when nothing of it is visible.
    private static func boxFrame(of node: AXNode, in window: AXUIElement, budget: DestinationAXBudget) -> CGRect? {
        guard let rect = node.frame else { return nil }
        let parent = node.parent
        let scrollArea = parent?.role == "AXScrollArea" ? parent?.frame : nil
        return clippedBoxFrame(rect, window: axFrame(of: window, budget: budget), scrollArea: scrollArea)
    }

    /// A finite, non-empty box, cut to the visible part of its scroll view and window; nil when nothing is left.
    static func clippedBoxFrame(_ rect: CGRect, window: CGRect?, scrollArea: CGRect? = nil) -> CGRect? {
        guard finite(rect) else { return nil }
        var visible = rect
        for clip in [scrollArea, window].compactMap({ $0 }) where finite(clip) {
            visible = visible.intersection(clip)
            if visible.isNull || visible.isEmpty { return nil }
        }
        return visible
    }

    private static func finite(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
    }

    fileprivate static func axFrame(of element: AXUIElement, budget: DestinationAXBudget) -> CGRect? {
        var raw: CFTypeRef?
        var position = CGPoint.zero
        guard budget.arm(element),
              AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success,
              let positionValue = raw, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position) else { return nil }
        raw = nil
        var size = CGSize.zero
        guard budget.arm(element),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success,
              let sizeValue = raw, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func validatedFieldFrame(_ rect: CGRect, containing caret: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0, validCaret(caret),
              rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: caret.midX, y: caret.midY)) else { return nil }
        return rect
    }

    private static func focusedField(app: AXUIElement, window: AXUIElement,
                                     budget: DestinationAXBudget) -> AXUIElement? {
        guard budget.arm(app) else { return nil }
        let focused = TargetDelivery.copyElement(kAXFocusedUIElementAttribute as String, from: app)
            ?? (budget.arm(window) ? TargetDelivery.copyElement(kAXFocusedUIElementAttribute as String, from: window) : nil)
        guard let focused else { return nil }
        // A web page or group reported as focused: the focused text box inside it, when there is one.
        return DestinationFocus.resolve(AXNode(focused, budget: budget))?.element ?? focused
    }

    /// A selected range or missing caret geometry is not a point insertion target.
    /// Terminal AX ranges describe scrollback; those apps are rejected before this query.
    static func caret(selection: CFRange?, bounds: (CFRange) -> CGRect?) -> CGRect? {
        guard let selection, selection.location >= 0, selection.length == 0,
              let rect = bounds(selection), validCaret(rect) else { return nil }
        return rect
    }

    static func validCaret(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width >= 0 && rect.size.width <= 8 && rect.size.height > 0
    }

    private static func bounds(of range: CFRange, in field: AXUIElement) -> CGRect? {
        var candidate = range
        guard let parameter = AXValueCreate(.cfRange, &candidate) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }

    static func label(app: String, role: String?, secure: Bool) -> String {
        if secure { return "\(app) · protected field" }
        switch role {
        case nil: return "\(app) · no text box detected"
        case "AXTextField", "AXComboBox": return "\(app) · text field"
        case "AXTextArea": return "\(app) · text area"
        default: return "\(app) · field unconfirmed"
        }
    }
}

/// What the focus resolver reads from one accessibility node: real AX in the app, fakes in tests.
protocol DestinationFocusNode {
    var role: String? { get }
    /// AXEditable: Chromium marks contenteditable regions with it.
    var editable: Bool { get }
    var focused: Bool { get }
    var children: [Self] { get }
}

/*
Chromium and Electron apps sometimes report the whole web page (AXWebArea) or a wrapping group
as the focused element while the caret sits in a composer inside it. The marker wants that
composer: the focused text box among the focused element's descendants, found breadth first
within a small node limit. Only roles and focus flags are read, never text.
*/
enum DestinationFocus {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// Containers that can be reported as focused while a text box inside them holds the caret.
    static let containerRoles: Set<String> = ["AXWebArea", "AXGroup", "AXScrollArea"]
    static let searchLimit = 160

    /// A text role, or an editable web group/page (a contenteditable composer or document).
    static func isTextBox(role: String?, editable: Bool) -> Bool {
        guard let role else { return false }
        return textRoles.contains(role) || (editable && (role == "AXGroup" || role == "AXWebArea"))
    }

    static func resolve<Node: DestinationFocusNode>(_ focused: Node, limit: Int = searchLimit) -> Node? {
        let role = focused.role
        if textRoles.contains(role ?? "") { return focused }
        guard containerRoles.contains(role ?? "") else { return nil }
        if isTextBox(role: role, editable: focused.editable) { return focused }
        var queue = focused.children[...]
        var visited = 0
        while visited < limit, let node = queue.popFirst() {
            visited += 1
            if node.focused, isTextBox(role: node.role, editable: node.editable) { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }
}

/// A live AX node; every read is armed against the reading's single deadline.
private final class AXNode: DestinationFocusNode {
    let element: AXUIElement
    private let budget: DestinationAXBudget

    init(_ element: AXUIElement, budget: DestinationAXBudget) {
        self.element = element
        self.budget = budget
    }

    var role: String? {
        budget.arm(element) ? TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: element) : nil
    }
    var editable: Bool { bool("AXEditable") }
    var focused: Bool { bool(kAXFocusedAttribute as String) }
    var frame: CGRect? { DestinationPreview.axFrame(of: element, budget: budget) }
    var parent: AXNode? {
        guard budget.arm(element),
              let parent = TargetDelivery.copyElement(kAXParentAttribute as String, from: element) else { return nil }
        return AXNode(parent, budget: budget)
    }
    var children: [AXNode] {
        var raw: CFTypeRef?
        guard budget.arm(element),
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let elements = raw as? [AXUIElement] else { return [] }
        return elements.map { AXNode($0, budget: budget) }
    }

    private func bool(_ name: String) -> Bool {
        var raw: CFTypeRef?
        guard budget.arm(element),
              AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return false }
        return (raw as? NSNumber)?.boolValue ?? false
    }
}

/*
Destination cues (the dotted corners and the pointer ring) run only while a talk records
(UX review: "this should only pop up during live dictations ... kind of like the mouse
bubble"). The standby bubble stays visible at rest, but clicking around with Tokens open no
longer draws corners. Preview stops while a final target is being delivered.
*/
enum DestinationPreviewPolicy {
    static let pollInterval: TimeInterval = 0.25
    /// A verified box lasts this long without a fresh read before the ring replaces it. Reads come
    /// every 0.25 s, but slow down while text is typed (build 83: 0.5 s made the box blink).
    static let cueLifetime: TimeInterval = 1.5
    static func runs(phase: TalkPhase, suspended: Bool = false) -> Bool {
        !suspended && phase == .capturing
    }
}
