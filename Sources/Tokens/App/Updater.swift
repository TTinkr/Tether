


//
import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI
import TokensCore


// Updater — Shows Sparkle's update progress and waits for a quiet moment to restart


/// Sparkle owns validation, extraction, replacement and relaunch. This class owns UI only.
/// App-owned discovery timing; Sparkle's automatic scheduler stays disabled.
struct BackgroundUpdateSchedule {
    static let startupDelay: TimeInterval = 3
    static let interval: TimeInterval = 60
    private(set) var nextCheckAt: Date?
    private(set) var inFlight = false

    mutating func start(now: Date) {
        guard nextCheckAt == nil else { return }
        nextCheckAt = now.addingTimeInterval(Self.startupDelay)
    }

    mutating func beginIfDue(now: Date, eligible: Bool) -> Bool {
        guard eligible, !inFlight, let due = nextCheckAt, now >= due else { return false }
        inFlight = true
        // Missed checks coalesce into one attempt; offline failures retry on the next cadence.
        nextCheckAt = now.addingTimeInterval(Self.interval)
        return true
    }

    mutating func finish() { inFlight = false }
}

final class Updater: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {


    // State and starting a check — what the update row shows, check(), cancel(), resumeWhenIdle()


    @Published private(set) var label = "Check for updates"
    @Published private(set) var busy  = false
    @Published private(set) var progress: Double?
    @Published private(set) var restarting = false
    @Published private(set) var canRetryRestart = false
    private var retryTermination: (() -> Void)? {
        didSet { canRetryRestart = retryTermination != nil }
    }
    /// An explicit install may restart a terminal failed paste only after exact held words
    /// survive a durable save/readback. Active microphone work always wins over installation.
    static func canSafelyRestart(phase: TalkPhase, microphoneBusy: Bool, retainedText: String,
                                 preserve: () -> Bool) -> Bool {
        guard !microphoneBusy else { return false }
        switch phase {
        case .idle, .delivered: return true
        case .capturing, .finalizing: return false
        case .failed: return retainedText.isEmpty || preserve()
        }
    }

    var canRestart: () -> Bool             = { false }
    /// Explain the actual restart hold without implying an idle failed paste is recording.
    var restartHoldExplanation: () -> String = { "Update downloaded · waiting to restart" }
    // Manual and scheduled checks share setup consent; tests inject a nonbinding fixture policy.
    var hasAgreement: () -> Bool           = { !TalkModel.tokensFirstRunPending }
    private var engine: SPUUpdater?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var pendingInstall: ((SPUUserUpdateChoice) -> Void)?
    // A found update, from either kind of check, awaiting an explicit Install or Later choice.
    @Published private(set) var available = false
    // A genuine Sparkle offer remains discoverable after Later, cancellation or a failed attempt.
    // This is independent of the single-use reply, which must never be reused as consent.
    @Published private(set) var knownUpdateVersion: String?
    @Published private(set) var knownUpdateIsCritical = false
    var updateNoticeDetail: String {
        if busy { return label }
        return knownUpdateIsCritical ? "Important update available" : "New version available"
    }
    var showsUpdateNotice: Bool { knownUpdateVersion != nil }
    var canActOnUpdateNotice: Bool { hasAgreement() && (canRetryRestart || (!busy && !restarting)) }

    func actOnUpdateNotice() {
        guard showsUpdateNotice, canActOnUpdateNotice else { return }
        if canRetryRestart { retryRestart() }
        else if available { installAvailable() }
        else { check() } // Revalidate a dismissed/cancelled offer through Sparkle.
    }
    private var pendingFound: ((SPUUserUpdateChoice) -> Void)?
    private var pendingFoundStage: SPUUserUpdateStage = .notDownloaded
    private var backgroundTimer: Timer?
    private var startupTimer: Timer?
    private var backgroundObservers: [NSObjectProtocol] = []
    private(set) var backgroundSchedule = BackgroundUpdateSchedule()

    deinit {
        backgroundTimer?.invalidate()
        startupTimer?.invalidate()
        for observer in backgroundObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    @Published private(set) var canCancel = false
    private var cancellation: (() -> Void)? { didSet { canCancel = cancellation != nil } }

    /*
    `label` is the one line of text the update row shows. `busy` is true from a check until it ends.
    `progress` is a 0 to 1 download fraction, nil when the size is unknown (`expected` and
    `received` are the byte counts it is worked out from). `canRestart` is set by TalkModel: it
    answers whether the app is idle enough to restart. `engine` is the Sparkle updater, made on
    the first check. `pendingInstall` holds Sparkle's reply for a downloaded update that has not
    been allowed to restart the app yet. `cancellation` is Sparkle's cancel action for the
    current step, if any; `canCancel` mirrors whether it is set.
    */

    /*
    What a check the person asked for does with the updater's state (build 81: the menu bar's
    Check for Updates… must always get an answer, never return without a word). An offer that is
    already waiting is shown, never re-checked: checking is never consent to install. A quiet
    background check that is already asking is waited for, never doubled.
    */
    enum CheckStep: Equatable { case needsAgreement, showOffer, showProgress, waitForQuietCheck, start }

    static func checkStep(agreed: Bool, available: Bool, busy: Bool,
                          quietCheckRunning: Bool, sparkleBusy: Bool) -> CheckStep {
        guard agreed else { return .needsAgreement }
        if available { return .showOffer }
        if busy { return .showProgress }
        if quietCheckRunning { return .waitForQuietCheck }
        return sparkleBusy ? .showProgress : .start
    }

    /// The person asked while a quiet background check was running; finishBackgroundCheck answers them.
    private var userCheckWaiting = false

    /*
    Starts a check that the user asked for. Refuses to run unless Info.plist has an https
    SUFeedURL and a SUPublicEDKey that decodes to exactly 32 bytes (a base64 Ed25519 public
    key); otherwise the label says updates are not configured.
    */
    func check() {
        switch Self.checkStep(agreed: hasAgreement(), available: available, busy: busy,
                              quietCheckRunning: backgroundSchedule.inFlight,
                              sparkleBusy: engine?.sessionInProgress == true) {
        case .needsAgreement:
            label = "Agree to Terms before checking"
        case .showOffer, .showProgress:
            return
        case .waitForQuietCheck:
            userCheckWaiting = true
            label = "Checking…"
        case .start:
            guard startEngine() else { return }
            busy  = true
            label = "Checking…"
            engine?.checkForUpdates()
        }
    }

    /*
    True when Info.plist names an https feed and a 32-byte Ed25519 public key. Without both,
    nothing is ever requested from the network.
    */
    /// True when this build carries an update feed and key. Without them the update controls
    /// are hidden, so nobody is shown a button that can only say "not configured".
    var isConfigured: Bool { configured }

    private var configured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return Data(base64Encoded: key)?.count == 32
    }

//
// :)
//
//
    private func startEngine() -> Bool {
        guard configured else { label = "Updates not configured"; return false }
        if engine != nil { return true }
        do {
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
            // Tokens owns discovery and explicit installation consent, including on upgraded profiles.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            try updater.start()
            engine = updater
            return true
        } catch {
            label = Self.failureLabel(error)
            Diagnostics.event("updater_start_failed detail=\(Self.failureCode(error))")
            return false
        }
    }

    /*
    Updates are optional but highly encouraged.
    Theorem: a background check never downloads or installs anything by itself. It only turns
             `available` on; the person chooses Install now or Later. Tokens keeps working either way.
    Checks 3 seconds after eligible startup/setup, then about every minute while running.
    Wake and app activation trigger one check only when due. No feed means no requests.
    */
    func startBackgroundChecks() {
        guard hasAgreement(), configured, backgroundTimer == nil else { return }
        backgroundSchedule.start(now: Date())
        startupTimer = Timer.scheduledTimer(withTimeInterval: BackgroundUpdateSchedule.startupDelay, repeats: false) { [weak self] _ in
            self?.checkInBackground()
        }
        // A short due probe keeps discovery responsive without overlapping network checks.
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
        backgroundObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkInBackground() })
        backgroundObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkInBackground() })
    }

    private func checkInBackground() {
        let eligible = hasAgreement() && configured && !busy && !available && !restarting
            && engine?.sessionInProgress != true
        guard backgroundSchedule.beginIfDue(now: Date(), eligible: eligible) else { return }
        guard startEngine(), let engine, !engine.sessionInProgress else {
            finishBackgroundCheck()
            return
        }
        engine.checkForUpdatesInBackground()
    }

    // An update relaunch comes back quietly, without Home over the app being used (build 81).
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        LaunchPresentation.markUpdateRelaunch()
        Diagnostics.event("updater_will_relaunch")
    }

    // Silent no-update/network-error cycles may never call the user driver. Release their gate here.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishBackgroundCheck()
    }

    func finishBackgroundCheck() {
        backgroundSchedule.finish()
        guard userCheckWaiting else { return }
        userCheckWaiting = false
        /*
        A check was asked for while this quiet one ran (build 81). A found update is already on
        show; otherwise ask Sparkle once for the person, on the next turn because Sparkle may
        still be closing this session. If it cannot start, the label never stays "Checking…".
        */
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.available, !self.busy else { return }
            self.label = "Check for updates"
            self.check()
        }
    }

    /// Explicit Install action: download or resume an installation, then restart only once idle.
    func installAvailable() {
        guard hasAgreement(), let reply = pendingFound else { return }
        pendingFound = nil; available = false
        busy = true
        if pendingFoundStage == .installing {
            // Sparkle resumes this stage by quitting immediately; there is no new ready callback.
            pendingInstall = reply
            label = restartHoldExplanation()
            resumeWhenIdle()
        } else {
            label = "Downloading…"
            reply(.install)
        }
    }

    /// Not now. Keep the notice; its next action rechecks, as does the next scheduled check.
    func dismissAvailable() {
        guard let reply = pendingFound else { return }
        pendingFound = nil; available = false
        label = "Check for updates"
        reply(.dismiss)
    }

    func cancel() { let action = cancellation; cancellation = nil; action?() }
    /*
    A downloaded update is held until `canRestart()` is true; TalkModel calls this on every
    phase change, so the restart happens once no talk is in progress.
    */
    func resumeWhenIdle() {
        guard let reply = pendingInstall else { return }
        guard hasAgreement() else { label = "Agree to Terms before restarting"; return }
        guard canRestart() else { label = restartHoldExplanation(); return }
        pendingInstall = nil
        restarting     = true
        label          = "Restarting…"
        reply(.install)
    }


    // Sparkle's callbacks — permission, found, download, extraction, ready, installed


    /*
    Sparkle asks permission for automatic checks and for sending a system profile. Both answers
    are always no: this driver never turns on automatic checks and never sends a system profile.
    */
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

//
// :)
//
//
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        busy = true; label = "Checking…"; self.cancellation = cancellation
    }
    /*
    The functions below are SPUUserDriver callbacks: Sparkle calls them as an update moves
    through found, download, extraction, ready and installed. Each one sets `label`, `busy`,
    `progress` and similar state for the update row; some also answer Sparkle or log an event.
    */
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate else {
            label = "Manual update required"; busy = false; reply(.dismiss); return
        }
        /*
        A manual check asks whether an update exists; it is not permission to download/install.
        Both manual and background callbacks retain the reply for the same explicit choice.
        */
        offerUpdate(version: appcastItem.displayVersionString, critical: appcastItem.isCriticalUpdate, stage: state.stage, reply: reply)
    }

    /// Shared consent boundary, also testable without starting Sparkle or requesting the network.
    func offerUpdate(version: String, critical: Bool, stage: SPUUserUpdateStage = .notDownloaded, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard hasAgreement() else { reply(.dismiss); busy = false; cancellation = nil; return }
        knownUpdateVersion = version
        knownUpdateIsCritical = critical
        pendingFoundStage = stage
        pendingFound = reply; available = true; busy = false; cancellation = nil; progress = nil
        label = critical ? "Important update \(version) available" : "Update \(version) available"
        Diagnostics.event("update_available critical=\(critical)")
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        knownUpdateVersion = nil; knownUpdateIsCritical = false; pendingFound = nil; available = false; cancellation = nil
        label = "You're up to date"; busy = false; progress = nil; acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        label      = Self.failureLabel(error); busy = false; progress = nil
        restarting = false; pendingInstall = nil; cancellation = nil; retryTermination = nil
        pendingFound = nil; available = false
        Diagnostics.event("updater_session_failed detail=\(Self.failureCode(error))"); acknowledgement()
    }
    // Report only allowlisted domains and numeric codes: NSError descriptions/userInfo can
    // contain local paths or authenticated URLs. Preserve the underlying network error too.
    static func failureCode(_ error: Error) -> String {
        var current = error as NSError
        var codes: [String] = []
        for _ in 0..<3 {
            let domain = [NSURLErrorDomain, "SUSparkleErrorDomain", "SUErrorDomain", NSCocoaErrorDomain].contains(current.domain)
                ? current.domain : "UpdateError"
            codes.append("\(domain):\(current.code)")
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return codes.joined(separator: " / ")
    }

    static func failureLabel(_ error: Error) -> String {
        var current = error as NSError
        for _ in 0..<3 {
            if current.domain == NSURLErrorDomain {
                switch current.code {
                case NSURLErrorNotConnectedToInternet: return "Offline · reconnect and retry"
                case NSURLErrorTimedOut: return "Update timed out · retry"
                case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                    return "Cannot reach update server · retry"
                case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                    return "Secure update connection failed · retry"
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return "Update failed (\(failureCode(error))) · retry"
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0; received = 0; progress = nil
        busy     = true; label = "Downloading…"; self.cancellation = cancellation
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength; updateProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).overflow ? UInt64.max : received + length
        updateProgress()
    }
    private func updateProgress() {
        guard expected > 0 else { progress = nil; label = "Downloading…"; return }
        let fraction = min(1, Double(received) / Double(expected))
        progress     = fraction; label = String(format: "Downloading %.4f%%", fraction * 100)
    }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil; progress = nil; label = "Verifying update…"
    }
    func showExtractionReceivedProgress(_ progress: Double) { label = "Preparing update…" }
    /*
    The update is downloaded and checked. Keep Sparkle's reply, then install only if the app is
    idle right now; otherwise it waits for resumeWhenIdle().
    */
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingInstall = reply; label = restartHoldExplanation()
        resumeWhenIdle()
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        busy = true; restarting = true
        // Sparkle may wait indefinitely if its quit event is delayed or cancelled. Keep
        // its supported retry available; never force-kill the process or start a new update.
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        label = applicationTerminated ? "Installing update…" : "Update ready · restart Tokens to finish"
        Diagnostics.event("updater_installing application_terminated=\(applicationTerminated)")
    }

    /// An explicit retry still respects the same microphone and durable-text gate as install.
    func retryRestart() {
        guard let retry = retryTermination else { return }
        guard hasAgreement() else { label = "Agree to Terms before restarting"; return }
        guard canRestart() else { label = restartHoldExplanation(); return }
        label = "Waiting for Tokens to close · retry if needed"
        Diagnostics.event("updater_restart_retry")
        retry()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        knownUpdateVersion = nil
        knownUpdateIsCritical = false
        retryTermination = nil
        label = "Updated"; busy = false; restarting = false; acknowledgement()
    }
    func dismissUpdateInstallation() {
        busy = false; restarting = false; retryTermination = nil
        progress = nil; cancellation = nil; pendingInstall = nil
        pendingFound = nil; available = false
    }

//
// :)
//
//
    func showUpdateInFocus() {}


}

