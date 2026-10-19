

import Combine
import Foundation
import os
import TokensCore

@MainActor
final class SpeechModelStore: ObservableObject {
    static let shared = SpeechModelStore()

    enum State: Equatable {
        case builtIn
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
        /// This build does not yet ship the runtime for the model's family.
        case comingSoon
    }

    @Published private(set) var states: [String: State] = [:]
    /// Each model's downloads, Cancel's recheck and Remove's delete, in turn (ModelTransferSlots).
    let slots = ModelTransferSlots()
    /// The app refreshes and warms only if this is still the selected model.
    var onReady: ((String) -> Void)?
    private var orukeetObservation: AnyCancellable?

    private init() {
        orukeetObservation = OrukeetModelDownload.shared.$state.sink { [weak self] _ in
            Task { @MainActor in self?.refreshOrukeet() }
        }
        refresh()
    }

    // MARK: Facts that do not need the main actor

    /// Families whose worker ships in this build.
    nonisolated static func runnable(_ entry: SpeechModelEntry, bundle: Bundle = .main) -> Bool {
        switch entry.runtime {
        case .apple: return true
        case .nemoGGML: return entry.id == SpeechModelCatalog.orukeetID
        case .transcribeCpp: return TranscribeRuntime.workerURL(bundle) != nil && entry.download != nil
        }
    }

    nonisolated static func installedURL(_ entry: SpeechModelEntry, bundle: Bundle = .main) -> URL {
        if entry.id == SpeechModelCatalog.orukeetID { return OrukeetModelStore.installedURL(bundle) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle.bundleIdentifier ?? "com.tinkr.tokens", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(entry.download?.fileName ?? entry.id)
    }

    private static let readyIDs = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Read on every engine lookup: a flag set only after a full verification.
    nonisolated static func isReady(_ id: String) -> Bool {
        guard let entry = SpeechModelCatalog.entry(id) else { return false }
        if entry.runtime == .apple { return true }
        if id == SpeechModelCatalog.orukeetID { return OrukeetModelStore.isReady }
        return readyIDs.withLock { $0.contains(id) }
    }

    /// Full pinned check of an installed file; cleanup refuses links and directories.
    nonisolated static func verifyInstalled(_ entry: SpeechModelEntry, bundle: Bundle = .main,
                                            cache: UserDefaults = .standard) -> Bool {
        guard let download = entry.download else { return true }
        let file = installedURL(entry, bundle: bundle)
        let ok = FileManager.default.fileExists(atPath: file.path)
            && (try? OrukeetAssets.verifyDownloadedModel(at: file, bundle: bundle, cache: cache,
                                                         expectedSHA256: download.sha256,
                                                         expectedBytes: download.bytes)) != nil
        if !ok { try? ModelPartialFile.remove(at: file) }
        let wasReady = readyIDs.withLock { ready -> Bool in
            let was = ready.contains(entry.id)
            if ok { ready.insert(entry.id) } else { ready.remove(entry.id) }
            return was
        }
        /*
        A file that was verified this session and now fails (removed or changed under the app, found
        when a worker starts) must leave its row unavailable. The row goes back to Download;
        recognition waits until this selected model is ready again.
        */
        if !ok, wasReady, entry.id != SpeechModelCatalog.orukeetID {
            Task { @MainActor in SpeechModelStore.shared.markMissing(entry.id) }
        }
        return ok
    }

    /// A ready model whose file failed its check: Download again (a download in flight is left alone).
    func markMissing(_ id: String) {
        guard !slots.isBusy(id), states[id] == .ready else { return }
        states[id] = .notDownloaded
    }

    // MARK: State

    func state(for id: String) -> State { states[id] ?? .notDownloaded }

    /// The state once this launch has checked the model's file; nil while that check still runs.
    func checkedState(for id: String) -> State? { states[id] }

    /// Recomputes every row; files are verified off the main thread.
    func refresh() {
        for entry in SpeechModelCatalog.all {
            if entry.runtime == .apple { states[entry.id] = .builtIn; continue }
            if entry.id == SpeechModelCatalog.orukeetID { refreshOrukeet(); continue }
            guard Self.runnable(entry) else { states[entry.id] = .comingSoon; continue }
            guard !slots.isBusy(entry.id) else { continue }
            Task { [weak self] in
                let ok = await Task.detached { Self.verifyInstalled(entry) }.value
                guard let self, !self.slots.isBusy(entry.id) else { return }
                self.states[entry.id] = ok ? .ready : .notDownloaded
                if ok { self.onReady?(entry.id) }
            }
        }
    }

    private func refreshOrukeet() {
        let id = SpeechModelCatalog.orukeetID
        guard OrukeetModelStore.downloadURL() != nil else {
            // A bundle that ships the weights (Dev, older packaging) has nothing to download.
            states[id] = SpeechEngineChoice.orukeetBundled ? .builtIn : .comingSoon
            return
        }
        switch OrukeetModelDownload.shared.state {
        case .downloading(let fraction): states[id] = .downloading(fraction)
        case .ready:
            states[id] = .ready
            // A download the person started is chosen only once verified (Codex review of 86).
            if let choiceAtStart = orukeetChoiceAtStart {
                orukeetChoiceAtStart = nil
                chooseFinished(id, true, choiceAtStart)
            }
        case .failed(let reason): states[id] = .failed(reason); orukeetChoiceAtStart = nil
        case .idle: states[id] = OrukeetModelStore.isReady ? .ready : .notDownloaded
        }
    }

    /// Prepare the selected local model on a normal launch. Verification precedes any
    /// download; this never changes saved selection and never runs for synthetic previews.
    func prepareSelectedModel() {
        let id = SpeechEngineChoice.selectedModelID()
        guard let entry = SpeechModelCatalog.entry(id), entry.runtime != .apple else { return }
        guard Self.runnable(entry) else { states[id] = .comingSoon; return }
        if id == SpeechModelCatalog.orukeetID {
            if Self.isReady(id) { onReady?(id) }
            OrukeetModelDownload.shared.startIfNeeded()
            return
        }
        switch state(for: id) {
        case .builtIn, .ready: onReady?(id)
        case .notDownloaded, .failed: download(id)
        case .downloading, .comingSoon: break
        }
    }

    func waitingLine(for id: String = SpeechEngineChoice.selectedModelID()) -> String {
        Self.waitingLine(modelID: id, state: checkedState(for: id))
    }

    nonisolated static func waitingLine(modelID id: String, state: State?) -> String {
        guard let entry = SpeechModelCatalog.entry(id), entry.runtime != .apple else { return "Apple speech is selected." }
        switch state {
        case .downloading(let fraction)?:
            return "\(entry.name) downloading (\(Int(fraction * 100))%). Dictation will be ready when it finishes."
        case .failed(let reason)? where OrukeetDownloadFailure.isNoSpace(reason):
            return "Not enough free space for \(entry.name). Free some, then Retry in Models."
        case .failed?: return "\(entry.name) download paused. Retry in Models, or explicitly choose another model."
        case .notDownloaded?: return "\(entry.name) isn't on this Mac. Download it in Models, or choose another model."
        case .comingSoon?: return "\(entry.name) is unavailable in this build. Choose another model in Models."
        case .ready?, .builtIn?: return "\(entry.name) is ready on this Mac."
        case nil: return "Checking \(entry.name) on this Mac. Try again in a moment."
        }
    }

    var selectedSetupLine: String? {
        SpeechEngineChoice.waitingForOrukeet() ? waitingLine() : nil
    }

    // MARK: Actions

    /// Starts a download only for a model that is not on this Mac yet, or whose download stopped.
    /// `selectWhenReady`: the person asked for this download, so it becomes the model in use once ready.
    func downloadIfMissing(_ id: String, selectWhenReady: Bool = false) {
        switch state(for: id) {
        case .notDownloaded, .failed: download(id, selectWhenReady: selectWhenReady)
        default: break
        }
    }

    /*
    Every choice made by hand bumps choiceRevision. A finished download is chosen only if no choice
    was made by hand while it ran: comparing model names was not enough (Codex QA of 86: Apple, then
    B, then Apple again looked unchanged and the download took over).
    */
    nonisolated static func choosesWhenReady(revisionAtStart: Int, revisionNow: Int) -> Bool { revisionAtStart == revisionNow }
    private(set) var choiceRevision = 0

    func download(_ id: String, selectWhenReady: Bool = false) {
        guard let entry = SpeechModelCatalog.entry(id), Self.runnable(entry), let download = entry.download else { return }
        let choiceAtStart = choiceRevision
        if id == SpeechModelCatalog.orukeetID {
            // Chosen when OrukeetModelDownload reports it verified (refreshOrukeet), never before:
            // a failed or cancelled download leaves the choice alone (Codex review of 86).
            if selectWhenReady { orukeetChoiceAtStart = choiceAtStart }
            if case .failed = OrukeetModelDownload.shared.state { OrukeetModelDownload.shared.retry() }
            else { OrukeetModelDownload.shared.startIfNeeded() }
            return
        }
        guard !slots.isRunning(id) else { return }
        // Never fetch again what is already on this Mac (build 81: Download all re-downloaded the
        // model in use and showed Apple as in use meanwhile).
        switch state(for: id) {
        case .ready, .builtIn, .downloading, .comingSoon: return
        case .notDownloaded, .failed: break
        }
        let destination = Self.installedURL(entry)
        states[id] = .downloading(0)
        /*
        The transfer starts only after any earlier attempt for this model has closed its .partial
        file (a Cancel then Download used to let two transfers write it at once). A stale attempt (cancelled, or replaced) never changes the row.
        */
        slots.start(id) { [weak self] current in
            /*
            A file already on this Mac (a transfer that finished just as Cancel landed) is used as
            it is, never fetched again beside itself (independent review, 2026-10-17).
            */
            if await Task.detached(operation: { Self.verifyInstalled(entry) }).value {
                if current() {
                    self?.states[id] = .ready
                    self?.chooseFinished(id, selectWhenReady, choiceAtStart)
                    self?.onReady?(id)
                }
                return
            }
            do {
                try await OrukeetModelTransfer.fetch(
                    from: download.url, to: destination, expectedSHA256: download.sha256, expectedBytes: download.bytes,
                    progress: { bytes in
                        let fraction = Double(bytes) / Double(download.bytes)
                        Task { @MainActor in
                            guard let self, current(), case .downloading(let shown) = self.states[id],
                                  Int(fraction * 100) != Int(shown * 100) else { return }
                            self.states[id] = .downloading(fraction)
                        }
                    })
                let ok = await Task.detached { Self.verifyInstalled(entry) }.value
                guard current() else { return }
                self?.states[id] = ok ? .ready : .failed(OrukeetDownloadFailure.checksum.localizedDescription)
                if ok {
                    self?.chooseFinished(id, selectWhenReady, choiceAtStart)
                    self?.onReady?(id)
                }
            } catch {
                // Cancel already put the row back to Download; a stopped transfer is not a failure.
                guard current() else { return }
                self?.states[id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Dev fixture proofs only (--fixture-download): runs download(id) exactly as the Download
    /// button does, waits for ready or failed, and writes a receipt. True when the model is ready.
    static func downloadForProof(_ id: String, receipt: String) async -> Bool {
        let store = SpeechModelStore.shared
        let started = Date()
        let wasReady = isReady(id)
        if !wasReady { store.download(id) }
        var state = store.state(for: id)
        while Date().timeIntervalSince(started) < 1800 {
            state = store.state(for: id)
            if state == .ready || isReady(id) { state = .ready; break }
            if case .failed = state { break }
            if state == .comingSoon || state == .notDownloaded && !store.slots.isBusy(id) && !wasReady
                && Date().timeIntervalSince(started) > 5 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let entry = SpeechModelCatalog.entry(id)
        let row: [String: Any] = [
            "model_id": id, "already_present": wasReady, "state": "\(state)",
            "ready": state == .ready, "seconds": Date().timeIntervalSince(started),
            "url": entry?.download?.url.absoluteString ?? "", "expected_sha256": entry?.download?.sha256 ?? "",
            "expected_bytes": entry?.download?.bytes ?? 0,
            "installed_path": entry.map { installedURL($0).path } ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: receipt))
        }
        return state == .ready
    }

    /*
    Cancel on a downloading row (build 82: per-model download, cancel, retry). The row
    goes back to Download at once; the transfer stops and its late answer is ignored. A Download
    pressed right after waits for that transfer to close its file. If the transfer had already
    finished and verified its file when Cancel landed, the row says so once it has stopped (Use).
    Orukeet's download is the app's default and is not cancelled here.
    */
    func cancel(_ id: String) {
        guard id != SpeechModelCatalog.orukeetID, slots.isRunning(id), let entry = SpeechModelCatalog.entry(id) else { return }
        slots.cancel(id)
        states[id] = .notDownloaded
        Diagnostics.event("speech_model_download_cancelled id=\(id)")
        slots.then(id) { [weak self] in
            guard let self, !self.slots.isRunning(id), self.states[id] == .notDownloaded else { return }
            if await Task.detached(operation: { Self.verifyInstalled(entry) }).value {
                if !self.slots.isRunning(id), self.states[id] == .notDownloaded { self.states[id] = .ready }
            } else if !self.slots.isRunning(id) {
                // Cancel gives the space back: the stopped transfer's part file goes too (review, 2026-10-17).
                Self.discardPartial(for: Self.installedURL(entry))
            }
        }
    }

    /// The part file a stopped transfer keeps for resuming (OrukeetModelTransfer), removed.
    nonisolated static func discardPartial(for destination: URL) {
        try? ModelPartialFile.remove(at: destination.appendingPathExtension("partial"))
    }

    /*
    Removes a downloaded model; if it was chosen, the packaged default takes over. The row and the
    choice change at once; the file goes once any transfer for this model has stopped, so a transfer
    finishing late cannot bring a removed model back.
    */
    func remove(_ id: String) {
        guard let entry = SpeechModelCatalog.entry(id), entry.download != nil,
              id != SpeechModelCatalog.orukeetID else { return }   // the default stays installed
        slots.cancel(id)
        Self.readyIDs.withLock { _ = $0.remove(id) }
        states[id] = .notDownloaded
        if SpeechEngineChoice.selectedModelID() == id {
            UserDefaults.standard.removeObject(forKey: SpeechEngineChoice.preferenceKey)
        }
        slots.then(id) {
            try? ModelPartialFile.remove(at: Self.installedURL(entry))
            Self.discardPartial(for: Self.installedURL(entry))
            Self.readyIDs.withLock { _ = $0.remove(id) }
        }
    }

    /// choiceRevision when the person started an Orukeet download; nil when none is pending.
    private var orukeetChoiceAtStart: Int?

    /// A download the person started becomes the model in use, unless they chose by hand meanwhile.
    private func chooseFinished(_ id: String, _ selectWhenReady: Bool, _ choiceAtStart: Int) {
        guard selectWhenReady, Self.choosesWhenReady(revisionAtStart: choiceAtStart, revisionNow: choiceRevision) else { return }
        if choose(id, byHand: false) { Diagnostics.event("speech_model_chosen_after_download model=\(id)") }
    }

    /// Saves the choice for the next dictation. Only built-in or ready models in a family this build
    /// can run are accepted.
    @discardableResult
    func choose(_ id: String, byHand: Bool = true) -> Bool {
        guard let entry = SpeechModelCatalog.entry(id), Self.runnable(entry) else { return false }
        switch state(for: id) {
        case .builtIn, .ready: break
        // Orukeet may be chosen while it downloads (or its stopped download restarts, build 81):
        // Dictation waits until it is verified.
        case .downloading where id == SpeechModelCatalog.orukeetID, .notDownloaded where id == SpeechModelCatalog.orukeetID,
             .failed where id == SpeechModelCatalog.orukeetID: break
        default: return false
        }
        UserDefaults.standard.set(id, forKey: SpeechEngineChoice.preferenceKey)
        if byHand { choiceRevision += 1 }
        /*
        The warm worker holds the previous model: replace it now so the next talk is warm. The
        pool's own check swaps an idle worker (or a background load) for a different model, but
        never a worker or load a talk is using; that talk's release swaps instead. An explicit unload
        here used to cancel the load the preference observer had just started when going from Apple
        to a local model, so Settings read "unavailable · canceled" (build 81).
        */
        if entry.runtime != .apple {
            Task { try? await OrukeetSpeechPipeline.prewarm() }
        }
        return true
    }
}
