


//
import Foundation
import TokensCore

/*
--paste-ledger <out-dir> [--paste-ledger-input <events.log>]. Without an input it reads this
build's own Diagnostics.url. Exit 0 on success, 2 when the log cannot be read, 1 when a file
could not be written.
*/
enum PasteLedgerReport {
    static func run(outputDirectory: String, inputPath: String?) -> Int32 {
        let input = inputPath.map { URL(fileURLWithPath: $0) } ?? Diagnostics.url
        guard let data = FileManager.default.contents(atPath: input.path) else {
            print("PASTE_LEDGER lines=0 error=unreadable")
            return 2
        }
        // This build's own log also reads the older file a size rotation left beside it (build 81).
        let older = inputPath == nil ? FileManager.default.contents(atPath: Diagnostics.previousURL.path) : nil
        // Lossy decode: a torn or non-UTF-8 line becomes an unparsed line, not a failed run.
        let ledger = PasteLedgerBuilder.build(lines: [older, data].compactMap { $0 }.map { String(decoding: $0, as: UTF8.self) })
        let root = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil,
              let json = try? encoder.encode(ledger),
              (try? json.write(to: root.appendingPathComponent("ledger.json"), options: .atomic)) != nil,
              (try? ledger.markdown().write(to: root.appendingPathComponent("ledger.md"), atomically: true, encoding: .utf8)) != nil
        else {
            print("PASTE_LEDGER lines=\(ledger.linesRead) error=write_failed")
            return 1
        }
        let o = ledger.overall
        print("PASTE_LEDGER lines=\(ledger.linesRead) unparsed=\(ledger.linesUnparsed) pastes=\(o.pastes) landed=\(o.landed) landed_unverified=\(o.landedUnverified) missed=\(o.missed) held=\(o.held) apps=\(ledger.apps.count)")
        return 0
    }
}

