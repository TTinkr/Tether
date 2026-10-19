


//
/*
ThinkingLane.swift

Owns: Lane identifiers, provider contract, and the display state of one lane.
Never: Persist streamed text or contact a remote model; delivery only receives validated metadata.
See: Sources/Tokens/LocalModel/ThinkingStream.swift and the related responsibility files below.
Related: ThinkingStream.swift
         ThinkingStream+Session.swift
         ThinkingStream+Execution.swift
         ThinkingStream+Content.swift
Port provenance: Sources/System/TokensThinkingStream.swift, donor 2ac14df.
*/


import Combine
import Foundation


// TokensThinkingLane — the two pencil lanes of the Temple panel: questions and reflection


/*
questions: two or three short grounded questions. The optional legacy reflection lane produces a TITLE,
SUMMARY and a few bullet lines. Their prompts live in TokensThinkingStream+Content.
*/


/// The two pencil lanes of the Temple panel.
enum TokensThinkingLane: String, Sendable, CaseIterable { case questions, reflection }


// TokensThinkingProvider — contract for the local models behind the Temple panel


/// Loopback-only local models for the Temple panel. Same rules as
/// OllamaThinkingProvider: no proxy, no redirects, no pulls, no cloud rows.
@MainActor protocol TokensThinkingProvider {
    /// Exact installed local model names, or nil when Ollama is not reachable.
    func installedModels() async -> Set<String>?
    /// Loads a model into memory without generating. Best effort, never throws.
    func warm(model: String) async
    /// Streams `message.content` deltas until a clean finish; throws on anything else.
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]],
                maxTokens: Int, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws
}


// TokensThinkingLaneOutput — what one lane shows right now, and in which state


/// What one lane shows. `text` never goes blank mid-session: a new run keeps
/// the previous text until its first validated delta, and a cancelled or
/// failed run falls back to its complete lines or the previous answer.
struct TokensThinkingLaneOutput: Equatable {
    enum State: Equatable {
        /*
        idle: nothing yet. waiting: asked, no validated text yet. streaming: text arriving. done: finished
        cleanly.
        */
        case idle, waiting, streaming, done
        /// Cancelled by speech or stop; showing its complete lines or the previous answer.
        case kept
        case unavailable(String)
        case failed(String)
    }
    var text         = ""
    var state: State = .idle

//
// :)
//
//
    var model: String
    /// Increments when a new answer replaces the shown one (crossfade key).
    var generation = 0
    /// Word count of the transcript this text was generated from.
    var sourceWords = 0
}

