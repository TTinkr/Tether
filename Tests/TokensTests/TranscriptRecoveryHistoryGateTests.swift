
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct TranscriptRecoveryHistoryGateTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecoveryHistoryGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func row(_ second: Double) -> PromptHistoryEntry {
        PromptHistoryEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: second), text: "fictional row")
    }

    /*
    The Codex RC3 fixture. History cannot be saved (a plain file sits where its folder should
    be, as on a locked or full disk), and 51 talks end with a posted but unconfirmed paste.
    After a relaunch, with History still unreadable, a fresh journal read from disk still holds
    all 51 texts, and the next talk's write trims none of them.
    */
    @Test func aHistoryWriteFailureKeepsAllFiftyOneUnconfirmedTalksAcrossARelaunch() throws {
        let root = try folder()
        defer { PromptHistoryStore.directoryOverride = nil; try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("history-blocked")
        try Data("not a folder".utf8).write(to: blocked)
        PromptHistoryStore.directoryOverride = blocked
        _ = try PromptHistoryStore.load()

        let journalFolder = root.appendingPathComponent("journal", isDirectory: true)
        let journal = TranscriptRecoveryStore(directory: journalFolder)
        var history: [PromptHistoryEntry] = []
        var texts: [String] = []
        for index in 0..<(TranscriptRecoveryStore.sentEntryLimit + 1) {
            let saved = row(1_000 + Double(index))
            history.insert(saved, at: 0)
            #expect(throws: (any Error).self) { try PromptHistoryStore.save(history) }
            let text = "fictional unconfirmed talk \(index)"
            try journal.checkpoint(sessionID: UUID(), text: text, state: .deliveryUncertain,
                                   historyEntryID: saved.id, at: Date(timeIntervalSince1970: 1_000 + Double(index)))
            texts.append(text)
        }

        // Relaunch: History still will not load or save; the journal is read back from disk.
        _ = try PromptHistoryStore.load()
        let relaunched = TranscriptRecoveryStore(directory: journalFolder)
        try relaunched.checkpoint(sessionID: UUID(), text: "fictional next talk", state: .capturing)
        let survived = try relaunched.recover().map(\.text)
        #expect(survived.count == texts.count + 1)
        #expect(Set(texts).isSubset(of: Set(survived)))
    }

    /*
    The bound still works when History really saved the rows, and stops the moment those rows
    are no longer confirmed: after Clear History saves an empty list, or after a History file
    that will not load. A failed save leaves the earlier confirmation in place, because the
    atomic write left the earlier file in place.
    */
    @Test func onlyTalksWhoseHistoryRowReallyLandedAreTrimmed() throws {
        let root = try folder()
        defer { PromptHistoryStore.directoryOverride = nil; try? FileManager.default.removeItem(at: root) }
        let historyFolder = root.appendingPathComponent("history", isDirectory: true)
        PromptHistoryStore.directoryOverride = historyFolder
        _ = try PromptHistoryStore.load()

        let limit = TranscriptRecoveryStore.sentEntryLimit
        let journal = TranscriptRecoveryStore(directory: root.appendingPathComponent("journal", isDirectory: true))
        var history: [PromptHistoryEntry] = []
        var sessions: [UUID] = []
        for index in 0..<(limit + 1) {
            let saved = row(2_000 + Double(index))
            history.insert(saved, at: 0)
            try PromptHistoryStore.save(history)
            let session = UUID()
            sessions.append(session)
            try journal.checkpoint(sessionID: session, text: "fictional saved talk \(index)", state: .deliveryUncertain,
                                   historyEntryID: saved.id, at: Date(timeIntervalSince1970: 2_000 + Double(index)))
        }
        var ids = Set(try journal.recover().map(\.id))
        #expect(ids.count == limit)
        #expect(!ids.contains(sessions[0]))

        // A relaunch reads the same History back, so the same rows stay confirmed.
        _ = try PromptHistoryStore.load()
        #expect(HistoryRowsOnDisk.contains(history[0].id))

        // A History save that fails leaves the earlier file, and its confirmation, as they were.
        let historyFile = historyFolder.appendingPathComponent("prompt-history.json")
        let before = try Data(contentsOf: historyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: historyFolder.path)
        #expect(throws: (any Error).self) { try PromptHistoryStore.save([row(9)] + history) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyFolder.path)
        #expect(try Data(contentsOf: historyFile) == before)
        #expect(HistoryRowsOnDisk.contains(history[0].id))

        // Clear History saves an empty list: no row is confirmed, so nothing more is trimmed.
        try PromptHistoryStore.save([])
        let afterClear = UUID()
        try journal.checkpoint(sessionID: afterClear, text: "fictional talk after clear", state: .deliveryUncertain,
                               historyEntryID: history[0].id, at: Date(timeIntervalSince1970: 3_000))
        ids = Set(try journal.recover().map(\.id))
        #expect(ids.count == limit + 1)
        #expect(ids.contains(sessions[1]))

        // A History file that will not load confirms nothing either.
        try PromptHistoryStore.save(history)
        try Data("{ not history".utf8).write(to: historyFile)
        #expect(throws: (any Error).self) { _ = try PromptHistoryStore.load() }
        #expect(!HistoryRowsOnDisk.contains(history[0].id))
    }

    /*
    A journal written before build 81 has no History pointers. Even with every History row
    confirmed, none of its talks is trimmed: build 81 never deletes recovery words that already
    exist on someone's Mac in order to make the file smaller.
    */
    @Test func aJournalFromBeforeBuild81KeepsEveryTalk() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = TranscriptRecoveryStore.sentEntryLimit + 1
        let lines = (0..<count).map { index in
            """
            {"createdAt":"2026-09-2\(index % 10)T10:00:00Z","id":"\(UUID().uuidString)","state":"deliveryUncertain",\
            "text":"fictional old talk \(index)","updatedAt":"2026-09-2\(index % 10)T10:00:\(String(format: "%02d", index % 60))Z"}
            """
        }
        let old = "{\"entries\":[\(lines.joined(separator: ","))],\"version\":1}"
        try Data(old.utf8).write(to: root.appendingPathComponent(TranscriptRecoveryStore.filename))

        let journal = TranscriptRecoveryStore(directory: root, historyHolds: { _ in true })
        #expect(try journal.recover().count == count)
        #expect(try journal.recover().allSatisfy { $0.historyEntryID == nil })
        try journal.checkpoint(sessionID: UUID(), text: "fictional new talk", state: .deliveryUncertain,
                               historyEntryID: UUID())
        let texts = Set(try journal.recover().map(\.text))
        #expect(texts.count == count + 1)
        #expect((0..<count).allSatisfy { texts.contains("fictional old talk \($0)") })
    }
}
