import Foundation
import Testing
@testable import TokensCore
struct ApprovedRevealTimingTests {
    @Test func acceptedFixturesUseOneExactAcknowledgedStream() throws {
        let encoded = ["QSBnb29kIHN0cmVhbSBnaXZlcyBldmVyeSB3b3JkIGEgbW9tZW50LCB0aGVuIGNhcnJpZXMgdGhlIHJlc3Qgb2YgdGhlIHRob3VnaHQgZm9yd2FyZC4gVGhlIG9wZW5pbmcgc2hvdWxkIGJlIGVhc3kgdG8gZm9sbG93LCB3aXRob3V0IGZlZWxpbmcgaGVzaXRhbnQuIEFzIHRoZSBpZGVhIGdyb3dzLCB0aGUgbW92ZW1lbnQgY2FuIGJlY29tZSBxdWlja2VyIGFuZCBtb3JlIGZsdWlkLiBFdmVuIG5lYXIgdGhlIGVuZCwgdGhlIHdvcmRzIHNob3VsZCBrZWVwIGFycml2aW5nIGluIGEgdmlzaWJsZSByaHl0aG0uCgpGb3IgYSBzaG9ydCBzZW50ZW5jZSwgdGhlcmUgaXMgbm8gcmVhc29uIHRvIHJ1c2guIEEgbGl0dGxlIHNwYWNlIGJldHdlZW4gd29yZHMgY2FuIG1ha2UgdGhlIHJlc3VsdCBmZWVsIGRlbGliZXJhdGUgYW5kIGNhbG0uIEEgcGFyYWdyYXBoIGFza3MgZm9yIGEgZGlmZmVyZW50IGJhbGFuY2U6IGVub3VnaCB0aW1lIHRvIHJlY29nbml6ZSB0aGUgYmVnaW5uaW5nLCBmb2xsb3dlZCBieSBhIHN0ZWFkeSBmbG93IHRoYXQga2VlcHMgdGhlIHdob2xlIHRob3VnaHQgY29ubmVjdGVkLiBUaGUgdGltaW5nIHNob3VsZCByZXNwb25kIHRvIHRoZSBhbW91bnQgb2YgdGV4dCwgcmF0aGVyIHRoYW4gZm9yY2luZyBldmVyeSBtZXNzYWdlIGludG8gdGhlIHNhbWUgdGlueSB3aW5kb3cuCgpBIGxvbmdlciBwcm9tcHQgbmVlZHMgcm9vbSB0byBtb3ZlLiBJdCBtaWdodCBjb250YWluIGEgcXVlc3Rpb24sIHNldmVyYWwgZXhhbXBsZXMsIGEgY2hhbmdlIG9mIGRpcmVjdGlvbiwgYW5kIGEgY2FyZWZ1bCBleHBsYW5hdGlvbiBvZiB3aGF0IG1hdHRlcnMgbW9zdC4gVGhvc2UgZGV0YWlscyBzaG91bGQgYXJyaXZlIGFzIHBhcnQgb2Ygb25lIGNvbnRpbnVvdXMgZ2VzdHVyZS4gV2UgZG8gbm90IG5lZWQgdG8gcmVhZCBlYWNoIHdvcmQgd2hpbGUgaXQgYXBwZWFycywgYnV0IHdlIHNob3VsZCBiZSBhYmxlIHRvIHNlZSB0aGF0IHRoZSBlbnRpcmUgcGFzc2FnZSBpcyBiZWluZyBkZWxpdmVyZWQsIGFsbCB0aGUgd2F5IHRocm91Z2ggaXRzIGZpbmFsIGxpbmVzLgoKVGhlIGltcG9ydGFudCB0aGluZyBpcyBjb250aW51aXR5LiBTcGVlZCBjYW4gY2hhbmdlLCBhbmQgZ3JvdXBzIG9mIHdvcmRzIGNhbiBncm93LCB3aXRob3V0IHR1cm5pbmcgdGhlIGVuZGluZyBpbnRvIGEgc2luZ2xlIHBhc3RlLiBPbmNlIHRoZSBsYXN0IHdvcmQgaXMgcHJlc2VudCwgdGhlIHRleHQgY2FuIHN0YXkgc3RpbGwuIFRoZSByZXN1bHQgc2hvdWxkIGZlZWwgY29tcGxldGUsIGNvbXBvc2VkLCBhbmQgcmVhZHkgZm9yIHRoZSBuZXh0IHN0ZXAuCgpUaGVyZSBpcyBhbm90aGVyIHdheSB0byB0aGluayBhYm91dCB0aGUgZXhwZXJpZW5jZS4gVGhlIHRleHQgaXMgYWxyZWFkeSBmaW5pc2hlZCBiZWZvcmUgdGhlIGFuaW1hdGlvbiBiZWdpbnMsIHNvIHRoZSBtb3ZlbWVudCBkb2VzIG5vdCBuZWVkIHRvIGltaXRhdGUgc29tZW9uZSB0eXBpbmcuIEl0IG5lZWRzIHRvIGNvbW11bmljYXRlIHRoYXQgYSBjb21wbGV0ZSB0aG91Z2h0IGlzIGFycml2aW5nLiBBIGNsZWFyIG9wZW5pbmcgY3JlYXRlcyB0aGF0IGNvbm5lY3Rpb24sIHdoaWxlIHRoZSBncm93aW5nIHNwZWVkIG1ha2VzIGEgbG9uZyBtZXNzYWdlIGZlZWwgbGlnaHQgYW5kIGltbWVkaWF0ZS4KClRoZSBjaGFsbGVuZ2UgYmVjb21lcyBtb3JlIGludGVyZXN0aW5nIHdoZW4gdGhlIG1lc3NhZ2UgZG91YmxlcyBpbiBsZW5ndGguIEEgdGlueSBjaGFuZ2UgaW4gdGhlIGN1cnZlIGNhbiBtYWtlIHRoZSBlbmRpbmcgbG9vayBlaXRoZXIgZmx1aWQgb3IgYWJydXB0LiBJZiB0b28gbXVjaCBvZiB0aGUgdGV4dCBpcyBoZWxkIGJhY2ssIHRoZSBmaW5hbCBtb21lbnQgYmVjb21lcyBhIGZsYXNoLiBJZiB0aGUgYmVnaW5uaW5nIG1vdmVzIHRvbyBxdWlja2x5LCB0aGUgd2hvbGUgZWZmZWN0IGxvc2VzIGl0cyBjaGFyYWN0ZXIuIFRoZSB1c2VmdWwgbWlkZGxlIGdyb3VuZCBpcyBhIHZpc2libGUgdHJhaWwgdGhhdCBrZWVwcyBtb3ZpbmcgYW5kIG5ldmVyIHN1ZGRlbmx5IHR1cm5zIGludG8gYSBibG9jay4KClRoaXMgbGFyZ2VyIGV4YW1wbGUgZ2l2ZXMgdGhhdCB0cmFpbCBtb3JlIGRpc3RhbmNlIHRvIHRyYXZlbC4gV2F0Y2ggdGhlIGZpcnN0IGxpbmVzLCB0aGVuIHRoZSBtaWRkbGUsIGFuZCBmaW5hbGx5IHRoZSBsYXN0IHBhcmFncmFwaC4gVGhlIHNhbWUgbW90aW9uIHNob3VsZCBjb25uZWN0IGFsbCB0aHJlZS4gVGhlIHNwZWVkIGNhbiByaXNlIHNoYXJwbHksIGJ1dCB0aGVyZSBzaG91bGQgc3RpbGwgYmUgYSBzZW5zZSBvZiBkaXJlY3Rpb24gdGhyb3VnaCB0aGUgcGFnZS4gRXZlcnkgc2VjdGlvbiBiZWxvbmdzIHRvIHRoZSBzYW1lIGRlbGl2ZXJ5LgoKV2hlbiB0aGUgZmluYWwgY2hhcmFjdGVycyBhcnJpdmUsIHRoZSBhbmltYXRpb24gc2hvdWxkIHNpbXBseSBzdG9wLiBObyBib3VuY2UsIG5vIGV4dHJhIGZsb3VyaXNoLCBhbmQgbm8gbG9uZyB3YWl0IGJlZm9yZSB0aGUgcmVzdWx0IGlzIHVzYWJsZS4gVGhlIGVudGlyZSBtZXNzYWdlIHN0YXlzIGluIHBsYWNlLCByZWFkeSB0byByZWFkLCBlZGl0LCBvciBzZW5kLiBUaGF0IHF1aWV0IGZpbmlzaCBpcyBwYXJ0IG9mIHdoYXQgbWFrZXMgdGhlIG1vdmVtZW50IGZlZWwgbmF0dXJhbC4=",
            "QSBnb29kIHN0cmVhbSBnaXZlcyBldmVyeSB3b3JkIGEgbW9tZW50LCB0aGVuIGNhcnJpZXMgdGhlIHJlc3Qgb2YgdGhlIHRob3VnaHQgZm9yd2FyZC4gVGhlIG9wZW5pbmcgc2hvdWxkIGJlIGVhc3kgdG8gZm9sbG93LCB3aXRob3V0IGZlZWxpbmcgaGVzaXRhbnQuIEFzIHRoZSBpZGVhIGdyb3dzLCB0aGUgbW92ZW1lbnQgY2FuIGJlY29tZSBxdWlja2VyIGFuZCBtb3JlIGZsdWlkLiBFdmVuIG5lYXIgdGhlIGVuZCwgdGhlIHdvcmRzIHNob3VsZCBrZWVwIGFycml2aW5nIGluIGEgdmlzaWJsZSByaHl0aG0uIFRoZSBmaW5hbCBsaW5lIHNob3VsZCBmZWVsIGxpa2UgdGhlIGVuZCBvZiBhIHNlbnRlbmNlLCByYXRoZXIgdGhhbiBhIHN1ZGRlbiB3YWxsIG9mIHRleHQu",
            "QSBnb29kIHN0cmVhbSBnaXZlcyBldmVyeSB3b3JkIGEgbW9tZW50LCB0aGVuIGNhcnJpZXMgdGhlIHJlc3Qgb2YgdGhlIHRob3VnaHQgZm9yd2FyZC4="]
        for (index, fixture) in encoded.enumerated() {
            let data = try #require(Data(base64Encoded: fixture))
            let body = try #require(String(data: data, encoding: .utf8))
            let plan = TranscriptRevealPlan(marker: "", body: body, metadata: "", spokenWordCount: 0)
            for ackDelay in [0.0, 0.014, 0.032, 0.2] {
                var now = 0.0, pieces: [String] = [], posts: [Double] = [], received = "", pending = false
                let result = AcknowledgedRevealDriver.run(plan: plan, guardFailure: { nil }, post: { piece in
                    #expect(!pending)
                    #expect(!piece.isEmpty)
                    #expect(piece.count <= 96)
                    #expect(body.utf8.starts(with: (received + piece).utf8))
                    pending = true; pieces.append(piece); posts.append(now); return .posted
                }, acknowledge: { piece in
                    now += ackDelay; received += piece; pending = false; return nil
                }, now: { now }, wait: { now += Double($0) / 1_000_000 })
                #expect(result == .delivered(acknowledgedWrites: pieces.count))
                #expect(received.utf8.elementsEqual(body.utf8))
                #expect(pieces.first?.filter { !$0.isWhitespace }.count == 1)
                #expect(try #require(posts.first) > 0)
                #expect(try #require(posts.first) <= 0.025)
                let opening = zip(pieces, posts).filter { $0.1 <= 0.100 }.map { $0.0 }.joined()
                #expect(opening.filter { !$0.isWhitespace }.count <= 9)
                let row: [String: Any] = ["fixture": index, "ack_delay_ms": ackDelay * 1000,
                    "first_post_ms": (posts.first ?? 0) * 1000, "completion_ms": now * 1000,
                    "writes": pieces.count, "exact": received.utf8.elementsEqual(body.utf8),
                    "measured_app_latency": false]
                print("APPROVED_REVEAL_SYNTHETIC " + String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
            }
        }
    }
}
