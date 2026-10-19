import AppKit
import Combine

/// The panel action for one model snapshot. Recovery remains model-controlled because some
/// failures intentionally keep their words in Home without opening an overlay.
enum PersistentBubblePresentation: Equatable {
    case suppressed
    case standby
    case activeTalk
    case modelControlledRecovery
}

enum PersistentBubbleSuspensionReason: Hashable {
    case systemSleep
    case screensSleep
    case inactiveSession
}

struct PersistentBubbleSuspensionState: Equatable {
    private(set) var reasons: Set<PersistentBubbleSuspensionReason> = []
    var isSuspended: Bool { !reasons.isEmpty }

    mutating func set(_ reason: PersistentBubbleSuspensionReason, active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

/// Remembers whether a visible recovery panel was suppressed by sleep/session state. Additional
/// suspension reasons cannot erase that intent, and a recovery the model already hid stays hidden.
struct PersistentBubbleRecoveryRestoreState: Equatable {
    private(set) var wasSuspended = false
    private(set) var restoreOnResume = false

    mutating func transition(suspended: Bool, failed: Bool,
                             panelPresentationRequested: Bool) -> Bool {
        if suspended && !wasSuspended {
            restoreOnResume = failed && panelPresentationRequested
        }
        if !failed { restoreOnResume = false }

        let shouldRestore = wasSuspended && !suspended && failed && restoreOnResume
        wasSuspended = suspended
        if !suspended { restoreOnResume = false }
        return shouldRestore
    }
}

enum PersistentBubblePolicy {
    static func presentation(publicTokens: Bool, normalLaunch: Bool, setupComplete: Bool,
                             suspended: Bool, phase: TalkPhase,
                             tokensHomeFrontmost: Bool,
                             standbyOverride: Bool = false) -> PersistentBubblePresentation {
        guard publicTokens, normalLaunch, setupComplete, !suspended else { return .suppressed }
        switch phase {
        case .idle, .delivered:
            return .standby
        case .capturing, .finalizing:
            return tokensHomeFrontmost ? .suppressed : .activeTalk
        case .failed:
            return standbyOverride ? .standby : .modelControlledRecovery
        }
    }

    static func persistentFeedbackEnabled(publicTokens: Bool, normalLaunch: Bool,
                                          setupComplete: Bool) -> Bool {
        publicTokens && normalLaunch && setupComplete
    }

    static func convertsFailedDismissalToStandby(persistentPreviewEnabled: Bool,
                                                  phase: TalkPhase) -> Bool {
        persistentPreviewEnabled && phase == .failed
    }

    @MainActor static func apply(_ presentation: PersistentBubblePresentation,
                                 to panel: CaptureBubblePanel) {
        switch presentation {
        case .standby, .activeTalk:
            if !panel.presentationRequested { panel.presentRequested() }
        case .suppressed:
            if panel.presentationRequested || panel.isVisible { panel.dismissRequested() }
        case .modelControlledRecovery:
            break
        }
    }
}

/// Owns only persistent presentation. It requests no permissions and never activates Tokens.
/// TalkModel still owns capture, delivery, explicit recovery overlays and destination contents.
@MainActor
final class PersistentBubbleLifecycle {
    private weak var model: TalkModel?
    private weak var panel: CaptureBubblePanel?
    private var modelChange: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var suspensions = PersistentBubbleSuspensionState()
    private var recoveryRestore = PersistentBubbleRecoveryRestoreState()
    private var terminating = false
    private var previewEnabled: Bool?
    private var previewSuspended: Bool?
    private var started = false

    init(model: TalkModel, panel: CaptureBubblePanel) {
        self.model = model
        self.panel = panel
    }

    func start() {
        guard !started else { return }
        started = true
        modelChange = model?.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }

        let defaults = NotificationCenter.default
        observe(defaults, UserDefaults.didChangeNotification) { [weak self] _ in self?.scheduleSync() }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observe(defaults, name) { [weak self] _ in self?.scheduleSync() }
        }
        observe(defaults, NSApplication.willTerminateNotification) { [weak self] _ in
            self?.terminating = true
            self?.sync()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.setSuspension(.systemSleep, active: true)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.setSuspension(.systemSleep, active: false)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            self?.setSuspension(.screensSleep, active: true)
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.setSuspension(.screensSleep, active: false)
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.setSuspension(.inactiveSession, active: true)
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.setSuspension(.inactiveSession, active: false)
        }
        sync()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         using block: @escaping @MainActor @Sendable (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated { block(notification) }
        }
        observers.append((center, token))
    }

    private func scheduleSync() {
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    private func setSuspension(_ reason: PersistentBubbleSuspensionReason, active: Bool) {
        suspensions.set(reason, active: active)
        sync()
    }

    private func sync() {
        guard let model, let panel else { return }
        let setupComplete = !TalkModel.tokensSetupInProgress
        let suspended = suspensions.isSuspended || terminating
        let restoreFailedPanel = recoveryRestore.transition(
            suspended: suspended, failed: model.phase == .failed,
            panelPresentationRequested: panel.presentationRequested)
        if previewSuspended != suspended {
            previewSuspended = suspended
            model.setDestinationPreviewSuspended(suspended)
        }
        let preview = PersistentBubblePolicy.persistentFeedbackEnabled(
            publicTokens: publicTokens, normalLaunch: true, setupComplete: setupComplete)
        if previewEnabled != preview {
            previewEnabled = preview
            model.setPersistentDestinationPreviewEnabled(preview)
        }

        let presentation = PersistentBubblePolicy.presentation(
            publicTokens: publicTokens, normalLaunch: true, setupComplete: setupComplete,
            suspended: suspended, phase: model.phase,
            tokensHomeFrontmost: model.tokensWindowIsFrontmost,
            standbyOverride: model.bubbleStandbyOverride)
        PersistentBubblePolicy.apply(presentation, to: panel)
        if restoreFailedPanel, presentation == .modelControlledRecovery {
            PersistentBubblePolicy.apply(.activeTalk, to: panel)
        }
    }

    deinit {
        modelChange?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
