import Foundation
import Testing
import TokensCore
@testable import Tokens

/// Regression coverage for reviewed integration failures.
struct Build82ReviewFixesTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Cancel gives the space back: the stopped transfer's part file is removed once it has stopped.
    @Test func cancelDiscardsThePartFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokens-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try Data(repeating: 7, count: 1024).write(to: partial)
        SpeechModelStore.discardPartial(for: destination)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let store = try source("Sources/Tokens/Speech/SpeechModelStore.swift")
        let cancel = try #require(store.range(of: "func cancel(_ id: String)"))
        let body = store[cancel.lowerBound...].prefix(1200)
        #expect(body.contains("Self.discardPartial(for: Self.installedURL(entry))"), "Cancel's step after the transfer stops")
        // A file already on this Mac is used, never fetched beside itself.
        #expect(store.contains("if await Task.detached(operation: { Self.verifyInstalled(entry) }).value {\n                if current() {\n                    self?.states[id] = .ready\n                    self?.chooseFinished(id, selectWhenReady, choiceAtStart)\n                    self?.onReady?(id)\n                }"))
    }

    /// The Settings line beside the menu carries only loading or unavailable, for every status the app writes.
    @Test func settingsLineShowsOnlyNews() {
        for repeated in ["Orukeet · ready on this Mac", "Whisper Small · ready on this Mac", "Apple · on this Mac", "Orukeet · local model"] {
            #expect(TokensHome.speechEngineNews(repeated) == nil, "\(repeated) repeats the menu's name")
        }
        for news in ["Loading Whisper Small on this Mac…", "Qwen3 ASR unavailable · worker exited", "Apple speech unavailable"] {
            #expect(TokensHome.speechEngineNews(news) == news)
        }
    }

    /// The menus: clicking the checked model changes nothing, the switch re-checks the talk at click
    /// time, and during a talk the menu names the engine that talk started with.
    @Test func menuSwitchingRules() throws {
        let menu = try source("Sources/Tokens/Features/Home/TokensModelMenu.swift")
        #expect(menu.contains("guard !talking, id != current else { return }"))
        #expect(menu.contains("choose(id)") && !menu.contains("store.choose(id)"), "the menu never switches on a value captured at render")
        #expect(menu.contains("let current = talkingWith ?? Self.inUse(store)"))
        let settings = try source("Sources/Tokens/Features/Home/TokensHomeSettings.swift")
        #expect(settings.contains("func chooseSpeechModel(id: String) {\n        guard !talkingNow else { return }"))
        #expect(settings.contains("return audio.sessionSpeechEngine == .apple ? SpeechModelCatalog.appleID : SpeechEngineChoice.selectedModelID()"))
        // Switching between two local models reloads and re-states the Settings line.
        let capture = try source("Sources/Tokens/Speech/AudioCapture.swift")
        #expect(capture.contains("guard choice != self.observedSpeechEngine || model != self.observedSpeechModel else { return }"))
    }

    /// The Models page says what was measured, in words VoiceOver can read, and Remove is reachable.
    @Test func modelsPageWordsAndAccess() throws {
        let stats = MeasuredSpeechStats(wer: 1.97, talkSeconds: 0.0565, loadSeconds: 0.269, clips: 200)
        #expect(SpeechModelDisplay.spokenAccuracy(stats) == "Accuracy 98.0 percent")
        #expect(SpeechModelDisplay.spokenSpeed(stats) == "Speed 0.06 seconds")
        #expect(SpeechModelDisplay.spokenAccuracy(nil) == "Accuracy not measured")
        let entry = try #require(SpeechModelCatalog.entry("orukeet"))
        let help = SpeechModelDisplay.rowHelp(entry, stats: stats)
        #expect(help.contains("from a cold start to its first text") && !help.contains("to load"))
        let run = SpeechBenchmarkRun(machine: "MacBook Pro (M5, 24 GB)", date: "2026-10-16", clipSet: "200 LibriSpeech recordings", build: "81")
        #expect(SpeechModelDisplay.measuredNote(run).contains("100% minus the word error rate"))
        let page = try source("Sources/Tokens/Features/Home/TokensModelsPage.swift")
        #expect(page.contains(".accessibilityActions {"), "Remove is a VoiceOver row action, not only a right-click")
        // The bubble names where a missing model downloads now.
        let download = try source("Sources/Tokens/Speech/OrukeetModelDownload.swift")
        #expect(download.contains("Download it again in Models, or choose Apple.") && !download.contains("Download it again in Settings"))
    }
}
