


//
import AppKit
import Combine
import SwiftUI


// TokensThinkingTemple — Joins the thinking stream to the π thinking panel


/// Joins the thinking stream to the π thinking panel. The dictation model only calls
/// begin / observe / end; nothing here writes to the transcript, history or clipboard.
/// Like TokenPauseAsides, every entry point is called on the main thread.
final class TokensThinkingTemple {


    // Session entry points


    // Launch scope (October 5): only the tiny talk bubble, no typing/questions panel.
    // Keep old notes/preferences intact; the release gate overrides even a saved true.
    static let launchPanelAvailable = false

    // Retained preference for historical compatibility, not launch authorization.
    static let enabledKey = "TokensThinkingPanelEnabled.v1"

    /*
    stream: the source of questions and thinking state. panelState and
    controller are made the first time a talk begins. subscriptions and ticker are the Combine
    connections from the stream (and the 0.25 s counter) into the panel. shownThisSession makes the
    panel come up once per talk; sessionLive is true between begin() and end(); renderingPreview
    (launched with --render-preview-frames) keeps the panel from ever being shown.
    */
    let stream: TokensThinkingStream
    private(set) var panelState: ThinkingPanelState?
    private var controller: ThinkingPanelController?
    private var subscriptions = Set<AnyCancellable>()
    private var ticker: AnyCancellable?
    private var shownThisSession = false
    private var sessionLive      = false
    private let renderingPreview: Bool

    // Builds the stream from the launch arguments and forwards every event it reports to Diagnostics.
    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        stream           = TokensThinkingStream.makeDefault(arguments: arguments)
        renderingPreview = arguments.contains("--render-preview-frames")
        stream.onEvent   = { Diagnostics.event($0) }
    }

    /// The launch gate wins over saved settings. AudioCapture independently drives the tiny bubble.
    var panelEnabled: Bool { Self.launchPanelAvailable && (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true) }

    /// A dictation started: clear the last session's text and warm the local models.
    func begin() {
        guard Self.launchPanelAvailable else { return }
        sessionLive = true
        stream.begin()
        /*
        All entry points are called on the main thread (see the type's comment), so main-actor work is
        done in place.
        */
        MainActor.assumeIsolated {
            let state = ensurePanel()
            state.beginSession()
            controller?.beginSession()
            state.isThinking = false; state.elapsed = 0
            state.status     = Self.status(for: stream)
            shownThisSession = false
        }
    }

    /*
    Pass-through of one measurement per analysed audio buffer: the open pause length (and whether it
    is an estimate), the level in dB, the words so far, and the current host uptime.
    */
    /// One call per analysed buffer while capturing.
    func observe(pauseSeconds: Double?, estimated: Bool, rmsDB: Double, transcript: String) {
        guard Self.launchPanelAvailable else { return }
        stream.observe(pauseSeconds: pauseSeconds, estimated: estimated, rmsDB: rmsDB, transcript: transcript,
                       host: ProcessInfo.processInfo.systemUptime)
    }

    /// The dictation finished, was discarded or failed. Idempotent. The panel is left where it is
    /// with what it last wrote: it appears once and then keeps still until the user closes it.
    func end() {
        stream.end()
        ticker      = nil
        sessionLive = false
        MainActor.assumeIsolated {
            guard let panelState else { return }
            panelState.cancelSpacing()
            panelState.isThinking = false
            panelState.elapsed    = 0
            // Nothing is listening any more, and the panel must not say otherwise.
            panelState.status = panelState.question.isEmpty ? "" : "From your last talk"
        }
    }

//
// :)
//
//
    /// Main-thread delivery reads typed notes separately from recognized words.
    var notesForDelivery: String {
        guard Self.launchPanelAvailable else { return "" }
        return MainActor.assumeIsolated { panelState?.notes ?? "" }
    }

    /// Called after the delivery latch succeeds: take the exact notes once.
    func consumeNotesForDelivery() -> String {
        guard Self.launchPanelAvailable else { return "" }
        return MainActor.assumeIsolated { panelState?.consumeNotesForDelivery() ?? "" }
    }

    /// A Stop pressed while typing here must hold the payload, never paste it
    /// back into this notes editor or into a previously focused application.
    var isEditingNotes: Bool { MainActor.assumeIsolated { controller?.isEditingNotes ?? false } }

    /*
    SettingsPane calls these panel-only controls. They never start microphone capture.
    Saving off also hides the panel; re-enabling clears its explicit dismissal.
    */
    /// Closed for good: the panel stays away, across dictations and launches, until turned back on.
    func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        MainActor.assumeIsolated { panelState?.cancelSpacing(); controller?.hide() }
    }

    func turnOn() {
        guard Self.launchPanelAvailable else { return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        MainActor.assumeIsolated {
            /*
            Explicitly re-enabling restores the existing page now; no capture or model work starts.
            Preview/test mode must remain incapable of ordering a native window onto the desktop.
            */
            guard !renderingPreview else { return }
            _ = ensurePanel()
            controller?.show()
        }
    }


    // Wiring the stream to the panel


    /*
    Creates panel state and its controller once, then subscribes to questions and thinking state.
    Duplicate thinking values are dropped. Reflection is passed to the status helper but not
    subscribed or rendered here; the window itself is created on first show.
    */
    @MainActor private func ensurePanel() -> ThinkingPanelState {
        if let panelState { return panelState }
        let state  = ThinkingPanelState()
        state.repairSpacing = { [weak self, weak state] raw in
            guard let self, let state, !self.renderingPreview else { return nil }
            let epoch = state.spacingEpoch, snapshot = Array(state.notes.utf8)
            let proposal = await TypedSpacing.repair(raw, provider: self.stream.provider,
                                                     model: self.stream.tuning.questionsModel)
            guard state.spacingEpoch == epoch, Array(state.notes.utf8) == snapshot else { return nil }
            return proposal
        }
        panelState = state
        controller = ThinkingPanelController(state: state)
        stream.$questions.sink { [weak self] output in
            MainActor.assumeIsolated { self?.apply(questions: output) }
        }.store(in: &subscriptions)
        stream.$isThinking.removeDuplicates().sink { [weak self] thinking in
            MainActor.assumeIsolated { self?.apply(thinking: thinking) }
        }.store(in: &subscriptions)
        return state
    }

    @MainActor private func apply(questions output: TokensThinkingLaneOutput) {
        panelState?.receive(output)
        showOnFirstText(output.text)
        refreshStatus(questions: output, reflection: stream.reflection)
    }

    /// The panel comes up only when there is something written to read, once per dictation. With no
    /// local model, or before anything was said, it never appears. A panel the user closed stays closed.
    @MainActor private func showOnFirstText(_ text: String) {
        guard sessionLive, !shownThisSession, !text.isEmpty, panelEnabled, !renderingPreview else { return }
        shownThisSession = true
        controller?.show()
        /*
        Explicit synthetic UI proof only: make the floating panel the selected window
        for automation clients that cannot bind a non-key macOS panel by window ID.
        */
        if bubbleInteractivePreview && ProcessInfo.processInfo.arguments.contains("--temple-panel-ui-proof") {
            controller?.panel?.makeKeyAndOrderFront(nil)
        }
    }

//
// :)
//
//
    /*
    While a thinking pause is open, a timer re-reads the pause length from the stream every 0.25 s
    and puts it in `elapsed`; the timer is dropped as soon as thinking stops.
    */
    /// Thinking state for the panel's counter. Showing the panel is `showOnFirstText`.
    @MainActor private func apply(thinking: Bool) {
        guard let panelState else { return }
        panelState.isThinking = thinking
        ticker                = nil
        // The counter starts from this pause's own length, never the last pause's final value.
        panelState.elapsed = thinking ? (stream.presenceDisplay(at: ProcessInfo.processInfo.systemUptime)?.seconds ?? 0) : 0
        if thinking {
            ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let shown = self.stream.presenceDisplay(at: ProcessInfo.processInfo.systemUptime) else { return }
                    self.panelState?.elapsed = shown.seconds
                }
            }
        }
        refreshStatus(questions: stream.questions, reflection: stream.reflection)
    }

    @MainActor private func refreshStatus(questions: TokensThinkingLaneOutput, reflection: TokensThinkingLaneOutput) {
        guard sessionLive else { return }
        panelState?.status = Self.status(thinking: panelState?.isThinking ?? false, questions: questions, reflection: reflection)
    }

    static func status(for stream: TokensThinkingStream) -> String {
        status(thinking: stream.isThinking, questions: stream.questions, reflection: stream.reflection)
    }

    /*
    Status checks questions only: unavailable reason, Asking while waiting/streaming,
    Thinking with you during a pause, then Waiting for a pause or Listening.
    The retained reflection argument is currently unused by this helper.
    */
    /// One calm line: what is happening and which local model is writing.
    static func status(thinking: Bool, questions: TokensThinkingLaneOutput, reflection: TokensThinkingLaneOutput) -> String {
        if case .unavailable(let reason) = questions.state { return reason }
        if questions.state == .streaming || questions.state == .waiting { return "Asking · \(questions.model)" }
        if thinking { return "Thinking with you" }
        return questions.text.isEmpty ? "Waiting for a pause" : "Listening"
    }


}

