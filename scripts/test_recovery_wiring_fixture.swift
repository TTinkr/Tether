


//
/*
Source-extracted wiring with a stub surrounding model is NOT installed UI/microphone proof.
All text and identities below are fictional. Production methods are inserted unchanged.
*/
import Foundation

enum TalkPhase { case idle, capturing, finalizing, failed }
enum Diagnostics {
    static var events: [String] = []
    static func event(_ text: String) { events.append(text) }
}
struct PromptHistoryEntry: Equatable, ExpressibleByStringLiteral {
    let text: String
    let createdAt: Date
    init(stringLiteral value: String) { text = value; createdAt = Date(timeIntervalSince1970: 100) }
    init(text: String, createdAt: Date) { self.text = text; self.createdAt = createdAt }
}
enum PromptHistoryStore {
    static var rows: [PromptHistoryEntry] = ["fictional saved history"]
    static var saveCalls = 0
    static var failSave = false
    static func save(_ newRows: [PromptHistoryEntry]) throws {
        saveCalls += 1
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        rows = newRows
    }
    static func reset() { rows = ["fictional saved history"]; saveCalls = 0; failSave = false }
}
final class DeniedDirectoryManager: FileManager, @unchecked Sendable {
    var writeAttempts = 0
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        writeAttempts += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}
struct ProbeRow { let transcript: String }
struct RecoveredTalk: Equatable { let id: UUID; let text: String }
final class ProbeModel {
    var isSyntheticRun = false
    var historyRecoveryRequired = false
    var retainedFailurePayload = ""
    var retainedFailureText = ""
    var retainedSendReturn = false
    var phase = TalkPhase.idle
    var sessionID: UUID?
    var restoredRecoveryID: UUID?
    var earlierRecovery: RecoveredTalk?
    var earlierRecoveryNote: String?
    var unresolvedDiscardIDs: Set<UUID> = []
    static let discardKeptNote = "Not discarded · words kept"
    var recoveryClearRequestedAt: Date?
    var recoveryClearExempt: Set<UUID> = []
    var promptHistory: [PromptHistoryEntry] = ["fictional saved history"]
    var lastTranscriptForCopy = "fictional saved history"
    var historyStoreWritable = true
    var historyStorageError = ""
    var historyStorageNotice = ""
    var historyRecordedSessionIDs: Set<UUID> = []
    var historyRowIDs: [UUID: UUID] = [:]
    var rows: [ProbeRow] = []
    func historyPresentation(_ row: PromptHistoryEntry) -> String { row.text }
    var clearHeldWordsCalls = 0
    let transcriptRecovery: TranscriptRecoveryStore
    init(_ directory: URL, fileManager: FileManager = .default) {
        transcriptRecovery = TranscriptRecoveryStore(directory: directory, fileManager: fileManager)
    }
    func clearHeldWords() { clearHeldWordsCalls += 1 }
/* PRODUCTION_METHODS */
}
struct FailedCheck: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw FailedCheck(description: message) }
}
let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let newestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
let held = "fictional retained words"
func seed(_ store: TranscriptRecoveryStore, _ id: UUID, _ text: String, _ date: Double = 100,
          _ state: TranscriptRecoveryState = .held) throws {
    try store.checkpoint(sessionID: id, text: text, state: state, at: Date(timeIntervalSince1970: date))
}

//
// :)
//
//
func journal(_ directory: URL) -> URL { directory.appendingPathComponent(TranscriptRecoveryStore.filename) }
func ids(_ store: TranscriptRecoveryStore) throws -> Set<UUID> { Set(try store.recover().map(\.id)) }
func restored(_ model: ProbeModel) {
    model.restoredRecoveryID = olderID
    model.retainedFailurePayload = held
    model.retainedFailureText = "fictional recovery label"
    model.retainedSendReturn = true
    model.lastTranscriptForCopy = held
}
@main struct RecoveryWiringChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokens-fictional-wiring-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [[String: Any]] = []
        func check(_ name: String, _ body: (URL) throws -> Void) {
            PromptHistoryStore.reset(); Diagnostics.events = []; HistoryRowsOnDisk.replace(with: [])
            let directory = root.appendingPathComponent("case-\(results.count)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try body(directory)
                results.append(["case": name, "passed": true])
            } catch { results.append(["case": name, "passed": false, "error": String(describing: error)]) }
        }
        check("corrupt journal preflight preserves history and reports no deletion") { directory in
            let damaged = Data("{ fictional damaged journal".utf8)
            try damaged.write(to: journal(directory))
            let model = ProbeModel(directory)
            model.clearPromptHistory()
            try expect(PromptHistoryStore.saveCalls == 0, "history save ran before failed preflight")
            try expect(model.promptHistory == PromptHistoryStore.rows, "memory changed before save")
            try expect(try Data(contentsOf: journal(directory)) == damaged, "damaged bytes changed")
            try expect(model.historyStorageNotice.isEmpty && model.historyStorageError.contains("Nothing was deleted"), "false success on preflight failure")
        }
        check("successful recovered-launch clear removes all copy payload and held presentation") { directory in
            let model = ProbeModel(directory); try seed(model.transcriptRecovery, olderID, held); restored(model)
            model.clearPromptHistory()
            try expect(try model.transcriptRecovery.recover().isEmpty, "recovered journal remains")
            try expect(model.restoredRecoveryID == nil && model.retainedFailurePayload.isEmpty && model.retainedFailureText.isEmpty,
                       "deleted launch words remain held")
            try expect(!model.retainedSendReturn && model.lastTranscriptForCopy.isEmpty && model.clearHeldWordsCalls == 1,
                       "deleted launch copy/UI state remains")
            try expect(model.latestTranscript.isEmpty, "actual Copy latest still returns cleared recovered words")
            try expect(model.historyStorageNotice == "History cleared." && model.historyStorageError.isEmpty, "success missing")
        }
        check("startup chooses newest but preserves older unresolved journals byte for byte") { directory in
            let model = ProbeModel(directory)
            try seed(model.transcriptRecovery, olderID, "fictional older", 100)
            try seed(model.transcriptRecovery, newestID, "fictional newest", 200)
            let before = try Data(contentsOf: journal(directory)); model.restoreTranscriptRecovery()
            try expect(model.restoredRecoveryID == newestID && model.retainedFailurePayload == "fictional newest", "newest not offered")
            try expect(model.lastTranscriptForCopy == "fictional newest", "copy candidate not set")
            try expect(try Data(contentsOf: journal(directory)) == before && ids(model.transcriptRecovery) == [olderID, newestID], "startup deleted recovery")
        }
        check("A failed, B succeeded, relaunch: Copy latest is B and A stays reachable as an earlier talk") { directory in
            let model = ProbeModel(directory)
            try seed(model.transcriptRecovery, olderID, "fictional unsent A", 100)
            let b = PromptHistoryEntry(stringLiteral: "fictional delivered B")
            model.promptHistory = [PromptHistoryEntry(text: b.text, createdAt: Date(timeIntervalSince1970: 300))]
            model.lastTranscriptForCopy = ""
            let before = try Data(contentsOf: journal(directory)); model.restoreTranscriptRecovery()
            try expect(model.earlierRecovery == RecoveredTalk(id: olderID, text: "fictional unsent A"), "earlier unsent words unreachable")
            try expect(model.restoredRecoveryID == nil && model.retainedFailurePayload.isEmpty, "earlier words outrank the newest talk")
            try expect(model.latestTranscript == "fictional delivered B", "Copy latest is not the newest talk")
            try expect(try Data(contentsOf: journal(directory)) == before, "startup changed the journal")
        }
        check("A and C failed, B succeeded: C offered first, then A once C is handled") { directory in
            let model = ProbeModel(directory)
            let cID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            try seed(model.transcriptRecovery, olderID, "fictional unsent A", 100)
            try seed(model.transcriptRecovery, cID, "fictional unsent C", 200)
            model.promptHistory = [PromptHistoryEntry(text: "fictional delivered B", createdAt: Date(timeIntervalSince1970: 300))]
            model.lastTranscriptForCopy = ""
            model.restoreTranscriptRecovery()
            try expect(model.earlierRecovery?.id == cID, "newest earlier talk C not offered first")
            try model.transcriptRecovery.resolve(sessionID: cID)
            model.refreshEarlierRecovery()
            try expect(model.earlierRecovery == RecoveredTalk(id: olderID, text: "fictional unsent A"), "A not promoted after C")
            try model.transcriptRecovery.resolve(sessionID: olderID)
            model.refreshEarlierRecovery()
            try expect(model.earlierRecovery == nil && model.latestTranscript == "fictional delivered B", "offer not cleared")
        }
        check("two discards the journal could not record: each stays offered until handled, with its note") { directory in
            let model = ProbeModel(directory)
            let d0 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!
            let d1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
            // Both newer than the newest History talk (a discard writes no History row).
            try seed(model.transcriptRecovery, d0, "fictional discarded D0", 400, .capturing)
            try seed(model.transcriptRecovery, d1, "fictional discarded D1", 500, .capturing)
            model.promptHistory = [PromptHistoryEntry(text: "fictional delivered B", createdAt: Date(timeIntervalSince1970: 300))]
            model.unresolvedDiscardIDs = [d0, d1]
            model.refreshEarlierRecovery()
            try expect(model.earlierRecovery?.id == d1 && model.earlierRecoveryNote == ProbeModel.discardKeptNote, "newest unrecorded discard not offered")
            try model.transcriptRecovery.resolve(sessionID: d1)
            model.refreshEarlierRecovery()
            try expect(model.earlierRecovery == RecoveredTalk(id: d0, text: "fictional discarded D0")
                       && model.earlierRecoveryNote == ProbeModel.discardKeptNote, "first unrecorded discard hidden after the second was forgotten")
            try model.transcriptRecovery.resolve(sessionID: d0)
            model.refreshEarlierRecovery()
            try expect(model.earlierRecovery == nil && model.earlierRecoveryNote == nil && model.unresolvedDiscardIDs.isEmpty, "handled discards still offered")
        }
        check("empty history and absent journal clear successfully") { directory in
            let model = ProbeModel(directory); model.promptHistory = []; PromptHistoryStore.rows = []
            model.clearPromptHistory()
            try expect(PromptHistoryStore.saveCalls == 1 && model.promptHistory.isEmpty, "empty clear failed")
            try expect(model.historyStorageNotice == "History cleared." && model.historyStorageError.isEmpty, "empty clear not successful")
        }
        check("empty startup recovery has no copy offer or file write") { directory in
            let model = ProbeModel(directory); model.lastTranscriptForCopy = ""
            model.restoreTranscriptRecovery()
            try expect(model.restoredRecoveryID == nil && model.retainedFailurePayload.isEmpty, "empty startup fabricated words")
            try expect(!FileManager.default.fileExists(atPath: journal(directory).path), "startup created journal")
        }
        for synthetic in [true, false] {
            check(synthetic ? "synthetic clear is guarded" : "unreadable-history clear is guarded") { directory in
                let model = ProbeModel(directory); try seed(model.transcriptRecovery, olderID, held); restored(model)
                model.isSyntheticRun = synthetic; model.historyRecoveryRequired = !synthetic
                let before = try Data(contentsOf: journal(directory)); model.clearPromptHistory()
                try expect(PromptHistoryStore.saveCalls == 0 && model.promptHistory == ["fictional saved history"], "guard cleared history")
                try expect(try Data(contentsOf: journal(directory)) == before, "guard mutated journal")
                try expect(model.retainedFailurePayload == held && model.clearHeldWordsCalls == 0, "guard discarded held words")
            }
        }
        for capturing in [true, false] {
            check(capturing ? "capturing checkpoint survives history clear" : "finalizing checkpoint survives history clear") { directory in
                let model = ProbeModel(directory); model.phase = capturing ? .capturing : .finalizing; model.sessionID = currentID
                try seed(model.transcriptRecovery, olderID, "fictional old")
                try seed(model.transcriptRecovery, currentID, "fictional current", 200, capturing ? .capturing : .stopped)
                model.clearPromptHistory()
                try expect(try ids(model.transcriptRecovery) == [currentID], "active checkpoint missing or old checkpoint retained")
                try expect(model.promptHistory.isEmpty && model.historyStorageNotice == "History cleared.", "history clear failed")
            }
        }
        check("current failed paste payload survives successful history clear") { directory in
            let model = ProbeModel(directory); model.phase = .failed; model.sessionID = currentID
            model.retainedFailurePayload = held; model.retainedFailureText = "fictional failed paste"; model.retainedSendReturn = true
            try seed(model.transcriptRecovery, currentID, held); try seed(model.transcriptRecovery, olderID, "fictional old")
            model.clearPromptHistory()
            try expect(try ids(model.transcriptRecovery) == [currentID], "current failed checkpoint missing")
            try expect(model.retainedFailurePayload == held && model.retainedFailureText == "fictional failed paste" && model.retainedSendReturn,
                       "current failed state discarded")
            try expect(model.lastTranscriptForCopy == held && model.clearHeldWordsCalls == 0, "current held presentation discarded")
            try expect(model.latestTranscript == held, "actual Copy latest lost current failed paste")
        }
        check("valid current identity does not retain older duplicate matching text") { directory in
            let model = ProbeModel(directory); model.sessionID = currentID; model.retainedFailurePayload = held
            try seed(model.transcriptRecovery, currentID, held); try seed(model.transcriptRecovery, olderID, held)
            model.clearPromptHistory()
            try expect(try ids(model.transcriptRecovery) == [currentID], "duplicate older identity retained by text match")
        }
        check("missing current identity falls back only to exact held text") { directory in
            let model = ProbeModel(directory); model.retainedFailurePayload = held
            try seed(model.transcriptRecovery, currentID, held); try seed(model.transcriptRecovery, olderID, "fictional unrelated")
            model.clearPromptHistory()
            try expect(try ids(model.transcriptRecovery) == [currentID], "held text fallback lost or over-retained entries")
        }
        check("history save failure preserves journal, memory, identity and copy state") { directory in
            let model = ProbeModel(directory); try seed(model.transcriptRecovery, olderID, held); restored(model)
            model.historyRecordedSessionIDs = [olderID]; PromptHistoryStore.failSave = true
            let before = try Data(contentsOf: journal(directory)); model.clearPromptHistory()
            try expect(PromptHistoryStore.saveCalls == 1 && PromptHistoryStore.rows == ["fictional saved history"], "unexpected history write")
            try expect(model.promptHistory == PromptHistoryStore.rows && model.historyRecordedSessionIDs == [olderID], "memory cleared despite save failure")
            try expect(try Data(contentsOf: journal(directory)) == before, "journal changed despite save failure")
            try expect(model.restoredRecoveryID == olderID && model.retainedFailurePayload == held && model.lastTranscriptForCopy == held,
                       "copy state lost despite failure")
            try expect(model.historyStorageNotice.isEmpty && model.historyStorageError.contains("Nothing was deleted"), "save failure gave deletion claim")
        }
        check("real journal write path failure reports partial cleanup and preserves held recovery") { directory in
            let seedStore = TranscriptRecoveryStore(directory: directory); try seed(seedStore, olderID, held)
            let denied = DeniedDirectoryManager(); let model = ProbeModel(directory, fileManager: denied); restored(model)
            model.historyRecordedSessionIDs = [olderID]
            let before = try Data(contentsOf: journal(directory)); model.clearPromptHistory()
            try expect(denied.writeAttempts == 1, "actual recovery write was not attempted")
            try expect(PromptHistoryStore.rows.isEmpty && model.promptHistory.isEmpty && model.historyRecordedSessionIDs.isEmpty,
                       "saved history and memory disagree")
            try expect(try Data(contentsOf: journal(directory)) == before, "failed journal write damaged bytes")
            try expect(model.restoredRecoveryID == olderID && model.retainedFailurePayload == held && model.lastTranscriptForCopy == held && model.retainedSendReturn,
                       "partial failure destroyed recovery state")
            try expect(model.clearHeldWordsCalls == 0 && model.historyStorageNotice.isEmpty && model.historyStorageError.contains("Saved history was cleared, but recovery data could not be cleared"),
                       "partial failure falsely reported complete success")
        }
        check("new-talk preparation clears presentation identity without resolving recovery file") { directory in
            let model = ProbeModel(directory); try seed(model.transcriptRecovery, olderID, held); restored(model)
            let before = try Data(contentsOf: journal(directory)); model.prepareRecoveredWordsForNewTalk()
            try expect(model.restoredRecoveryID == nil, "presentation identity not cleared")
            try expect(try Data(contentsOf: journal(directory)) == before, "new talk resolved undelivered recovery")
            try expect(model.retainedFailurePayload == held && PromptHistoryStore.saveCalls == 0, "helper changed unrelated state")
        }
        check("startup corrupt journal preserves bytes and explains recovery error") { directory in
            let damaged = Data("{ fictional unreadable recovery".utf8); try damaged.write(to: journal(directory))
            let model = ProbeModel(directory); model.restoreTranscriptRecovery()
            try expect(try Data(contentsOf: journal(directory)) == damaged, "startup overwrote corrupt recovery")
            try expect(model.restoredRecoveryID == nil && model.retainedFailurePayload.isEmpty && !model.historyStorageError.isEmpty,
                       "startup fabricated recovery or hid failure")
        }
        /*
        Codex RC3 review (build 81): the production checkpointTranscript with History never saved.
        51 talks end with a posted but unconfirmed paste; a fresh journal read from disk after a
        relaunch still holds every text, and the next talk's write trims none of them.
        */
        check("history write failure: 51 unconfirmed talks all survive a relaunch") { directory in
            let model = ProbeModel(directory)
            var texts: [String] = []
            for index in 0..<(TranscriptRecoveryStore.sentEntryLimit + 1) {
                let session = UUID()
                model.historyRowIDs[session] = UUID()
                let text = "fictional unconfirmed talk \(index)"
                model.checkpointTranscript(text, session: session, state: .deliveryUncertain)
                texts.append(text)
            }
            try expect(model.historyStorageError.isEmpty, "a checkpoint failed")
            let relaunched = TranscriptRecoveryStore(directory: directory)
            try relaunched.checkpoint(sessionID: UUID(), text: "fictional next talk", state: .capturing)
            let entries = try relaunched.recover()
            try expect(entries.count == texts.count + 1 && Set(texts).isSubset(of: Set(entries.map(\.text))),
                       "unconfirmed words were trimmed")
            try expect(entries.filter { $0.state == .deliveryUncertain }.allSatisfy { $0.historyEntryID != nil },
                       "checkpointTranscript dropped the History row id")
        }
        check("checkpointTranscript trims only talks whose History row landed on disk") { directory in
            let model = ProbeModel(directory)
            var sessions: [UUID] = []
            for index in 0..<(TranscriptRecoveryStore.sentEntryLimit + 1) {
                let session = UUID()
                model.historyRowIDs[session] = UUID()
                // What PromptHistoryStore.save reports after a History write lands.
                HistoryRowsOnDisk.replace(with: model.historyRowIDs.values)
                model.checkpointTranscript("fictional saved talk \(index)", session: session, state: .deliveryUncertain)
                sessions.append(session)
            }
            let kept = try ids(model.transcriptRecovery)
            try expect(kept.count == TranscriptRecoveryStore.sentEntryLimit && !kept.contains(sessions[0]),
                       "the bound did not trim the oldest saved talk")
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if results.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
}

