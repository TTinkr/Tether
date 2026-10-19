


//
/*
TokenPauseAsides.swift

Owns: Observable aside state, request bookkeeping, provider lifetime, and audit emission.
Never: Delay delivery, collect telemetry, or contact anything beyond loopback Ollama.
See: Sources/Tokens/LocalModel/TokenPauseAsides.swift and the related responsibility files below.
Related: TokenPauseAsides+Requests.swift
         TokenPauseAsides+Content.swift
Port provenance: Sources/System/TTTTinkering.swift, donor 2ac14df.
*/


/*
Shared state remains on one owner. Internal members support its cross-file extensions;
they are not a public API or permission to bypass the owner lifecycle.
*/

import Combine
import Foundation


// TokenPauseAsides — runs the live table and final summary under deadlines; delivery never waits


/// Like Tinkering, synchronous entry points are called on the app main thread.
/// Async work and published-state callbacks are explicitly MainActor isolated.
final class TokenPauseAsides: ObservableObject {
    /*
    Two jobs share this class, both through launch():
     - the LIVE table: while a talk runs, observe() asks the model about the last 900 characters of the
       transcript, at most once every 5 s. The streamed lines appear in currentText.
     - the FINAL summary: after the talk, prepareFinal() asks once more with up to the last 6,000 characters.
       Whatever completed last is what stop() returns for delivery.
    launch() allows one request at a time and gives every request a deadline of 4.3 s at most.
    */


    // State the UI reads — asides, workspace snapshots and the Ollama status line


    struct Aside: Equatable {
        let text: String
        let model: String
    }
    /*
    currentText is what the live panel shows now (the streaming table, or the last completed text).
    lastCompletedDisplay is the text of the last completed run; fail() puts it back so a failed run does not
    leave the panel blank.
    */
    @Published var currentText = ""
    var lastCompletedDisplay   = ""
    /*
    The table text plus the transcript it was made from. The newest three are kept (recentWorkspaceResponses)
    so the panel can compare the current table with earlier ones.
    */
    struct WorkspaceSnapshot: Equatable {
        let text: String
        let source: String
    }
    @Published var workspaceSource = ""
    @Published var recentWorkspaceResponses: [WorkspaceSnapshot] = []
    @Published var modelLabel = ""
    /*
    unknown: not probed yet. notRunning: no answer from Ollama. noModel: Ollama is up but the exact model is
    missing. ready: the model is there.
    */
    enum OllamaPresence: Equatable {
        case unknown, notRunning, noModel(String), ready(String)
        var model: String? {
            if case .ready(let model) = self { return model }
            return nil
        }
    }

//
// :)
//
//
    /// Set by the first probe; never reset between sessions.
    @Published var ollamaPresence: OllamaPresence = .unknown
    var ollamaStatusLine: String {
        switch ollamaPresence {
        case .unknown:            return "Ollama · checking"
        case .notRunning:         return "Ollama not running · talking works without it"
        case .noModel(let model): return "Ollama running · model \(model) not installed · run: ollama pull \(model)"
        case .ready(let model):   return "Ollama · \(model) ready"
        }
    }
    /// Panel caption: what is actually reachable, not what the last session happened to load.
    var modelDisplayName: String {
        switch ollamaPresence {
        case .ready(let model):   return modelLabel.isEmpty ? model : modelLabel
        case .noModel(let model): return "\(model) not pulled"
        case .notRunning:         return "Ollama off"
        case .unknown:            return modelLabel.isEmpty ? "Ollama" : modelLabel
        }
    }
    /// Settings probe: the same 2 s loopback /api/tags check as a session, never a pull.
    func refreshOllamaPresence() {
        let provider = self.provider
        Task { @MainActor [weak self] in
            let presence = await provider.resolvePresence()
            self?.ollamaPresence = presence
        }
    }
    @Published var completed: [Aside] = []
    @Published var status             = "No completed reflection"


    // Bookkeeping — private state, init, and the audit record emitter


    /*
    Private state, in order:
     - provider and finalProvider: the live-table model and the final-summary model. deadline: time limit for
       a live run.
     - active: live requests are allowed (from begin() until prepareFinal(), stop() or reset()). sessionOpen:
       a talk is open. finalRequested: prepareFinal() has already run.
     - lastAttempt: when the last live request started (5 s spacing). epoch: identity of the current request;
       a new value makes every older callback a no-op.
     - job and timer: the request task and its deadline timer.
     - audit, auditSession, generationCount: the private audit sink, the talk's id and a run counter.
    */
    let provider: any TokenPauseProvider
    let finalProvider: any TokenPauseProvider
    let deadline: TimeInterval
    let clock: () -> TimeInterval
    var active         = false
    var sessionOpen    = false
    var finalRequested = false
    var lastAttempt: TimeInterval?
    var epoch = UUID()
    var job: Task<Void, Never>?
    var timer: Task<Void, Never>?
    private let audit: (any QualityAuditing)?
    var auditSession    = UUID()
    var generationCount = 0
    /*
    Everything the audit record needs about the run in progress. model, maxTokens and output are filled in as
    the run goes.
    */
    struct Inflight {
        let id = UUID()
        let generation: Int
        let kind: QualityAuditRecord.Kind
        let source: String
        let startedAt     = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let budget: TimeInterval
        var maxTokens: Int
        let promptVersion: String
        var model  = ""
        var output = ""
    }

//
// :)
//
//
    /// At most one: set by launch, cleared by exactly one termination record.
    var inflight: Inflight?


    init(provider: (any TokenPauseProvider)? = nil, deadline: TimeInterval = 4.3,
         finalProvider: (any TokenPauseProvider)? = nil,
         audit: (any QualityAuditing)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        /*
        By default the live provider is in table mode and the final provider in summary mode. The live
        deadline is held between 0.01 s and 4.3 s.
        */
        self.provider      = provider ?? OllamaTokenPauseProvider(structuredWorkspace: true)
        self.finalProvider = finalProvider ?? OllamaTokenPauseProvider(model: "qwen3.5:4b")
        self.deadline      = min(4.3, max(0.01, deadline))
        self.audit         = audit
        self.clock         = clock
    }
    // Cancels all work and files an audit record as cancelled ("released"), so no run goes unrecorded.
    deinit { job?.cancel(); timer?.cancel(); terminate(.cancelled, "released") }


    /// The only place a private audit record is emitted; never logged elsewhere.
    func terminate(_ status: QualityAuditRecord.Status, _ reason: String) {
        /*
        Clearing `inflight` before the record is emitted is what makes it one record per run: a second call
        finds nothing to record.
        */
        guard let run = inflight else { return }
        inflight = nil
        audit?.record(QualityAuditRecord(
            id: run.id, sessionID: auditSession, generation: run.generation, kind: run.kind,
            status: status, reason: reason, model: run.model, promptVersion: run.promptVersion,
            startedAt: run.startedAt, durationSeconds: ProcessInfo.processInfo.systemUptime - run.startedUptime,
            budgetSeconds: run.budget, maxTokens: run.maxTokens,
            sourceTranscript: run.source, output: run.output))
    }


}

