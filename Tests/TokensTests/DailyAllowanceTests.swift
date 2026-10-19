


//
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct DailyAllowanceTests {
    @Test static func run() throws {
        func check(_ value: Bool, _ message: String = "check failed") { precondition(value, message) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TTTAllowanceTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar      = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        var clock     = date(2026, 9, 19)
        let url       = root.appendingPathComponent("private/deliveries.json")
        let allowance = DailyAllowance(storeURL: url, calendar: calendar, now: { clock })
        try check(allowance.status().remaining == 5)
        let session = UUID()
        for outcome: DailyAllowance.Outcome in [.uncertain, .cancelled, .failed] {
            try check(allowance.recordDelivery(sessionID: session, outcome: outcome).remaining == 5)
        }
        precondition(!FileManager.default.fileExists(atPath: url.path))
        try check(!allowance.requiresDecorations(for: session))
        try check(allowance.recordDelivery(sessionID: session, outcome: .verifiedSuccess).remaining == 4)
        try check(allowance.recordDelivery(sessionID: session, outcome: .verifiedSuccess).remaining == 4)
        do { _ = try allowance.requiresDecorations(for: session); fatalError("Successful UUID reused") }
        catch DailyAllowance.Failure.alreadyDelivered { }
        let restarted = DailyAllowance(storeURL: url, calendar: calendar, now: { clock })
        try check(restarted.status().remaining == 4)
        for expected in (0...3).reversed() {
            let next = UUID()
            try check(!restarted.requiresDecorations(for: next))
            try check(restarted.recordDelivery(sessionID: next, outcome: .verifiedSuccess).remaining == expected)
        }
        let sixth = UUID()
        try check(allowance.requiresDecorations(for: sixth))
        try check(allowance.recordDelivery(sessionID: sixth, outcome: .verifiedSuccess).remaining == 0)
        try check(allowance.status().used == 5)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try allowance.status()
        let correctedDirectory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let correctedFile = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((correctedDirectory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition((correctedFile[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        clock = try allowance.status().resetsAt.addingTimeInterval(-0.001)
        try check(allowance.status().remaining == 0)
        clock = clock.addingTimeInterval(0.002)
        try check(allowance.status().remaining == 5)
        /*
        A decorated payload prepared before midnight must not spend a clean
        use merely because its verified completion arrives after midnight.
        */
        try check(allowance.recordDelivery(sessionID: UUID(), outcome: .verifiedSuccess, wasClean: false).remaining == 5)
        try check(allowance.recordDelivery(sessionID: session, outcome: .verifiedSuccess).remaining == 5)
        clock = date(2026, 9, 19)
        try check(allowance.status().remaining == 0, "Clock rollback erased used day")
        for (month, day, expectedHours) in [(3, 8, 23.0), (11, 1, 25.0)] {
            clock = date(2026, month, day, 0)
            try check(allowance.status().resetsAt.timeIntervalSince(clock) == expectedHours * 3600)
        }
        try Data("not json".utf8).write(to: url)
        do { _ = try restarted.status(); fatalError("Corruption silently reset") }
        catch DailyAllowance.Failure.corruptStore { }
        try check(String(contentsOf: url, encoding: .utf8) == "not json")
        let blocked = root.appendingPathComponent("file-not-directory")
        try Data("x".utf8).write(to: blocked)
        let unavailable = DailyAllowance(storeURL: blocked.appendingPathComponent("store.json"))
        do { _ = try unavailable.status(); fatalError("Storage error silently reset") }
        catch DailyAllowance.Failure.storageUnavailable { }
        print("PASS five clean verified deliveries, sixth decorated, non-success no consume, UUID retry/restart dedupe, midnight/rollback/DST, private permissions, corruption and IO failure")
    }
}

