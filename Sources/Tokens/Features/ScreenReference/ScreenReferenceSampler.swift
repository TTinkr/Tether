


//
import AppKit
import ApplicationServices
import Combine
import TokensCore

/// Samples the focused titles of the front windows at key-down and turns them into a note.
@MainActor final class ScreenReferenceSampler {
    typealias Sample = (bundleIdentifier: String?, title: String)
    /// Reads titles off the main thread; tests pass a fixture instead of Accessibility.
    typealias TitleSource = @Sendable () -> [Sample]

    static let shared = ScreenReferenceSampler()
    nonisolated static let key = "TokensScreenReference.v1"
    nonisolated static let budget: Duration = .milliseconds(40)
    nonisolated static let maximumApps = 5

    /// UserDefaults is thread-safe, so the menu can read and flip this from any context.
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Memory only, cleared at idle or failure. Never logged.
    private(set) var samples: [Sample] = []
    /// The in-flight read for the current talk; tests await it.
    private(set) var pendingSample: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    /// True from capturing until idle or failure, so a late async sample never lands after a talk ends.
    private var active = false
    /// Bumped per talk, so a slow read from an earlier talk never lands in a later one.
    private var ticket = 0
    private let defaults: UserDefaults
    private let isTrusted: () -> Bool
    private let titleSource: TitleSource

    init(defaults: UserDefaults = .standard,
         isTrusted: @escaping () -> Bool = { TargetDelivery.accessibilityTrusted(prompt: false) },
         titleSource: @escaping TitleSource = { ScreenReferenceSampler.frontWindowTitles() }) {
        self.defaults = defaults
        self.isTrusted = isTrusted
        self.titleSource = titleSource
    }

    var enabled: Bool { defaults.bool(forKey: Self.key) }

    func attach(to model: TalkModel) {
        cancellable = model.$phase.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.handle(phase) }
    }

    /*
    Capturing starts a fresh sample. The Accessibility reads run on a utility-priority task,
    so key-down never waits on a slow app; the result lands on main only if the same talk is
    still active. Finalizing and delivered keep the sample because delivery composes there.
    */
    func handle(_ phase: TalkPhase) {
        switch phase {
        case .capturing:
            samples = []
            active = true
            ticket &+= 1
            guard enabled, isTrusted() else { pendingSample = nil; return }
            let talk = ticket
            let source = titleSource
            pendingSample = Task { [weak self] in
                let found = await Task.detached(priority: .utility) { source() }.value
                self?.land(found, talk: talk)
            }
        case .idle, .failed:
            samples = []
            active = false
        case .finalizing, .delivered:
            break
        }
    }

    /// Keeps a finished read only when sampling is on and the talk that asked for it is live.
    private func land(_ found: [Sample], talk: Int) {
        guard enabled, active, talk == ticket else { return }
        samples = found
    }

    /*
    Front-to-back owner PIDs from CGWindowList (no kCGWindowName, so no Screen Recording), then
    each app's focused window title. Runs off main. The budget is checked before every
    Accessibility call and each call times out at 20 ms, so the worst case is about 60 ms.
    Electron editors take about 16 ms per app, so a sample usually reaches the front 2-3 apps,
    not all 5; the front app, the one being talked about, always comes first.
    */
    nonisolated static func frontWindowTitles() -> [Sample] {
        let clock = ContinuousClock()
        let started = clock.now
        let overBudget = { clock.now - started >= budget }
        let own = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        var pids: [pid_t] = []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != own, !pids.contains(pid) else { continue }
            pids.append(pid)
            if pids.count == maximumApps { break }
        }
        var found: [Sample] = []
        for pid in pids {
            if overBudget() { break }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.02)
            guard let window = TargetDelivery.focusedWindow(in: app) else { continue }
            if overBudget() { break }
            AXUIElementSetMessagingTimeout(window, 0.02)
            guard let title = TargetDelivery.stringAttribute(kAXTitleAttribute as String, from: window),
                  !title.isEmpty else { continue }
            found.append((NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, title))
        }
        let elapsed = clock.now - started
        let ms = Int(Double(elapsed.components.attoseconds) / 1e15) + Int(elapsed.components.seconds) * 1000
        // Count and time only; never a title.
        Diagnostics.event("screen_reference_sampled count=\(found.count) apps=\(pids.count) ms=\(ms)")
        return found
    }

    /// Empty unless enabled, the words point at the screen and a sampled title parses.
    func lines(for deliveredText: String) -> [String] {
        guard enabled else { return [] }
        let deictics = DeicticSpeech.detect(in: deliveredText)
        guard !deictics.isEmpty else { return [] }
        let references = samples.compactMap {
            WindowTitleParser.parse(title: $0.title, bundleIdentifier: $0.bundleIdentifier)
        }
        return ScreenReferenceNote.line(deictics: deictics, references: references).map { [$0] } ?? []
    }

    /// Test hook: stands in for an Accessibility sample.
    func inject(_ samples: [Sample]) { self.samples = samples }

    func reset() { samples = []; active = false; ticket &+= 1 }
}

