


//
import Foundation
import Testing
@testable import Tokens
import TokensCore

@Suite struct VoiceLedgerSourceTests {
    static let formatter = ISO8601DateFormatter()

    static func line(_ date: Date, bundle: String) -> String {
        "\(formatter.string(from: date)) app=x pid=1 delivery_preflight bundle=\(bundle) window=true\n"
    }

    static func writeLog(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-ledger-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An event older than any fixed tail (here 200 KB of newer filler vs 4 KB chunks) is still found.
    @Test func readsPastTheOldTailBoundaryUntilTheWindowStart() throws {
        let now = Date(timeIntervalSince1970: 1_760_378_400)
        let old = now.addingTimeInterval(-12 * 86_400)
        var text = Self.line(now.addingTimeInterval(-30 * 86_400), bundle: "com.apple.Safari")
        text += Self.line(old, bundle: "com.anthropic.claudefordesktop")
        let filler = Self.line(now.addingTimeInterval(-3_600), bundle: "com.openai.codex")
        text += String(repeating: filler, count: 200_000 / filler.utf8.count)
        let url = try Self.writeLog(text)
        defer { try? FileManager.default.removeItem(at: url) }

        let since = now.addingTimeInterval(-14 * 86_400)
        let events = VoiceLedgerSource.deliveryEvents(url: url, since: since, chunk: 4_096)
        #expect(events.contains { $0.bundle == "com.anthropic.claudefordesktop" })
        #expect(VoiceAppAttribution.app(at: old.addingTimeInterval(5), events: events) == "com.anthropic.claudefordesktop")
        #expect(events.allSatisfy { $0.date >= since.addingTimeInterval(-40 * 86_400) })
    }

    /// The read stops once it reaches a line older than `since`, and never exceeds the hard cap.
    @Test func stopsAtWindowStartAndHardCap() throws {
        let now = Date(timeIntervalSince1970: 1_760_378_400)
        let ancient = Self.line(now.addingTimeInterval(-60 * 86_400), bundle: "com.apple.Terminal")
        let recent = Self.line(now.addingTimeInterval(-60), bundle: "com.openai.codex")
        let text = String(repeating: ancient, count: 2_000) + String(repeating: recent, count: 50)
        let url = try Self.writeLog(text)
        defer { try? FileManager.default.removeItem(at: url) }

        let stopped = VoiceLedgerSource.deliveryEvents(url: url, since: now.addingTimeInterval(-86_400), chunk: 1_024)
        let terminal = stopped.filter { $0.bundle == "com.apple.Terminal" }.count
        #expect(stopped.filter { $0.bundle == "com.openai.codex" }.count == 50)
        #expect(terminal < 30)

        let capped = VoiceLedgerSource.deliveryEvents(url: url, since: .distantPast, chunk: 1_024, hardCap: 2_048)
        #expect(capped.count < 50)
        #expect(VoiceLedgerSource.deliveryEvents(url: url.appendingPathExtension("missing"), since: now).isEmpty)
    }

    /// Build 81: after events.log is rotated, the window's older lines are read from events.1.log.
    @Test func readsOnIntoTheRotatedLogWhenTheCurrentOneStartsInsideTheWindow() throws {
        let now = Date(timeIntervalSince1970: 1_760_378_400)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-ledger-rotated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("events.log")
        #expect(Diagnostics.previousURL(for: current).lastPathComponent == "events.1.log")
        let older = Self.line(now.addingTimeInterval(-30 * 86_400), bundle: "com.apple.Terminal")
            + Self.line(now.addingTimeInterval(-10 * 86_400), bundle: "com.anthropic.claudefordesktop")
        try Data(older.utf8).write(to: Diagnostics.previousURL(for: current))
        try Data(Self.line(now.addingTimeInterval(-60), bundle: "com.openai.codex").utf8).write(to: current)

        let events = VoiceLedgerSource.deliveryEvents(url: current, since: now.addingTimeInterval(-14 * 86_400))
        #expect(events.map(\.bundle).suffix(2) == ["com.anthropic.claudefordesktop", "com.openai.codex"])

        // When events.log alone already reaches back past the window, the older file is not read.
        try Data((Self.line(now.addingTimeInterval(-20 * 86_400), bundle: "com.apple.Safari")
            + Self.line(now.addingTimeInterval(-60), bundle: "com.openai.codex")).utf8).write(to: current)
        let covered = VoiceLedgerSource.deliveryEvents(url: current, since: now.addingTimeInterval(-14 * 86_400))
        #expect(!covered.contains { $0.bundle == "com.anthropic.claudefordesktop" })
    }

    @Test func windowStartCoversFourteenDays() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_378_400)
        let start = VoiceLedgerSource.windowStart(now: now, calendar: utc)
        #expect(now.timeIntervalSince(start) > 14 * 86_400)
        #expect(now.timeIntervalSince(start) < 15 * 86_400)
    }
}

