


//
import Foundation
import Testing
@testable import Tokens


// retainOnly — keep chosen entries, remove the rest, never overwrite damage


@Suite struct TranscriptRecoveryRetainTests {
    private func store() throws -> (TranscriptRecoveryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecoveryRetainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (TranscriptRecoveryStore(directory: directory), directory)
    }

    @Test func keepsOnlyTheChosenEntries() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = UUID(), sent = UUID(), old = UUID()
        try journal.checkpoint(sessionID: old, text: "an old talk", state: .deliveryUncertain)
        try journal.checkpoint(sessionID: sent, text: "a sent talk", state: .deliveryUncertain)
        try journal.checkpoint(sessionID: held, text: "words waiting to paste", state: .held)

        #expect(try journal.retainOnly { $0.id == held } == 2)
        #expect(try journal.recover().map(\.id) == [held])
        #expect(try journal.retainOnly { $0.id == held } == 0)
        #expect(try journal.retainOnly { _ in false } == 1)
        #expect(try journal.recover().isEmpty)
    }

    @Test func updateRestartPreservesExactPayloadAndOriginalCheckpoint() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = UUID()
        try journal.checkpoint(sessionID: original, text: "fictional raw words", state: .deliveryUncertain, at: Date(timeIntervalSince1970: 123))
        let payload = "# Fictional\n\n<char>RILEY</char>\n\n<thinking duration=\"1.5000s\"/>\n\nGreen notebook."
        #expect(try journal.preserveForUpdateRestart(payload, at: Date(timeIntervalSince1970: 123)))
        #expect(try journal.preserveForUpdateRestart(payload, at: Date(timeIntervalSince1970: 124)))
        let entries = try journal.recover()
        #expect(entries.count == 2)
        #expect(try journal.latestCopyEntry()?.text == payload)
        #expect(entries.contains { $0.id == original && $0.text == "fictional raw words" })
        #expect(entries.contains { $0.id != original && $0.text == payload && $0.state == .held })
    }

    @Test func updateRestartRefusesDamagedJournalWithoutDiscardingIt() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(TranscriptRecoveryStore.filename)
        let broken = Data("{broken".utf8)
        try broken.write(to: file)
        #expect(throws: (any Error).self) { try journal.preserveForUpdateRestart("fictional words") }
        #expect(try Data(contentsOf: file) == broken)
    }

    @Test func noJournalFileIsNotAnError() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try journal.retainOnly { _ in false } == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranscriptRecoveryStore.filename).path))
    }

    @Test func aDamagedJournalThrowsAndIsLeftExactlyAsItWas() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url     = directory.appendingPathComponent(TranscriptRecoveryStore.filename)
        let damaged = Data("{ not a journal".utf8)
        try damaged.write(to: url)
        #expect(throws: (any Error).self) { try journal.retainOnly { _ in false } }
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func historyClearRetainsTheCutoffSecondAndLaterTalks() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = UUID(), sameSecond = UUID(), later = UUID()
        try journal.checkpoint(sessionID: earlier, text: "fictional earlier", state: .held,
                               at: Date(timeIntervalSince1970: 999))
        try journal.checkpoint(sessionID: sameSecond, text: "fictional same second", state: .held,
                               at: Date(timeIntervalSince1970: 1_000.9))
        try journal.checkpoint(sessionID: later, text: "fictional later", state: .held,
                               at: Date(timeIntervalSince1970: 1_001))

        #expect(try journal.clearForHistory(requestedAt: Date(timeIntervalSince1970: 1_000.5), keeping: []) == 1)
        #expect(try Set(journal.recover().map(\.id)) == [sameSecond, later])
    }

    @Test func historyClearKeepsClickTimeSparedIdentityAfterItFinishes() throws {
        let (journal, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spared = UUID(), earlier = UUID()
        try journal.checkpoint(sessionID: spared, text: "fictional active", state: .capturing,
                               at: Date(timeIntervalSince1970: 100))
        try journal.checkpoint(sessionID: earlier, text: "fictional old", state: .held,
                               at: Date(timeIntervalSince1970: 100))
        // Later state updates preserve createdAt; a retry still needs the spared identity.
        try journal.checkpoint(sessionID: spared, text: "fictional finished", state: .deliveryUncertain,
                               at: Date(timeIntervalSince1970: 300))

        #expect(try journal.clearForHistory(requestedAt: Date(timeIntervalSince1970: 200), keeping: [spared]) == 1)
        #expect(try journal.recover().map(\.id) == [spared])
        #expect(try journal.copyCandidate(sessionID: spared) == "fictional finished")
    }
}

