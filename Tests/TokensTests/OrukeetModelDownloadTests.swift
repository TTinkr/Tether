import CryptoKit
import Foundation
import Testing
@testable import Tokens

// Serialized: ModelDownloadSpace's bookings are process-wide, and these tests check exact totals.
@Suite(.serialized)
struct OrukeetModelDownloadTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OrukeetModelDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func verifiedTransferInstallsOnlyTheMatchingFile() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let source = dir.appendingPathComponent("source.gguf")
        try bytes.write(to: source)
        let destination = dir.appendingPathComponent("installed/model.gguf")
        try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha(bytes),
                                             expectedBytes: Int64(bytes.count))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
    }

    @Test func aCompletedTransferNeverReplacesAnUnexpectedDestinationDirectory() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 7, count: 50_000)
        let source = dir.appendingPathComponent("source.gguf")
        try bytes.write(to: source)
        let destination = dir.appendingPathComponent("model.gguf")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        let original = Data("fictional unrelated content".utf8)
        try original.write(to: sentinel)
        await #expect(throws: (any Error).self) {
            try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha(bytes),
                                                 expectedBytes: Int64(bytes.count))
        }
        #expect(try Data(contentsOf: sentinel) == original)
        OrukeetModelStore.invalidate(destination)
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test func checksumOrLengthMismatchNeverInstalls() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 7, count: 50_000)
        let source = dir.appendingPathComponent("source.gguf")
        try bytes.write(to: source)
        let destination = dir.appendingPathComponent("model.gguf")
        await #expect(throws: OrukeetDownloadFailure.checksum) {
            try await OrukeetModelTransfer.fetch(from: source, to: destination,
                                                 expectedSHA256: String(repeating: "0", count: 64),
                                                 expectedBytes: Int64(bytes.count))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
        await #expect(throws: OrukeetDownloadFailure.wrongLength) {
            try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha(bytes),
                                                 expectedBytes: Int64(bytes.count + 1))
        }
        await #expect(throws: OrukeetDownloadFailure.tooLarge) {
            try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha(bytes),
                                                 expectedBytes: Int64(bytes.count - 1))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func sameSizeCorruptInstallIsNeverTrustedAndIsDeleted() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = Data((0..<40_000).map { UInt8($0 % 13) })
        var bad = good
        bad[20_000] ^= 0xFF
        let file = dir.appendingPathComponent(OrukeetModelStore.fileName)
        let cache = try #require(UserDefaults(suiteName: "OrukeetModelDownloadTests.\(UUID().uuidString)"))
        try bad.write(to: file)
        #expect(!OrukeetModelStore.verifyInstalled(at: file, cache: cache, expectedSHA256: sha(good),
                                                   expectedBytes: Int64(good.count)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try good.write(to: file)
        #expect(OrukeetModelStore.verifyInstalled(at: file, cache: cache, expectedSHA256: sha(good),
                                                  expectedBytes: Int64(good.count)))
        // Corrupted in place after a good check: the stat fingerprint changes, so it is re-hashed.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data([0xAB]))
        try handle.close()
        #expect(!OrukeetModelStore.verifyInstalled(at: file, cache: cache, expectedSHA256: sha(good),
                                                   expectedBytes: Int64(good.count)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Build 81: Orukeet and each downloaded model keep their own fast-path entry, so verifying one
    /// never makes the next check of another hash its whole file again.
    @Test func eachModelKeepsItsOwnVerifiedFingerprint() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try #require(UserDefaults(suiteName: "OrukeetModelDownloadTests.\(UUID().uuidString)"))
        let a = Data((0..<30_000).map { UInt8($0 % 7) }), b = Data((0..<20_000).map { UInt8($0 % 11) })
        let fileA = dir.appendingPathComponent("a.gguf"), fileB = dir.appendingPathComponent("b.gguf")
        try a.write(to: fileA)
        try b.write(to: fileB)
        try OrukeetAssets.verifyDownloadedModel(at: fileA, bundle: .main, cache: cache,
                                                expectedSHA256: sha(a), expectedBytes: Int64(a.count))
        let keyA = OrukeetAssets.verifiedKey(sha256: sha(a)), keyB = OrukeetAssets.verifiedKey(sha256: sha(b))
        let verifiedA = try #require(cache.string(forKey: keyA))
        try OrukeetAssets.verifyDownloadedModel(at: fileB, bundle: .main, cache: cache,
                                                expectedSHA256: sha(b), expectedBytes: Int64(b.count))
        // B's check left A's entry alone (one shared slot used to be overwritten here).
        #expect(cache.string(forKey: keyA) == verifiedA)
        #expect(cache.string(forKey: keyB) != nil && keyA != keyB)
        #expect(cache.string(forKey: OrukeetAssets.verifiedModelKey) == nil)
        // A changed file still gets the full hash and is refused.
        try Data(repeating: 1, count: a.count).write(to: fileA)
        #expect(throws: OrukeetFailure.self) {
            try OrukeetAssets.verifyDownloadedModel(at: fileA, bundle: .main, cache: cache,
                                                    expectedSHA256: sha(a), expectedBytes: Int64(a.count))
        }
    }

    /// Build 81: a download that does not fit with the spare gigabyte never starts, and its
    /// earlier partial file (Tokens' own resume point) stays untouched.
    @Test func aDownloadThatDoesNotFitNeverStarts() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0..<60_000).map { UInt8($0 % 239) })
        let source = dir.appendingPathComponent("source.gguf")
        try bytes.write(to: source)
        let destination = dir.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try bytes.prefix(1_000).write(to: partial)
        let tight: ModelDownloadSpace.FreeBytes = { _ in ModelDownloadSpace.spareBytes + 10 }
        await #expect {
            try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha(bytes),
                                                 expectedBytes: Int64(bytes.count), freeBytes: tight)
        } throws: { error in
            guard case OrukeetDownloadFailure.noSpace(let short) = error else { return false }
            return short >= 59_000 - 10
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect((try? Data(contentsOf: partial))?.count == 1_000)
        // With room, the same transfer installs the file.
        try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha(bytes),
                                             expectedBytes: Int64(bytes.count), freeBytes: { _ in 100_000_000_000 })
        #expect(try Data(contentsOf: destination) == bytes)
    }

    /// Transfers running together count each other's bytes, so downloads running together cannot overfill a disk.
    @Test func bookedBytesCountAgainstTheNextDownload() throws {
        let folder = FileManager.default.temporaryDirectory
        let big: Int64 = 2_000_000_000
        let free: ModelDownloadSpace.FreeBytes = { _ in ModelDownloadSpace.spareBytes + big + 100_000_000 }
        #expect(ModelDownloadSpace.shortfall(big, in: folder, freeBytes: free) == nil)
        try ModelDownloadSpace.book(big, in: folder, freeBytes: free)
        #expect(ModelDownloadSpace.shortfall(big, in: folder, freeBytes: free) != nil)
        #expect(throws: OrukeetDownloadFailure.self) { try ModelDownloadSpace.book(big, in: folder, freeBytes: free) }
        ModelDownloadSpace.release(big)
        #expect(ModelDownloadSpace.shortfall(big, in: folder, freeBytes: free) == nil)
        // Unknown free space never blocks a download.
        #expect(ModelDownloadSpace.shortfall(big, in: folder, freeBytes: { _ in nil }) == nil)
    }

    /// Codex RC3 (build 81): a server that answers a resume with the whole file (200, not 206)
    /// restarts the transfer from zero. The restart books the whole file, so a second download that
    /// asks for room after the restart's first bytes land cannot take the space its tail still needs.
    @Test func aRestartedResumeKeepsItsWholeFileBooked() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<100_000).map { UInt8($0 % 241) })
        let destination = dir.appendingPathComponent("model.gguf")
        // A stale 90 KB partial that the server will not resume, so the resume booked only 10 KB.
        try Data(repeating: 0xEE, count: 90_000).write(to: destination.appendingPathExtension("partial"))
        // The volume holds exactly one model beyond the spare gigabyte.
        let volume = PretendVolume(folder: dir, capacity: ModelDownloadSpace.spareBytes + Int64(body.count))
        let server = try LoopbackFileServer(body: body, ignoresRange: true, pauseAfter: 30_000)
        defer { server.stop() }
        let competitor = Locked<(receivedAt: Int64, gotRoom: Bool)?>(nil)
        try await OrukeetModelTransfer.fetch(
            from: server.url, to: destination, expectedSHA256: sha(body), expectedBytes: Int64(body.count),
            freeBytes: volume.freeBytes,
            progress: { received in
                // Past the 10 KB the resume alone booked, a second download asks for exactly the room
                // this restart still has to fill.
                guard received >= 10_000, competitor.value == nil else { return }
                let tail = Int64(body.count) - received
                let gotRoom = (try? ModelDownloadSpace.book(tail, in: dir, freeBytes: volume.freeBytes)) != nil
                if gotRoom { ModelDownloadSpace.release(tail) }
                competitor.value = (received, gotRoom)
                server.sendRest.signal()
            })
        #expect(server.rangeHeader == "bytes=90000-")
        let attempt = try #require(competitor.value)
        #expect(attempt.receivedAt < Int64(body.count))
        #expect(!attempt.gotRoom)
        #expect(try Data(contentsOf: destination) == body)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
        // Every booked byte came back once the file landed.
        #expect(ModelDownloadSpace.shortfall(0, in: dir, freeBytes: { _ in ModelDownloadSpace.spareBytes }) == nil)
    }

    /// Codex RC3 (build 81): when the Mac filled up between the resume request and the server's
    /// whole-file answer, the restart stops as noSpace, naming what to free, instead of writing into
    /// the spare gigabyte; the partial the server would not resume goes too.
    @Test func aRestartThatNoLongerFitsStopsAsNoSpace() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<100_000).map { UInt8($0 % 233) })
        let destination = dir.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try Data(repeating: 0xEE, count: 90_000).write(to: partial)
        let volume = PretendVolume(folder: dir, capacity: ModelDownloadSpace.spareBytes + Int64(body.count))
        let server = try LoopbackFileServer(body: body, ignoresRange: true, holdResponse: true)
        defer { server.stop() }
        let transfer = Task {
            try await OrukeetModelTransfer.fetch(from: server.url, to: destination, expectedSHA256: sha(body),
                                                 expectedBytes: Int64(body.count), freeBytes: volume.freeBytes)
        }
        #expect(await Task.detached { server.requestArrived() }.value)
        // Another app writes 50 KB while the request is in flight.
        volume.shrink(by: 50_000)
        server.sendResponse.signal()
        await #expect {
            try await transfer.value
        } throws: { error in
            guard case OrukeetDownloadFailure.noSpace(let short) = error else { return false }
            return short == 50_000
        }
        #expect(server.rangeHeader == "bytes=90000-")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(ModelDownloadSpace.shortfall(0, in: dir, freeBytes: { _ in ModelDownloadSpace.spareBytes }) == nil)
    }

    /// A server that honors the Range request still resumes (206): the hash covers the bytes already
    /// on disk, and only the missing tail needs room (build 81).
    @Test func anHonoredResumeFinishesInTheRoomItsTailNeeds() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<100_000).map { UInt8($0 % 229) })
        let destination = dir.appendingPathComponent("model.gguf")
        try body.prefix(90_000).write(to: destination.appendingPathExtension("partial"))
        let volume = PretendVolume(folder: dir, capacity: ModelDownloadSpace.spareBytes + Int64(body.count))
        let server = try LoopbackFileServer(body: body, ignoresRange: false)
        defer { server.stop() }
        try await OrukeetModelTransfer.fetch(from: server.url, to: destination, expectedSHA256: sha(body),
                                             expectedBytes: Int64(body.count), freeBytes: volume.freeBytes)
        #expect(server.rangeHeader == "bytes=90000-")
        #expect(try Data(contentsOf: destination) == body)
        #expect(ModelDownloadSpace.shortfall(0, in: dir, freeBytes: { _ in ModelDownloadSpace.spareBytes }) == nil)
    }

    @Test func aResumePathReplacedByASymlinkNeverAppendsToItsTarget() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<100_000).map { UInt8($0 % 229) })
        let destination = dir.appendingPathComponent("model.gguf")
        let partial = destination.appendingPathExtension("partial")
        try body.prefix(90_000).write(to: partial)
        let victim = dir.appendingPathComponent("unrelated.txt")
        let original = Data("fictional unrelated data".utf8)
        try original.write(to: victim)
        let server = try LoopbackFileServer(body: body, ignoresRange: false, holdResponse: true)
        defer { server.stop() }
        let transfer = Task {
            try await OrukeetModelTransfer.fetch(from: server.url, to: destination, expectedSHA256: sha(body),
                                                 expectedBytes: Int64(body.count))
        }
        #expect(await Task.detached { server.requestArrived() }.value)
        try FileManager.default.removeItem(at: partial)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: victim)
        server.sendResponse.signal()
        await #expect(throws: (any Error).self) { try await transfer.value }
        #expect(try Data(contentsOf: victim) == original)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aFullDiskIsNamedAsSuch() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(ModelDownloadSpace.isOutOfSpace(posix))
        #expect(ModelDownloadSpace.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                        userInfo: [NSUnderlyingErrorKey: posix])))
        #expect(ModelDownloadSpace.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(!ModelDownloadSpace.isOutOfSpace(URLError(.networkConnectionLost)))
        #expect(OrukeetDownloadFailure.isNoSpace(OrukeetDownloadFailure.noSpace(short: 5_000_000).localizedDescription))
        #expect(!OrukeetDownloadFailure.isNoSpace(OrukeetDownloadFailure.interrupted("offline").localizedDescription))
        #expect(!OrukeetDownloadFailure.isNoSpace(OrukeetDownloadFailure.checksum.localizedDescription))
    }

    /// Opt-in end-to-end: TOKENS_ORUKEET_STAGE_MODEL=<staged gguf> pulls the real 714 MB weights
    /// through the transfer with the app's pinned length and SHA-256, then the resolver's check.
    @Test func realWeightsPassThePinnedChecks() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOKENS_ORUKEET_STAGE_MODEL"] else { return }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent(OrukeetModelStore.fileName)
        let started = Date()
        try await OrukeetModelTransfer.fetch(from: URL(fileURLWithPath: path), to: destination,
                                             expectedSHA256: OrukeetAssets.modelSHA256,
                                             expectedBytes: OrukeetAssets.modelBytes)
        let cache = try #require(UserDefaults(suiteName: "OrukeetModelDownloadTests.\(UUID().uuidString)"))
        try OrukeetAssets.verifyDownloadedModel(at: destination, bundle: .main, cache: cache)
        print("ORUKEET_E2E transfer+verify \(Date().timeIntervalSince(started)) s")
    }

    @MainActor @Test func previewFixtureNeedsAProofRenderAndParsesItsState() {
        let render = ["Tokens", "--render-preview-frames", "/tmp/x", "--orukeet-preview-download"]
        #expect(OrukeetModelDownload.previewState(arguments: render + ["47"], allowed: true) == .downloading(0.47))
        #expect(OrukeetModelDownload.previewState(arguments: render + ["paused"], allowed: true) == .failed("preview"))
        #expect(OrukeetModelDownload.previewState(arguments: render + ["47"], allowed: false) == nil)
        #expect(OrukeetModelDownload.previewState(arguments: ["Tokens", "--orukeet-preview-download", "47"], allowed: true) == nil)
    }

    /*
    Interleaving: B reads free space while A writes and releases its booking. Free space
    is read under the booking lock, so A's release cannot land between B's two readings; B is refused
    instead of overbooking with a stale free value and a fresh, smaller total.
    */
    @Test func aBookingNeverPairsStaleFreeSpaceWithAFresherTotal() throws {
        let spare = ModelDownloadSpace.spareBytes
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        let a: Int64 = 100
        try ModelDownloadSpace.book(a, in: folder, freeBytes: { _ in spare + a })      // A booked
        let released = DispatchSemaphore(value: 0)
        let free: ModelDownloadSpace.FreeBytes = { _ in
            let before = spare + a                                                   // B's reading
            DispatchQueue.global().async {                                           // A writes, then releases
                ModelDownloadSpace.release(a)
                released.signal()
            }
            _ = released.wait(timeout: .now() + .milliseconds(80))                   // blocked by the lock now
            return before
        }
        #expect(throws: OrukeetDownloadFailure.self) { try ModelDownloadSpace.book(a, in: folder, freeBytes: free) }
        _ = released.wait(timeout: .now() + 2)
        // Nothing left booked by this test either way.
        #expect(ModelDownloadSpace.shortfall(0, in: folder, freeBytes: { _ in spare }) == nil)
    }


    /*
    Build 82 (moved from ModelTransferSlotsTests): it books disk space through ModelDownloadSpace,
    which is process-wide, so it runs in this serialized suite with the other booking tests.
    */
    /// A transfer whose task is cancelled before the request starts answers with an error and leaves
    /// nothing behind (before build 82 it could start a data task on an invalidated session).
    @Test func aTransferCancelledBeforeItStartsAnswers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokens-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let source = folder.appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let destination = folder.appendingPathComponent("models/model.gguf")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha,
                                                 expectedBytes: Int64(bytes.count), freeBytes: { _ in 1 << 40 })
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        // The same transfer, not cancelled, still lands the verified file.
        try await OrukeetModelTransfer.fetch(from: source, to: destination, expectedSHA256: sha,
                                             expectedBytes: Int64(bytes.count), freeBytes: { _ in 1 << 40 })
        #expect(try Data(contentsOf: destination) == bytes)
    }
}

/// One value shared between a test and a transfer's delegate queue.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A pretend volume for the space tests: `capacity` bytes minus the files in `folder`, so writing
/// or deleting the partial changes its free space the way the real disk would.
private final class PretendVolume: @unchecked Sendable {
    private let folder: URL
    private let capacity: Locked<Int64>
    init(folder: URL, capacity: Int64) {
        self.folder = folder
        self.capacity = Locked(capacity)
    }

    /// Another app writing elsewhere on the same volume.
    func shrink(by bytes: Int64) { capacity.value -= bytes }

    var freeBytes: ModelDownloadSpace.FreeBytes {
        { [self] _ in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let used = files.reduce(Int64(0)) { total, file in
                total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return capacity.value - used
        }
    }
}

/*
A one-request HTTP server on 127.0.0.1 for the resume tests (build 81). It records the Range header
it was sent and either ignores it (200 with the whole file, as some servers and proxies do) or
honors it (206). It can hold its answer, or pause after the first `pauseAfter` body bytes, so a
test acts at an exact moment. Every wait is bounded, so a broken transfer fails instead of hanging.
*/
private final class LoopbackFileServer: @unchecked Sendable {
    let url: URL
    private let requestSeen = DispatchSemaphore(value: 0)
    /// Signal to answer, when built with holdResponse.
    let sendResponse = DispatchSemaphore(value: 0)
    /// Signal to send the rest of the body, when built with pauseAfter.
    let sendRest = DispatchSemaphore(value: 0)
    private let listener: Int32
    private let range = Locked<String?>(nil)
    var rangeHeader: String? { range.value }

    init(body: Data, ignoresRange: Bool, holdResponse: Bool = false, pauseAfter: Int? = nil) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, socketAddress, &length) == 0
            }
        }
        guard ready else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        listener = fd
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/model.gguf")!
        Thread { [self] in
            serve(body: body, ignoresRange: ignoresRange, holdResponse: holdResponse, pauseAfter: pauseAfter)
        }.start()
    }

    func stop() { close(listener) }

    /// Blocks until the transfer's request arrived (at most ten seconds); call it off the main actor.
    func requestArrived() -> Bool { requestSeen.wait(timeout: .now() + 10) == .success }

    private func serve(body: Data, ignoresRange: Bool, holdResponse: Bool, pauseAfter: Int?) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // A transfer that stops early closes its end; that must not kill the test process.
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
        }
        let header = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
        range.value = header.map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        requestSeen.signal()
        if holdResponse { _ = sendResponse.wait(timeout: .now() + 10) }
        var start = 0
        var head = "HTTP/1.1 200 OK\r\n"
        if !ignoresRange, let asked = range.value, asked.hasPrefix("bytes="),
           let from = Int(asked.dropFirst("bytes=".count).prefix { $0.isNumber }), from < body.count {
            start = from
            head = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(body.count - 1)/\(body.count)\r\n"
        }
        let payload = body.subdata(in: start..<body.count)
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        guard sendAll(Data(head.utf8), to: client) else { return }
        if let pauseAfter {
            guard sendAll(payload.prefix(pauseAfter), to: client) else { return }
            _ = sendRest.wait(timeout: .now() + 10)
            _ = sendAll(payload.dropFirst(pauseAfter), to: client)
        } else {
            _ = sendAll(payload, to: client)
        }
    }

    private func sendAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }
}
