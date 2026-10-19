import CryptoKit
import Foundation
import TokensCore

enum OrukeetFailure: Error, LocalizedError {
    case assets, invalidAudio, conversion, overload, busy, canceled, startupTimeout, requestTimeout, protocolFailure, workerExited
    var errorDescription: String? {
        switch self {
        case .assets: return "Orukeet's bundled speech assets are missing or failed verification."
        case .invalidAudio: return "Orukeet received unsupported audio."
        case .conversion: return "Orukeet could not convert the captured audio."
        case .overload: return "Orukeet could not keep up with this recording. The available words are kept for recovery."
        case .busy: return "Orukeet is still finishing another recording."
        case .canceled: return "Orukeet recognition was canceled."
        case .startupTimeout: return "Orukeet did not become ready in time."
        case .requestTimeout: return "Orukeet did not finish decoding in time. The available words are kept for recovery."
        case .protocolFailure: return "Orukeet returned an invalid recognition response."
        case .workerExited: return "Orukeet's local recognizer stopped unexpectedly."
        }
    }
}

/// Only the signed application's resource tree is admitted, plus, in a bundle that names
/// TokensOrukeetModelURL, the weights file OrukeetModelDownload installed in Application Support
/// (same pinned length and SHA-256). No environment override or other path is accepted.
struct OrukeetAssets: Sendable {
    static let modelSHA256 = "93ce19c6d8244acbfea980eeaf970531d4f216171578ef8e041dcc2d070a45bd"
    static let modelBytes: Int64 = 714_456_704
    let workerURL: URL
    let modelURL: URL
    let libraryURL: URL
    let resourceRoot: URL
    static let verifiedModelKey = "TokensOrukeetVerifiedModel.v1"
    /*
    One fast-path slot per pinned file (build 81). A single shared slot let each verified model
    push out the others, so with Orukeet plus a downloaded model every launch, prewarm and model
    switch hashed 0.3 to 1 GB again in full (up to about 5 GB with every model downloaded), and the chosen
    model sat on Apple until that hash finished. Separate keys are each written whole, so the
    launch's parallel checks cannot lose one another's entry.
    */
    static func verifiedKey(sha256: String) -> String { verifiedModelKey + "." + sha256 }
    /*
    Build 79: the worker and weights for the chosen local model. Orukeet runs on its NeMo worker as
    before; every other downloadable model runs on the bundled transcribe-worker with the weights
    SpeechModelStore downloaded and verified (same pinned length and SHA-256 check).
    */
    static func resolveSelected(bundle: Bundle = .main, cache: UserDefaults = .standard) throws -> OrukeetAssets {
        let id = SpeechEngineChoice.selectedModelID()
        guard let entry = SpeechModelCatalog.entry(id), entry.runtime == .transcribeCpp else {
            return try resolve(bundle: bundle, cache: cache)
        }
        guard let worker = TranscribeRuntime.workerURL(bundle),
              SpeechModelStore.verifyInstalled(entry, bundle: bundle, cache: cache) else { throw OrukeetFailure.assets }
        let root = worker.deletingLastPathComponent()
        return .init(workerURL: worker, modelURL: SpeechModelStore.installedURL(entry, bundle: bundle),
                     libraryURL: root, resourceRoot: root)
    }

    static func resolve(bundle: Bundle = .main, cache: UserDefaults = .standard) throws -> OrukeetAssets {
        do { return try verified(bundle: bundle, cache: cache) }
        catch { throw OrukeetFailure.assets }
    }
    /// Identity of one verified model file for this app build: device, inode, size,
    /// modification and status-change times (ctime moves on any content or metadata
    /// change, including a restored mtime). Any difference forces a full re-hash.
    static func modelFingerprint(path: String, expectedSHA256: String, appVersion: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [appVersion, expectedSHA256, "\(info.st_dev)", "\(info.st_ino)", "\(info.st_size)",
                "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
                "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"].joined(separator: "|")
    }
    private static func appVersion(_ bundle: Bundle) -> String {
        ["CFBundleShortVersionString", "CFBundleVersion", "TokensSourceCommit"]
            .map { bundle.object(forInfoDictionaryKey: $0) as? String ?? "" }.joined(separator: "/")
    }
    /// The downloaded weights get the bundled file's checks: a regular file, the pinned length,
    /// and the pinned SHA-256 (skipped only when this exact file was already verified).
    static func verifyDownloadedModel(at file: URL, bundle: Bundle, cache: UserDefaults,
                                      expectedSHA256: String = modelSHA256, expectedBytes: Int64 = modelBytes) throws {
        guard try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == expectedBytes
        else { throw OrukeetFailure.assets }
        let fingerprint = modelFingerprint(path: file.path, expectedSHA256: expectedSHA256, appVersion: appVersion(bundle))
        let key = verifiedKey(sha256: expectedSHA256)
        if let fingerprint, cache.string(forKey: key) == fingerprint { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else { throw OrukeetFailure.assets }
        if let fingerprint { cache.set(fingerprint, forKey: key) }
    }

    private static func verified(bundle: Bundle, cache: UserDefaults) throws -> OrukeetAssets {
        guard let resources = bundle.resourceURL else { throw OrukeetFailure.assets }
        let root = resources.appendingPathComponent("Orukeet", isDirectory: true)
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == root.standardizedFileURL.path else { throw OrukeetFailure.assets }
        let manifestURL = root.appendingPathComponent("asset-manifest.json")
        let manifestHandle = try FileHandle(forReadingFrom: manifestURL)
        defer { try? manifestHandle.close() }
        let manifestData = try manifestHandle.read(upToCount: 1_048_577) ?? Data()
        guard manifestData.count <= 1_048_576,
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["schema_version"] as? Int == 1,
              manifest["model_sha256"] as? String == modelSHA256,
              let files = manifest["files"] as? [String: String], files.count <= 256,
              files["orukeet-v0.1.0-q8.gguf"] == modelSHA256
                || (files["orukeet-v0.1.0-q8.gguf"] == nil && OrukeetModelStore.downloadURL(bundle) != nil),
              files["orukeet-worker"] != nil, files.keys.contains(where: { $0.hasPrefix("lib/") }) else {
            throw OrukeetFailure.assets
        }
        for (relative, expected) in files {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                  expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw OrukeetFailure.assets }
            let file = root.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard file.path.hasPrefix(canonical.path + "/"),
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw OrukeetFailure.assets }
            var fingerprint: String?
            if relative == "orukeet-v0.1.0-q8.gguf" {
                let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                guard size?.int64Value == modelBytes else { throw OrukeetFailure.assets }
                // Re-hashing 714 MB costs ~1 s and disk-cache churn on every cold load. Skip it
                // only for the identical, already verified file of this exact app build.
                fingerprint = modelFingerprint(path: file.path, expectedSHA256: expected, appVersion: appVersion(bundle))
                if let fingerprint, cache.string(forKey: verifiedKey(sha256: expected)) == fingerprint { continue }
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw OrukeetFailure.assets }
            if let fingerprint { cache.set(fingerprint, forKey: verifiedKey(sha256: expected)) }
        }
        // An unlisted runtime library must not get loaded through the directory search path.
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil) {
            guard files["lib/" + file.lastPathComponent] != nil else { throw OrukeetFailure.assets }
        }
        let worker = root.appendingPathComponent("orukeet-worker")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { throw OrukeetFailure.assets }
        var model = root.appendingPathComponent("orukeet-v0.1.0-q8.gguf")
        if files["orukeet-v0.1.0-q8.gguf"] == nil {
            model = OrukeetModelStore.installedURL(bundle)
            do { try verifyDownloadedModel(at: model, bundle: bundle, cache: cache) } catch {
                // A downloaded file that fails here is never retried as-is: drop it, fall back to
                // Apple for the next dictation, and fetch it again.
                OrukeetModelStore.invalidate(model)
                Task { @MainActor in OrukeetModelDownload.shared.restartAfterInvalidation() }
                throw error
            }
        }
        return .init(workerURL: worker, modelURL: model, libraryURL: lib, resourceRoot: root)
    }
}

/// The bundled transcribe-worker (transcribe.cpp, MIT, pinned in scripts/transcribe/build_worker.sh).
enum TranscribeRuntime {
    static func workerURL(_ bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let worker = resources.appendingPathComponent("Transcribe/transcribe-worker")
        return FileManager.default.isExecutableFile(atPath: worker.path) ? worker : nil
    }
}
