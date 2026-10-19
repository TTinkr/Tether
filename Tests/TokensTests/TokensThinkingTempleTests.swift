


//
import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Tokens

/// The bubble-only launch must refuse the retired panel through every session entry point,
/// including the old offline-preview arguments. No live input or native window is opened.
@Suite(.serialized) struct TokensThinkingTempleTests {
    @Test @MainActor static func retiredPreviewCannotReopenLaunchPanel() {
        let temple = TokensThinkingTemple(arguments: ["TTT", "--temple-preview", "--render-preview-frames"])
        let words = "Keep every spoken word and the tiny bubble."
        #expect(!TokensThinkingTemple.launchPanelAvailable)

        /*
        Repeat lifecycle calls to catch a stale state or a later re-enable attempt.
        The controller suite separately injects a saved true preference in an isolated domain.
        */
        for _ in 0..<2 {
            temple.turnOn()
            temple.begin()
            temple.observe(pauseSeconds: 30, estimated: false, rmsDB: -60, transcript: words)
            temple.observe(pauseSeconds: 2, estimated: true, rmsDB: -60, transcript: words)
            temple.observe(pauseSeconds: nil, estimated: false, rmsDB: -25, transcript: words + " Then finish.")
            #expect(!temple.panelEnabled)
            #expect(temple.panelState == nil)
            #expect(!temple.stream.isThinking)
            #expect(temple.stream.questions.text.isEmpty)
            #expect(temple.stream.reflection.text.isEmpty)
            #expect(temple.notesForDelivery.isEmpty)
            #expect(temple.consumeNotesForDelivery().isEmpty)
            #expect(!temple.isEditingNotes)
            temple.end()
            temple.end()
            #expect(temple.panelState == nil)
        }
    }
}

