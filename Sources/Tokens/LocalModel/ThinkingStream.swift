


//
/*
ThinkingStream.swift

Owns: Thinking-lane configuration, observable state, runtime records, and owner lifetime.
Never: Persist streamed text or contact a remote model; delivery only receives validated metadata.
See: Sources/Tokens/LocalModel/ThinkingStream.swift and the related responsibility files below.
Related: ThinkingStream+Session.swift
         ThinkingStream+Execution.swift
         ThinkingStream+Content.swift
Port provenance: Sources/System/TokensThinkingStream.swift, donor 2ac14df.
*/


/*
Shared state remains on one owner. Internal members support its cross-file extensions;
they are not a public API or permission to bypass the owner lifecycle.
*/

import Combine
import Foundation


// TokensThinkingStream — starts, cancels and checks pause questions


/// Ephemeral "pencil" thinking for the Temple panel, plus the sticky
/// presence the bubble and panel share. Not MainActor-isolated because
/// TalkModel is not; like TokenPauseAsides, every synchronous
/// entry point is called on the main thread and async work hops to MainActor.
/// Nothing here is delivered, stored or logged as text, except `title` and
/// `headerNotes(finalTranscript:)`, which only the presented copy may carry.
final class TokensThinkingStream: ObservableObject {
    /*
    How a thinking pause flows through this class:
     1. observe() is called for every analysed audio buffer while a talk runs. ThinkingPresence turns the
        measured silence into one steady "thinking" state, so noise does not make it flicker.
     2. When that state starts, pauseBegan() starts questions. The legacy reflection lane is opt-in.
     3. Each lane streams from Ollama into its own Runtime. Its text is checked line by line against the
        transcript and pushed to the panel at most about 30 times a second.
     4. When the speaker talks again, or the talk ends, both lanes are cancelled. Whatever they had shown
        stays on screen.
    */


    // Setup — tuning numbers, published state, runtime records and init


    struct Tuning: Equatable {
        // The fast questions model is the default. Reflection remains available for older callers and tests.
        var questionsModel    = "qwen3.5:0.8b"
        var reflectionModel   = "qwen3.5:4b"
        var reflectionEnabled = false
        // A lane starts only once the transcript has at least this many words.
        var questionsMinimumWords = 3
        /// Only a completed, usable set closes its source to another five-word cadence.
        /// Interrupted sets can finish on the same words when silence returns.
        var questionsNewWords      = 5
        var reflectionMinimumWords = 20
        /// A new reflection needs this many words beyond the last one's source.
        var reflectionNewWords = 8
        /// Lets the 0.8b reach first tokens before the 4b competes for the GPU.
        var reflectionDelay: TimeInterval           = 0.6
        var reflectionMinimumInterval: TimeInterval = 4
        // Request time limits, in seconds.
        var questionsTimeout: TimeInterval = 6
        /// Includes queueing behind an in-flight live workspace run (<= 4.3 s).
        var reflectionTimeout: TimeInterval = 14
        // Reply length caps in tokens, then how many trailing characters of the transcript each lane is shown.
        var questionsMaxTokens        = 96
        var reflectionMaxTokens       = 200
        var questionsInputCharacters  = 1_200
        var reflectionInputCharacters = 3_600
        // After this many failures in a row a lane is shown as paused. A clean answer resets the count.
        var maximumFailuresPerSession = 3
        // Fastest rate at which a lane's text is pushed to the screen: 30 times a second.
        var publishInterval: TimeInterval = 1.0 / 30
        /// Retry an unreachable Ollama at most this often (only from begin/prewarm).
        var reprobeInterval: TimeInterval = 20
    }

//
// :)
//
//
    /*
    Availability of Ollama: unknown (not probed yet), checking (a probe is running), ready, ollamaOff.
    Summary: the reflection's one-sentence SUMMARY with the model that wrote it and how many words it read.
    */
    enum Availability: Equatable { case unknown, checking, ready, ollamaOff }
    struct Summary: Equatable { let text: String; let model: String; let sourceWords: Int }


    /*
    What the panel and the bubble read. begin() resets the lanes, title and summary; availability and
    installed carry over from talk to talk.
    */
    @Published var isThinking = false
    @Published var questions: TokensThinkingLaneOutput
    @Published var reflection: TokensThinkingLaneOutput
    @Published var availability: Availability = .unknown
    @Published var installed: Set<String>     = []
    /// Newest grounded TITLE from a reflection this session.
    @Published var title: String?
    var titleSourceWords = 0
    var summary: Summary?
    /// Counts-only events for Diagnostics; never text.
    var onEvent: ((String) -> Void)?


    let tuning: Tuning
    /*
    The provider and the clock can be replaced so tests can use a fake model and a fake clock (system uptime
    by default).
    */
    let provider: any TokensThinkingProvider
    let clock: () -> TimeInterval
    /*
    Private bookkeeping.
     - presence: turns measured silence into one steady "thinking" state (ThinkingPresence).
     - sessionOpen: true between begin() and end().
     - soundInterrupted: speech-level sound cut a held pause short; see observe().
     - latestTranscript: the newest transcript observe() saw; the reflection reads it when its timer fires.
     - lastProbe: when Ollama was last probed. reflectionTimer: the armed delayed start of the reflection
       lane.
    */
    var presence                  = ThinkingPresence()
    var sessionOpen               = false
    var soundInterrupted          = false
    var latestTranscript          = ""
    var recentQuestions: [String] = []
    var lastProbe: TimeInterval?
    var reflectionTimer: Task<Void, Never>?


    /*
    Everything one lane needs while it runs. begin() replaces each lane's Runtime with a fresh one.
     - epoch: a new UUID for every request. Every callback carries the epoch it started with and is ignored
       if it no longer matches. This is how late answers from a cancelled or replaced request are dropped.
     - job: the streaming task; nil when the lane is idle.
     - raw: all text received so far. receivedDelta: any text yet (for the first-token timing event). bumped:
       this answer has already advanced the display `generation`.
     - source: the transcript this request was built from. completedSource and completedWords: the last
       request that finished cleanly, so the same words are not asked twice.
     - lastStart: when the last request began. failures: failures in a row. flushScheduled and lastFlush: the
       publish throttle.
     - shown: what was on screen when this request began; the fallback if the request fails before showing
       anything.
    */
    struct Runtime {
        var job: Task<Void, Never>?
        var epoch         = UUID()
        var raw           = ""
        var receivedDelta = false
        var bumped        = false
        var source        = ""
        /// Normalized source and word count of the last run that finished cleanly.
        var completedSource = ""
        var completedWords  = 0
        var askedWords      = 0
        var lastStart: TimeInterval?
        var failures                = 0
        var flushScheduled          = false
        var lastFlush: TimeInterval = -.infinity
        var shown                   = TokensThinkingLaneOutput(model: "")
    }

//
// :)
//
//
    var runtime: [TokensThinkingLane: Runtime] = [.questions: Runtime(), .reflection: Runtime()]


    init(provider: any TokensThinkingProvider = TokensOllamaThinkingProvider(), tuning: Tuning = Tuning(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.provider = provider
        self.tuning   = tuning
        self.clock    = clock
        questions     = TokensThinkingLaneOutput(model: tuning.questionsModel)
        reflection    = TokensThinkingLaneOutput(model: tuning.reflectionModel)
    }


    /// The --temple-preview proof uses the offline canned provider.
    static func makeDefault(arguments: [String]) -> TokensThinkingStream {
        // Canned text only in an offscreen render; a live session always uses the real local models.
        arguments.contains("--temple-preview") && arguments.contains("--render-preview-frames")
            ? TokensThinkingStream(provider: TokensThinkingCannedProvider())
            : TokensThinkingStream()
    }


    deinit { reflectionTimer?.cancel(); runtime.values.forEach { $0.job?.cancel() } }


    /// Legacy coordination with the other 4b workspace, active only when reflection is enabled.
    var holdsReflectionModel: Bool {
        tuning.reflectionEnabled && (reflectionTimer != nil || runtime[.reflection]?.job != nil)
    }


    /// Sticky Thinking counter for the bubble and panel, or nil while speaking.
    func presenceDisplay(at host: TimeInterval) -> ThinkingPresence.Display? { presence.display(at: host) }


    func output(_ lane: TokensThinkingLane) -> TokensThinkingLaneOutput { lane == .questions ? questions : reflection }


}

