import CryptoKit
import Foundation
import os
import Testing
import TokensCore
@testable import Tokens

struct SpeechModelStoreTests {
    @Test func onlyShippedRuntimesAreRunnable() {
        #expect(SpeechModelStore.runnable(SpeechModelCatalog.entry("apple")!))
        #expect(SpeechModelStore.runnable(SpeechModelCatalog.entry("orukeet")!))
        let future = SpeechModelEntry(id: "whisper-base-en", name: "Whisper base.en", family: "Whisper",
                                      runtime: .transcribeCpp, parameters: 74_000_000, download: nil,
                                      languages: "English", licence: "MIT", published: nil)
        #expect(!SpeechModelStore.runnable(future))
        #expect(SpeechModelStore.isReady("apple"))
        #expect(!SpeechModelStore.isReady("not-a-model"))
    }

    @MainActor @Test func appleIsBuiltInAndChoosable() throws {
        let store = SpeechModelStore.shared
        #expect(store.state(for: "apple") == .builtIn)
        let saved = UserDefaults.standard.object(forKey: SpeechEngineChoice.preferenceKey)
        defer { UserDefaults.standard.set(saved, forKey: SpeechEngineChoice.preferenceKey) }
        #expect(store.choose("apple"))
        #expect(!store.choose("not-a-model"))
        // A model that is not on this Mac cannot be chosen: Download first, then Use (build 82).
        #expect(store.state(for: "whisper-base.en") == .ready || !store.choose("whisper-base.en"))
    }

    @Test func selectedModelWaitingMessagesNeverPromiseAppleFallback() {
        let id = "parakeet-tdt-0.6b-v3"
        let states: [SpeechModelStore.State?] = [nil, .notDownloaded, .downloading(0.42), .failed("offline"), .comingSoon]
        for state in states {
            let line = SpeechModelStore.waitingLine(modelID: id, state: state)
            #expect(line.contains("Parakeet v3"))
            #expect(!line.contains("Apple"))
        }
        #expect(SpeechModelStore.waitingLine(modelID: id, state: .downloading(0.42)).contains("42%"))
        #expect(SpeechModelStore.waitingLine(modelID: id, state: .ready) == "Parakeet v3 is ready on this Mac.")
        #expect(SpeechModelStore.waitingLine(modelID: id, state: .failed(OrukeetDownloadFailure.noSpace(short: 1).localizedDescription))
            .contains("Not enough free space for Parakeet v3"))
    }

    @Test func cancellingDownloadNeverDeletesAnUnexpectedPartialDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedModelCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let sentinel = partial.appendingPathComponent("sentinel")
        let original = Data("fictional unrelated content".utf8)
        try original.write(to: sentinel)
        SpeechModelStore.discardPartial(for: destination)
        #expect(try Data(contentsOf: sentinel) == original)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
    }

    /*
    Build 81 (C47): going from Apple to a local model, the preference observer and choose() each
    prewarm. They must share one load. choose() used to unload in between, which canceled the
    observer's load and left Settings reading "unavailable · canceled".
    */
    @Test func twoPrewarmsShareOneLoadWithoutCanceling() async throws {
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let pool = OrukeetWorkerPool(start: {
            starts.withLock { $0 += 1 }
            try await Task.sleep(nanoseconds: 80_000_000)
            return QuietDecoder()
        }, identity: { "parakeet-tdt-0.6b-v2" })
        let observer = Task { try await pool.prewarm() }
        try await Task.sleep(nanoseconds: 10_000_000)
        try await pool.prewarm()          // choose()'s prewarm
        try await observer.value          // no OrukeetFailure.canceled
        #expect(starts.withLock { $0 } == 1)
        #expect(await pool.isWarm)
        let store = try source("Speech/SpeechModelStore.swift")
        let choose = try #require(store.range(of: "func choose(_ id: String, byHand: Bool = true) -> Bool"))
        #expect(!store[choose.lowerBound...].contains("unloadIfIdle()"))
        // A load a newer pick replaced reports the newer load, not "canceled".
        #expect(try source("Speech/AudioCapture+Recognition.swift")
            .contains("catch OrukeetFailure.canceled where !Task.isCancelled && SpeechEngineChoice.load() == .orukeet"))
    }

    /// Build 82: Download only downloads and never switches models; Use switches.
    /// A file that fails after it was ready still sends its row back to Download (build 81, C48).
    @Test func downloadsNeverSwitchAndMissingFilesLeaveInUse() throws {
        let store = try source("Speech/SpeechModelStore.swift")
        let settings = try source("Features/Home/TokensHomeSettings.swift")
        #expect(!settings.contains("downloadAndChoose") && !store.contains("pendingChoice") && !store.contains("func downloadAll()"))
        #expect(settings.contains("use: chooseSpeechModel"))
        #expect(store.contains("if !ok, wasReady, entry.id != SpeechModelCatalog.orukeetID {"))
        #expect(store.contains("guard !slots.isBusy(id), states[id] == .ready else { return }"))
    }

    /// unless another model was chosen while it downloaded. Proof downloads never switch.
    @Test func aDownloadYouStartBecomesTheModelInUse() throws {
        #expect(SpeechModelStore.choosesWhenReady(revisionAtStart: 3, revisionNow: 3))
        #expect(!SpeechModelStore.choosesWhenReady(revisionAtStart: 3, revisionNow: 4))
        let settings = try source("Features/Home/TokensHomeSettings.swift")
        let store = try source("Speech/SpeechModelStore.swift")
        #expect(settings.contains("downloadIfMissing($0.id, selectWhenReady: true)"))
        #expect(store.contains("if !wasReady { store.download(id) }"))  // the proof path does not switch
        // Orukeet too is chosen only once verified, never when its download starts (Codex review of 86).
        #expect(store.contains("if selectWhenReady { orukeetChoiceAtStart = choiceAtStart }"))
        #expect(!store.contains("if selectWhenReady { choose(id) }"))
    }

    /// Codex QA of 86: Apple, then B, then Apple again by hand during a download keeps Apple.
    @MainActor @Test func aChoiceByHandDuringADownloadWinsEvenWhenItReturnsToTheStart() throws {
        let store = SpeechModelStore.shared
        let saved = UserDefaults.standard.string(forKey: SpeechEngineChoice.preferenceKey)
        defer { UserDefaults.standard.set(saved, forKey: SpeechEngineChoice.preferenceKey) }
        let start = store.choiceRevision
        #expect(store.choose(SpeechModelCatalog.appleID))
        #expect(store.choose(SpeechModelCatalog.appleID))   // A -> ... -> A: same name, new choices
        #expect(!SpeechModelStore.choosesWhenReady(revisionAtStart: start, revisionNow: store.choiceRevision))
        // An automatic choice after a download does not count as a choice by hand.
        let before = store.choiceRevision
        _ = store.choose(SpeechModelCatalog.appleID, byHand: false)
        #expect(store.choiceRevision == before)
    }

    /// Cancel puts the row back to Download at once; a stale attempt never changes the row; Remove's
    /// delete waits for any transfer (ordering itself: ModelTransferSlotsTests).
    @MainActor @Test func cancelAndRemoveGoThroughTheModelsQueue() throws {
        let store = try source("Speech/SpeechModelStore.swift")
        #expect(store.contains("guard id != SpeechModelCatalog.orukeetID, slots.isRunning(id), let entry = SpeechModelCatalog.entry(id) else { return }"))
        #expect(store.contains("slots.start(id) { [weak self] current in"))
        #expect(store.components(separatedBy: "guard current() else { return }").count == 3, "both outcomes check the attempt is current")
        let remove = try #require(store.range(of: "func remove(_ id: String)"))
        #expect(store[remove.lowerBound...].contains("slots.then(id) {\n            try? ModelPartialFile.remove(at: Self.installedURL(entry))"))
    }
}

/// A fake warm worker for pool checks: no process, model or microphone.
private final class QuietDecoder: OrukeetDecoding, @unchecked Sendable {
    func decode(_ samples: [Float], completion: @escaping (Result<OrukeetDecodedAudio, Error>) -> Void) {}
    func shutdown() {}
}
