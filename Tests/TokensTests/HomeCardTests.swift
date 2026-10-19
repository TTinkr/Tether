import Foundation
import Testing
@testable import Tokens

/// Build 83 Home side card (approved mock): words this week, usual speed, streak.
@Suite("Home side card")
struct HomeCardTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var now: Date { Date(timeIntervalSince1970: 1_792_368_000) }  // 2026-10-18 00:00 UTC + 0

    private func talk(daysAgo: Int, _ text: String = "one two three") -> PromptHistoryEntry {
        PromptHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(Double(-daysAgo) * 86_400 + 3_600), text: text)
    }

    @Test func noTalksMeansTheFirstTalkCard() {
        #expect(TokensHomeCardSummary.make(history: [], now: now, calendar: calendar) == TokensHomeCardSummary())
    }

    @Test func weekCountsTheLastSevenDaysOnly() {
        let history = [talk(daysAgo: 0), talk(daysAgo: 6, "a b"), talk(daysAgo: 7, "not this week at all")]
        let summary = TokensHomeCardSummary.make(history: history, now: now, calendar: calendar)
        #expect(summary.weekWords == 5)
        #expect(summary.hasTalks)
    }

    /// Unbroken days ending today, or ending yesterday before today's first talk.
    @Test func streakCountsDaysInARow() {
        let day = { (n: Int) in now.addingTimeInterval(Double(-n) * 86_400 + 3_600) }
        #expect(TokensHomeCardSummary.streak(days: [day(0), day(1), day(2), day(4)], now: now, calendar: calendar) == 3)
        #expect(TokensHomeCardSummary.streak(days: [day(1), day(2)], now: now, calendar: calendar) == 2)
        #expect(TokensHomeCardSummary.streak(days: [day(2)], now: now, calendar: calendar) == 0)
    }

    @Test func speedIsTheMedianOfStatedSpeeds() {
        #expect(TokensHomeCardSummary.median([]) == nil)
        #expect(TokensHomeCardSummary.median([150, 120, 180]) == 150)
        #expect(TokensHomeCardSummary.median([100, 140]) == 120)
    }

    @Test func firstTalkStepsFollowTheKeyAndMode() {
        let tap = TokensHomeFirstTalk.steps(keyName: "Right Option", tap: true)
        #expect(tap.count == 3 && tap[1].contains("Tap Right Option") && tap[2].contains("Tap it again"))
        #expect(TokensHomeFirstTalk.steps(keyName: "Fn", tap: false)[2].contains("Let go"))
    }
}
