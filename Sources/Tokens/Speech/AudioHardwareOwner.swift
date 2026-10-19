import AVFoundation
import Foundation

/// Only this queue may create or touch the engine and its nodes. Injected backends
/// let tests stall real lifecycle boundaries without permissions or microphone use.
protocol AudioHardwareBackend: AnyObject {
    func format() throws -> AVAudioFormat
    func start(format: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void,
               current: () -> Bool) throws -> Bool
    func detach(stop: Bool)
    func reset()
}

enum AudioHardwareFailure: Error { case unavailable, cancelled, busy }

final class AudioHardwareOwner {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation: UUID?
    private var busy = false
    private var quiescent = true
    private var stopped = true
    private var detachPending = false
    private var stopPending = false
    private var resetPending = false
    private var completions: [() -> Void] = []
    // Queue-only storage, including its final destruction.
    private final class Storage {
        var backend: AudioHardwareBackend?
        let make: () -> AudioHardwareBackend
        init(make: @escaping () -> AudioHardwareBackend) { self.make = make }
        func get() -> AudioHardwareBackend {
            if let backend { return backend }
            let value = make(); backend = value; return value
        }
    }
    private let storage: Storage

    init(make: @escaping (DispatchQueue) -> AudioHardwareBackend) {
        let queue = DispatchQueue(label: "Tokens.audio-hardware-owner", qos: .userInitiated)
        self.queue = queue
        storage = Storage(make: { make(queue) })
    }

    deinit {
        let storage = storage
        queue.async { storage.backend?.detach(stop: true); storage.backend?.reset(); storage.backend = nil }
    }

    var isQuiescent: Bool { lock.lock(); defer { lock.unlock() }; return quiescent }
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    func isCurrent(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == id
    }

    @discardableResult
    func prepare(generation id: UUID, completion: @escaping (Result<AVAudioFormat, Error>) -> Void) -> Bool {
        lock.lock()
        guard !busy, generation == nil else { lock.unlock(); return false }
        busy = true; generation = id; lock.unlock()
        queue.async { [self] in
            let result = Result { () throws -> AVAudioFormat in
                guard isCurrent(id) else { throw AudioHardwareFailure.cancelled }
                let format = try storage.get().format()
                guard isCurrent(id) else { throw AudioHardwareFailure.cancelled }
                return format
            }
            finishWork()
            DispatchQueue.main.async { [self] in
                guard isCurrent(id) else { return }
                completion(result)
            }
        }
        return true
    }

    @discardableResult
    func start(generation id: UUID, format: AVAudioFormat,
               sink: @escaping (AVAudioPCMBuffer) -> Void,
               completion: @escaping (Result<Bool, Error>) -> Void) -> Bool {
        lock.lock()
        guard !busy, generation == id else { lock.unlock(); return false }
        busy = true; quiescent = false; stopped = false; lock.unlock()
        queue.async { [self] in
            let result = Result { () throws -> Bool in
                guard isCurrent(id) else { throw AudioHardwareFailure.cancelled }
                let started = try storage.get().start(format: format, sink: { [weak self] buffer in
                    guard self?.isCurrent(id) == true else { return }
                    sink(buffer)
                }, current: { self.isCurrent(id) })
                guard isCurrent(id) else { throw AudioHardwareFailure.cancelled }
                return started
            }
            finishWork()
            DispatchQueue.main.async { [self] in
                guard isCurrent(id) else { return }
                completion(result)
            }
        }
        return true
    }

    /// Invalidates admission immediately, but quiescent detach runs on the owner.
    /// Requests coalesce behind a stalled call. No replacement owner or synchronous wait.
    func stop(stopHardware: Bool, reset: Bool = false, completion: (() -> Void)? = nil) {
        lock.lock()
        generation = nil
        if !busy && quiescent && (!stopHardware || stopped) && !reset {
            lock.unlock(); completion?(); return
        }
        detachPending = true; stopPending = stopPending || stopHardware; resetPending = resetPending || reset
        if let completion { completions.append(completion) }
        let schedule = !busy
        busy = true
        lock.unlock()
        if schedule { queue.async { [self] in finishWork() } }
    }

    private func finishWork() {
        var finished: [() -> Void] = []
        while true {
            lock.lock()
            guard detachPending else {
                busy = false; lock.unlock()
                let callbacks = finished
                DispatchQueue.main.async { callbacks.forEach { $0() } }
                return
            }
            let stop = stopPending, reset = resetPending, callbacks = completions
            detachPending = false; stopPending = false; resetPending = false; completions = []
            lock.unlock()
            storage.backend?.detach(stop: stop || reset)
            lock.lock(); quiescent = true; if stop || reset { stopped = true }; lock.unlock()
            if reset { storage.backend?.reset() }
            finished.append(contentsOf: callbacks)
        }
    }
}

/// Constructed lazily by AudioHardwareOwner on its serial queue; never escapes it.
final class EngineAudioHardwareBackend: AudioHardwareBackend {
    private var engine: AVAudioEngine?
    private var input: AVAudioInputNode?
    private var observer: NSObjectProtocol?
    private let router: AudioTapRouter
    private let configurationChanged: () -> Void
    private let ownerQueue: DispatchQueue
    // The observer callback retains its source across an asynchronous hop. Epochs
    // are independent of capture generations, so obsolete engine notices are ignored.
    private let epochLock = NSLock()
    private var epoch = UUID()

    init(router: AudioTapRouter, queue: DispatchQueue, configurationChanged: @escaping () -> Void) {
        self.router = router; self.ownerQueue = queue; self.configurationChanged = configurationChanged
    }
    private func getEngine() -> AVAudioEngine {
        if let engine { return engine }
        let value = AVAudioEngine(); engine = value
        epochLock.lock(); let observedEpoch = epoch; epochLock.unlock()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: value, queue: nil) { [weak self] notification in
                guard let self, let source = notification.object as? AVAudioEngine else { return }
                // Never release an engine inside its internal notification callback.
                self.ownerQueue.async { [weak self, source] in
                    _ = source
                    guard let self else { return }
                    self.epochLock.lock(); let current = self.epoch == observedEpoch; self.epochLock.unlock()
                    if current {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.epochLock.lock(); let current = self.epoch == observedEpoch; self.epochLock.unlock()
                            if current { self.configurationChanged() }
                        }
                    }
                }
            }
        return value
    }
    func format() throws -> AVAudioFormat {
        let node = getEngine().inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioHardwareFailure.unavailable }
        return format
    }
    func start(format: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void,
               current: () -> Bool) throws -> Bool {
        guard current() else { throw AudioHardwareFailure.cancelled }
        let engine = getEngine(), node = engine.inputNode
        let actual = node.outputFormat(forBus: 0)
        guard current() else { throw AudioHardwareFailure.cancelled }
        guard actual.sampleRate == format.sampleRate, actual.channelCount == format.channelCount,
              actual.sampleRate > 0, actual.channelCount > 0 else { throw AudioHardwareFailure.unavailable }
        router.replace(sink)
        guard current() else { router.replace(nil); throw AudioHardwareFailure.cancelled }
        if engine.isRunning { return false }
        if let input { input.removeTap(onBus: 0) }
        input = node
        let router = router
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in router.route(buffer) }
        guard current() else { throw AudioHardwareFailure.cancelled }
        engine.prepare()
        guard current() else { throw AudioHardwareFailure.cancelled }
        try engine.start()
        return true
    }
    func detach(stop: Bool) {
        router.replace(nil)
        guard stop else { return }
        if engine?.isRunning == true { engine?.stop() }
        if let input { input.removeTap(onBus: 0) }
        input = nil
    }
    func reset() {
        epochLock.lock(); epoch = UUID(); epochLock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; input = nil; engine = nil
    }
}
