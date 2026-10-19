


//
/*
QualityAuditRecord.swift

Owns: Optional private audit record data and the nonblocking audit sink contract.
Never: Delay delivery, collect telemetry, or contact anything beyond loopback Ollama.
See: Sources/Tokens/LocalModel/TokenPauseAsides.swift and the related responsibility files below.
Related: TokenPauseAsides.swift
         TokenPauseAsides+Requests.swift
         TokenPauseAsides+Content.swift
Port provenance: Sources/System/TTTTinkering.swift, donor 2ac14df.
*/


import Combine
import Foundation


// QualityAuditRecord — private local record of one finished model run and what it was given


/// One terminated Thoughts-from-Tokens generation, paired with the transcript
/// snapshot it was given. Goes only to the private local audit sink; never to
/// diagnostics, analytics, delivery or back into a prompt.
struct QualityAuditRecord: Codable, Equatable {
    /*
    How the run ended: completed; cancelled (superseded, stopped or reset); deadline (timed out); discarded
    (failed or unusable).
    */
    enum Status: String, Codable { case completed, cancelled, deadline, discarded }
    // live: started during the talk. final: started after it ended (prepareFinal).
    enum Kind: String, Codable { case live, final }


    // id: this run. sessionID: the talk. generation: the run number within the talk.
    var id: UUID
    var sessionID: UUID
    var generation: Int
    var kind: Kind
    var status: Status
    var reason: String
    var model: String
    var promptVersion: String
    var startedAt: Date
    var durationSeconds: Double
    var budgetSeconds: Double
    var maxTokens: Int
    /// Snapshot only. The stored raw transcript elsewhere remains authoritative.
    var sourceTranscript: String
    var output: String
}


// QualityAuditing — where audit records are sent (must return at once)


protocol QualityAuditing: AnyObject {
    /// Must return at once; callers are on the main thread.
    func record(_ record: QualityAuditRecord)
}

