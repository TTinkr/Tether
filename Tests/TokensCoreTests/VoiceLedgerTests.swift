


//
import Foundation
import Testing
@testable import TokensCore

struct VoiceLedgerTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // 2026-10-13 18:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_914_400)
    static func daysAgo(_ days: Double, hour: Double = 0) -> Date { now.addingTimeInterval(-days * 86_400 + hour * 3_600) }

    static func envelope(_ body: String, stats: String) -> String {
        "# π\n" + body + "\n\n---\n\n" + AuthoredPrompt.metadataHeading + "\n\n" + stats
    }

    @Test func parsesCurrentEnvelopeIntoNumbersOnly() throws {
        let text = Self.envelope("Fix the build.\n*[pause 2.3500]* then *[pause 0.5000]* rename it",
                                 stats: "> *3.0000s · 6 words · 240 wpm · 2x thinking (2.8500s)*")
        let record = try #require(VoiceRecord.parse(text: text, date: Self.now, app: "com.openai.codex"))
        #expect(record.app == .codex)
        #expect(record.words == 6)
        #expect(record.wpm == 240)
        #expect(record.seconds == 3)
        #expect(record.pauseCount == 2)
        #expect(record.longestPause == 2.35)
    }

    @Test func parsesLegacyReceiptAndPlainText() throws {
        let legacy = "⟨π\nhello there agent\n17 characters · 3 words · 1.5s · 120 wpm ⟩"
        let receipt = try #require(VoiceRecord.parse(text: legacy, date: Self.now, app: nil))
        #expect(receipt.words == 3 && receipt.wpm == 120 && receipt.seconds == 1.5 && receipt.app == .other)
        let plain = try #require(VoiceRecord.parse(text: "just four plain words", date: Self.now, app: "Terminal"))
        #expect(plain.words == 4 && plain.wpm == nil && plain.app == .terminal)
        #expect(VoiceRecord.parse(text: "   ", date: Self.now, app: nil) == nil)
    }

    @Test func bucketsKnownAgentApps() {
        #expect(VoiceApp.classify("com.anthropic.claudefordesktop") == .claude)
        #expect(VoiceApp.classify("com.todesktop.230313mzl4w4u92") == .cursor)
        #expect(VoiceApp.classify("com.googlecode.iterm2") == .terminal)
        #expect(VoiceApp.classify("com.mitchellh.ghostty") == .terminal)
        #expect(VoiceApp.classify("com.apple.Safari") == .other)
        #expect(VoiceApp.classify(nil) == .other)
    }

    @Test func aggregatesDaysAppsAndFastShare() throws {
        let records = [
            VoiceRecord(date: Self.daysAgo(0), app: .codex, words: 100, wpm: 250, pauseCount: 4, longestPause: 3.2),
            VoiceRecord(date: Self.daysAgo(0), app: .codex, words: 50, wpm: 200, pauseCount: 1, longestPause: 1.0),
            VoiceRecord(date: Self.daysAgo(0), app: .claude, words: 50, wpm: 300),
            VoiceRecord(date: Self.daysAgo(1), app: .terminal, words: 10),
            VoiceRecord(date: Self.daysAgo(20), app: .cursor, words: 999, wpm: 100),
        ]
        let ledger = VoiceLedger.build(records, now: Self.now, calendar: Self.utc)
        #expect(ledger.days.count == 14)
        let today = try #require(ledger.days.last)
        #expect(today.talks == 3 && today.words == 200)
        #expect(today.medianWPM == 250)
        #expect(today.fastShare == 2.0 / 3.0)
        #expect(today.pausesPer100Words == 2.5)
        #expect(today.longestPause == 3.2)
        // The 20-day-old Cursor talk is outside the window, so Cursor is not listed.
        #expect(ledger.apps.map(\.id) == ["codex", "claude", "terminal"])
        #expect(ledger.apps[0].medianWPM == 225)
        #expect(ledger.apps[2].medianWPM == nil && ledger.apps[2].fastShare == nil)
        #expect(ledger.total.talks == 4 && ledger.total.words == 210)
    }

    @Test func streakCountsBackFromTodayOrYesterday() {
        let active = [0.0, 1, 2, 4].map { VoiceRecord(date: Self.daysAgo($0), app: .other, words: 1) }
        #expect(VoiceLedger.build(active, now: Self.now, calendar: Self.utc).streak == 3)
        let fromYesterday = [1.0, 2].map { VoiceRecord(date: Self.daysAgo($0), app: .other, words: 1) }
        #expect(VoiceLedger.build(fromYesterday, now: Self.now, calendar: Self.utc).streak == 2)
        #expect(VoiceLedger.build([], now: Self.now, calendar: Self.utc).streak == 0)
    }

    @Test func attributesNearestDeliveryEvent() throws {
        let log = """
        2026-10-13T17:59:00Z app=x pid=1 delivery_preflight bundle=com.openai.codex window=true
        2026-10-13T18:00:30Z app=x pid=1 delivery_preflight bundle=com.anthropic.claudefordesktop window=true
        2026-10-13T18:00:31Z app=x pid=1 staging_plan bundle=com.apple.Terminal eligible=true
        2026-10-13T18:30:00Z app=x pid=1 delivery_preflight bundle=unknown window=false
        """
        let events = VoiceAppAttribution.events(fromLog: log)
        #expect(events.count == 2)
        #expect(VoiceAppAttribution.app(at: Self.now, events: events) == "com.anthropic.claudefordesktop")
        #expect(VoiceAppAttribution.app(at: Self.now.addingTimeInterval(3_600), events: events) == nil)
    }

    @Test func medianHandlesEvenAndOdd() {
        #expect(VoiceLedger.median([]) == nil)
        #expect(VoiceLedger.median([3, 1, 2]) == 2)
        #expect(VoiceLedger.median([200, 251]) == 226)
    }
}

