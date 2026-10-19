


//
import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Speech
import SwiftUI


// DatasetRow


struct DatasetRow: Codable, Equatable {
    var id: UUID
    var timestamp: Date
    var label: String
    var transcript: String
    var lens: Lense
    var reaction: Reaction
    var features: AudioFeatures
    var rawAudioSaved: Bool
    /// Exact recognizer text before delivery-only whitespace formatting.
    /// Optional for backward-compatible decoding of existing history.
    var rawTranscript: String? = nil
}
