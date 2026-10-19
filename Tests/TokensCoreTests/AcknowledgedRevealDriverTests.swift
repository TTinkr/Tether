import Foundation
import Testing
@testable import TokensCore

struct AcknowledgedRevealDriverTests {
    let marker = "# π\n", metadata = "\n\n---\n\n# Metadata\n\n> exact final counts"

    func plan(_ body: String, words: Int = 69) -> TranscriptRevealPlan {
        .init(marker: marker, body: body, metadata: metadata, spokenWordCount: words)
    }

    @Test @MainActor func asyncWaitServicesScheduledCancellationWithoutAnotherWrite() async {
        var cancelled = false, callbackRan = false, pieces: [String] = [], time = 0.0
        let result = await AcknowledgedRevealDriver.runAsync(plan: plan("one two three four five"),
            guardFailure: { cancelled ? "cancelled" : nil },
            post: { pieces.append($0); return .posted }, acknowledge: { _ in nil },
            now: { time }, wait: { delay in
                // This callback needs the same actor as delivery. A blocking
                // pacing sleep would prevent it from handling Return/cancellation.
                let callback = Task { @MainActor in
                    callbackRan = true
                    cancelled = true
                }
                await callback.value
                time += Double(delay) / 1_000_000
            })
        #expect(callbackRan)
        #expect(pieces == [marker])
        #expect(result == .stopped(reason: "cancelled", postedWrites: 1,
                                  acknowledgedWrites: 1, acknowledgedPayload: marker))
    }

    @Test @MainActor func asyncAcknowledgementServicesCallbackAndStillStopsOnGuard() async {
        var cancelled = false, pieces: [String] = []
        let result = await AcknowledgedRevealDriver.runAsync(plan: plan("one two three four"),
            guardFailure: { cancelled ? "lease_cancelled" : nil },
            post: { pieces.append($0); return .posted }, acknowledge: { _ in
                let callback = Task { @MainActor in cancelled = true }
                await callback.value
                return nil
            }, now: { 0 }, wait: { _ in Issue.record("Cancelled ACK must not earn visual wait") })
        #expect(pieces == [marker])
        #expect(result == .stopped(reason: "lease_cancelled", postedWrites: 1,
                                  acknowledgedWrites: 1, acknowledgedPayload: marker))
    }

    @Test @MainActor func clipboardChangeDuringAsyncAckNeverReplaysOrPostsTail() async {
        var pieces: [String] = []
        let result = await AcknowledgedRevealDriver.runAsync(plan: plan("one two three four"),
            guardFailure: { nil },
            post: { pieces.append($0); return .posted },
            acknowledge: { _ in
                await Task.yield()
                return "clipboard_changed_during_reveal_ack"
            }, now: { 0 }, wait: { _ in Issue.record("Interrupted ACK must stop immediately") })
        #expect(pieces == [marker])
        #expect(result == .stopped(reason: "clipboard_changed_during_reveal_ack",
            postedWrites: 1, acknowledgedWrites: 0, acknowledgedPayload: ""))
    }

    @Test @MainActor func asyncSlowAcknowledgementsPreserveBoundsAndExactText() async {
        let value = plan(String(repeating: "word 👩🏽‍💻 ", count: 230), words: 458)
        var time = 0.0, pieces: [String] = [], pending = false
        let result = await AcknowledgedRevealDriver.runAsync(plan: value,
            guardFailure: { nil }, post: { piece in
                #expect(!pending); pending = true; pieces.append(piece); return .posted
            }, acknowledge: { _ in
                await Task.yield()
                time += 0.200; pending = false; return nil
            }, now: { time }, wait: { delay in
                await Task.yield()
                time += Double(delay) / 1_000_000
            })
        #expect(result == .delivered(acknowledgedWrites: pieces.count))
        #expect(pieces.joined().utf8.elementsEqual(value.completeText.utf8))
        #expect(pieces.dropFirst().dropLast().allSatisfy { $0.count <= 96 })
        #expect(pieces.last == metadata)
        #expect(time > value.duration)
    }

    @Test func exactTextOneOutstandingWriteAndMetadataAcknowledgedLast() {
        let value = plan(String(repeating: "hello 👩🏽‍💻 e\u{301} café ", count: 20))
        var time = 0.0, observed = "", pending: String?, pieces: [String] = [], acked: [String] = []
        let outcome = AcknowledgedRevealDriver.run(plan: value, guardFailure: { nil }, post: { piece in
            #expect(pending == nil)
            pending = piece; pieces.append(piece); return .posted
        }, acknowledge: { piece in
            #expect(pending == piece)
            observed += piece; pending = nil; acked.append(piece)
            time += 0.002
            return nil
        }, now: { time }, wait: { time += Double($0) / 1_000_000 })
        #expect(outcome == .delivered(acknowledgedWrites: pieces.count))
        #expect(pieces == acked)
        #expect(pieces.first == marker)
        #expect(pieces.last == metadata)
        #expect(observed.utf8.elementsEqual(value.completeText.utf8))
    }

    @Test func slowAcknowledgementsNeverTriggerHugeDeadlineTail() {
        let value = plan(String(repeating: "word ", count: 458), words: 458)
        var time = 0.0, pieces: [String] = [], waiting = false
        let outcome = AcknowledgedRevealDriver.run(plan: value, guardFailure: { nil }, post: { piece in
            #expect(!waiting); waiting = true; pieces.append(piece); return .posted
        }, acknowledge: { _ in time += 0.200; waiting = false; return nil },
            now: { time }, wait: { time += Double($0) / 1_000_000 })
        #expect(outcome == .delivered(acknowledgedWrites: pieces.count))
        #expect(time > value.duration)
        #expect(pieces.dropFirst().dropLast().allSatisfy { $0.count <= 96 })
        #expect(pieces.count > 20)
        #expect(pieces.joined() == value.completeText)
    }

    @Test func literalAnnotationsRevealCharacterPrefixesWithinBatchCap() {
        let annotation = "<num>" + String(repeating: "1 2 3 ", count: 30) + "</num>"
        let value = TranscriptRevealPlan(marker: "", body: annotation + " end", metadata: "", spokenWordCount: 90)
        var configuration = AcknowledgedRevealDriver.Configuration()
        configuration.minimumBodyBatch = 1
        configuration.maximumBodyBatch = 8
        var time = 0.0, pieces: [String] = [], waits = 0
        var delivered = ""
        let outcome = AcknowledgedRevealDriver.run(plan: value, configuration: configuration, guardFailure: {
            waits > 1000 ? "test_stalled" : nil
        }, post: {
            pieces.append($0); delivered += $0
            #expect(value.completeText.utf8.starts(with: delivered.utf8))
            #expect($0.count <= 8)
            return .posted
        }, acknowledge: { expected in
            #expect(expected.utf8.elementsEqual((pieces.last ?? "").utf8)); return nil
        }, now: { time }, wait: { waits += 1; time += Double($0) / 1_000_000 })
        #expect(outcome == .delivered(acknowledgedWrites: pieces.count))
        #expect(pieces.first == "<")
        #expect(!pieces.contains(annotation))
        #expect(delivered.utf8.elementsEqual(value.completeText.utf8))
    }

    @Test func failedOrUncertainAckNeverPostsTailOrMetadata() {
        for reason in ["unacknowledged", "focus_changed", "caret_changed", "clipboard_replaced", "secure_input", "cancelled"] {
            let value = plan("one two three four five six seven eight nine")
            var pieces: [String] = []
            let outcome = AcknowledgedRevealDriver.run(plan: value, guardFailure: { nil },
                post: { pieces.append($0); return .posted }, acknowledge: { _ in reason },
                now: { 0 }, wait: { _ in Issue.record("No cosmetic wait follows failed ACK") })
            #expect(outcome == .stopped(reason: reason, postedWrites: 1, acknowledgedWrites: 0, acknowledgedPayload: ""))
            #expect(pieces == [marker])
        }
    }

    @Test func guardChangeDuringWaitStopsAfterLastAcknowledgedPrefix() {
        var moved = false, pieces: [String] = [], time = 0.0
        let outcome = AcknowledgedRevealDriver.run(plan: plan("one two three four five"),
            guardFailure: { moved ? "focus_changed" : nil }, post: { pieces.append($0); return .posted },
            acknowledge: { _ in nil }, now: { time }, wait: { time += Double($0) / 1_000_000; moved = true })
        #expect(outcome == .stopped(reason: "focus_changed", postedWrites: 1, acknowledgedWrites: 1, acknowledgedPayload: marker))
        #expect(pieces == [marker])
    }

    @Test func partialPrefixContinuesExactlyAndRejectsUnsafePrefix() {
        let value = plan("one two three <num>1 2 3</num> four five")
        for prefix in ["", "# π", "# π\n", "# π\none ", "# π\none two three <num>1", value.completeText] {
            var time = 0.0, text = prefix, pieces: [String] = []
            let outcome = AcknowledgedRevealDriver.run(plan: value, acknowledgedPrefix: prefix,
                guardFailure: { nil }, post: { pieces.append($0); text += $0; return .posted },
                acknowledge: { _ in nil }, now: { time }, wait: { time += Double($0) / 1_000_000 })
            #expect(outcome == .delivered(acknowledgedWrites: pieces.count))
            #expect(text.utf8.elementsEqual(value.completeText.utf8))
        }
        for prefix in ["wrong", value.completeText.dropLast().description] {
            let result = AcknowledgedRevealDriver.run(plan: value, acknowledgedPrefix: prefix,
                guardFailure: { nil }, post: { _ in Issue.record("Unsafe prefix must not post"); return .posted },
                acknowledge: { _ in nil }, now: { 0 }, wait: { _ in })
            if case .stopped(_, let posted, _, _) = result { #expect(posted == 0) }
            else { Issue.record("Unsafe prefix accepted") }
        }
    }

    @Test func postRefusalAndUncertainPostingHaveDifferentPartialEvidence() {
        for (postResult, expectedCount) in [(AcknowledgedRevealDriver.PostResult.refused("lease_changed"), 0),
                                           (.uncertain("event_result_unknown"), 1)] {
            let outcome = AcknowledgedRevealDriver.run(plan: plan("words"), guardFailure: { nil },
                post: { _ in postResult }, acknowledge: { _ in Issue.record("Failed post must not ACK"); return nil },
                now: { 0 }, wait: { _ in })
            if case .stopped(_, let count, let acked, let prefix) = outcome {
                #expect(count == expectedCount); #expect(acked == 0); #expect(prefix.isEmpty)
            } else { Issue.record("Post failure accepted") }
        }
    }

    @Test func metadataMustAcknowledgeAndFinalGuardMustRemainValid() {
        for finalGuard in [false, true] {
            var time = 0.0, changed = false, pieces: [String] = []
            let outcome = AcknowledgedRevealDriver.run(plan: plan("one", words: 1),
                guardFailure: { changed ? "lease_changed" : nil }, post: { pieces.append($0); return .posted },
                acknowledge: { piece in
                    if piece == metadata {
                        if finalGuard { changed = true; return nil }
                        return "metadata_unacknowledged"
                    }
                    return nil
                }, now: { time }, wait: { time += Double($0) / 1_000_000 })
            if case .stopped(let reason, _, _, _) = outcome {
                #expect(reason == (finalGuard ? "lease_changed" : "metadata_unacknowledged"))
            } else { Issue.record("Submission must remain blocked") }
            #expect(pieces.last == metadata)
        }
    }

    @Test @MainActor func deferredWhitespacePreservesExactBytesAndAsyncParity() async {
        var configuration = AcknowledgedRevealDriver.Configuration()
        configuration.deferTrailingWhitespace = true
        configuration.maximumBodyBatch = 8
        let fixtures = [
            "one two three\n\n👩🏽‍💻 e\u{301} café\r\nend \t\n",
            "a <num>1 2 3</num> then *[pause 1.25]* end\n",
            "before <char>unfinished protected text \n\t",
            " \n\t\r\n", "", "one", "one two three"
        ]
        for body in fixtures {
            for footer in [metadata, "", " \n\t"] {
                let value = TranscriptRevealPlan(marker: marker, body: body,
                    metadata: footer, spokenWordCount: 16)
                for prefix in ["", "# π", marker] {
                    var time = 0.0, pieces: [String] = [], acked = 0
                    let outcome = AcknowledgedRevealDriver.run(plan: value,
                        acknowledgedPrefix: prefix, configuration: configuration,
                        guardFailure: { nil }, post: { pieces.append($0); return .posted },
                        acknowledge: { _ in acked += 1; return nil }, now: { time },
                        wait: { time += Double($0) / 1_000_000 })
                    #expect(outcome == .delivered(acknowledgedWrites: pieces.count))
                    #expect(acked == pieces.count)
                    #expect((prefix + pieces.joined()).utf8.elementsEqual(value.completeText.utf8))
                    #expect(pieces.dropLast().allSatisfy { $0.last?.isWhitespace == false })
                    var deliveredCount = prefix.count
                    for piece in pieces.dropLast() {
                        deliveredCount += piece.count
                        let bodyCount = max(0, min(body.count, deliveredCount - marker.count))
                        #expect(value.safeBodyCount(upTo: bodyCount) == bodyCount)
                    }
                    var asyncTime = 0.0, asyncPieces: [String] = []
                    let asyncOutcome = await AcknowledgedRevealDriver.runAsync(plan: value,
                        acknowledgedPrefix: prefix, configuration: configuration,
                        guardFailure: { nil }, post: { asyncPieces.append($0); return .posted },
                        acknowledge: { _ in await Task.yield(); return nil }, now: { asyncTime },
                        wait: { asyncTime += Double($0) / 1_000_000; await Task.yield() })
                    #expect(asyncOutcome == outcome)
                    #expect(asyncPieces == pieces)
                }
            }
        }
    }

    @Test func deferredWhitespaceDoesNotCountAsAnAcknowledgedWrite() {
        var configuration = AcknowledgedRevealDriver.Configuration()
        configuration.deferTrailingWhitespace = true
        let value = TranscriptRevealPlan(marker: "# π\n", body: " \n\t",
            metadata: "\nmetadata", spokenWordCount: 3)
        var time = 0.0, pieces: [String] = [], acknowledgements = 0
        let outcome = AcknowledgedRevealDriver.run(plan: value, configuration: configuration,
            guardFailure: { nil }, post: { pieces.append($0); return .posted },
            acknowledge: { _ in
                acknowledgements += 1
                return acknowledgements == 2 ? "unacknowledged" : nil
            }, now: { time }, wait: { time += Double($0) / 1_000_000 })
        #expect(pieces == ["# π", "\n \n\t\nmetadata"])
        #expect(outcome == .stopped(reason: "unacknowledged", postedWrites: 2,
            acknowledgedWrites: 1, acknowledgedPayload: "# π"))
    }

    @Test @MainActor func deferredTailCancellationKeepsOnlyActuallyAcknowledgedBytes() async {
        var configuration = AcknowledgedRevealDriver.Configuration()
        configuration.deferTrailingWhitespace = true
        for useAsync in [false, true] {
            var cancelled = false, time = 0.0, pieces: [String] = []
            let value = plan("one two three four five")
            let outcome: AcknowledgedRevealDriver.Outcome
            if useAsync {
                outcome = await AcknowledgedRevealDriver.runAsync(plan: value, configuration: configuration,
                    guardFailure: { cancelled ? "cancelled" : nil },
                    post: { pieces.append($0); return .posted }, acknowledge: { _ in nil },
                    now: { time }, wait: { time += Double($0) / 1_000_000; cancelled = true })
            } else {
                outcome = AcknowledgedRevealDriver.run(plan: value, configuration: configuration,
                    guardFailure: { cancelled ? "cancelled" : nil },
                    post: { pieces.append($0); return .posted }, acknowledge: { _ in nil },
                    now: { time }, wait: { time += Double($0) / 1_000_000; cancelled = true })
            }
            #expect(pieces == ["# π"])
            #expect(outcome == .stopped(reason: "cancelled", postedWrites: 1,
                acknowledgedWrites: 1, acknowledgedPayload: "# π"))
        }
    }


    @Test @MainActor func acknowledgementTimeCountsTowardTransportCadence() async {
        let value = plan(String(repeating: "word ", count: 69))
        for delay in [0.0, 0.004, 1.0] {
            var configuration = AcknowledgedRevealDriver.Configuration()
            configuration.maximumBodyBatch = 8
            var time = 0.0, pieces: [String] = [], postTimes: [Double] = []
            var waitsAfterFirstBody = 0
            let outcome = AcknowledgedRevealDriver.run(plan: value, configuration: configuration,
                guardFailure: { nil }, post: {
                    pieces.append($0); postTimes.append(time); return .posted
                }, acknowledge: { _ in time += delay; return nil }, now: { time }, wait: {
                    if pieces.count >= 2 { waitsAfterFirstBody += 1 }
                    time += Double($0) / 1_000_000
                })
            #expect(outcome == .delivered(acknowledgedWrites: pieces.count))
            #expect(pieces.joined().utf8.elementsEqual(value.completeText.utf8))
            if delay == 1 { #expect(waitsAfterFirstBody == 0) }
            // Excludes marker and final metadata. Metadata has no artificial end hold.
            let bodyTimes = Array(postTimes.dropFirst().dropLast())
            for pair in zip(bodyTimes, bodyTimes.dropFirst()) {
                #expect(pair.1 - pair.0 >= 0.008332)
            }
            // Once the curve is fully visible, capped batches need only the cadence
            // or the ACK duration, whichever is longer, rather than their sum.
            let latePairs = zip(bodyTimes, bodyTimes.dropFirst()).filter { $0.0 > value.duration + delay }
            #expect(!latePairs.isEmpty)
            for pair in latePairs {
                #expect(pair.1 - pair.0 <= max(0.008333, delay) + 0.000002)
            }
            var asyncTime = 0.0, asyncPieces: [String] = [], asyncPostTimes: [Double] = []
            let asyncOutcome = await AcknowledgedRevealDriver.runAsync(plan: value, configuration: configuration,
                guardFailure: { nil }, post: {
                    asyncPieces.append($0); asyncPostTimes.append(asyncTime); return .posted
                }, acknowledge: { _ in asyncTime += delay; await Task.yield(); return nil },
                now: { asyncTime }, wait: { asyncTime += Double($0) / 1_000_000; await Task.yield() })
            #expect(asyncOutcome == outcome)
            #expect(asyncPieces == pieces)
            #expect(asyncPostTimes == postTimes)
        }
    }

    @Test @MainActor func backwardClockBeforePostIsRejectedInBothDrivers() async {
        for useAsync in [false, true] {
            var samples = [0.0, 0.0, 1.0, -1.0]
            var pieces: [String] = []
            let clock = { samples.isEmpty ? -1.0 : samples.removeFirst() }
            let outcome: AcknowledgedRevealDriver.Outcome
            if useAsync {
                outcome = await AcknowledgedRevealDriver.runAsync(plan: plan("one two three four"),
                    guardFailure: { nil }, post: { pieces.append($0); return .posted },
                    acknowledge: { _ in nil }, now: clock, wait: { _ in })
            } else {
                outcome = AcknowledgedRevealDriver.run(plan: plan("one two three four"),
                    guardFailure: { nil }, post: { pieces.append($0); return .posted },
                    acknowledge: { _ in nil }, now: clock, wait: { _ in })
            }
            #expect(pieces == [marker])
            #expect(outcome == .stopped(reason: "invalid_reveal_clock", postedWrites: 1,
                acknowledgedWrites: 1, acknowledgedPayload: marker))
        }
    }

    @Test @MainActor func markerlessRawTextStreamsExactlyAndInterruptionNeverReplays() async {
        let raw = String(repeating: "NASA 1234567910 café 👩🏽‍💻 ends here. ", count: 8)
        let value = TranscriptRevealPlan(marker: "", body: raw, metadata: "", spokenWordCount: 56)
        for interrupt in [false, true] {
            var config = AcknowledgedRevealDriver.Configuration()
            config.deferTrailingWhitespace = true
            var time = 0.0, pieces: [String] = [], pending = false, acknowledged = ""
            let result = await AcknowledgedRevealDriver.runAsync(plan: value, configuration: config,
                guardFailure: { nil }, post: { piece in
                    #expect(!pending)
                    #expect(!piece.isEmpty)
                    pending = true
                    pieces.append(piece)
                    return .posted
                }, acknowledge: { piece in
                    await Task.yield()
                    time += 0.02
                    if interrupt && pieces.count == 2 { return "clipboard_changed_during_reveal_ack" }
                    acknowledged += piece
                    pending = false
                    return nil
                }, now: { time }, wait: { time += Double($0) / 1_000_000 })
            if interrupt {
                #expect(pieces.count == 2)
                #expect(result == .stopped(reason: "clipboard_changed_during_reveal_ack",
                    postedWrites: 2, acknowledgedWrites: 1, acknowledgedPayload: pieces[0]))
            } else {
                #expect(pieces.count > 1)
                #expect(pieces.allSatisfy { $0.count <= config.maximumBodyBatch })
                #expect(pieces.joined().utf8.elementsEqual(raw.utf8))
                #expect(acknowledged == raw)
                #expect(result == .delivered(acknowledgedWrites: pieces.count))
            }
        }
    }

}
