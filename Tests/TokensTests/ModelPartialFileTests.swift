import Darwin
import Foundation
import Testing
@testable import Tokens

struct ModelPartialFileTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ModelPartialFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func resumesThroughOneDescriptorAndCreatesPrivateFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.partial")
        let initial = try ModelPartialFile.create(at: file)
        try initial.write(contentsOf: Data("model prefix".utf8))
        try initial.close()
        #expect(try ModelPartialFile.length(at: file) == 12)
        let resumed = try ModelPartialFile.resume(at: file, maximumBytes: 100)
        #expect(try resumed.readToEnd() == Data("model prefix".utf8))
        try resumed.write(contentsOf: Data(" tail".utf8))
        try resumed.close()
        #expect(try Data(contentsOf: file) == Data("model prefix tail".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func refusesSymlinksAndHardlinksWithoutChangingUnrelatedFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim.txt")
        let original = Data("fictional unrelated data".utf8)
        try original.write(to: victim)
        for (name, hard) in [("symbolic.partial", false), ("hard.partial", true)] {
            let linked = root.appendingPathComponent(name)
            if hard { try FileManager.default.linkItem(at: victim, to: linked) }
            else { try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: victim) }
            #expect(throws: (any Error).self) { try ModelPartialFile.length(at: linked) }
            #expect(throws: (any Error).self) { try ModelPartialFile.resume(at: linked, maximumBytes: 100) }
            #expect(throws: (any Error).self) { try ModelPartialFile.create(at: linked) }
            #expect(try Data(contentsOf: victim) == original)
            try FileManager.default.removeItem(at: linked)
        }
    }

    @Test func existingFilesAreNeverTruncatedAndOversizedResumesFail() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.partial")
        let original = Data("fictional model bytes".utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) { try ModelPartialFile.create(at: file) }
        #expect(throws: (any Error).self) { try ModelPartialFile.resume(at: file, maximumBytes: 4) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func namedPipesAreRefusedWithoutWaitingForAWritingProcess() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = root.appendingPathComponent("model.partial")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try ModelPartialFile.length(at: pipe) }
        #expect(throws: (any Error).self) { try ModelPartialFile.resume(at: pipe, maximumBytes: 100) }
        #expect(throws: (any Error).self) { try ModelPartialFile.create(at: pipe) }
    }
    @Test func promotionReplacesAnExistingModelWithoutDeletingItFirst() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try Data("fictional previous model".utf8).write(to: destination)
        let replacement = Data("fictional replacement model".utf8)
        try replacement.write(to: partial)
        try ModelPartialFile.promote(from: partial, to: destination)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func failedPromotionPreservesThePreviousModel() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        let previous = Data("fictional previous model".utf8)
        try previous.write(to: destination)
        #expect(throws: (any Error).self) { try ModelPartialFile.promote(from: partial, to: destination) }
        #expect(try Data(contentsOf: destination) == previous)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: destination)
        #expect(throws: (any Error).self) { try ModelPartialFile.promote(from: partial, to: destination) }
        #expect(try Data(contentsOf: destination) == previous)
    }

    @Test func promotionAndCleanupNeverRecursivelyRemoveAnUnexpectedDirectory() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        let original = Data("fictional unrelated content".utf8)
        let replacement = Data("fictional replacement model".utf8)
        try original.write(to: sentinel)
        try replacement.write(to: partial)
        #expect(throws: (any Error).self) { try ModelPartialFile.promote(from: partial, to: destination) }
        #expect(throws: (any Error).self) { try ModelPartialFile.remove(at: destination) }
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(try Data(contentsOf: partial) == replacement)
    }

    @Test func promotionRefusesLinkedDestinationsAndLeavesBothFilesUntouched() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("unrelated.txt")
        let destination = root.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        let original = Data("fictional unrelated content".utf8)
        let replacement = Data("fictional replacement model".utf8)
        try original.write(to: victim)
        try replacement.write(to: partial)
        for hard in [false, true] {
            if hard { try FileManager.default.linkItem(at: victim, to: destination) }
            else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim) }
            #expect(throws: (any Error).self) { try ModelPartialFile.promote(from: partial, to: destination) }
            #expect(throws: (any Error).self) { try ModelPartialFile.remove(at: destination) }
            #expect(try Data(contentsOf: victim) == original)
            #expect(try Data(contentsOf: partial) == replacement)
            try FileManager.default.removeItem(at: destination)
        }
    }

}
