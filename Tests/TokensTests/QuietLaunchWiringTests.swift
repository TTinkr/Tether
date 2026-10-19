


//
import Foundation
import Testing
@testable import Tokens

@Suite struct QuietLaunchWiringTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Sources/Tokens/App/" + name), encoding: .utf8)
    }
    @Test func duplicateDispatchAndBothReopenEntrypointsUseTheSharedSetupGate() throws {
        let proof = try source("AppDelegateProof.swift")
        let dispatch = try #require(proof.range(of: "        if shouldPresentHomeOnReopen {"))
        let stop = try #require(proof.range(of: "        NSApp.terminate(nil)", range: dispatch.upperBound..<proof.endIndex))
        let gated = proof[dispatch.upperBound..<stop.lowerBound]
        #expect(gated.contains("DistributedNotificationCenter.default().postNotificationName("))
        #expect(gated.contains("_ = existing.activate(options: [])"))
        #expect(proof.components(separatedBy: "existing.activate(options: [])").count == 2)
        let lifecycle = try source("AppDelegateLifecycle.swift")
        #expect(lifecycle.components(separatedBy: "if shouldPresentHomeOnReopen { showStyleChooser() }").count == 3)
        #expect(lifecycle.contains("targetPID.int32Value == ProcessInfo.processInfo.processIdentifier else { return }"))
        let app = try source("AppDelegate.swift")
        #expect(app.contains("var shouldPresentHomeOnReopen: Bool {\n        LaunchPresentation.needsHome("))
        let menu = try source("AppDelegateMenu.swift")
        #expect(!menu.contains("shouldPresentHomeOnReopen"))
    }
    /// First-run launch triggers the Orukeet prewarm: the call sits in the normal launch
    /// branch ahead of, and outside, every first-run/permission gate.
    @Test func firstRunLaunchPrewarmsBundledLocalModel() throws {
        let app = try source("AppDelegate.swift")
        let normal = try #require(app.range(of: "The normal start."))
        let call = try #require(app.range(of: "if LaunchPresentation.prewarmsLocalSpeech(engine: SpeechEngineChoice.load(),",
                                           range: normal.upperBound..<app.endIndex))
        let gated = try #require(app.range(of: "if publicTokens && !tokensFirstRunPending { model.prepareSpeech() }",
                                            range: normal.upperBound..<app.endIndex))
        #expect(call.lowerBound < gated.lowerBound)
        let close = try #require(app.range(of: "}", range: call.upperBound..<app.endIndex))
        let block = app[call.lowerBound..<close.upperBound]
        #expect(block.contains("model.audio.prewarmRecognition()"))
        #expect(!block.contains("tokensFirstRunPending") && !block.contains("requestAccess"))
        // prewarmRecognition itself never asks for a permission or checks first run.
        let recognition = try String(contentsOf: root.appendingPathComponent("Sources/Tokens/Speech/AudioCapture+Recognition.swift"),
                                     encoding: .utf8)
        let start = try #require(recognition.range(of: "func prewarmRecognition() {"))
        let end = try #require(recognition.range(of: "func idleListenerEngine(", range: start.upperBound..<recognition.endIndex))
        let body = recognition[start.upperBound..<end.lowerBound]
        #expect(!body.contains("requestAccess") && !body.contains("requestAuthorization") && !body.contains("FirstRun"))
    }
}

