


//
import Foundation


// TranscriptRecoveryState — Where a talk's text stands before its delivery is known done


/// The durable state of recognized text which has not yet reached a known
/// terminal delivery outcome. This deliberately contains only recognized
/// text and delivery state: never microphone samples, target details, keys,
/// or an instruction to replay a paste/send.
enum TranscriptRecoveryState: String, Codable, Equatable {
    /// A bounded live checkpoint captured while recognition is still active.
    /// Recovery may offer Copy only; it never resumes capture or replays delivery.
    case capturing
    /// Stop was requested and the five-second finish gate is running.
    case stopped
    /// A later ASR result replaced the stop snapshot while still awaiting delivery.
    case finalTextReady
    /// No eligible target was available, so the user must explicitly copy text.
    case held
    /// A paste or Return was dispatched but the destination did not verify it.
    case deliveryUncertain
    /// The local model/finalization path timed out before a known delivery result.
    case modelTimedOut
}


// TranscriptRecoveryEntry — One talk's saved text, its state, and its two timestamps


// `id` is the talk's session id, which is how later calls find and replace the same entry.
struct TranscriptRecoveryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var state: TranscriptRecoveryState
    let createdAt: Date
    var updatedAt: Date
    /*
    The History row made for this talk, when it has one (build 81). It is only a pointer: the
    entry is trimmed only while HistoryRowsOnDisk confirms that row is in the saved History file.
    Journals written before build 81 have no pointer, so their entries are never trimmed; older
    builds ignore the extra key.
    */
    var historyEntryID: UUID? = nil
}


// TranscriptRecoveryJournal — The file as stored: a version number and the list of entries


// Only version 1 is understood; recover() treats any other number as a corrupt file.
struct TranscriptRecoveryJournal: Codable {
    let version: Int
    let entries: [TranscriptRecoveryEntry]
}


// TranscriptRecoveryStore — A small local crash-recovery journal for raw recognized text


/// A small local crash-recovery journal for raw recognized text.
///
/// The caller must persist a stop snapshot before it starts any finish timer.
/// The journal has no pasteboard or target API by design. Loading an entry is
/// only enough to offer a visible, explicit Copy action in the app layer.
struct TranscriptRecoveryStore {


    // Setup and reading — init and recover()


    static let filename = "recognized-transcript-recovery.json"

    /*
    How many sent-but-unconfirmed talks (deliveryUncertain) whose words are already saved in
    History the file keeps, newest first (build 81). A posted paste is not proof the words
    arrived, and a History save can fail, so an entry is trimmable only while its History row
    is confirmed on disk (HistoryRowsOnDisk); every other entry stays until it is resolved or
    explicitly discarded (Codex RC3 review). Unbounded, the file reached 561 entries (443 KB)
    in three weeks, and every checkpoint read and rewrote all of it.
    */
    static let sentEntryLimit = 50

    private let url: URL
    private let fileManager: FileManager
    private let io = JournalIO()
    /// Whether a History row is confirmed in the saved History file. Tests pass their own.
    private let historyHolds: (UUID) -> Bool

    init(directory: URL, fileManager: FileManager = .default,
         historyHolds: @escaping (UUID) -> Bool = HistoryRowsOnDisk.contains) {
        self.url          = directory.appendingPathComponent(Self.filename, isDirectory: false)
        self.fileManager  = fileManager
        self.historyHolds = historyHolds
    }

//
// :)
//
//
    /// Reads recoverable entries without performing any delivery side effect.
    /// No file yet gives an empty list; an unreadable file or a version other than 1 throws.
    /// checkpoint() and resolve() both start by calling this, so a damaged journal makes them
    /// throw as well rather than overwrite it.
    func recover() throws -> [TranscriptRecoveryEntry] {
        try io.sync {
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            let data = try PrivateFileStore.read(from: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let journal = try decoder.decode(TranscriptRecoveryJournal.self, from: data)
            guard journal.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return journal.entries
        }
    }


    // Saving and clearing entries — checkpoint(), resolve(), copyCandidate(), discard(), write()


    /// The exact recognized string is written unchanged. Empty recognition is
    /// not recoverable text and intentionally produces no journal entry.
    /// A session that already has an entry is updated in place (new text, state, History
    /// pointer and `updatedAt`; `createdAt` stays); a new session is added. Returns whether
    /// anything was saved. A checkpoint without `historyEntryID` clears an older pointer, so
    /// the entry is kept rather than trimmed on a stale promise.
    @discardableResult
    func checkpoint(
        sessionID: UUID,
        text: String,
        state: TranscriptRecoveryState,
        historyEntryID: UUID? = nil,
        at date: Date = Date()
    ) throws -> Bool {
        guard !text.isEmpty else { return false }
        return try io.sync {
            // A later state closes the talk to live snapshots still waiting (see checkpointInBackground).
            if state != .capturing { io.sealed.insert(sessionID) }
            var entries = try recover()
            if let index = entries.firstIndex(where: { $0.id == sessionID }) {
                entries[index].text = text
                entries[index].state = state
                entries[index].updatedAt = date
                entries[index].historyEntryID = historyEntryID
            } else {
                entries.append(TranscriptRecoveryEntry(
                    id: sessionID, text: text, state: state, createdAt: date, updatedAt: date,
                    historyEntryID: historyEntryID
                ))
            }
            try write(entries)
            return true
        }
    }

    /*
    The live snapshot taken every 0.75 s while someone talks, saved off the main thread (build
    81: the main thread also runs the talk key and the bubble, and used to stall on this file).
    Only the newest waiting snapshot per talk is written; older ones are skipped. Every other
    call waits its turn on the same serial queue, so a snapshot queued before Stop is written
    before the stop checkpoint, and one can never land after a later state or a resolve for
    its talk. `onFailure` runs on the journal queue when the snapshot could not be saved.
    */
    func checkpointInBackground(sessionID: UUID, text: String, at date: Date = Date(),
                                onFailure: @escaping () -> Void) {
        guard !text.isEmpty else { return }
        io.stash(sessionID, text: text, at: date)
        let store = self
        io.queue.async {
            guard let snapshot = store.io.take(sessionID), !store.io.sealed.contains(sessionID) else { return }
            do { try store.checkpoint(sessionID: sessionID, text: snapshot.text, state: .capturing, at: snapshot.date) }
            catch { onFailure() }
        }
    }

    /// Returns once every snapshot queued so far is on disk (or has failed).
    func waitForPendingWrites() { io.sync {} }

    /// ISO8601 journals can place two entries in the same second. In that case the last
    /// appended entry is newest; a pre-update snapshot must win over its raw checkpoint.
    func latestCopyEntry() throws -> TranscriptRecoveryEntry? {
        try recover().enumerated().max { Self.isOlder($0, than: $1) }?.element
    }

    /// Newest by updatedAt; within one second, the later position in the file is newer.
    private static func isOlder(_ a: (offset: Int, element: TranscriptRecoveryEntry),
                                than b: (offset: Int, element: TranscriptRecoveryEntry)) -> Bool {
        a.element.updatedAt == b.element.updatedAt ? a.offset < b.offset : a.element.updatedAt < b.element.updatedAt
    }

    /// Keep a separate exact Copy-latest payload before an explicitly requested update.
    /// Preserve the original recognition checkpoint as well. Startup offers the newest held
    /// text for Copy only: no paste, Return, microphone start or other replay is authorized.
    func preserveForUpdateRestart(_ payload: String, at date: Date = Date()) throws -> Bool {
        guard !payload.isEmpty else { return true }
        return try io.sync {
            // A retry may reuse an already durable, newest exact held snapshot. Read from disk,
            // never an in-memory flag, so damaged storage still blocks the restart.
            if let latest = try latestCopyEntry(), latest.state == .held, latest.text == payload { return true }
            let id = UUID()
            try checkpoint(sessionID: id, text: payload, state: .held, at: date)
            return try recover().contains { $0.id == id && $0.text == payload && $0.state == .held }
        }
    }

    /// Removes only the specified session after a known terminal outcome. A
    /// stale completion cannot erase a newer session's checkpoint.
    @discardableResult
    func resolve(sessionID: UUID) throws -> Bool {
        try io.sync {
            io.sealed.insert(sessionID)
            var entries  = try recover()
            let oldCount = entries.count
            entries.removeAll { $0.id == sessionID }
            guard entries.count != oldCount else { return false }
            try write(entries)
            return true
        }
    }

    /// Returns raw text for a user-initiated copy control. It does not touch
    /// NSPasteboard and intentionally leaves the recovery entry in place.
    func copyCandidate(sessionID: UUID) throws -> String? {
        try recover().first(where: { $0.id == sessionID })?.text
    }

    /// Keeps only the entries `keep` accepts and removes the rest in one write.
    ///
    /// Theorem: a damaged journal throws (recover() runs first) and is never overwritten.
    /// Used by explicit Clear History; startup recovery is read-only. Returns entries removed.
    @discardableResult
    func retainOnly(where keep: (TranscriptRecoveryEntry) -> Bool) throws -> Int {
        try io.sync {
            let entries = try recover()
            let kept    = entries.filter(keep)
            guard kept.count != entries.count else { return 0 }
            try write(kept)
            return entries.count - kept.count
        }
    }

    /// Completes an explicit history-clear request without extending it to later talks.
    /// ISO-8601 journal dates have whole-second precision. Keep the cutoff second too:
    /// deleting a same-second entry would risk erasing words created after the click.
    @discardableResult
    func clearForHistory(requestedAt: Date, keeping sessionIDs: Set<UUID>) throws -> Int {
        let cutoff = requestedAt.timeIntervalSince1970.rounded(.down)
        return try retainOnly { entry in
            sessionIDs.contains(entry.id) || entry.createdAt.timeIntervalSince1970 >= cutoff
        }
    }

    /// Explicit discard for a recovery UI. This must never be called merely
    /// because a process relaunched or because delivery was uncertain.
    @discardableResult
    func discard(sessionID: UUID) throws -> Bool {
        try resolve(sessionID: sessionID)
    }

    /*
    Rewrites the whole journal in one atomic write, creating the folder if needed. Keys are
    sorted so the same entries always give the same file. Callers are already on the journal
    queue. Older sent-but-unconfirmed entries already saved in History are left out here
    (bounded()); nothing else is.
    */
    private func write(_ entries: [TranscriptRecoveryEntry]) throws {
        let encoder                  = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = [.sortedKeys]
        try PrivateFileStore.write(
            encoder.encode(TranscriptRecoveryJournal(version: 1, entries: Self.bounded(entries, historyHolds: historyHolds))),
            to: url, fileManager: fileManager)
    }

    /*
    Keeps every entry except trimmable ones beyond the newest `limit` of them (build 81). An
    entry is trimmable only when it is deliveryUncertain AND its History row is confirmed in the
    saved History file, so its words are durable there (Codex RC3 review: a posted paste is not
    an accepted one, and a failed History save left the journal as the only saved copy).
    Unsent words, entries with no History pointer and entries whose History row is not confirmed
    are never trimmed. The newest entry overall always survives: if it is trimmable it is among
    the newest of those, so what startup offers never changes. Order in the file is kept.
    */
    static func bounded(_ entries: [TranscriptRecoveryEntry],
                        limit: Int = sentEntryLimit,
                        historyHolds: (UUID) -> Bool) -> [TranscriptRecoveryEntry] {
        let trimmable = entries.enumerated().filter { item in
            item.element.state == .deliveryUncertain && item.element.historyEntryID.map(historyHolds) == true
        }
        guard trimmable.count > limit else { return entries }
        let keep = Set(trimmable.sorted { isOlder($1, than: $0) }.prefix(max(0, limit)).map(\.offset))
        let drop = Set(trimmable.map(\.offset)).subtracting(keep)
        return entries.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }


}


// HistoryRowsOnDisk — which History rows are known to be in the saved History file (build 81)


/*
The rows this process last read from prompt-history.json or last wrote to it. PromptHistoryStore
replaces the list after each successful load or save; a load that fails empties it, and a save
that fails leaves the file (an atomic write) and this list as they were. The recovery journal
asks it before trimming a sent-but-unconfirmed talk, so a History save that failed, a History
that would not load or a cleared History never lets the journal drop the only saved copy of
someone's words (Codex RC3 review). Another product's History, not loaded now, counts as
unconfirmed: those entries are simply kept.
*/
enum HistoryRowsOnDisk {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rows: Set<UUID> = []

    static func replace<S: Sequence>(with ids: S) where S.Element == UUID {
        let next = Set(ids)
        lock.lock(); defer { lock.unlock() }
        rows = next
    }

    static func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rows.contains(id)
    }
}


// JournalIO — the one serial queue a journal's reads and writes take turns on (build 81)


/*
`sync` runs inline when already on the queue, so a public call made from inside another (for
example preserveForUpdateRestart → checkpoint) cannot deadlock. `pending` holds the newest live
snapshot per talk until the queue writes it; it is the only state touched from two threads, so
it has its own lock. `sealed` is read and written only on the queue.
*/
private final class JournalIO {
    let queue = DispatchQueue(label: "com.tinkr.tokens.recovery-journal", qos: .userInitiated)
    private let onQueue = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var pending: [UUID: (text: String, date: Date)] = [:]
    /// Talks that reached a later state or were resolved: a live snapshot never reopens them.
    var sealed: Set<UUID> = []

    init() { queue.setSpecific(key: onQueue, value: true) }

    func sync<T>(_ work: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: onQueue) == true ? try work() : try queue.sync(execute: work)
    }

    func stash(_ id: UUID, text: String, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = (text, date)
    }

    func take(_ id: UUID) -> (text: String, date: Date)? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }
}

