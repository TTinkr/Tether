


//
import Foundation
import Testing
import TokensCore
@testable import Tokens

@Suite struct PasteLedgerReportTests {
    @Test func writesJSONAndMarkdownFromAnInputLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("events.log")
        try """
        2026-10-13T10:00:00Z app=t pid=1 capture_target bundle=com.anthropic.claudefordesktop restored=false element=true range=true
        2026-10-13T10:00:01Z app=t pid=1 paste_ack bundle=com.anthropic.claudefordesktop readable=true changed_ms=none probe=false verified=false staged=0 reason=text
        2026-10-13T10:00:01Z app=t pid=1 delivery_unverified session=A
        not an event line

        """.write(to: log, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("out")
        #expect(PasteLedgerReport.run(outputDirectory: out.path, inputPath: log.path) == 0)
        let ledger = try JSONDecoder().decode(PasteLedger.self, from: Data(contentsOf: out.appendingPathComponent("ledger.json")))
        #expect(ledger.linesUnparsed == 1)
        #expect(ledger.apps.first?.name == "Claude" && ledger.apps.first?.counts.missed == 1)
        let markdown = try String(contentsOf: out.appendingPathComponent("ledger.md"), encoding: .utf8)
        #expect(markdown.contains("| Claude | 1 |"))
    }

    @Test func missingLogFailsWithoutWriting() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-ledger-\(UUID().uuidString)")
        #expect(PasteLedgerReport.run(outputDirectory: root.path, inputPath: root.appendingPathComponent("absent.log").path) == 2)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

