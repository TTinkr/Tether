
import AppKit

/*
Dev-only talk-key edges for live QA (build 81). A second launch of the Dev binary sends one edge
to one running Dev copy, addressed by its PID, and waits for that copy's acknowledgement.

What it is: the edge enters GlobalKeyMonitor.injectQAEdge, which runs the same Return gate,
front-app/window stamp, input generation and onPress/onRelease dispatch as a physical edge.
What it is not: proof of the physical key (no hardware event, ShortcutHold is not consulted),
and it binds the edge to the moment the request arrives, not to a finger.

Boundaries: one request at a time; a release or stopping tap only
acts on a talk a QA edge started; an edge never changes a talk the physical key is holding.
*/
enum QATalkTrigger {
    static let name    = Notification.Name("com.tinkr.tokens.qa.talk")
    static let ackName = Notification.Name("com.tinkr.tokens.qa.talk.ack")

    enum Edge: String, CaseIterable { case press, release, tap }

    /// Only a Dev-channel build that keeps its proof routes listens or posts.
    static func allowed(devChannel: Bool, proofRoutes: Bool) -> Bool { devChannel && proofRoutes }
    static var isAvailable: Bool { allowed(devChannel: DevChannel.isActive, proofRoutes: ProofRoutes.isAllowed) }

    /// Exit codes for the posting launch.
    enum Exit: Int32, Error { case accepted = 0, usage = 64, rejected = 65, noReceiver = 69, noAck = 75 }

    /// Which running copy gets the edge: the one asked for, or the only one running.
    static func target(requested: Int32?, running: [Int32]) -> Result<Int32, Exit> {
        if let requested { return running.contains(requested) ? .success(requested) : .failure(.noReceiver) }
        if running.count == 1 { return .success(running[0]) }
        return .failure(running.isEmpty ? .noReceiver : .usage)
    }

    // MARK: Posting launch

    /// `--qa-talk <edge> [--qa-pid <pid>]`: send, wait up to 3 s for the receipt, print it as JSON.
    static func post(_ argument: String, pid requested: Int32?) -> Int32 {
        func fail(_ code: Exit, _ message: String) -> Int32 {
            FileHandle.standardError.write(Data((message + "\n").utf8)); return code.rawValue
        }
        guard isAvailable else { return fail(.usage, "--qa-talk is only in Dev builds") }
        guard let edge = Edge(rawValue: argument.lowercased()), let bundle = Bundle.main.bundleIdentifier else {
            return fail(.usage, "usage: Tokens --qa-talk press|release|tap [--qa-pid <pid>]")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .filter { !$0.isTerminated && $0.processIdentifier != me }.map(\.processIdentifier)
        let target: Int32
        switch Self.target(requested: requested, running: running) {
        case .success(let pid): target = pid
        case .failure(let code):
            return fail(code, code == .usage ? "several Tokens Dev copies running (\(running)); pass --qa-pid"
                                             : "no running Tokens Dev\(requested.map { " with pid \($0)" } ?? "")")
        }
        let request = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        var receipt: [String: String]?
        let token = center.addObserver(forName: ackName, object: bundle, queue: nil) { note in
            guard let info = note.userInfo as? [String: String], info["request"] == request else { return }
            receipt = info
        }
        center.postNotificationName(name, object: bundle, userInfo: [
            "edge": edge.rawValue, "target_pid": String(target), "request": request,
        ], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        while receipt == nil, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        center.removeObserver(token)
        let printed = receipt ?? ["request": request, "pid": String(target), "edge": edge.rawValue, "result": "no_ack"]
        if let json = try? JSONSerialization.data(withJSONObject: printed, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(json + Data("\n".utf8))
        }
        guard let receipt else { return Exit.noAck.rawValue }
        return receipt["result"] == "accepted" ? Exit.accepted.rawValue : Exit.rejected.rawValue
    }

    // MARK: Running copy

    /// The running copy's side: requests addressed to this PID go to `handle`, which replies once.
    static func listen(_ handle: @escaping (Edge, @escaping ([String: String]) -> Void) -> Void) -> NSObjectProtocol? {
        guard isAvailable, let bundle = Bundle.main.bundleIdentifier else { return nil }
        let me = String(ProcessInfo.processInfo.processIdentifier)
        return DistributedNotificationCenter.default().addObserver(forName: name, object: bundle, queue: .main) { note in
            guard let info = note.userInfo as? [String: String], info["target_pid"] == me,
                  let request = info["request"], let raw = info["edge"] else { return }
            guard let edge = Edge(rawValue: raw) else {
                reply(bundle, ["request": request, "pid": me, "edge": raw, "result": "rejected:unknown_edge"]); return
            }
            handle(edge) { fields in
                var receipt = fields
                receipt["request"] = request; receipt["pid"] = me; receipt["edge"] = edge.rawValue
                // The commit the package was built from (DevChannel's promote key is empty in Dev packages).
                receipt["source"] = String((Bundle.main.object(forInfoDictionaryKey: "TokensSourceCommit") as? String ?? "").prefix(7))
                Diagnostics.event("qa_talk_edge " + receipt.filter { $0.key != "request" }.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                reply(bundle, receipt)
            }
        }
    }

    private static func reply(_ bundle: String, _ receipt: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(ackName, object: bundle, userInfo: receipt,
                                                                     deliverImmediately: true)
    }
}

/// The running copy's QA state: whether a QA press is down, and which talk QA started.
struct QATalkState {
    var pressed = false
    var session: UUID?
    var busy = false
}

extension TalkModel {
    /// Applies one QA request through the key monitor, then replies with the talk's state.
    func handleQATalk(_ edge: QATalkTrigger.Edge, reply: @escaping ([String: String]) -> Void) {
        let before = "\(phase)"
        func done(_ result: String) {
            // After the main-thread press/release callbacks the edge dispatched have run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if self.phase == .idle { self.qaTalk.session = nil }
                reply(["result": result, "phase_before": before, "phase_after": "\(self.phase)",
                       "session": self.sessionID?.uuidString ?? "-",
                       "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"])
            }
        }
        guard !qaTalk.busy else { return done("rejected:busy") }
        // A talk QA did not start is never stopped by QA (a physical key talk, or the menu).
        let capturing = phase == .capturing || phase == .finalizing
        let ownsTalk = capturing && sessionID != nil && sessionID == qaTalk.session
        switch edge {
        case .press:
            guard !qaTalk.pressed else { return done("rejected:already_pressed") }
            guard !capturing || ownsTalk else { return done("rejected:not_qa_talk") }
            guard input.injectQAEdge(down: true) else { return done("rejected:key_down") }
            qaTalk.pressed = true
            afterEdge { self.rememberQATalk() }
            done("accepted")
        case .release:
            guard qaTalk.pressed else { return done("rejected:orphan_release") }
            guard input.injectQAEdge(down: false) else { qaTalk.pressed = false; return done("rejected:key_up") }
            qaTalk.pressed = false
            afterEdge { self.rememberQATalk() }
            done("accepted")
        case .tap:
            guard !qaTalk.pressed else { return done("rejected:already_pressed") }
            guard !capturing || ownsTalk else { return done("rejected:not_qa_talk") }
            guard input.injectQAEdge(down: true) else { return done("rejected:key_down") }
            qaTalk.busy = true
            let sessionAtPress = sessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                defer { self.qaTalk.busy = false }
                // The release belongs to this tap only if no other edge changed the talk meanwhile.
                guard self.input.injectQAEdge(down: false) else { return }
                self.rememberQATalk(startedFrom: sessionAtPress)
            }
            done("accepted")
        }
    }

    /// Runs after the main-thread callback the injected edge queued.
    private func afterEdge(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    /// A talk that began on a QA edge is QA's to stop.
    private func rememberQATalk(startedFrom previous: UUID? = nil) {
        if phase == .capturing, let sessionID, sessionID != previous || qaTalk.session == sessionID {
            qaTalk.session = sessionID
        } else if phase == .idle {
            qaTalk.session = nil
        }
    }
}
