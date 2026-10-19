


//
import AppKit
import SwiftUI
import Foundation
import Sparkle
import Testing
@testable import Tokens

// Sparkle exposes state construction through NSSecureCoding, without starting an updater.
private final class UpdateStageFixtureCoder: NSCoder {
    let stage: SPUUserUpdateStage
    init(stage: SPUUserUpdateStage) { self.stage = stage; super.init() }
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int {
        key == "SPUUserUpdateStateStage" ? stage.rawValue : 0
    }
    override func decodeBool(forKey key: String) -> Bool { true }
}

@Suite(.serialized) struct UpdaterTests {
    @Test static func failedUpdateExplainsNetworkFailureAndAcknowledgesOnce() {
        let updater = Updater()
        var acknowledgements = 0
        let nested = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1002,
                            userInfo: [NSUnderlyingErrorKey: nested])
        updater.showUpdaterError(error) { acknowledgements += 1 }
        #expect(updater.label == "Update timed out · retry")
        #expect(acknowledgements == 1 && !updater.busy && !updater.available)
        #expect(Updater.failureCode(error) == "SUSparkleErrorDomain:1002 / NSURLErrorDomain:-1001")
    }

    @Test static func updateFailureNeverExposesDescriptionsOrUnknownDomains() {
        let error = NSError(domain: "private-account@example.invalid", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "private URL and path"])
        #expect(Updater.failureLabel(error) == "Update failed (UpdateError:42) · retry")
        #expect(Updater.failureCode(error) == "UpdateError:42")
    }

    @Test static func installingStageCallbackWaitsForExplicitConsentAndIdleExactlyOnce() throws {
        let updater = Updater()
        updater.hasAgreement = { true }
        var idle = false
        updater.canRestart = { idle }
        let state = try #require(SPUUserUpdateState(coder: UpdateStageFixtureCoder(stage: .installing)))
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "19", "sparkle:shortVersionString": "0.3.2",
            "enclosure": ["url": "https://keeptinkr.ing/tokens/fixture.dmg"]
        ]))
        var choices: [SPUUserUpdateChoice] = []
        updater.showUpdateFound(with: item, state: state) { choices.append($0) }
        updater.resumeWhenIdle()
        #expect(choices.isEmpty && updater.available && !updater.busy)
        updater.installAvailable()
        updater.installAvailable()
        #expect(choices.isEmpty && updater.busy && !updater.restarting && updater.showsUpdateNotice)
        updater.resumeWhenIdle()
        #expect(choices.isEmpty)
        idle = true
        updater.resumeWhenIdle()
        updater.resumeWhenIdle()
        #expect(choices == [.install] && updater.restarting)
    }

    @Test static func installingStageLaterNeverAuthorizesRestart() throws {
        let updater = Updater()
        updater.hasAgreement = { true }
        updater.canRestart = { true }
        let state = try #require(SPUUserUpdateState(coder: UpdateStageFixtureCoder(stage: .installing)))
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "19", "enclosure": ["url": "https://keeptinkr.ing/tokens/fixture.dmg"]
        ]))
        var choices: [SPUUserUpdateChoice] = []
        updater.showUpdateFound(with: item, state: state) { choices.append($0) }
        updater.dismissAvailable()
        updater.installAvailable()
        updater.resumeWhenIdle()
        #expect(choices == [.dismiss] && !updater.restarting && updater.showsUpdateNotice)
    }

    @Test static func criticalNoticeSurvivesLaterAndFailureAndResetsWithNewEvidence() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var choices: [SPUUserUpdateChoice] = []
        updater.offerUpdate(version: "20", critical: true) { choices.append($0) }
        #expect(updater.updateNoticeDetail == "Important update available")
        updater.dismissAvailable()
        #expect(choices == [.dismiss])
        #expect(updater.updateNoticeDetail == "Important update available")
        updater.showUpdaterError(NSError(domain: "fixture", code: 1)) {}
        #expect(updater.updateNoticeDetail == "Important update available")
        updater.offerUpdate(version: "21", critical: false) { _ in }
        #expect(updater.updateNoticeDetail == "New version available")
        updater.offerUpdate(version: "22", critical: true) { _ in }
        updater.showUpdateNotFoundWithError(NSError(domain: "fixture", code: 2)) {}
        #expect(!updater.knownUpdateIsCritical && !updater.showsUpdateNotice)
        updater.offerUpdate(version: "23", critical: true) { _ in }
        updater.showUpdateInstalledAndRelaunched(true) {}
        #expect(!updater.knownUpdateIsCritical && !updater.showsUpdateNotice)
    }

    @Test static func delayedTerminationOffersExplicitRetryWithoutStartingAnotherInstall() {
        let updater = Updater()
        updater.hasAgreement = { true }
        updater.canRestart = { true }
        var installs = 0
        var retries = 0
        updater.offerUpdate(version: "29", critical: false) { _ in installs += 1 }
        updater.installAvailable()
        updater.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        #expect(updater.restarting && updater.busy && updater.canRetryRestart)
        #expect(updater.label == "Update ready · restart Tokens to finish")
        #expect(updater.canActOnUpdateNotice)
        #expect(installs == 1 && retries == 0)
        updater.actOnUpdateNotice()
        updater.retryRestart()
        #expect(installs == 1 && retries == 2)
        updater.showInstallingUpdate(withApplicationTerminated: true) { retries += 100 }
        updater.retryRestart()
        #expect(!updater.canRetryRestart && !updater.canActOnUpdateNotice)
        #expect(updater.label == "Installing update…" && retries == 2)
    }

    @Test static func retryRequiresAgreementAndSafeRestartAndTerminalCallbacksRevokeIt() {
        let updater = Updater()
        var agreed = false
        var safe = false
        var retries = 0
        updater.hasAgreement = { agreed }
        updater.canRestart = { safe }
        updater.restartHoldExplanation = { "Finish dictation before restarting" }
        updater.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        updater.retryRestart()
        #expect(retries == 0 && updater.label == "Agree to Terms before restarting")
        agreed = true
        updater.retryRestart()
        #expect(retries == 0 && updater.label == "Finish dictation before restarting")
        safe = true
        updater.retryRestart()
        #expect(retries == 1)
        updater.dismissUpdateInstallation()
        updater.retryRestart()
        #expect(retries == 1 && !updater.restarting && !updater.canRetryRestart)
        updater.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        updater.showUpdaterError(NSError(domain: "fixture", code: 1)) {}
        updater.retryRestart()
        #expect(retries == 1 && !updater.canRetryRestart)
        updater.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        updater.showUpdateInstalledAndRelaunched(true) {}
        updater.retryRestart()
        #expect(retries == 1 && !updater.restarting && !updater.canRetryRestart)
    }

    @Test static func run() {
        let updater = Updater()
        updater.hasAgreement = { true }
        updater.check()
        precondition(updater.label == "Updates not configured" && !updater.busy)
        var cancelled = 0
        updater.showDownloadInitiated { cancelled += 1 }
        updater.showDownloadDidReceiveData(ofLength: 25)
        precondition(updater.progress == nil) // Unknown length is never fake percent.
        updater.showDownloadDidReceiveExpectedContentLength(100)
        precondition(updater.progress == 0.25 && updater.label == "Downloading 25.0000%")
        updater.showDownloadDidReceiveData(ofLength: 100)
        precondition(updater.progress == 1)
        updater.cancel(); updater.cancel()
        precondition(cancelled == 1)
        updater.showDownloadDidStartExtractingUpdate()
        precondition(updater.progress == nil && !updater.canCancel)
        var ready          = false
        var installs       = 0
        updater.canRestart = { ready }
        updater.showReady { choice in precondition(choice == .install); installs += 1 }
        precondition(installs == 0 && !updater.restarting)
        ready = true
        updater.resumeWhenIdle(); updater.resumeWhenIdle()
        precondition(installs == 1 && updater.restarting)
        updater.showUpdaterError(NSError(domain: "fixture", code: 1)) {}
        precondition(!updater.busy && !updater.restarting && updater.progress == nil)
        print("PASS: configuration gate, real byte progress, unknown length, clamping, single cancel, idle-only single restart, error cleanup")
    }
    @Test static func installationHandlerReadsBackHeldWordsBeforeOneRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterHeldWords-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TranscriptRecoveryStore(directory: directory)
        let updater = Updater()
        updater.hasAgreement = { true }
        let payload = "The green notebook has eleven pages."
        var storageWorks = false
        var installs = 0
        updater.canRestart = {
            Updater.canSafelyRestart(phase: .failed, microphoneBusy: false, retainedText: payload) {
                storageWorks && ((try? journal.preserveForUpdateRestart(payload)) == true)
            }
        }
        updater.showReady { _ in
            #expect((try? journal.latestCopyEntry()?.text) == payload)
            installs += 1
        }
        #expect(installs == 0)
        storageWorks = true
        updater.resumeWhenIdle()
        updater.resumeWhenIdle()
        #expect(installs == 1)
        #expect(try journal.recover().count == 1)
    }

    @Test static func restartGateRequiresDurabilityAndNeverInterruptsCapture() {
        var saves = 0
        func saved() -> Bool { saves += 1; return true }
        for phase in [TalkPhase.capturing, .finalizing] {
            #expect(!Updater.canSafelyRestart(phase: phase, microphoneBusy: false, retainedText: "fictional", preserve: saved))
        }
        #expect(!Updater.canSafelyRestart(phase: .failed, microphoneBusy: true, retainedText: "fictional", preserve: saved))
        #expect(saves == 0)
        #expect(!Updater.canSafelyRestart(phase: .failed, microphoneBusy: false, retainedText: "fictional", preserve: { false }))
        #expect(Updater.canSafelyRestart(phase: .failed, microphoneBusy: false, retainedText: "fictional", preserve: saved))
        #expect(saves == 1)
    }

    @Test static func retainedDictationExplainsRestartHoldWithoutLosingInstallReply() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var mayRestart = false
        var installs = 0
        updater.canRestart = { mayRestart }
        updater.restartHoldExplanation = { "Update downloaded · pending dictation needs attention on Home" }
        updater.showReady { choice in
            #expect(choice == .install)
            installs += 1
        }
        #expect(installs == 0)
        #expect(updater.label.contains("pending dictation"))
        updater.resumeWhenIdle()
        #expect(installs == 0)
        mayRestart = true
        updater.resumeWhenIdle()
        updater.resumeWhenIdle()
        #expect(installs == 1)
        #expect(updater.label == "Restarting…")
    }

    @Test static func checkingNeverInstallsAndExplicitChoiceIsSingleUse() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var choices: [SPUUserUpdateChoice] = []
        updater.showUserInitiatedUpdateCheck(cancellation: {})
        updater.offerUpdate(version: "2", critical: false) { choices.append($0) }
        #expect(updater.available && !updater.busy && !updater.canCancel)
        #expect(choices.isEmpty)
        updater.check(); updater.check()
        #expect(choices.isEmpty && updater.available)
        updater.installAvailable(); updater.installAvailable(); updater.check()
        #expect(choices == [.install])
        #expect(!updater.available && updater.busy)
    }

    @Test static func laterAndErrorRevokePendingConsent() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var choices: [SPUUserUpdateChoice] = []
        updater.offerUpdate(version: "2", critical: true) { choices.append($0) }
        #expect(updater.available && choices.isEmpty)
        updater.dismissAvailable(); updater.dismissAvailable(); updater.installAvailable()
        #expect(choices == [.dismiss] && !updater.available)
        updater.offerUpdate(version: "3", critical: false) { choices.append($0) }
        updater.showUpdaterError(NSError(domain: "fixture", code: 2)) {}
        updater.installAvailable()
        #expect(choices == [.dismiss] && !updater.available && !updater.busy)
    }

    @Test static func manualCheckAndInstallRespectTheAgreementBoundary() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var agreed = false
        var choices: [SPUUserUpdateChoice] = []
        updater.hasAgreement = { agreed }
        updater.check(); updater.startBackgroundChecks()
        #expect(updater.label == "Agree to Terms before checking" && !updater.busy)
        updater.offerUpdate(version: "2", critical: false) { choices.append($0) }
        #expect(choices == [.dismiss] && !updater.available)
        choices = []; agreed = true
        updater.offerUpdate(version: "2", critical: false) { choices.append($0) }
        agreed = false
        updater.installAvailable()
        #expect(choices.isEmpty && updater.available && !updater.busy)
        agreed = true
        updater.installAvailable(); updater.installAvailable()
        #expect(choices == [.install] && !updater.available)
    }

    @Test static func noticeSurvivesLaterCancellationAndFailureWithoutReusingConsent() {
        let updater = Updater()
        updater.hasAgreement = { true }
        #expect(!updater.showsUpdateNotice)
        var choices: [SPUUserUpdateChoice] = []
        updater.offerUpdate(version: "2", critical: false) { choices.append($0) }
        #expect(updater.showsUpdateNotice && updater.canActOnUpdateNotice)
        updater.dismissAvailable()
        updater.dismissUpdateInstallation()
        #expect(updater.showsUpdateNotice && !updater.available)
        updater.actOnUpdateNotice() // No test-bundle configuration: cannot request or install.
        #expect(choices == [.dismiss])
        updater.offerUpdate(version: "2", critical: false) { choices.append($0) }
        updater.actOnUpdateNotice()
        #expect(choices == [.dismiss, .install])
        #expect(updater.showsUpdateNotice && !updater.canActOnUpdateNotice)
        var cancellations = 0
        updater.showDownloadInitiated { cancellations += 1 }
        updater.cancel()
        updater.dismissUpdateInstallation()
        #expect(cancellations == 1 && updater.showsUpdateNotice)
        updater.showUpdaterError(NSError(domain: "fixture", code: 3)) {}
        #expect(updater.showsUpdateNotice && updater.canActOnUpdateNotice)
        updater.showUpdateNotFoundWithError(NSError(domain: "fixture", code: 4)) {}
        #expect(!updater.showsUpdateNotice)
    }

    @Test static func noticeStaysVisibleDuringDictationAndClearsOnlyAfterInstallation() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var idle = false
        updater.canRestart = { idle }
        updater.offerUpdate(version: "2", critical: false) { _ in }
        updater.actOnUpdateNotice()
        var installs = 0
        updater.showReady { _ in installs += 1 }
        updater.actOnUpdateNotice()
        #expect(installs == 0 && updater.showsUpdateNotice && !updater.canActOnUpdateNotice)
        idle = true
        updater.resumeWhenIdle()
        #expect(installs == 1 && updater.showsUpdateNotice && updater.restarting)
        updater.showUpdateInstalledAndRelaunched(true) {}
        #expect(!updater.showsUpdateNotice)
    }

    @Test static func backgroundScheduleDelaysStartupAndCoalescesWakeAndTimer() {
        var schedule = BackgroundUpdateSchedule()
        let startup = Date(timeIntervalSince1970: 1000)
        schedule.start(now: startup)
        schedule.start(now: startup.addingTimeInterval(10)) // Startup/setup calls are idempotent.
        #expect(schedule.nextCheckAt == startup.addingTimeInterval(3))
        #expect(Bool(!schedule.beginIfDue(now: startup.addingTimeInterval(2), eligible: true)))
        let first = startup.addingTimeInterval(3)
        #expect(Bool(schedule.beginIfDue(now: first, eligible: true)))
        #expect(schedule.inFlight)
        #expect(Bool(!schedule.beginIfDue(now: first, eligible: true)))
        schedule.finish()
        #expect(Bool(!schedule.beginIfDue(now: first.addingTimeInterval(59), eligible: true)))
        #expect(Bool(schedule.beginIfDue(now: first.addingTimeInterval(60), eligible: true)))
        schedule.finish()
        let wakeAfterDays = first.addingTimeInterval(3 * 86400)
        #expect(Bool(schedule.beginIfDue(now: wakeAfterDays, eligible: true)))
        schedule.finish()
        #expect(Bool(!schedule.beginIfDue(now: wakeAfterDays, eligible: true)))
        #expect(schedule.nextCheckAt == wakeAfterDays.addingTimeInterval(60))
    }

    @Test static func blockedChecksStayDueAndSilentCompletionAllowsTheNextAttempt() {
        var schedule = BackgroundUpdateSchedule()
        let now = Date(timeIntervalSince1970: 1000)
        #expect(Bool(!schedule.beginIfDue(now: now, eligible: true))) // Never started before consent/config.
        schedule.start(now: now)
        let due = now.addingTimeInterval(3)
        #expect(Bool(!schedule.beginIfDue(now: due, eligible: false))) // Consent, active offer or Sparkle session.
        #expect(schedule.nextCheckAt == due)
        #expect(Bool(schedule.beginIfDue(now: due, eligible: true)))
        #expect(Bool(!schedule.beginIfDue(now: due.addingTimeInterval(3600), eligible: true)))
        schedule.finish() // Silent no-update/offline cycle completion.
        #expect(Bool(schedule.beginIfDue(now: due.addingTimeInterval(3600), eligible: true)))
    }

    @Test static func backgroundCompletionPreservesAnOfferAndItsExplicitConsent() {
        let updater = Updater()
        updater.hasAgreement = { true }
        var choices: [SPUUserUpdateChoice] = []
        updater.offerUpdate(version: "4", critical: false) { choices.append($0) }
        let engine = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: updater)
        // Do not start Sparkle: invoke both completion paths without network or timers.
        updater.updater(engine, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        updater.updater(engine, didFinishUpdateCycleFor: .updatesInBackground,
                        error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(updater.available && updater.showsUpdateNotice && !updater.busy)
        #expect(choices.isEmpty)
        updater.installAvailable()
        #expect(choices == [.install])
    }

    @Test @MainActor static func renderOffscreenNoticeFixture() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_UPDATE_RENDER_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let updater = Updater()
        updater.hasAgreement = { true }
        updater.offerUpdate(version: "99.0 fixture", critical: false) { _ in }
        for mode in ["available", "deferred"] {
            if mode == "deferred" {
                updater.actOnUpdateNotice()
                updater.showReady { _ in }
            }
            let view = NSHostingView(rootView: VStack(alignment: .leading) {
                Text("OFFSCREEN FIXTURE — NO LIVE UPDATE").font(.system(size: 9))
                Spacer()
                TokensLogoUpdate(updater: updater, appName: "Tokens", width: 120)
            }.padding(24).frame(width: 216, height: 240).background(Color.white))
            let rect = NSRect(x: 0, y: 0, width: 216, height: 240)
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            view.frame = rect
            try await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("update-notice-" + mode + "-fixture.png"))
            #expect(!window.isVisible)
            window.close()
        }
    }

}

