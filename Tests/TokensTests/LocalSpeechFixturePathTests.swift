import Foundation
import Testing
@testable import Tokens

@Suite struct LocalSpeechFixturePathTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func samePathAndAliasCannotOverwriteInput() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("fictional.aiff")
        let bytes = Data("fictional fixture sentinel".utf8)
        try bytes.write(to: input)
        #expect(LocalSpeechFixtureProof.reserveReceipt(input: input.path, output: input.path) == nil)
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        #expect(LocalSpeechFixtureProof.reserveReceipt(input: input.path, output: alias.path) == nil)
        #expect(try Data(contentsOf: input) == bytes)
    }
    @Test func existingOutputIsPreserved() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.aiff")
        let output = dir.appendingPathComponent("receipt.json")
        let bytes = Data("existing receipt sentinel".utf8)
        try bytes.write(to: output)
        #expect(LocalSpeechFixtureProof.reserveReceipt(input: input.path, output: output.path) == nil)
        #expect(try Data(contentsOf: output) == bytes)
    }
    @Test func freshReceiptIsExclusivelyReserved() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.aiff")
        let output = dir.appendingPathComponent("receipt.json")
        let reserved = LocalSpeechFixtureProof.reserveReceipt(input: input.path, output: output.path)
        #expect(reserved != nil)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(LocalSpeechFixtureProof.reserveReceipt(input: input.path, output: output.path) == nil)
    }
}
