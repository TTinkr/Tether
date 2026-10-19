import Darwin
import Foundation
import Testing
@testable import Tokens

struct PrivateFileStoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PrivateFileStoreTests-\(UUID().uuidString)")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    @Test func privateAtomicWritesKeepOnlyTheFinishedOwnerOnlyFile() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        try PrivateFileStore.write(Data("fictional first words".utf8), to: file)
        try PrivateFileStore.write(Data("fictional replacement".utf8), to: file)
        #expect(try PrivateFileStore.read(from: file) == Data("fictional replacement".utf8))
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["history.json"])
    }

    @Test func readingOlderFilesTightensPermissionsWithoutChangingTheirBytes() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        let original = Data("fictional older history".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try PrivateFileStore.read(from: file) == original)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(file) == 0o600)
    }

    @Test func linkedFilesAreNeverReadOrReplacedAndTheirTargetIsUntouched() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim.txt")
        let original = Data("fictional unrelated file".utf8)
        try original.write(to: victim)
        for (name, hard) in [("symlink.json", false), ("hardlink.json", true)] {
            let linked = root.appendingPathComponent(name)
            if hard { try FileManager.default.linkItem(at: victim, to: linked) }
            else { try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: victim) }
            #expect(throws: (any Error).self) { try PrivateFileStore.read(from: linked) }
            #expect(throws: (any Error).self) { try PrivateFileStore.write(Data("replacement".utf8), to: linked) }
            #expect(try Data(contentsOf: victim) == original)
            try FileManager.default.removeItem(at: linked)
        }
    }

    @Test func aLinkedStorageDirectoryIsRefused() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        #expect(throws: (any Error).self) {
            try PrivateFileStore.write(Data("fictional words".utf8), to: linked.appendingPathComponent("history.json"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }

    @Test func failedReplacementPreservesExistingData() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        let original = Data("fictional untouched words".utf8)
        try original.write(to: sentinel)
        #expect(throws: (any Error).self) { try PrivateFileStore.write(Data("replacement".utf8), to: destination) }
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["history.json"])
    }

    @Test func namedPipesAreRefusedWithoutWaitingForAWriter() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pipe = root.appendingPathComponent("history.json")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try PrivateFileStore.read(from: pipe) }
        #expect(throws: (any Error).self) { try PrivateFileStore.write(Data("fictional".utf8), to: pipe) }
    }

    @Test func recoveryJournalUsesOwnerOnlyStorageAndStillRoundTrips() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TranscriptRecoveryStore(directory: root)
        let session = UUID()
        try journal.checkpoint(sessionID: session, text: "fictional recovery words", state: .held)
        #expect(try journal.copyCandidate(sessionID: session) == "fictional recovery words")
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(root.appendingPathComponent(TranscriptRecoveryStore.filename)) == 0o600)
        try journal.resolve(sessionID: session)
        #expect(try journal.recover().isEmpty)
    }
    @Test func privacyTighteningPreservesIntentionalOwnerReadOnlyPermissions() throws {
        let root = folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        let original = Data("fictional retained words".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(try PrivateFileStore.read(from: file) == original)
        #expect(try permissions(root) == 0o500)
        #expect(try permissions(file) == 0o400)
        #expect(throws: (any Error).self) { try PrivateFileStore.write(Data("replacement".utf8), to: file) }
        #expect(try Data(contentsOf: file) == original)
        #expect(try permissions(root) == 0o500)
    }

}
