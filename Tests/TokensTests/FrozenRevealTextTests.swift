import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Tokens

struct FrozenRevealTextTests {
    @Test func frozenBodyKeepsBoundaryWhitespaceAndUnicodeBytes() {
        for before in ["", "Existing", "Existing\n", "("] {
            let target = CapturedTarget(id: UUID(), application: .current,
                pid: ProcessInfo.processInfo.processIdentifier, element: nil, window: nil,
                screenFrame: nil, selection: CFRange(location: before.utf16.count, length: 0), valueBefore: before)
            for body in [" \t👩🏽‍💻 e\u{301}\r\n  ", "word\n", ", end  "] {
                let result = TargetDelivery.preparedText(body, for: target, preservingWhitespace: true)
                let separator = before == "Existing" && body == "word\n" ? " " : ""
                #expect(result.utf8.elementsEqual((separator + body).utf8))
            }
        }
    }
    @Test func readbackTimingNeverLabelsAnUncertainWriteComplete() {
        var timing = RevealDeliveryTiming(targetMS: 400, maximumBatchCharacters: 96)
        timing.writes = [.init(characters: 1, cumulativeCharacters: 1, postedMS: 20, acknowledgedMS: 35),
                         .init(characters: 2, cumulativeCharacters: 3, postedMS: 40, acknowledgedMS: nil)]
        timing.outcome = "unacknowledged"
        #expect(timing.firstPostMS == 20)
        #expect(timing.firstAcknowledgedMS == 35)
        #expect(timing.completeAcknowledgedMS == nil)
    }
}
