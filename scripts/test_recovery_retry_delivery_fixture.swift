


//
// Actual extracted wiring with fictional collaborators is NOT installed UI/microphone proof.
import Foundation
enum TalkPhase { case idle, capturing, finalizing, failed, delivered }
enum Diagnostics { static func event(_ text: String) {} }
struct AuthoredPrompt {
    let transcript: String
    let spokenText: String
    var text: String { transcript }
    var isEmpty: Bool { text.isEmpty }
    var spokenWordCount: Int { spokenText.split(separator: " ").count }
}
// Stands in for TokensCore's PromptTargetApp (the app in front at Stop, kept with a History row).
struct PromptTargetApp: Equatable {
    let bundleID: String
    let name: String?
    init?(bundleID: String?, name: String?) {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        self.bundleID = bundleID; self.name = name
    }
}
struct PromptHistoryEntry {
    let id: UUID
    let createdAt: Date
    let authored: AuthoredPrompt
    var targetApp: PromptTargetApp? = nil
    var text: String { authored.text }
}
// The real Tokens app is always the public launch build (TokensApp.swift).
let publicTokens = true
// The extracted extension refers to its own type by name (TalkModel.keptInAppMessage).
typealias TalkModel = ProbeModel
enum PromptHistoryStore {
    static var rows: [PromptHistoryEntry] = []
    static var failSave = false
    static var saveCalls = 0
    static var onSave: (() throws -> Void)?
    static func save(_ newRows: [PromptHistoryEntry]) throws {
        saveCalls += 1; try onSave?()
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        rows = newRows
    }
    static func load() throws -> [PromptHistoryEntry] { rows }
    static func recoverPreservingSource(with rows: [PromptHistoryEntry]) throws -> URL? { try save(rows); return nil }
    static func reset() { rows = []; failSave = false; saveCalls = 0; onSave = nil }
}
final class ToggleDirectoryManager: FileManager, @unchecked Sendable {
    var denied = false
    var attempts = 0
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        attempts += 1
        if denied { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
enum BrandVocabulary { static func apply(to text: String) -> String { text } }
// requiresReview is the only segment field delivery reads; these talks never need review.
struct CompletedSegment { var requiresReview = false }
struct Rendered { let markdownText: String; let deliveryText: String }
// Reveal pacing and the opt-in metadata footer are presentation. With metadata off (the
// default, and these cases) the real TokensOutputOptions.parts returns the words unchanged.
struct TranscriptRevealPlan {}
struct TokensPromptParts {
    let text: String
    func revealPlan(spokenWordCount: Int) -> TranscriptRevealPlan { TranscriptRevealPlan() }
}
enum TokensOutputOptions {
    static func parts(_ rendered: String, metadata: Bool) -> TokensPromptParts { TokensPromptParts(text: rendered) }
}
// Stop-time streamed prefix state; these cases never streamed a prefix before Stop.
struct StopStreamProbe {
    var prefix: String? = nil
    var frozenTitle: String? = nil
    var stoppedText = ""
}
struct RecoveredTalk { let id: UUID; let text: String }
enum CharacterTalk { static func render(_ text: String) -> Rendered { Rendered(markdownText: text, deliveryText: text) } }
enum InlineTalkMarkdown {
    static func authoredPrompt(_ text: String, spokenText: String) -> AuthoredPrompt {
        AuthoredPrompt(transcript: text, spokenText: spokenText)
    }
}
enum TinkeringSection { static func appending(_ section: String?, to text: String) -> String { text } }
enum StagedPrompt {
    static func render(body: String, duration: Double, frozenHeader: String?) -> String { body }
    static func remainder(final: String, committed: String) -> String? { final }
}
// The captured Stop target; delivery reads only its app's identity for the History row.
struct FakeApplication { var bundleIdentifier: String? = "com.example.fictional"; var localizedName: String? = "Fictional" }
struct FakeTarget { var application = FakeApplication() }
enum DeliveryOutcome: Equatable { case verified, delivered, notObserved, failed(String) }
enum TargetDelivery {
    static var outcome = DeliveryOutcome.verified
    static var insertCalls = 0
    static var returnCalls = 0
    // Async since build 81 (acknowledged reveal); the outcome is controlled per case.
    @MainActor static func insert(_ text: String, into target: FakeTarget, latencyStartUptime: TimeInterval?,
                                  threeSteps: Bool, revealPlan: TranscriptRevealPlan? = nil,
                                  textReadyUptime: TimeInterval? = nil,
                                  isCurrent: @escaping () -> Bool = { true }) async -> DeliveryOutcome {
        insertCalls += 1; return outcome
    }
    static func appendVerified(_ text: String, to target: FakeTarget) -> FakeTarget? { target }
    static func sendReturn(to target: FakeTarget) -> Bool { returnCalls += 1; return true }
}
final class InputProbe {
    var hasReservedReturn = false
    var finished = 0
    func finishReturnReservation() { finished += 1 }
}
struct PauseProbe { func stop() -> Bool { true } }
struct ProbeRow { let transcript: String }
final class ProbeModel {

//
// :)
//
//
    var isSyntheticRun = false
    var historyRecoveryRequired = false
    var retainedFailurePayload = ""
    var retainedFailureText = ""
    var retainedSendReturn = false
    var phase = TalkPhase.idle
    var sessionID: UUID?
    var restoredRecoveryID: UUID?
    var recoveryClearRequestedAt: Date?
    var recoveryClearExempt: Set<UUID> = []
    var promptHistory: [PromptHistoryEntry] = []
    var historyRecordedSessionIDs: Set<UUID> = []
    var historyRowIDs: [UUID: UUID] = [:]
    var earlierRecovery: RecoveredTalk?
    var historyStoreWritable = true
    var historyStorageError = ""
    var historyStorageNotice = ""
    var historyExpanded = false
    var onHistoryExpansionChange: ((Bool) -> Void)?
    var lastTranscriptForCopy = ""
    var rows: [ProbeRow] = []
    var clearHeldWordsCalls = 0
    var completedSessionIDs: Set<UUID> = []
    var input = InputProbe()
    var stagedCommitted: String?
    var stagedHeader: String?
    var stagedFailed = false
    var frozenRecordingDurationSeconds: Double?
    var thinkingExperience = false
    var metadataEnabled = false
    var thinkingMetadataEnabled: Bool { thinkingExperience && metadataEnabled }
    var tokensWindowIsFrontmost = false
    var stopStream = StopStreamProbe()
    var selectedProduct = "Tokens"
    var pauseAsides = PauseProbe()
    var displayText = ""
    var displayStableWordCount = 0
    var target: FakeTarget? = FakeTarget()
    static let threeStepPasteEnabled = false
    var dailyDeliveryNotice = ""
    var celebrations = 0
    var recoveryOverlay = false
    var recoveryWindow = false
    var surfaceHidden = false
    let transcriptRecovery: TranscriptRecoveryStore
    init(_ directory: URL, manager: FileManager = .default) {
        transcriptRecovery = TranscriptRecoveryStore(directory: directory, fileManager: manager)
    }
    func clearHeldWords() { clearHeldWordsCalls += 1 }
    func historyPresentation(_ entry: PromptHistoryEntry) -> String { entry.text }
    func thinkingPayload(raw: String, segment: CompletedSegment, durationSeconds: Double, titleOverride: String? = nil) -> String { raw }
    // No prefix was streamed at Stop, so the real method returns nil and the full paste runs.
    func deliverStreamedRemainder(_ payload: String, into destination: FakeTarget, latencyStartUptime: TimeInterval?,
                                  revealPlan: TranscriptRevealPlan? = nil, session: UUID) async -> DeliveryOutcome? {
        stopStream.prefix == nil ? nil : .failed("partial_fixture_streamed_prefix_unsupported")
    }
    func renderTranscript(_ text: String, durationSeconds: Double, includePlainMetadata: Bool) -> String { text }
    func shouldDecorateDelivery(session: UUID) -> Bool { false }
    func logStopTiming(stage: String, session: UUID) {}
    func hideSurface() { surfaceHidden = true }
    func resetSession() {}
    func recordVerifiedAllowance(session: UUID, wasClean: Bool) {}
    func celebrateDelivery(session: UUID) { celebrations += 1; phase = .delivered }
    func retainForRecovery(_ text: String, authored: AuthoredPrompt? = nil, message: String,
                           sendReturn: Bool = false, shouldRecordHistory: Bool = true,
                           showOverlay: Bool = true, holdWords: Bool = false, showRecoveryWindow: Bool = true) {
        retainedFailurePayload = text
        recoveryOverlay = showOverlay
        recoveryWindow = showOverlay && showRecoveryWindow
        phase = .failed
    }
/* EXTRACTED_PRODUCTION */
}
struct Failure: Error, CustomStringConvertible { let description: String }
func expect(_ value: @autoclosure () throws -> Bool, _ why: String) throws {
    if try !value() { throw Failure(description: why) }
}
let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let sparedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
let words = "fictional delivery words"
func seed(_ model: ProbeModel, _ id: UUID, at date: Date = Date(timeIntervalSince1970: 100), text: String = words) throws {
    try model.transcriptRecovery.checkpoint(sessionID: id, text: text, state: .held, at: date)
}
func identifiers(_ model: ProbeModel) throws -> Set<UUID> { Set(try model.transcriptRecovery.recover().map(\.id)) }
/// deliver(...) only claims the talk and queues its delivery on the main actor (build 81).
/// Wait for that task's deferred Return-reservation release, then give any duplicate task
/// time to run too, so the once-only checks still see every effect.
@MainActor func settleDelivery(_ model: ProbeModel) async throws {
    let deadline = Date().addingTimeInterval(2)
    while model.input.finished == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    try await Task.sleep(nanoseconds: 50_000_000)
}
func pending(_ directory: URL) throws -> (ProbeModel, ToggleDirectoryManager) {
    let manager = ToggleDirectoryManager(); let model = ProbeModel(directory, manager: manager)
    try seed(model, oldID); model.restoredRecoveryID = oldID
    model.retainedFailurePayload = words; model.lastTranscriptForCopy = words
    manager.denied = true; model.clearPromptHistory()
    return (model, manager)
}

//
// :)
//
//
@main struct Checks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fictional-retry-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [[String: Any]] = []
        func check(_ name: String, _ block: (URL) async throws -> Void) async {
            PromptHistoryStore.reset(); TargetDelivery.insertCalls = 0; TargetDelivery.returnCalls = 0
            do {
                let directory = root.appendingPathComponent("case-\(results.count)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await block(directory); results.append(["case": name, "passed": true])
            } catch { results.append(["case": name, "passed": false, "error": String(describing: error)]) }
        }
        await check("reachable Retry completes original journal clear after history already empty") { directory in
            let (model, manager) = try pending(directory)
            try expect(model.promptHistory.isEmpty && !model.historyStorageError.isEmpty, "partial-clear setup failed")
            manager.denied = false; model.retryPromptHistoryStorage()
            try expect(try identifiers(model).isEmpty, "Retry reported restoration but left old recovery journal")
            try expect(model.historyStorageError.isEmpty && model.latestTranscript.isEmpty, "Retry did not complete recovered copy cleanup")
        }
        await check("Retry failure retains pending error instead of falsely clearing it") { directory in
            let (model, _) = try pending(directory); model.retryPromptHistoryStorage()
            try expect(!model.historyStorageError.isEmpty && model.historyStorageNotice.isEmpty, "Retry hid failed journal clear")
            try expect(try identifiers(model) == [oldID], "failed Retry lost old recovery")
        }
        await check("later record-save cannot hide pending journal-clear failure") { directory in
            let (model, _) = try pending(directory)
            model.recordPromptHistory(AuthoredPrompt(transcript: "fictional later", spokenText: "fictional later"), session: newID)
            try expect(!model.historyStorageError.isEmpty && model.historyStorageNotice.isEmpty, "new history save hid pending clear error")
            try expect(try identifiers(model) == [oldID], "record unexpectedly removed pending journal")
        }
        for capturing in [true, false] {
            await check(capturing ? "Retry preserves click-time active session after finish and newer sessions" : "Retry preserves click-time held session after dismissal and newer sessions") { directory in
                let manager = ToggleDirectoryManager(); let model = ProbeModel(directory, manager: manager)
                try seed(model, oldID, text: "fictional obsolete")
                try seed(model, sparedID, text: "fictional spared")
                model.sessionID = sparedID
                model.phase = capturing ? .capturing : .failed
                if !capturing { model.retainedFailurePayload = "fictional spared" }
                manager.denied = true; model.clearPromptHistory()
                let cutoff = model.recoveryClearRequestedAt ?? Date()
                manager.denied = false
                try seed(model, newID, at: cutoff.addingTimeInterval(2), text: "fictional new")
                model.phase = .idle; model.sessionID = newID
                model.retainedFailurePayload = "fictional new"; model.lastTranscriptForCopy = "fictional new"
                model.retryPromptHistoryStorage()
                try expect(try identifiers(model) == [sparedID, newID], "Retry lost click-time/new sessions or retained obsolete journal")
                try expect(model.latestTranscript == "fictional new", "Retry erased newer Copy latest words")
            }
        }
        await check("Retry conservatively preserves same-second new checkpoint") { directory in
            let (model, manager) = try pending(directory); let cutoff = model.recoveryClearRequestedAt ?? Date()
            manager.denied = false
            try seed(model, newID, at: Date(timeIntervalSince1970: cutoff.timeIntervalSince1970.rounded(.down)), text: "fictional same second")
            model.restoredRecoveryID = nil; model.retainedFailurePayload = ""; model.lastTranscriptForCopy = "fictional same second"
            model.retryPromptHistoryStorage()
            try expect(try identifiers(model) == [newID], "same-second checkpoint lost or obsolete checkpoint retained")
            try expect(model.latestTranscript == "fictional same second", "new latest words erased")
        }
        await check("new recorded talk remains Copy latest after pending-clear Retry") { directory in
            let (model, manager) = try pending(directory)
            model.recordPromptHistory(AuthoredPrompt(transcript: "fictional newly recorded", spokenText: "fictional newly recorded"), session: newID)
            model.lastTranscriptForCopy = "fictional newly recorded"
            manager.denied = false; model.retryPromptHistoryStorage()
            try expect(try identifiers(model).isEmpty, "old recovered journal was not removed")
            try expect(model.promptHistory.count == 1 && model.latestTranscript == "fictional newly recorded", "Retry erased newer recorded copy words")
            try expect(model.historyStorageError.isEmpty, "Retry left error after successful completion")
        }
        for outcomeName in ["verified", "opaque", "missed", "partial"] {
            let verified = outcomeName == "verified"
            for saveFails in [false, true] {
                await check("\(outcomeName) delivery \(saveFails ? "save failure retains recovery" : "saves exactly once; only verified can send and resolve")") { directory in
                    let model = ProbeModel(directory); model.sessionID = newID; model.phase = .finalizing
                    try seed(model, newID)
                    TargetDelivery.outcome = verified ? .verified : outcomeName == "opaque" ? .delivered : outcomeName == "missed" ? .notObserved : .failed("partial_final_unacknowledged")
                    model.input.hasReservedReturn = true
                    var journalPresentWhenSaving: [Bool] = []
                    PromptHistoryStore.onSave = { journalPresentWhenSaving.append(try identifiers(model).contains(newID)) }
                    PromptHistoryStore.failSave = saveFails
                    model.deliver(session: newID, payload: words, segment: CompletedSegment(), sendReturn: true,
                                  latencyStartUptime: nil, tinkeringSection: nil)
                    model.deliver(session: newID, payload: words, segment: CompletedSegment(), sendReturn: true,
                                  latencyStartUptime: nil, tinkeringSection: nil)
                    try await settleDelivery(model)
                    try expect(journalPresentWhenSaving == [true], "journal resolved before actual history save attempt")
                    try expect(PromptHistoryStore.saveCalls == 1 && model.promptHistory.count == 1 && model.historyRecordedSessionIDs == [newID], "record/defer duplicated history")
                    try expect(TargetDelivery.insertCalls == 1 && TargetDelivery.returnCalls == (verified ? 1 : 0) && model.input.finished == 1, "duplicate effects or unacknowledged text submitted")
                    try expect(try identifiers(model).contains(newID) == (!verified || saveFails), "unconfirmed delivery resolved recovery or history save failure lost it")
                    if !verified {
                        try expect(model.retainedFailurePayload == words && model.celebrations == 0, "uncertain delivery discarded words or claimed success")
                    }
                    if outcomeName == "opaque" {
                        try expect(!model.recoveryOverlay && !model.recoveryWindow && model.surfaceHidden && model.phase == .idle,
                                   "opaque accepted text leaves a persistent failure overlay")
                    }
                    if outcomeName == "missed" {
                        try expect(model.recoveryOverlay && model.recoveryWindow && model.phase == .failed,
                                   "observed miss did not expose full recovery")
                    }
                    try expect(PromptHistoryStore.rows.count == (saveFails ? 0 : 1), "saved rows disagree with result")
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print("RECOVERY_RESULT_JSON=" + String(decoding: data, as: UTF8.self))
        if results.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}

