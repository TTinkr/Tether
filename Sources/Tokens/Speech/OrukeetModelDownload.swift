

import CryptoKit
import Foundation
import os
import TokensCore

/// Where a download-mode build keeps Orukeet's weights, and whether they are ready.
enum OrukeetModelStore {
    static let fileName = "orukeet-v0.1.0-q8.gguf"
    static let urlKey = "TokensOrukeetModelURL"

    /// Set by package_app.py --orukeet-model-url. nil: the weights are in the bundle (or absent).
    static func downloadURL(_ bundle: Bundle = .main) -> URL? {
        (bundle.object(forInfoDictionaryKey: urlKey) as? String).flatMap(URL.init(string:))
    }

    static func directory(_ bundle: Bundle = .main) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle.bundleIdentifier ?? "com.tinkr.tokens", isDirectory: true)
            .appendingPathComponent("Orukeet", isDirectory: true)
    }

    static func installedURL(_ bundle: Bundle = .main) -> URL {
        directory(bundle).appendingPathComponent(fileName)
    }

    private static let readyFlag = OSAllocatedUnfairLock(initialState: false)

    /// Read on every engine lookup, so it is a flag, not a file check. A download-mode bundle
    /// starts false until launch finds (or the download installs) a full-length file.
    static var isReady: Bool {
        downloadURL() == nil || readyFlag.withLock { $0 }
    }

    static func markReady() { readyFlag.withLock { $0 = true } }

    /*
    The only way to become ready: the installed file passes the resolver's own check (pinned
    length and SHA-256; a stat-only fast path when this exact file was verified before). A file
    that fails is deleted, so a same-size corrupt file can never be trusted and the download
    starts over. Runs off the main thread; a first full hash takes about a second.
    */
    @discardableResult
    static func verifyInstalled(at file: URL? = nil, bundle: Bundle = .main, cache: UserDefaults = .standard,
                                expectedSHA256: String = OrukeetAssets.modelSHA256,
                                expectedBytes: Int64 = OrukeetAssets.modelBytes) -> Bool {
        let file = file ?? installedURL(bundle)
        guard FileManager.default.fileExists(atPath: file.path) else {
            readyFlag.withLock { $0 = false }
            return false
        }
        do {
            try OrukeetAssets.verifyDownloadedModel(at: file, bundle: bundle, cache: cache,
                                                    expectedSHA256: expectedSHA256, expectedBytes: expectedBytes)
            markReady()
            return true
        } catch {
            invalidate(file)
            return false
        }
    }

    /// A downloaded file that failed verification: remove it and stop treating Orukeet as ready.
    static func invalidate(_ file: URL) {
        try? ModelPartialFile.remove(at: file)
        readyFlag.withLock { $0 = false }
    }
}

enum OrukeetDownloadFailure: Error, Equatable, LocalizedError {
    /// noSpace: how many more bytes this Mac would have to free for the download to fit.
    case http(Int), tooLarge, wrongLength, checksum, interrupted(String), noSpace(short: Int64)
    var errorDescription: String? {
        switch self {
        case .http(let code): return "the server answered \(code)"
        case .tooLarge, .wrongLength: return "the file had the wrong size"
        case .checksum: return "the file did not match its checksum"
        case .interrupted(let reason): return reason
        case .noSpace(let short):
            return Self.noSpacePrefix + " (free up \(ByteCountFormatter.string(fromByteCount: short, countStyle: .file)))"
        }
    }
    /// A stopped download's reason starts this way when the disk was the cause (the row says so).
    static let noSpacePrefix = "not enough free space on this Mac"
    static func isNoSpace(_ reason: String) -> Bool { reason.hasPrefix(noSpacePrefix) }
}

/*
Build 81: a model download never fills the disk. "Download all" started every transfer at once
with no look at free space; on a nearly full Mac each one failed at a full disk and kept its
partial file for a resume, so gigabytes stayed behind with no way to free them in the app. Now a
transfer first books the bytes it still has to write against the volume's free space, after
what other transfers have booked and a spare gigabyte the rest of the Mac keeps. One that does
not fit never starts, and its row says why. Only Tokens' own partial downloads are ever deleted.
*/
enum ModelDownloadSpace {
    static let spareBytes: Int64 = 1_000_000_000
    private static let booked = OSAllocatedUnfairLock<Int64>(initialState: 0)

    typealias FreeBytes = @Sendable (URL) -> Int64?

    /// Free space macOS would make for a file in this folder (purgeable space included); nil when
    /// unknown, which never blocks a download. Tests pass their own.
    static let systemFreeBytes: FreeBytes = { directory in
        // The Models folder may not exist before the first download: ask its nearest parent.
        var folder = directory
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /*
    Free space is read under the same lock as the booked total. Read
    before the lock, a transfer could write and release its booking in between, and the new
    booking would pair the old, larger free space with the new, smaller total and overbook.
    Under the lock a write in progress only ever makes the check stricter: its bytes leave free
    space before its booking is released.
    */
    /// What `bytes` more would leave short on that volume, after every booked transfer and the spare.
    static func shortfall(_ bytes: Int64, in directory: URL, freeBytes: FreeBytes = systemFreeBytes) -> Int64? {
        let short: Int64? = booked.withLock { total in
            guard let free = freeBytes(directory) else { return nil }
            return bytes + total + spareBytes - free
        }
        guard let short, short > 0 else { return nil }
        return short
    }

    /// Books `bytes` for one transfer, or throws noSpace when they do not fit.
    static func book(_ bytes: Int64, in directory: URL, freeBytes: FreeBytes = systemFreeBytes) throws {
        guard bytes > 0 else { return }
        try booked.withLock { total in
            if let free = freeBytes(directory), bytes + total + spareBytes > free {
                throw OrukeetDownloadFailure.noSpace(short: bytes + total + spareBytes - free)
            }
            total += bytes
        }
    }

    static func release(_ bytes: Int64) {
        guard bytes > 0 else { return }
        booked.withLock { $0 = max(0, $0 - bytes) }
    }

    /// Bytes a download of `expected` still has to write next to an existing partial file.
    static func remaining(_ expected: Int64, destination: URL) -> Int64 {
        let partial = destination.appendingPathExtension("partial")
        let existing = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        return existing < expected ? expected - existing : expected
    }

    /// A write that failed because the volume is full (POSIX ENOSPC or Foundation's out-of-space).
    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// One verified transfer. Bytes are hashed as they are written to `<destination>.partial`; an
/// interrupted transfer resumes with an HTTP Range request and re-hashes what it already has.
/// A server that answers the Range request with the whole file restarts it from zero, and the
/// transfer then books the whole file's space. The destination appears only when length and
/// SHA-256 both match.
final class OrukeetModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let expectedSHA256: String
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let freeBytes: ModelDownloadSpace.FreeBytes
    private var partial: URL { destination.appendingPathExtension("partial") }
    // Touched only on the session's serial delegate queue.
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var failure: OrukeetDownloadFailure?
    private var continuation: CheckedContinuation<Void, Error>?
    /// Set on the delegate queue when the caller's task is cancelled, before or after the request starts.
    private var cancelled = false
    /// This transfer's share of ModelDownloadSpace still unwritten; handed back as bytes land.
    private let unwritten = OSAllocatedUnfairLock<Int64>(initialState: 0)

    private init(source: URL, destination: URL, expectedSHA256: String, expectedBytes: Int64,
                 freeBytes: @escaping ModelDownloadSpace.FreeBytes, progress: @escaping @Sendable (Int64) -> Void) {
        self.source = source
        self.freeBytes = freeBytes
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    static func fetch(from source: URL, to destination: URL, expectedSHA256: String, expectedBytes: Int64,
                      freeBytes: @escaping ModelDownloadSpace.FreeBytes = ModelDownloadSpace.systemFreeBytes,
                      progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let transfer = OrukeetModelTransfer(source: source, destination: destination, expectedSHA256: expectedSHA256,
                                            expectedBytes: expectedBytes, freeBytes: freeBytes, progress: progress)
        try await transfer.run()
    }

    private func run() async throws {
        try PrivateFileStore.prepareDirectory(destination.deletingLastPathComponent())
        let existing = try ModelPartialFile.length(at: partial)
        if existing >= expectedBytes { try? ModelPartialFile.remove(at: partial) }
        // Nothing is fetched unless what is still to come fits beside the spare (build 81).
        let needed = ModelDownloadSpace.remaining(expectedBytes, destination: destination)
        try ModelDownloadSpace.book(needed, in: destination.deletingLastPathComponent(), freeBytes: freeBytes)
        unwritten.withLock { $0 = needed }
        defer { ModelDownloadSpace.release(unwritten.withLock { left in defer { left = 0 }; return left }) }
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if existing > 0, existing < expectedBytes, source.scheme?.hasPrefix("http") == true {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        /*
        Build 82: Cancel can now land before the request starts (a Download waiting for an earlier,
        cancelled attempt to close its file). Starting a data task on an invalidated session raises an
        exception, so the start and the cancel both run on the delegate's serial queue: a cancel that
        comes first makes the start answer CancellationError without touching the session; one that
        comes after cancels the running task, whose completion answers as before.
        */
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    if self.cancelled { return continuation.resume(throwing: CancellationError()) }
                    self.continuation = continuation
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            queue.addOperation {
                self.cancelled = true
                session.invalidateAndCancel()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        if let status, status != 200, status != 206 {
            failure = .http(status)
            return completionHandler(.cancel)
        }
        do {
            if status == 206 {
                // Read and append through the same checked descriptor. A .partial symlink
                // must never turn a failed model download into a write to another file.
                let resumed = try ModelPartialFile.resume(at: partial, maximumBytes: expectedBytes)
                handle = resumed
                while let chunk = try resumed.read(upToCount: 1_048_576), !chunk.isEmpty {
                    received += Int64(chunk.count)
                    guard received < expectedBytes else { throw OrukeetDownloadFailure.wrongLength }
                    hasher.update(data: chunk)
                }
            } else {
                // The whole file comes again: book all of it before the old partial goes (build 81).
                try bookWholeFile()
                try? ModelPartialFile.remove(at: partial)
                handle = try ModelPartialFile.create(at: partial)
            }
            progress(received)
            completionHandler(.allow)
        } catch {
            // A restart that no longer fits says so, like a download that never started (build 81).
            failure = error as? OrukeetDownloadFailure ?? .interrupted(error.localizedDescription)
            completionHandler(.cancel)
        }
    }

    /*
    Codex RC3 (build 81): run() booked only the bytes the partial file still lacked, because it
    asked the server to resume. A server that ignores the Range request answers 200 and sends the
    whole file, so this attempt writes every byte again. Without a bigger booking, the restart's
    tail was unbooked once its first bytes landed, and the space freed by deleting the partial
    looked free to the next Download: two transfers could then eat the spare gigabyte together.
    So the rest is booked here, before the partial is deleted and before any byte is written, and
    the partial's own bytes count as free for this one check because deleting it returns them.
    When even that does not fit (the Mac filled up meanwhile), the restart stops as noSpace.
    */
    private func bookWholeFile() throws {
        let extra = expectedBytes - unwritten.withLock { $0 }
        guard extra > 0 else { return }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        let freeBytes = self.freeBytes
        try ModelDownloadSpace.book(extra, in: destination.deletingLastPathComponent(),
                                    freeBytes: { folder in freeBytes(folder).map { $0 + onDisk } })
        unwritten.withLock { $0 += extra }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        received += Int64(data.count)
        guard received <= expectedBytes else {
            failure = .tooLarge
            return dataTask.cancel()
        }
        do { try handle.write(contentsOf: data) } catch {
            // At least what this attempt still had to write: the partial goes, so it starts over.
            failure = ModelDownloadSpace.isOutOfSpace(error)
                ? .noSpace(short: expectedBytes - received + Int64(data.count))
                : .interrupted(error.localizedDescription)
            return dataTask.cancel()
        }
        ModelDownloadSpace.release(unwritten.withLock { left in
            let landed = min(left, Int64(data.count)); left -= landed; return landed
        })
        hasher.update(data: data)
        progress(received)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let outcome: Result<Void, Error>
        if let failure {
            switch failure {
            // A full disk keeps nothing back: the partial is Tokens' own, and resuming it later
            // is worth less than the space the rest of the Mac needs now (build 81).
            case .tooLarge, .noSpace: try? ModelPartialFile.remove(at: partial)
            default: break
            }
            outcome = .failure(failure)
        } else if let error {
            // The partial file stays for the next attempt's Range request.
            outcome = .failure(OrukeetDownloadFailure.interrupted(error.localizedDescription))
        } else if received != expectedBytes {
            if received > expectedBytes { try? ModelPartialFile.remove(at: partial) }
            outcome = .failure(OrukeetDownloadFailure.wrongLength)
        } else if hasher.finalize().map({ String(format: "%02x", $0) }).joined() != expectedSHA256 {
            try? ModelPartialFile.remove(at: partial)
            outcome = .failure(OrukeetDownloadFailure.checksum)
        } else {
            do {
                try ModelPartialFile.promote(from: partial, to: destination)
                outcome = .success(())
            } catch {
                outcome = .failure(OrukeetDownloadFailure.interrupted(error.localizedDescription))
            }
        }
        continuation?.resume(with: outcome)
        continuation = nil
    }
}

/// Starts the weights download once per launch in a download-mode build, retries quietly, and
/// reports a one-line status for Settings.
@MainActor
final class OrukeetModelDownload: ObservableObject {
    static let shared = OrukeetModelDownload()

    enum State: Equatable {
        case idle, downloading(Double), ready, failed(String)
    }

    @Published private(set) var state: State = previewState() ?? .idle
    /// Called once when verified weights are installed (prewarm, refresh the engine line).
    var onReady: (() -> Void)?
    private var task: Task<Void, Never>?
    private static let retryDelays: [UInt64] = [0, 5, 30, 120]

    /*
    Render-only: --orukeet-preview-download <percent>|paused draws the download as in progress or
    paused, so the Settings and setup lines can be looked at (same gate as History's fixtures:
    --render-preview-frames in a proof-allowed build). Proof renders never call startIfNeeded, so
    nothing is fetched.
    */
    static func previewState(arguments: [String] = ProcessInfo.processInfo.arguments,
                             allowed: Bool = ProofRoutes.isAllowed) -> State? {
        guard allowed, arguments.contains("--render-preview-frames"),
              let flag = arguments.firstIndex(of: "--orukeet-preview-download"), flag + 1 < arguments.count
        else { return nil }
        let value = arguments[flag + 1]
        if value == "paused" { return .failed("preview") }
        return Double(value).map { .downloading(min(1, max(0, $0 / 100))) }
    }

    /*
    The optional Orukeet download's status. Dictation waits for verified weights;
    nil when there is nothing to say.
    */
    var setupLine: String? {
        switch state {
        case .idle, .ready: return nil
        case .downloading(let fraction):
            return "The voice model is downloading (\(Int(fraction * 100))%). Dictation waits until the model is ready."
        case .failed: return "The voice model will finish downloading later. Dictation waits until the model is ready."
        }
    }

    /// The optional Orukeet download status; selected-model waits use SpeechModelStore.
    var waitingLine: String {
        /*
        Build 81: the chosen model is another downloaded one whose file this launch found missing or
        bad. "Getting ready" was untrue: nothing fetches it again until the person asks.
        */
        let chosen = SpeechEngineChoice.selectedModelID()
        if chosen != SpeechModelCatalog.orukeetID, let entry = SpeechModelCatalog.entry(chosen), entry.runtime != .apple {
            switch SpeechModelStore.shared.checkedState(for: chosen) {
            case .notDownloaded?, .failed?:
                return "\(entry.name) isn't on this Mac. Download it again in Models, or choose Apple."
            case .downloading(let fraction)?:
                return "\(entry.name) downloading (\(Int(fraction * 100))%). Ready in a moment."
            default: break
            }
        }
        switch state {
        case .downloading(let fraction): return "Voice model downloading (\(Int(fraction * 100))%). Ready in a moment."
        case .failed(let reason) where OrukeetDownloadFailure.isNoSpace(reason):
            return "Not enough free space for the voice model. Free some, then Retry in Settings."
        case .failed: return "Voice model download paused. Retry in Settings, or choose Apple there."
        case .idle, .ready: return "Voice model getting ready. Try again in a moment."
        }
    }

    /// nil when there is nothing to say (bundled weights, or already ready).
    var statusLine: String? {
        switch state {
        case .idle, .ready: return nil
        case .downloading(let fraction): return "Orukeet downloading \(Int(fraction * 100))%"
        case .failed(let reason) where OrukeetDownloadFailure.isNoSpace(reason): return "no space for Orukeet"
        case .failed: return "Orukeet download paused"
        }
    }

    func startIfNeeded() {
        guard let source = OrukeetModelStore.downloadURL(), task == nil else { return }
        let destination = OrukeetModelStore.installedURL()
        task = Task { [weak self] in
            // An existing file is trusted only after the full check; a bad one is deleted here.
            if await Task.detached(operation: { OrukeetModelStore.verifyInstalled() }).value {
                self?.finish()
                return
            }
            self?.state = .downloading(0)
            var lastError = "it could not finish"
            for delay in Self.retryDelays {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                if Task.isCancelled { return }
                do {
                    try await OrukeetModelTransfer.fetch(
                        from: source, to: destination,
                        expectedSHA256: OrukeetAssets.modelSHA256, expectedBytes: OrukeetAssets.modelBytes,
                        progress: { bytes in
                            let fraction = Double(bytes) / Double(OrukeetAssets.modelBytes)
                            Task { @MainActor in
                                guard let self, case .downloading(let shown) = self.state,
                                      Int(fraction * 100) != Int(shown * 100) else { return }
                                self.state = .downloading(fraction)
                            }
                        })
                    // The transfer hashed what it wrote; this records the resolver's fast-path fingerprint.
                    guard await Task.detached(operation: { OrukeetModelStore.verifyInstalled() }).value else {
                        lastError = OrukeetDownloadFailure.checksum.localizedDescription
                        continue
                    }
                    Diagnostics.event("orukeet_model_download installed")
                    self?.finish()
                    return
                } catch {
                    lastError = error.localizedDescription
                    Diagnostics.event("orukeet_model_download attempt_failed")
                    // A full disk does not clear up in seconds: say so now instead of "0%" for minutes.
                    if case OrukeetDownloadFailure.noSpace = error { break }
                }
            }
            self?.state = .failed(lastError)
            self?.task = nil
        }
    }

    private func finish() {
        state = .ready
        task = nil
        onReady?()
    }

    func retry() {
        guard case .failed = state else { return }
        state = .idle
        startIfNeeded()
    }

    /// The resolver rejected the installed weights at use: dictation waits again and the
    /// file is fetched again.
    func restartAfterInvalidation() {
        guard task == nil else { return }
        state = .idle
        startIfNeeded()
    }
}
