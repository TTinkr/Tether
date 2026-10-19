import Foundation
import Testing
@testable import TokensCore

/// Executes the real raw streaming driver with synthetic transport faults.
/// Injected clocks measure model time only; no microphone, AX, paste or Return.
struct AcknowledgedRevealChaosTests {
    private func rawPlan(words: Int = 69) -> TranscriptRevealPlan {
        let samples = ["café", "e\u{301}", "👩🏽‍💻", "1234567910", "repeat", "repeat", "終わり"]
        let body = (0..<words).map { samples[$0 % samples.count] }.joined(separator: " ") + "\r\n"
        return TranscriptRevealPlan(marker: "", body: body, metadata: "", spokenWordCount: words)
    }

    private final class Probe {
        let plan: TranscriptRevealPlan
        var micros: UInt64 = 0
        var seed: UInt64
        var delayFloor: UInt64
        var posted: [String] = []
        var acknowledged: [String] = []
        var postTimes: [UInt64] = []
        var pending: String?
        var received: String
        var cancellation: UInt64?
        var failureAt: Int?
        var failureReason = "unacknowledged"
        var uncertainAt: Int?
        var waits = 0

        init(plan: TranscriptRevealPlan, seed: UInt64, prefix: String = "", delayFloor: UInt64 = 0) {
            self.plan = plan; self.seed = seed; self.delayFloor = delayFloor; received = prefix
        }
        func guardFailure() -> String? {
            if waits > 2_000 { return "test_wait_bound" }
            if let cancellation, micros >= cancellation { return "cancelled" }
            return nil
        }
        func post(_ piece: String) -> AcknowledgedRevealDriver.PostResult {
            #expect(pending == nil, "A second write must not replace unacknowledged bytes")
            #expect(!piece.isEmpty)
            #expect(plan.completeText.utf8.starts(with: (received + piece).utf8))
            pending = piece; posted.append(piece); postTimes.append(micros)
            if posted.count == uncertainAt { return .uncertain("paste_event_failed") }
            return .posted
        }
        func acknowledge(_ piece: String) -> String? {
            #expect(pending == piece)
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            micros += delayFloor + ((seed >> 32) % 16_001)
            // A failed readback may follow a write that physically landed.
            // Keeping it here catches a subsequent retry of uncertain text.
            received += piece; pending = nil
            if posted.count == failureAt {
                if failureReason == "unexpected_editor_text" { received += " foreign edit" }
                return failureReason
            }
            acknowledged.append(piece)
            return nil
        }
        func wait(_ delay: UInt32) { micros += UInt64(delay); waits += 1 }
    }

    private func runSyncProbe(_ probe: Probe, prefix: String = "",
                      configuration: AcknowledgedRevealDriver.Configuration = .init()) -> AcknowledgedRevealDriver.Outcome {
        AcknowledgedRevealDriver.run(plan: probe.plan, acknowledgedPrefix: prefix,
            configuration: configuration, guardFailure: { probe.guardFailure() },
            post: { probe.post($0) }, acknowledge: { probe.acknowledge($0) },
            now: { Double(probe.micros) / 1_000_000 }, wait: { probe.wait($0) })
    }

    @MainActor private func runAsyncProbe(_ probe: Probe, prefix: String = "",
                                 configuration: AcknowledgedRevealDriver.Configuration = .init()) async -> AcknowledgedRevealDriver.Outcome {
        await AcknowledgedRevealDriver.runAsync(plan: probe.plan, acknowledgedPrefix: prefix,
            configuration: configuration, guardFailure: { probe.guardFailure() },
            post: { probe.post($0) }, acknowledge: {
                await Task.yield()
                return probe.acknowledge($0)
            }, now: { Double(probe.micros) / 1_000_000 }, wait: {
                await Task.yield()
                probe.wait($0)
            })
    }

    @Test func seededRawReadbackDelaysPreserveBytesAndRecordFirstPostLatency() {
        var firstPosts: [UInt64] = [], completion: [UInt64] = []
        for seed in 1...48 {
            let words = [3, 16, 69, 230][seed % 4]
            let floor = [UInt64(0), 8_000, 64_000, 250_000][(seed / 4) % 4]
            let probe = Probe(plan: rawPlan(words: words), seed: UInt64(seed), delayFloor: floor)
            let result = runSyncProbe(probe)
            #expect(result == .delivered(acknowledgedWrites: probe.posted.count))
            #expect(probe.posted == probe.acknowledged)
            #expect(probe.received.utf8.elementsEqual(probe.plan.completeText.utf8))
            #expect(probe.posted.allSatisfy { $0.count <= 96 })
            #expect(probe.pending == nil)
            #expect(probe.waits < 2_000)
            if let first = probe.postTimes.first { firstPosts.append(first) }
            completion.append(probe.micros)
        }
        #expect(firstPosts.count == 48)
        print("REVEAL_CHAOS synthetic_raw cases=48 first_post_us_min=\(firstPosts.min() ?? 0) first_post_us_max=\(firstPosts.max() ?? 0) completion_us_max=\(completion.max() ?? 0) physical_latency=false")
    }

    @Test @MainActor func seededAsyncAndSyncRawTransportsHaveIdenticalOutcomes() async {
        for seed in 1...16 {
            let value = rawPlan(words: seed.isMultiple(of: 2) ? 69 : 16)
            let syncProbe = Probe(plan: value, seed: UInt64(seed), delayFloor: 32_000)
            let asyncProbe = Probe(plan: value, seed: UInt64(seed), delayFloor: 32_000)
            var config = AcknowledgedRevealDriver.Configuration()
            config.deferTrailingWhitespace = seed.isMultiple(of: 2)
            if seed.isMultiple(of: 3) {
                syncProbe.cancellation = 80_000; asyncProbe.cancellation = 80_000
            }
            let expected = runSyncProbe(syncProbe, configuration: config)
            let actual = await runAsyncProbe(asyncProbe, configuration: config)
            #expect(actual == expected)
            #expect(asyncProbe.posted == syncProbe.posted)
            #expect(asyncProbe.acknowledged == syncProbe.acknowledged)
            #expect(asyncProbe.postTimes == syncProbe.postTimes)
            #expect(asyncProbe.received.utf8.elementsEqual(syncProbe.received.utf8))
        }
    }

    @Test func failedReadbackAtSeveralWriteBoundariesStopsWithOnlyAcknowledgedPrefix() {
        for reason in ["unacknowledged", "unexpected_editor_text", "caret_changed", "clipboard_replaced", "cancelled"] {
            for failedWrite in 1...4 {
                let probe = Probe(plan: rawPlan(), seed: UInt64(failedWrite), delayFloor: 64_000)
                probe.failureAt = failedWrite; probe.failureReason = reason
                var config = AcknowledgedRevealDriver.Configuration()
                config.maximumBodyBatch = 8
                let result = runSyncProbe(probe, configuration: config)
                #expect(result == .stopped(reason: reason, postedWrites: failedWrite,
                    acknowledgedWrites: failedWrite - 1, acknowledgedPayload: probe.acknowledged.joined()))
                #expect(probe.posted.count == failedWrite)
                #expect(probe.acknowledged == Array(probe.posted.dropLast()))
                #expect(probe.plan.completeText.utf8.starts(with: probe.posted.joined().utf8))
                #expect(probe.pending == nil)
            }
        }
    }

    @Test func unicodeAndLiteralAnnotationPrefixesContinueExactlyWhileDivergenceRefuses() {
        let start = "Start café 👩🏽‍💻 e\u{301} "
        let body = start + "<char>RILEY</char> end."
        let value = TranscriptRevealPlan(marker: "", body: body, metadata: "\nMETA", spokenWordCount: 7)
        for prefix in ["", "Start ", "Start café ", "Start café 👩🏽‍💻 ", start, start + "<ch", start + "<char>RI", body, value.completeText] {
            let probe = Probe(plan: value, seed: 2, prefix: prefix)
            let result = runSyncProbe(probe, prefix: prefix)
            #expect(result == .delivered(acknowledgedWrites: probe.posted.count))
            #expect(probe.received.utf8.elementsEqual(value.completeText.utf8))
            #expect((prefix + probe.posted.joined()).utf8.elementsEqual(value.completeText.utf8))
        }
        let invalid: [(String, String)] = [
            ("wrong", "prefix_diverged"),
            ("Start cafe\u{301} ", "prefix_diverged"), // Canonically equal is not byte-equal.
            (body + "\nM", "prefix_inside_metadata")
        ]
        for (prefix, reason) in invalid {
            let probe = Probe(plan: value, seed: 2, prefix: prefix)
            let result = runSyncProbe(probe, prefix: prefix)
            #expect(result == .stopped(reason: reason, postedWrites: 0,
                acknowledgedWrites: 0, acknowledgedPayload: prefix))
            #expect(probe.posted.isEmpty && probe.acknowledged.isEmpty)
        }
    }

    @Test @MainActor func cancellationDeadlinesNeverAllowAPostAfterTheGuardChanges() async {
        for deferSpaces in [false, true] {
            for deadline in [UInt64(0), 1, 8_333, 25_000, 100_000, 300_000, 1_000_000] {
                let probe = Probe(plan: rawPlan(), seed: deadline + 1, delayFloor: 20_000)
                probe.cancellation = deadline
                var config = AcknowledgedRevealDriver.Configuration()
                config.deferTrailingWhitespace = deferSpaces
                config.maximumBodyBatch = 24
                let result = await runAsyncProbe(probe, configuration: config)
                #expect(probe.postTimes.allSatisfy { $0 < deadline })
                #expect(probe.posted == probe.acknowledged)
                #expect(probe.plan.completeText.utf8.starts(with: probe.received.utf8))
                if case .stopped(let reason, let posted, let acknowledged, let payload) = result {
                    #expect(reason == "cancelled")
                    #expect(posted == probe.posted.count && acknowledged == probe.acknowledged.count)
                    #expect(payload.utf8.elementsEqual(probe.received.utf8))
                } else {
                    #expect(probe.received.utf8.elementsEqual(probe.plan.completeText.utf8))
                }
            }
        }
    }

    @Test func uncertainPostAtSeveralBoundariesNeverAcknowledgesOrReplaysIt() {
        for uncertainWrite in 1...8 {
            let probe = Probe(plan: rawPlan(), seed: UInt64(uncertainWrite), delayFloor: 8_000)
            probe.uncertainAt = uncertainWrite
            var config = AcknowledgedRevealDriver.Configuration()
            config.maximumBodyBatch = 8
            let result = runSyncProbe(probe, configuration: config)
            #expect(result == .stopped(reason: "paste_event_failed", postedWrites: uncertainWrite,
                acknowledgedWrites: uncertainWrite - 1, acknowledgedPayload: probe.acknowledged.joined()))
            #expect(probe.posted.count == uncertainWrite)
            #expect(probe.acknowledged == Array(probe.posted.dropLast()))
            #expect(probe.pending == probe.posted.last)
            #expect(probe.plan.completeText.utf8.starts(with: probe.posted.joined().utf8))
        }
    }
}
