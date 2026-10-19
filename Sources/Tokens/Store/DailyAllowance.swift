


//
import Darwin
import Foundation


// DailyAllowance — Counts verified deliveries per local day against a limit of five


/// Local product allowance, not payment enforcement. Call only at the final
/// delivery boundary; recognition, copying, cancellation and uncertain pastes
/// do not consume a clean use. Callers must fail closed on an error.
final class DailyAllowance {


    // The record and its settings — limit, outcomes, errors, stored shape, file location


    /*
    TalkModel records verified deliveries here (Tokens product only), but its own comment in
    shouldDecorateDelivery says the ledger never gates formatting today and is kept for a
    possible future paid tier.
    */
    static let dailyLimit = 5
    /*
    Only `.verifiedSuccess` is ever written to disk (see recordDelivery); the other outcomes
    exist so callers can say what happened without it counting.
    */
    enum Outcome { case verifiedSuccess, uncertain, cancelled, failed }
    // `used` and `remaining` count today's clean uses; `resetsAt` is the end of the local day.
    struct Status: Equatable {
        let used: Int
        let remaining: Int
        let resetsAt: Date
    }
    enum Failure: Error, LocalizedError {
        case corruptStore
        case storageUnavailable(String)
        case invalidCalendar
        case alreadyDelivered
        var errorDescription: String? {
            switch self {
            case .corruptStore: return "The daily allowance record needs repair. Clean delivery is unavailable."
            case .storageUnavailable(let reason): return "Daily allowance could not be saved or read: \(reason)"
            case .invalidCalendar: return "The next local daily reset could not be determined."
            case .alreadyDelivered: return "This delivery was already recorded."
            }
        }
    }
    /*
    One recorded delivery. `usedCleanAllowance` is false for a delivery that was recorded but
    did not take a clean use (it was not clean, or none were left). Keeping that entry still
    matters: it is what stops the same session from being recorded twice.
    */
    private struct Entry: Codable {
        let sessionID: UUID
        let localDay: String
        let usedCleanAllowance: Bool
    }
    /*
    The whole file: a version number and every delivery ever recorded. The version is checked
    on load; anything but 1 is treated as a corrupt store.
    */
    private struct Store: Codable {
        var version             = 1
        var deliveries: [Entry] = []
    }
    /*
    Application Support/<folder>/deliveries-v1.json. The folder is the bundle identifier (plus
    DailyAllowance) in the public Tokens build, found through the TTTPublicTokens Info.plist key,
    and "Talk TT/DailyAllowance" otherwise. Both are names on people's Macs, so they stay as they are.
    */
    static var defaultURL: URL {
        let isPublicTokens = publicTokens
        let identity       = Bundle.main.bundleIdentifier ?? "com.tinkr.tokens.community.talk.macos"
        let directory      = isPublicTokens ? "\(identity)/DailyAllowance" : "Talk TT/DailyAllowance"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("deliveries-v1.json")
    }

//
// :)
//
//
    private let url: URL
    private let calendar: Calendar
    private let now: () -> Date
    private let mutex = NSLock()

    init(storeURL: URL = DailyAllowance.defaultURL,
         calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init) {
        self.url      = storeURL
        self.calendar = calendar
        self.now      = now
    }


    // Asking and recording — status(), requiresDecorations(), recordDelivery(), day arithmetic


    func status() throws -> Status {
        try access { store in try self.status(in: store, at: self.now()) }
    }

    /// Evaluate immediately before preparing a new session's final payload.
    /// A prior successful UUID cannot obtain another clean delivery.
    /// Returns true when no clean uses are left today; throws `alreadyDelivered` if this
    /// session was already recorded.
    func requiresDecorations(for sessionID: UUID) throws -> Bool {
        try access { store in
            guard !store.deliveries.contains(where: { $0.sessionID == sessionID }) else {
                throw Failure.alreadyDelivered
            }
            return try self.status(in: store, at: self.now()).remaining == 0
        }
    }

    /// Persist only positively verified success. Repeating a successful UUID is
    /// idempotent, including after restart or midnight; retries never consume twice.
    @discardableResult
    func recordDelivery(sessionID: UUID, outcome: Outcome, wasClean: Bool = true) throws -> Status {
        try access { store in
            let date = self.now()
            // Anything other than a verified success changes nothing and just reports the status.
            guard case .verifiedSuccess = outcome else { return try self.status(in: store, at: date) }
            // A session already on file is skipped, which is what makes a retry safe.
            if !store.deliveries.contains(where: { $0.sessionID == sessionID }) {
                let before = try self.status(in: store, at: date)
                store.deliveries.append(Entry(sessionID: sessionID, localDay: try self.dayKey(date),
                                              usedCleanAllowance: wasClean && before.remaining > 0))
                /*
                Written to a temporary file and swapped in (.atomic), then locked down to owner-only
                (0600), so a crash mid-write cannot leave a half-written ledger.
                */
                do {
                    let data = try JSONEncoder().encode(store)
                    try data.write(to: self.url, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
                } catch { throw Failure.storageUnavailable(error.localizedDescription) }
            }
            return try self.status(in: store, at: date)
        }
    }

    /*
    A text key for the local calendar day: calendar kind, era, year, month, day. Using the
    user's own calendar is what makes the day roll over at their local midnight.
    */
    private func dayKey(_ date: Date) throws -> String {
        let c = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let era = c.era, let year = c.year, let month = c.month, let day = c.day else { throw Failure.invalidCalendar }
        return "\(calendar.identifier):\(era):\(year):\(month):\(day)"
    }
    // Counts today's entries that took a clean use. `resetsAt` is the end of today's day interval.
    private func status(in store: Store, at date: Date) throws -> Status {
        let day = try dayKey(date)
        guard let interval = calendar.dateInterval(of: .day, for: date), interval.end > date else { throw Failure.invalidCalendar }
        let used = store.deliveries.filter { $0.localDay == day && $0.usedCleanAllowance }.count
        return Status(used: used, remaining: max(0, Self.dailyLimit - used), resetsAt: interval.end)
    }

//
// :)
//
//
    // Safe file access — access() locks, loads, checks, then runs the operation


    /// Atomic file replacement plus a stable sibling lock serializes instances.
    /// Reads re-load disk every time, so midnight/reset needs no timer or cron.
    /// Order of work: take the in-process lock; create the folder (owner-only, 0700); open the
    /// sibling ".lock" file and take an exclusive flock on it, which also keeps other processes
    /// out until this call returns; load and check the ledger; run `operation` on it. O_NOFOLLOW
    /// refuses to open the lock file if it has been replaced by a symlink. The checks decide
    /// "corrupt" (version not 1, a repeated session id, an empty day key, or more clean uses in
    /// one day than the limit) and any such failure throws `corruptStore`. A file that does not
    /// exist yet is simply an empty ledger.
    private func access<T>(_ operation: (inout Store) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw Failure.storageUnavailable(error.localizedDescription) }
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.storageUnavailable(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw Failure.storageUnavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.storageUnavailable(String(cString: strerror(errno))) }
        defer { _ = flock(fd, LOCK_UN) }
        var store: Store
        do {
            let data = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            do { store = try JSONDecoder().decode(Store.self, from: data) }
            catch { throw Failure.corruptStore }
            guard store.version == 1,
                  Set(store.deliveries.map(\.sessionID)).count == store.deliveries.count,
                  store.deliveries.allSatisfy({ !$0.localDay.isEmpty }) else { throw Failure.corruptStore }
            let grouped = Dictionary(grouping: store.deliveries.filter(\.usedCleanAllowance), by: \.localDay)
            guard grouped.values.allSatisfy({ $0.count <= Self.dailyLimit }) else { throw Failure.corruptStore }
        } catch let failure as Failure { throw failure }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { store = Store() }
        catch { throw Failure.storageUnavailable(error.localizedDescription) }
        return try operation(&store)
    }


}

