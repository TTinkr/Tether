import Foundation

/// Readback timing of real delivery. An AX acknowledgement bounds visibility;
/// it is not a pixel timestamp or a measurement of recognition finalization.
struct RevealDeliveryTiming: Codable {
    struct Write: Codable {
        let characters: Int
        let cumulativeCharacters: Int
        /// Dispatch-completion bound after successful Command-V posting, not pixel visibility.
        let postedMS: Double
        var acknowledgedMS: Double?
    }
    let targetMS: Double
    let maximumBatchCharacters: Int
    var writes: [Write] = []
    var outcome = "pending"
    var finishedMS: Double?
    var firstPostMS: Double? { writes.first?.postedMS }
    var firstAcknowledgedMS: Double? { writes.first?.acknowledgedMS }
    var completeAcknowledgedMS: Double? {
        outcome == "delivered" ? writes.last?.acknowledgedMS : nil
    }
}
