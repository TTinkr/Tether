
import Darwin
import Foundation
import Testing
@testable import Tokens

@Suite struct DiagnosticsRotationTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func rotatesOnceTheCapWouldBePassedAndKeepsOneOlderFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("events.log")
        let older = Diagnostics.previousURL(for: log)
        let neighbour = root.appendingPathComponent("capture.log")
        try Data("a neighbour log\n".utf8).write(to: neighbour)

        for index in 0..<4 { Diagnostics.append(Data("line \(index) fictional\n".utf8), to: log, rotatingAt: 64) }
        // 4 lines of 17-18 bytes: the fourth would pass 64 bytes, so lines 0-2 moved to events.1.log.
        #expect(text(older) == "line 0 fictional\nline 1 fictional\nline 2 fictional\n")
        #expect(text(log) == "line 3 fictional\n")

        for index in 4..<8 { Diagnostics.append(Data("line \(index) fictional\n".utf8), to: log, rotatingAt: 64) }
        // Only one older file is kept: the second rotation replaced it.
        #expect(text(older) == "line 3 fictional\nline 4 fictional\nline 5 fictional\n")
        #expect(text(log) == "line 6 fictional\nline 7 fictional\n")
        #expect(text(neighbour) == "a neighbour log\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["capture.log", "events.1.log", "events.log"])
    }

    @Test func makesAMissingFolderAndNeverRotatesASingleLongLine() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("Logs/nested/events.log")
        let long = Data((String(repeating: "x", count: 100) + "\n").utf8)
        Diagnostics.append(long, to: log, rotatingAt: 64)
        #expect(text(log).count == 101)
        #expect(!FileManager.default.fileExists(atPath: Diagnostics.previousURL(for: log).path))
    }

    @Test func theRotatedNameFollowsTheLogName() {
        let folder = URL(fileURLWithPath: "/tmp/fictional", isDirectory: true)
        #expect(Diagnostics.previousURL(for: folder.appendingPathComponent("events.log")).lastPathComponent == "events.1.log")
        #expect(Diagnostics.previousURL(for: folder.appendingPathComponent("trace")).lastPathComponent == "trace.1")
        #expect(Diagnostics.rotationBytes == 16 << 20)
    }
    @Test func logsAndTheirDirectoryUseOwnerOnlyPermissions() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("events.log")
        try Data("fictional earlier line\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        Diagnostics.append(Data("fictional next line\n".utf8), to: log, rotatingAt: 1)
        for file in [log, Diagnostics.previousURL(for: log)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(text(log) == "fictional next line\n")
    }

    @Test func linkedLogsNeverAppendToOrRotateAnUnrelatedFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("unrelated.txt")
        let original = Data("fictional unrelated content\n".utf8)
        try original.write(to: victim)
        for (name, hard) in [("symbolic.log", false), ("hard.log", true)] {
            let log = root.appendingPathComponent(name)
            if hard { try FileManager.default.linkItem(at: victim, to: log) }
            else { try FileManager.default.createSymbolicLink(at: log, withDestinationURL: victim) }
            Diagnostics.append(Data("must not append\n".utf8), to: log, rotatingAt: 1)
            #expect(try Data(contentsOf: victim) == original)
            #expect(!FileManager.default.fileExists(atPath: Diagnostics.previousURL(for: log).path))
            try FileManager.default.removeItem(at: log)
        }
    }

    @Test func linkedOlderLogIsNotReplacedDuringRotation() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("events.log")
        let older = Diagnostics.previousURL(for: log)
        let victim = root.appendingPathComponent("unrelated.txt")
        let original = Data("fictional unrelated content\n".utf8)
        let current = Data("fictional existing log\n".utf8)
        try original.write(to: victim)
        try current.write(to: log)
        for hard in [false, true] {
            if hard { try FileManager.default.linkItem(at: victim, to: older) }
            else { try FileManager.default.createSymbolicLink(at: older, withDestinationURL: victim) }
            Diagnostics.append(Data("must not rotate\n".utf8), to: log, rotatingAt: 1)
            #expect(try Data(contentsOf: victim) == original)
            #expect(try Data(contentsOf: log) == current)
            #expect(try Data(contentsOf: older) == original)
            try FileManager.default.removeItem(at: older)
        }
    }

    @Test func namedPipeLogIsRefusedWithoutWaitingForAReader() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("events.log")
        #expect(mkfifo(log.path, 0o600) == 0)
        Diagnostics.append(Data("fictional line\n".utf8), to: log, rotatingAt: 64)
        var info = stat()
        #expect(lstat(log.path, &info) == 0)
        #expect((info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO))
    }

    @Test func linkedLogDirectoryIsRefused() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        Diagnostics.append(Data("fictional line\n".utf8), to: linked.appendingPathComponent("events.log"), rotatingAt: 64)
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }

}
