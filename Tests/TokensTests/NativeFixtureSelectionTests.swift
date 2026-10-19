import Foundation
import Testing
@testable import Tokens

@Suite struct NativeFixtureSelectionTests {
    let bundle = "com.tinkr.testpad"
    let id = "tp-dev68native01"
    func candidate(pid: Int32, owned: Bool = true, secure: Bool = false, windows: Int? = 1,
                   focused: Bool = true, caret: Int? = nil) -> NativeEditorFixtureProof.CandidateEvidence {
        let text = NativeEditorFixtureProof.sentinel(id)
        return .init(pid: pid, value: owned ? text : "foreign content",
            range: NSRange(location: caret ?? text.utf16.count, length: 0), secure: secure,
            windowCount: windows, hasFocusedWindow: focused)
    }
    @Test func preparationRequiresExactDocumentAndCollapsedCaret() {
        var item = candidate(pid: 2, caret: 0)
        item.identifier = "testpad.target.tp-dev68n01"
        item.title = "Owned fixture [tp-dev68n01]"
        #expect(NativeEditorFixtureProof.mayPrepare(bundle: bundle, id: id, document: "tp-dev68n01", candidate: item))
        #expect(!NativeEditorFixtureProof.mayPrepare(bundle: bundle, id: id, document: "tp-peer01", candidate: item))
        #expect(!NativeEditorFixtureProof.mayPrepare(bundle: "com.apple.Notes", id: id, document: "tp-dev68n01", candidate: item))
        #expect(!NativeEditorFixtureProof.mayPrepare(bundle: bundle, id: id, document: "tp-BAD", candidate: item))
        #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id, candidates: [item]) == nil)
        #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id, candidates: [item], prepareDocument: "tp-dev68n01") == 0)
        #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id, candidates: [item, item], prepareDocument: "tp-dev68n01") == nil)
        var selected = candidate(pid: 2)
        selected = .init(pid: 2, value: item.value, range: NSRange(location: 0, length: 1), secure: false,
            windowCount: 1, hasFocusedWindow: true, identifier: item.identifier, title: item.title)
        #expect(!NativeEditorFixtureProof.mayPrepare(bundle: bundle, id: id, document: "tp-dev68n01", candidate: selected))
    }
    @Test func selectsOwnedInstanceInsteadOfFirstPeer() {
        #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id,
            candidates: [candidate(pid: 1, owned: false), candidate(pid: 2)]) == 1)
    }
    @Test func multipleOwnedInstancesAndAmbiguousWindowsRefuse() {
        #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id,
            candidates: [candidate(pid: 1), candidate(pid: 2)]) == nil)
        for count: Int? in [nil, 0, 2] {
            #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id,
                candidates: [candidate(pid: 1, windows: count)]) == nil)
        }
    }
    @Test func secureMissingFocusAndWrongCaretCannotAuthorize() {
        for item in [candidate(pid: 1, secure: true), candidate(pid: 1, focused: false), candidate(pid: 1, caret: 0)] {
            #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: bundle, id: id, candidates: [item]) == nil)
        }
        #expect(NativeEditorFixtureProof.uniqueOwnedIndex(bundle: "foreign.bundle", id: id, candidates: [candidate(pid: 1)]) == nil)
    }

    @Test func fileFixturePreservesExactUTF8WithoutRendering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional.txt")
        let text = "\u{FEFF}  R I L E Y <char>literal</char> café e\u{301} 👩🏽‍💻\r\n 1234567910\n\n"
        let bytes = Data(text.utf8)
        try bytes.write(to: file)
        let frozen = try #require(try NativeEditorFixtureProof.fixtureText(arguments:
            ["--raw-transcript", "--fixture-text", file.path]))
        #expect(Data(frozen.utf8) == bytes)
        #expect(try NativeEditorFixtureProof.fixtureText(arguments: []) == nil)
    }

    @Test func fileFixtureRejectsInvalidArgumentsBeforeReading() throws {
        typealias Failure = NativeEditorFixtureProof.FixtureTextError
        let cases: [([String], Failure)] = [
            (["--fixture-text"], .missingFixtureTextPath),
            (["--fixture-text", "--raw-transcript"], .missingFixtureTextPath),
            (["--fixture-text", "/not-read"], .requiresRawMode),
            (["--raw-transcript", "--fixture-text", "relative.txt"], .pathMustBeAbsolute),
            (["--raw-transcript", "--fixture-text", "/first", "--fixture-text", "/second"], .duplicateFixtureText)
        ]
        for (arguments, expected) in cases {
            do {
                _ = try NativeEditorFixtureProof.fixtureText(arguments: arguments)
                Issue.record("Expected explicit fixture error")
            } catch let error as Failure { #expect(error == expected) }
        }
    }

    @Test func fileFixtureEnforcesByteLimitStrictEncodingAndRegularFiles() throws {
        typealias Failure = NativeEditorFixtureProof.FixtureTextError
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional.txt")
        let arguments = ["--raw-transcript", "--fixture-text", file.path]
        let limit = NativeEditorFixtureProof.maximumFixtureTextBytes
        try Data(repeating: 65, count: limit).write(to: file)
        #expect(try NativeEditorFixtureProof.fixtureText(arguments: arguments)?.utf8.count == limit)
        let cases: [(Data, Failure)] = [
            (Data(repeating: 65, count: limit + 1), .tooLarge),
            (Data([0xff, 0xfe]), .invalidUTF8),
            (Data(), .empty),
            (Data(" \r\n\t".utf8), .empty)
        ]
        for (bytes, expected) in cases {
            try bytes.write(to: file)
            do {
                _ = try NativeEditorFixtureProof.fixtureText(arguments: arguments)
                Issue.record("Expected explicit fixture error")
            } catch let error as Failure { #expect(error == expected) }
        }
        do {
            _ = try NativeEditorFixtureProof.fixtureText(arguments: ["--raw-transcript", "--fixture-text", directory.path])
            Issue.record("Directory must not be read as a text fixture")
        } catch let error as Failure { #expect(error == .notRegularFile) }
        do {
            _ = try NativeEditorFixtureProof.fixtureText(arguments: ["--raw-transcript", "--fixture-text", directory.appendingPathComponent("absent").path])
            Issue.record("Missing file must report an input error")
        } catch let error as Failure { #expect(error == .unreadable) }
    }
}
