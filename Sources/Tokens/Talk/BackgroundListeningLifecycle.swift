


//
import AppKit


final class BackgroundListeningLifecycle {
    private var workspaceTokens: [NSObjectProtocol]   = []
    private var distributedTokens: [NSObjectProtocol] = []

    init(onChange: @escaping (BackgroundListeningConsent.Suspension, Bool) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason, suspended) in [
            (NSWorkspace.willSleepNotification, BackgroundListeningConsent.Suspension.sleep, true),
            (NSWorkspace.didWakeNotification, .sleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)
        ] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                onChange(reason, suspended)
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, suspended) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedTokens.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                onChange(.screenLock, suspended)
            })
        }
    }

    deinit {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}

