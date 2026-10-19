
import Foundation
import Testing
@testable import Tokens

@Suite struct TranscriptRecoveryJournalTests {
    private func store() throws -> (TranscriptRecoveryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (TranscriptRecoveryStore(directory: directory), directory)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func raise() { lock.lock(); count += 1; lock.unlock() }
        var raised: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test func liveSavesLandOffTheCallerAndTheNewestWins() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let talk = UUID(), failed = Flag()
        for words in ["fictional", "fictional green", "fictional green notebook"] {
            journal.checkpointInBackground(sessionID: talk, text: words) { failed.raise() }
        }
        journal.waitForPendingWrites()
        let entries = try journal.recover()
        #expect(entries.count == 1)
        #expect(entries.first?.text == "fictional green notebook")
        #expect(entries.first?.state == .capturing)
        #expect(failed.raised == 0)
    }

    @Test func aQueuedLiveSaveNeverUndoesStopOrAFinishedTalk() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stopped = UUID(), finished = UUID()
        journal.checkpointInBackground(sessionID: stopped, text: "fictional live") {}
        try journal.checkpoint(sessionID: stopped, text: "fictional at stop", state: .stopped)
        // A snapshot that arrives after Stop (it cannot in the app; the store refuses it anyway).
        journal.checkpointInBackground(sessionID: stopped, text: "fictional late live") {}
        journal.checkpointInBackground(sessionID: finished, text: "fictional sent") {}
        try journal.resolve(sessionID: finished)
        journal.checkpointInBackground(sessionID: finished, text: "fictional late live") {}
        journal.waitForPendingWrites()

        let entries = try journal.recover()
        #expect(entries.map(\.id) == [stopped])
        #expect(entries.first?.text == "fictional at stop")
        #expect(entries.first?.state == .stopped)
    }

    @Test func aDamagedJournalReportsTheLiveSaveAndIsLeftAsItWas() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(TranscriptRecoveryStore.filename)
        let damaged = Data("{ not a journal".utf8)
        try damaged.write(to: url)
        let failed = Flag()
        journal.checkpointInBackground(sessionID: UUID(), text: "fictional words") { failed.raise() }
        journal.waitForPendingWrites()
        #expect(failed.raised == 1)
        #expect(try Data(contentsOf: url) == damaged)
    }

    /*
    Only sent talks whose History row is confirmed saved are trimmed (build 81, Codex RC3 review).
    Unsent words, sent talks whose History save never landed, and sent talks with no History row
    all stay, however old and however many.
    */
    @Test func onlySentTalksSavedInHistoryAreTrimmedAndEveryOtherTalkStays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = TranscriptRecoveryStore.sentEntryLimit
        let savedRows = Set((0..<(limit + 7)).map { _ in UUID() })
        let journal = TranscriptRecoveryStore(directory: directory, historyHolds: { savedRows.contains($0) })
        var clock = 10.0
        func talk(_ text: String, _ state: TranscriptRecoveryState, row: UUID? = nil) throws -> UUID {
            let id = UUID(); clock += 1
            try journal.checkpoint(sessionID: id, text: text, state: state, historyEntryID: row,
                                   at: Date(timeIntervalSince1970: clock))
            return id
        }
        // The oldest talks: unsent words, sent talks whose History save failed, and one with no row.
        let kept = try [
            talk("fictional held", .held), talk("fictional live", .capturing), talk("fictional slow", .modelTimedOut),
            talk("fictional unsaved 1", .deliveryUncertain, row: UUID()),
            talk("fictional unsaved 2", .deliveryUncertain, row: UUID()),
            talk("fictional no row", .deliveryUncertain),
        ]
        var saved: [UUID] = []
        for (index, row) in savedRows.enumerated() {
            saved.append(try talk("fictional sent \(index)", .deliveryUncertain, row: row))
        }
        let ids = Set(try journal.recover().map(\.id))
        #expect(ids.count == kept.count + limit)
        #expect(ids.isSuperset(of: kept))
        #expect(ids.isSuperset(of: saved.suffix(limit)))
        #expect(ids.isDisjoint(with: saved.prefix(7)))
        #expect(try journal.latestCopyEntry()?.id == saved.last)
    }

    // A checkpoint without a History row clears an older pointer, so that talk is kept, not trimmed.
    @Test func aLaterCheckpointWithoutAHistoryRowKeepsTheTalk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TranscriptRecoveryStore(directory: directory, historyHolds: { _ in true })
        let talk = UUID()
        try journal.checkpoint(sessionID: talk, text: "fictional words", state: .deliveryUncertain,
                               historyEntryID: UUID(), at: Date(timeIntervalSince1970: 1))
        try journal.checkpoint(sessionID: talk, text: "fictional words", state: .deliveryUncertain,
                               at: Date(timeIntervalSince1970: 2))
        #expect(try journal.recover().first?.historyEntryID == nil)
        let entries = try journal.recover()
        #expect(TranscriptRecoveryStore.bounded(entries, limit: 0, historyHolds: { _ in true }) == entries)
    }

    @Test func theBoundKeepsFileOrderAndTheNewestOfASameSecondTie() {
        let second = Date(timeIntervalSince1970: 500)
        let entries = (0..<4).map {
            TranscriptRecoveryEntry(id: UUID(), text: "fictional \($0)", state: .deliveryUncertain,
                                    createdAt: second, updatedAt: second, historyEntryID: UUID())
        }
        let held = TranscriptRecoveryEntry(id: UUID(), text: "fictional held", state: .held,
                                           createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        let bounded = TranscriptRecoveryStore.bounded([held] + entries, limit: 2, historyHolds: { _ in true })
        #expect(bounded.map(\.id) == [held.id, entries[2].id, entries[3].id])
        #expect(TranscriptRecoveryStore.bounded(entries, limit: 4, historyHolds: { _ in true }) == entries)
        // With no History row confirmed, nothing is trimmed at all.
        #expect(TranscriptRecoveryStore.bounded(entries, limit: 0, historyHolds: { _ in false }) == entries)
    }
}
