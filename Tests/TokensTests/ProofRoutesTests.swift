


//
import Foundation
import Testing
@testable import Tokens


// Proof routes — closed in the public download, open in local builds


@Suite struct ProofRoutesTests {
    @Test func mutatingProofRoutesRequireExplicitDeveloperMode() {
        #expect(ProofRoutes.allowed(distributionMode: "dev"))
        for mode in ["distribution", "preview", "local-production", "fresh", "unknown", nil] as [String?] {
            #expect(!ProofRoutes.allowed(distributionMode: mode))
        }
    }

    @Test func nativeBubblePreviewIsExplicitAndSyntheticOnly() {
        for mode in ["preview", "dev"] {
            #expect(ProofRoutes.nativeBubblePreviewAllowed(arguments: ["--native-bubble-preview"], distributionMode: mode))
            #expect(!ProofRoutes.nativeBubblePreviewAllowed(arguments: [], distributionMode: mode))
        }
        for mode in ["distribution", "unknown", nil] as [String?] {
            #expect(!ProofRoutes.nativeBubblePreviewAllowed(arguments: ["--native-bubble-preview"], distributionMode: mode))
        }
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
    }

    // Every Swift file under Sources/Tokens, as (path relative to Sources/Tokens, lines).
    private func allSources() throws -> [(String, [String])] {
        let base = root.appendingPathComponent("Sources/Tokens")
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { url in
            (String(url.path.dropFirst(base.path.count + 1)),
             try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    /*
    Each trigger, as written in the source, and the only lines allowed to use it.
    Clearing a saved trigger (removeObject) is not a use.
    */
    private let triggers = ["\"--ambient-microphone-proof\"", "\"--takeoff-now-proof\"", "\"--microphone-pause-proof\"",
                            "\"--dictation-file-proof\"", "\"--legacy-dictation-file-proof\"", "\"--held-words-preview\"", "\"--single-paste-fixture-proof\"",
                            "\"TTTAmbientMicrophoneProofOutput.v1\"", "\"TTTMicrophonePauseProofOutput.v1\""]

    @Test func everyUseOfATriggerIsBehindProofRoutes() throws {
        for trigger in triggers {
            var uses: [(String, String)] = []
            for (path, lines) in try allSources() {
                for line in lines where line.contains(trigger) && !line.contains("removeObject(forKey:") {
                    uses.append((path, line))
                }
            }
            let appDelegate = uses.filter { $0.0 == "App/AppDelegate.swift" }
            let talkModel   = uses.filter { $0.0 == "Talk/TalkModel.swift" }
            // One read where the route runs, and (for the four proof routes and two settings) one in TalkModel's gated synthetic-run check.
            #expect(appDelegate.count == 1, "\(trigger): \(appDelegate.count) reads in AppDelegate")
            #expect(appDelegate.allSatisfy { $0.1.contains("ProofRoutes.isAllowed") }, "\(trigger) read without ProofRoutes")
            #expect(talkModel.count == 1, "\(trigger): \(talkModel.count) reads in TalkModel")
            #expect(uses.count == appDelegate.count + talkModel.count, "\(trigger) read in another file: \(uses.map(\.0))")
        }
    }

    // In TalkModel the same triggers only make a synthetic run inside the ProofRoutes gate.
    @Test func proofTriggersOnlyMakeASyntheticRunWhereAllowed() throws {
        let model = try source("Talk/TalkModel.swift")
        guard let start = model.range(of: "let proofRun = ProofRoutes.isAllowed && ("),
              let end   = model.range(of: "isSyntheticRun = ", range: start.upperBound..<model.endIndex)
        else { Issue.record("TalkModel.init changed shape"); return }
        let gated = model[start.upperBound..<end.lowerBound]
        for trigger in triggers where !trigger.contains("held-words") {
            #expect(gated.contains(trigger), "\(trigger)")
        }
    }

    // The proof work itself (microphone, speech, file transcription) is reachable only from AppDelegate's gated branches.
    @Test func proofSinksAreCalledOnlyFromAppDelegate() throws {
        let sinks = ["MicrophonePauseProof.run(", "await TalkFileProof.run(", "await LegacyTalkFileProof.run(", "runAmbientLifecycleProof(", "runTakeOffNowProof("]
        for sink in sinks {
            var calls: [String] = []
            for (path, lines) in try allSources() {
                for line in lines where line.contains(sink) && !line.contains("func ") { calls.append(path) }
            }
            #expect(calls == ["App/AppDelegate.swift"], "\(sink) called from \(calls)")
        }
    }

//
// :)
//
//
    // The gate reads the signed Info.plist key that package_app.py writes for the public build.
    @Test func theGateReadsTheKeyThePackagerWrites() throws {
        let routes = try source("App/ProofRoutes.swift")
        #expect(routes.contains("Bundle.main.object(forInfoDictionaryKey: \"TokensDistributionMode\")"))
        let packager = try String(contentsOf: root.appendingPathComponent("scripts/package_app.py"), encoding: .utf8)
        #expect(packager.contains("\"TokensDistributionMode\": args.mode"))
    }
}

