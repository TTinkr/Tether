import Foundation
import Darwin
import TokensCore

struct OrukeetWord: Decodable, Sendable {
    let text: String
    let startMS: Double
    let endMS: Double
    enum CodingKeys: String, CodingKey { case text; case startMS = "start_ms"; case endMS = "end_ms" }
}
struct OrukeetDecodedAudio: Sendable {
    let text: String
    let words: [OrukeetWord]
}
protocol OrukeetDecoding: AnyObject, Sendable {
    func decode(_ samples: [Float], completion: @escaping (Result<OrukeetDecodedAudio, Error>) -> Void)
    func shutdown()
    /// False once the worker process has exited or been stopped; the pool never leases it then.
    var isAlive: Bool { get }
    /// Called once if the process exits without shutdown() (crash, kill, OOM).
    func onUnexpectedExit(_ handler: @escaping @Sendable () -> Void)
}
extension OrukeetDecoding {
    var isAlive: Bool { true }
    func onUnexpectedExit(_ handler: @escaping @Sendable () -> Void) {}
}

/// Serial binary request/JSON response transport. POSIX nonblocking pipes are used
/// only on the worker queue. stderr is drained and discarded, never transcript-logged.
final class OrukeetWorker: OrukeetDecoding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tokens.orukeet.worker", qos: .userInitiated)
    private let process = Process()
    private let input = Pipe(), output = Pipe(), diagnostic = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var exitHandler: (@Sendable () -> Void)?
    private var nextID: UInt64 = 0
    private var readBuffer = Data()
    private let maximumLineBytes = 2 * 1024 * 1024
    private var stopRequested: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private init(assets: OrukeetAssets) {
        process.executableURL = assets.workerURL
        process.arguments = ["--model", assets.modelURL.path, "--gpu", "0"]
        var environment = ProcessInfo.processInfo.environment
        environment["GGML_BACKEND_DL_PATH"] = assets.libraryURL.path
        environment["OMP_NUM_THREADS"] = "2"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
        process.terminationHandler = { [weak self] _ in self?.processExited() }
    }
    var isAlive: Bool { !stopRequested && process.isRunning }
    func onUnexpectedExit(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); exitHandler = handler; lock.unlock()
    }
    private func processExited() {
        lock.lock(); let expected = stopped; stopped = true
        let handler = expected ? nil : exitHandler; exitHandler = nil; lock.unlock()
        handler?()
    }
    static func start(assets: OrukeetAssets) async throws -> OrukeetWorker {
        let worker = OrukeetWorker(assets: assets)
        return try await withCheckedThrowingContinuation { continuation in
            worker.queue.async {
                do {
                    try worker.process.run()
                    try worker.input.fileHandleForReading.close()
                    try worker.output.fileHandleForWriting.close()
                    try worker.diagnostic.fileHandleForWriting.close()
                    for fd in [worker.input.fileHandleForWriting.fileDescriptor, worker.output.fileHandleForReading.fileDescriptor,
                               worker.diagnostic.fileHandleForReading.fileDescriptor] {
                        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw OrukeetFailure.protocolFailure }
                    }
                    let ready = try worker.readObject(deadline: ProcessInfo.processInfo.systemUptime + 25, startup: true)
                    guard ready["type"] as? String == "ready", ready["protocol"] as? String == "ORK1",
                          ready["mode"] as? String == "offline_retained", ready["sample_format"] as? String == "mono_f32le",
                          ready["max_seconds"] as? Int == 30, ready["backend_requested"] as? String == "metal" else {
                        throw OrukeetFailure.protocolFailure
                    }
                    continuation.resume(returning: worker)
                } catch { worker.stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    static func frame(samples: [Float], requestID: UInt64) throws -> Data {
        guard requestID > 0, !samples.isEmpty, samples.count <= 480_000, samples.allSatisfy(\.isFinite) else {
            throw OrukeetFailure.invalidAudio
        }
        var frame = Data("ORK1".utf8)
        func append<T>(_ value: T) { var value = value; withUnsafeBytes(of: &value) { frame.append(contentsOf: $0) } }
        append(requestID.littleEndian); append(UInt32(16000).littleEndian); append(UInt32(samples.count).littleEndian)
        for sample in samples { append(sample.bitPattern.littleEndian) }
        return frame
    }
    static func result(_ object: [String: Any], requestID: UInt64, samples: Int) throws -> OrukeetDecodedAudio {
        guard object["type"] as? String == "result", object["request_id"] as? String == String(requestID),
              object["sample_rate"] as? Int == 16000, object["sample_count"] as? Int == samples,
              object["mode"] as? String == "offline", object["is_final"] as? Bool == true,
              let text = object["text"] as? String, text.utf8.count <= 1_048_576,
              let rawWords = object["words"] as? [[String: Any]], rawWords.count <= 32_768 else { throw OrukeetFailure.protocolFailure }
        let words = try JSONDecoder().decode([OrukeetWord].self, from: JSONSerialization.data(withJSONObject: rawWords))
        return OrukeetDecodedAudio(text: text, words: words)
    }
    func decode(_ samples: [Float], completion: @escaping (Result<OrukeetDecodedAudio, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard !stopRequested, nextID < UInt64.max else { throw OrukeetFailure.canceled }
                nextID += 1
                let frame = try Self.frame(samples: samples, requestID: nextID)
                let deadline = ProcessInfo.processInfo.systemUptime + 25
                try write(frame, deadline: deadline)
                let object = try readObject(deadline: deadline, startup: false)
                guard !stopRequested else { throw OrukeetFailure.canceled }
                completion(.success(try Self.result(object, requestID: nextID, samples: samples.count)))
            } catch { stopOnQueue(); completion(.failure(error)) }
        }
    }
    func shutdown() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in stopOnQueue() }
    }
    private func check(_ deadline: TimeInterval, startup: Bool = false) throws {
        guard !stopRequested else { throw OrukeetFailure.canceled }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw startup ? OrukeetFailure.startupTimeout : OrukeetFailure.requestTimeout
        }
        guard process.isRunning else { throw OrukeetFailure.workerExited }
        drainDiagnostics()
    }
    private func drainDiagnostics() {
        var scratch = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = Darwin.read(diagnostic.fileHandleForReading.fileDescriptor, &scratch, scratch.count)
            if count <= 0 { break }
        }
    }
    private func pause(_ fd: Int32, events: Int16) { var item = pollfd(fd: fd, events: events, revents: 0); _ = poll(&item, 1, 20) }
    private func write(_ data: Data, deadline: TimeInterval) throws {
        let fd = input.fileHandleForWriting.fileDescriptor
        // Suppress SIGPIPE for this owned pipe only. EPIPE becomes an explicit failure.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try check(deadline)
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EAGAIN || errno == EINTR) { pause(fd, events: Int16(POLLOUT)) }
                else { throw OrukeetFailure.workerExited }
            }
        }
    }
    private func readObject(deadline: TimeInterval, startup: Bool) throws -> [String: Any] {
        let fd = output.fileHandleForReading.fileDescriptor
        while true {
            try check(deadline, startup: startup)
            if let end = readBuffer.firstIndex(of: 10) {
                let line = readBuffer.prefix(upTo: end); readBuffer.removeSubrange(...end)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw OrukeetFailure.protocolFailure }
                if object["type"] as? String == "error" { throw OrukeetFailure.workerExited }
                return object
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                readBuffer.append(contentsOf: chunk.prefix(count))
                guard readBuffer.count <= maximumLineBytes else { throw OrukeetFailure.protocolFailure }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) { pause(fd, events: Int16(POLLIN)) }
            else { throw OrukeetFailure.workerExited }
        }
    }
    private func stopOnQueue() {
        lock.lock(); stopped = true; lock.unlock()
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        try? output.fileHandleForReading.close(); try? diagnostic.fileHandleForReading.close()
        readBuffer.removeAll(keepingCapacity: false)
    }
}

/// One warm recognizer per app, leased to only one talk. Each request is a separate
/// offline decode (the worker keeps no PCM between requests), so a lease returns
/// warm after success or cancellation once no decode is in flight. Only a worker
/// fault (protocol, timeout, exit) quarantines it, followed by a bounded background
/// re-prewarm so the next talk does not pay the cold load.
actor OrukeetWorkerPool {
    static let shared = OrukeetWorkerPool(
        start: { try await OrukeetWorker.start(assets: OrukeetAssets.resolveSelected()) },
        rewarmAllowed: { SpeechEngineChoice.load() == .orukeet },
        identity: { SpeechEngineChoice.selectedModelID() })
    private let start: @Sendable () async throws -> OrukeetDecoding
    private let rewarmAllowed: @Sendable () -> Bool
    /// Build 79: which model the warm worker holds; a different chosen model replaces it.
    private let identity: @Sendable () -> String
    private var workerIdentity = ""
    private var worker: OrukeetDecoding?
    private var loading: Task<OrukeetDecoding, Error>?
    private var leased = false
    private var acquiring = 0 // Pending acquires keep a shared load from being unloaded.
    private var loadGeneration = UUID()
    // Consecutive quarantines without a healthy release; bounds a crash/reload loop.
    private var rewarms = 0
    private let maximumRewarms = 3
    /// The injected starter permits pool lifecycle tests without models.
    init(start: @escaping @Sendable () async throws -> OrukeetDecoding,
         rewarmAllowed: @escaping @Sendable () -> Bool = { true },
         identity: @escaping @Sendable () -> String = { "" }) {
        self.start = start; self.rewarmAllowed = rewarmAllowed; self.identity = identity
    }
    private func ready() async throws -> OrukeetDecoding {
        let wanted = identity()
        // A different chosen model: an idle warm worker (or a load) for the old one is dropped.
        if wanted != workerIdentity, !leased {
            worker?.shutdown(); worker = nil
            if loading != nil { loadGeneration = UUID(); loading?.cancel(); loading = nil }
        }
        if let worker {
            if worker.isAlive { return worker }
            // Died while idle and its exit notice has not arrived yet: reload now
            // instead of failing this talk at its first decode.
            worker.shutdown(); self.worker = nil
        }
        let task: Task<OrukeetDecoding, Error>
        let token: UUID
        if let loading { task = loading; token = loadGeneration }
        else {
            token = UUID(); loadGeneration = token; workerIdentity = wanted
            let start = self.start
            task = Task.detached { try await start() }
            loading = task
        }
        do {
            let value = try await task.value
            guard token == loadGeneration else { value.shutdown(); throw OrukeetFailure.canceled }
            // Multiple prewarm/acquire waiters may share this task, but an obsolete
            // waiter must never resurrect a worker canceled by a completed lease.
            if worker == nil {
                worker = value
                let id = ObjectIdentifier(value)
                value.onUnexpectedExit { [weak self] in Task { await self?.exited(id) } }
            }
            loading = nil
            return value
        } catch {
            if token == loadGeneration { loading = nil }
            throw error
        }
    }
    func acquire() async throws -> OrukeetDecoding {
        acquiring += 1; defer { acquiring -= 1 }
        // The lease is taken only once the model is ready. A talk canceled during a
        // cold load therefore never blocks the next key press for the whole load:
        // both share one load, and the canceled one hands the worker straight back.
        for _ in 0..<3 {
            // A just-finished or canceled talk releases asynchronously (queue, Task, actor),
            // so a fast next key press briefly waits for that release instead of failing.
            let deadline = ContinuousClock.now + .seconds(1)
            while leased && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            guard !leased else { throw OrukeetFailure.busy }
            let value = try await ready()
            if !leased, worker === value { leased = true; return value }
        }
        throw OrukeetFailure.busy
    }
    func prewarm() async throws {
        /*
        A talk waiting on a cold load keeps that load (build 81). A model picked meanwhile (a row's
        Download finishing mid-talk, or a pick right after a talk was let go) used to replace it,
        so the talk failed with "canceled" and lost what was said while the model loaded. The talk
        uses the model it started with; release swaps in the new pick once it hands the worker back.
        */
        guard !leased, acquiring == 0 else { return }
        _ = try await ready()
    }
    /// reusable=false only for worker faults; callers return a canceled lease warm.
    func release(_ value: OrukeetDecoding, reusable: Bool) {
        guard worker === value else { return }
        leased = false
        if reusable {
            rewarms = 0
            // A model picked while this talk held the worker: warm it now, so the next talk is warm.
            if identity() != workerIdentity, rewarmAllowed() { Task { try? await self.prewarm() } }
            return
        }
        value.shutdown(); worker = nil; loading = nil; loadGeneration = UUID()
        scheduleRewarm()
    }
    /// An idle worker that exits is cleared and reloaded in the background. A leased
    /// one is left to its talk, whose next decode reports the fault and releases it.
    private func exited(_ id: ObjectIdentifier) {
        guard let worker, ObjectIdentifier(worker) == id, !leased else { return }
        self.worker = nil
        scheduleRewarm()
    }
    private func scheduleRewarm() {
        guard rewarms < maximumRewarms, rewarmAllowed() else { return }
        rewarms += 1
        Task { try? await self.prewarm() }
    }
    /// Selection changes and app shutdown can release an idle model. An active
    /// recording retains its lease; callers may try again after it finishes.
    func unloadIfIdle() {
        guard !leased, acquiring == 0 else { return }
        loadGeneration = UUID(); loading?.cancel(); loading = nil
        worker?.shutdown(); worker = nil
    }
    /// Test/diagnostic view of the warm state; never used to authorize a lease.
    var isWarm: Bool { worker != nil }
}
