


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — observable state


/*
One talk, in the order the code runs:
  key press        routeRightOption → pressToTalkBegin → begin()        phase: capturing
  while talking    observeTranscript: bubble text and recovery checkpoints
  stop (release in hold mode, second press in tap mode)
                   routeRightOption → pressToTalkEnd → finish()          phase: finalizing
                   (finishAtSpeedOfSound instead when Speed of Sound is on)
  at Stop          captureStopTarget freezes the target app; beginFinishCountdown arms
                   the stop gate (FinishGate) for the send delay
  words ready      complete() → FinishGate.offer
  gate opens       tickFinishCountdown, takeOffNow, or a late complete()
                   → launchGatedDelivery → deliver()
  delivered        celebrateDelivery → resetSession()                    phase: delivered → idle
  anything fails   retainForRecovery: words held for Copy latest         phase: failed

Timers run on the main run loop and delayed work uses DispatchQueue.main. Each
callback checks sessionID (and usually phase) before acting, so work left over
from an older talk does nothing.

Legacy product state remains here for Tokens, Talk, Telescope and Tincture.
The public launch uses Tokens; retained legacy state is not a promise of launch UI.
*/

/*
State remains on one ObservableObject so existing subscriptions retain identity.
Cross-file implementation members use module-internal access because Swift
private setters cannot be mutated by extensions in other files. UI code observes
these values; the TalkModel extensions own their mutation.
*/

final class TalkModel: ObservableObject {

    // Talk key — the shortcut that starts a talk, and choosing a new one

    /// The app updater. Every phase change calls resumeWhenIdle(); it restarts the app only
    /// when canRestart (set in init) allows: idle or delivered, and the lab not listening.
    let updater = Updater()

    // The talk key's name and key code, as shown in Home and Settings.
    @Published var shortcutName = TalkShortcut.load().displayName

    @Published var shortcutKeyCode = TalkShortcut.load().keyCode

    /*
    Key access. Granted: the global key monitor is attached. NeedsRelaunch: Accessibility
    changed but the event tap still could not start (tapUnavailable).
    */
    @Published var shortcutAccessGranted = false

    @Published var shortcutAccessNeedsRelaunch = false

    /// True while the next key pressed will become the new talk key.
    @Published var recordingShortcut = false

    // Published state — what the bubble and Home show for the current talk

    /**
    Where the current talk is (see TalkPhase). Every change also offers a pending app
    update its chance to install, stops the live notes outside capturing and
    finalizing, and ends the π thinking panel outside capturing.
    */
    @Published var phase: TalkPhase = .idle {
        didSet {
            if phase != .failed, bubbleStandbyOverride { bubbleStandbyOverride = false }
            updater.resumeWhenIdle()
            if phase != .capturing && phase != .finalizing { pauseAsides.stop() }
            // The pointer ring is a while-talking cue only; at rest it goes at once (build 83).
            PasteMarker.ringWhileTalking = phase == .capturing
            if phase != .capturing, PasteMarker.shared.mode == .cursor { PasteMarker.shared.hide() }
            // A talk that fails mid-way takes its box down at once, not at the next tick (build 81).
            syncDestinationPreview()
            /*
            A talk that ends between Stop and delivery without delivering (failure, nothing to
            paste) gives Return back to every app at once (build 81). Delivery itself releases
            it after any owed Return is sent, so .delivered is left to it.
            */
            if oldValue == .capturing || oldValue == .finalizing, phase == .failed || phase == .idle,
               input.hasPendingReturnReservation {
                Diagnostics.event("delivery_return_released reason=\(phase == .failed ? "failed" : "idle")")
                input.finishReturnReservation()
            }
            // A talk-key press made while it finished may start the next talk now (build 81).
            if oldValue == .finalizing, phase != .finalizing { lastTalkLeftFinalizing() }
        }
    }

//
// :)
//
//
    /// What the bubble shows: the live words while capturing, then the delivered text.
    @Published var displayText = ""

    /// How many leading words of displayText recognition has settled.
    @Published var displayStableWordCount = 0

    /*
    After a failure: the short status line (for example "Paste unavailable · Copy latest")
    and the held words that Copy latest and the held-words capsule copy.
    */
    @Published var retainedFailureText = "" {
        // Any newer status owns the line, even when its text happens to be identical.
        didSet { shortcutAccessFailure = nil }
    }

    @Published var retainedFailurePayload = ""

    /// The recovery-journal entry offered at launch as "Recovered transcript", until the next
    /// talk starts (the journal remains recoverable) or Clear History removes it.
    var restoredRecoveryID: UUID?
    /// Unsent words older than the newest talk, offered on Home with their own Copy (build 81).
    @Published var earlierRecovery: RecoveredTalk?
    /// Why the last Copy or Forget on the earlier talk did not stick, shown on its Home line.
    @Published var earlierRecoveryNote: String?
    /// Talks discarded this run whose journal entry could not be resolved: Home keeps offering
    /// them as earlier talks ("Not discarded · words kept") until Copy or Forget records them.
    var unresolvedDiscardIDs: Set<UUID> = []

    /// If Clear History emptied the history file but journal cleanup failed, Retry must
    /// finish that same request. Keep the click-time cutoff and spared session identities
    /// so a later retry cannot delete new talks or a talk that finished in the meantime.
    var recoveryClearRequestedAt: Date?
    var recoveryClearExempt: Set<UUID> = []

    /// Words with nowhere to paste, shown highlighted until copied, dismissed, or timed out.
    @Published var heldWordsVisible = false

    @Published var heldWordsCopied = false

    @Published var heldWordsRevision = 0

    var heldWordsTimer: Timer?

    /**
    Always empty. The old tree appended every talk's words to dataset.jsonl and loaded them
    here; that write was removed (no data collection). The property
    stays only because Unreached/Lab.swift still reads it.
    */
    @Published var rows: [DatasetRow] = []

    /// True once Stop hides the live words; cleared on a new talk, on held words, or on reset.
    @Published var previewIsHidden = false


    // Stop → wait → deliver


    /**
    Legacy storage for the two-choice paste control: 0 means Fast snapshot, positive
    means finish recognition first. Public Tokens adds no artificial delay in either
    mode. Other legacy products retain their countdown. A missing setting reads as Fast.
    */
    @Published var sendDelaySeconds: Double = TokensPasteTiming(delay: UserDefaults.standard.double(forKey: "TTTSendDelaySeconds.v1")).delay {
        didSet { UserDefaults.standard.set(min(5, max(0, sendDelaySeconds)), forKey: "TTTSendDelaySeconds.v1") }
    }

    /// Sends Return only after a confirmed paste. Manual Return remains an explicit action.
    @Published var autoSendAfterPasting = TokensAutoSendPreference.load() {
        didSet { TokensAutoSendPreference.save(autoSendAfterPasting) }
    }

    /// Whole seconds left before the stop gate releases delivery; nil when no countdown is showing.
    @Published var finishCountdownSeconds: Int?

    /// 0 at Stop, 1 when the gate opens; drawn by the bubble.
    @Published var finishCountdownProgress = 0.0

    /// True once delivery has been launched for this talk. Late recognizer results,
    /// Take off now and discard check it, so nothing launches twice or discards after launch.
    @Published var finishLaunching = false

    // The voice lab window: open, listening, and a briefly shown sound name.
    @Published var isLabOpen = false

    // Lab stops do not change the talk phase; release any consented restart at this boundary.
    @Published var isLabListening = false {
        didSet {
            if oldValue && !isLabListening { updater.resumeWhenIdle() }
        }
    }

    @Published var labPreviewCandidate: Candidate?

    @Published var labPreviewRevision = 0

    /// Always .terminal in Tokens (set in init).
    @Published var dictationStyle: TalkStyle

    /// Tap to talk or hold to talk; saved per product.
    @Published var rightOptionMode: RightOptionMode

    /// The most recent delivered or held words; one of the sources of Copy latest.
    @Published var lastTranscriptForCopy = ""

    // Prompt history shown in Home, newest first, and its storage status messages.
    @Published var promptHistory: [PromptHistoryEntry] = []

    @Published var historyStorageError = ""

    @Published var historyStorageNotice = ""

    @Published var historyRecoveryRequired = false

    // Whether the history list and the product drawer are open.
    @Published var historyExpanded = false

    @Published var productDrawerExpanded = false

    // Products — Tokens, Talk, Telescope, Tincture, and switching between them

    /// Which product this model is acting as: "Tokens", "Talk", "Telescope" or "Tincture".
    @Published var selectedProduct = "Tokens"

    var onProductChange: (() -> Void)?

//
// :)
//
//
    var suspendedProducts: [String: SuspendedProduct] = [:]

    /// Called when the product drawer opens or closes.
    var onProductDrawerChange: ((Bool) -> Void)?


    // Background listening — microphone ownership and consent


    /// True while an idle listener owns the microphone: the input-level preview, background
    /// listening, or Tincture's voice box. begin() stops it before a talk.
    @Published var inputPreviewOwnsCapture = false

    var inputPreviewVisible = false

    // Tincture's voice box: on/off, its live words, and how many are settled.
    @Published var tinctureVoiceEnabled = true

    @Published var tinctureVoiceTranscript = ""

    @Published var tinctureStableWords = 0

    var tinctureOwnsCapture = false

    /// Current-launch background consent. Old Live notes preferences never authorize capture.
    @Published var ambientEnabled = false

    var backgroundConsent = BackgroundListeningConsent()
    var backgroundLifecycle: BackgroundListeningLifecycle?

    // Background listening: whether it owns the microphone, and its last 900 characters.
    @Published var ambientOwnsCapture = false

    @Published var ambientTranscript = ""

    /// Restarts the idle recognizer every 60 s (see resumeInputPreview).
    var ambientRotation: Timer?

    /// Set at quit so nothing reopens the microphone.
    var ambientShuttingDown = false

    let ambientReflection = TokenPauseAsides() // Deliberately no audit/persistence sink.

    /// Small floating chip shown in place of a hidden notes panel.
    var ambientChip: NSPanel?

    // Product drawer — the hover menu that picks a product

    /// Pending close of the drawer after the pointer leaves it.
    var productDrawerDismissal: DispatchWorkItem?

    // Copy — explicit clipboard writes with a brief "copied" mark

    /// Which control shows "copied" right now ("latest", a history entry id, ...), and a
    /// revision so an older 1.6 s timer cannot clear newer feedback.
    @Published var copyFeedbackKey: String?

    @Published var copyFeedbackRevision = UUID()


    // Output settings — receipts and retained formatting helpers


    // Output settings for the current product: receipt, Markdown, Speed of Sound.
    @Published var metadataEnabled = false
    @Published var characterTagsEnabled = true
    @Published var numberTagsEnabled = true

    @Published var markdownEnabled: Bool

    @Published var speedOfSoundEnabled: Bool

    /*
    Set only by scripted previews; nil means "use the live audio value" (see
    effectiveInputDeviceName, audioIsConfirmed and the bubble).
    */
    @Published var previewWaveform: [Double]?

    @Published var previewInputLevel: Double?

    @Published var previewPauseRevision: Int?

    @Published var previewAudioConfirmed: Bool?

    @Published var previewInputDeviceName: String?

    /// Local formatting pass over the words. Only the Talk product lets it use a model.
    let localFormatter = LocalFormatter()

//
// :)
//
//
    /// Optional layout and title proposals for the Tokens thinking layout (Tokens only).
    let thinkingFormatter = ThinkingFormatter()

    /// Optional generated appendix for lab Tokens; off by default.
    let tinkering = Tinkering()

    /*
    Retained notes service. Public capture does not start it or append its generated
    summary to the delivered transcript; background consent is managed separately.
    */
    let pauseAsides = TokenPauseAsides()

    /// The floating notes panel, created on first show.
    var asidePanel: NSPanel?

    /// The panel's own hide control. Survives idle, model refreshes and STOP;
    /// only the next explicit capture start (or the setting) shows it again.
    var asideHiddenByUser = false

    /// Set when delivery launches: hides the notes panel and chip until an explicit show.
    var asideDismissedAfterSend = false

    /// Notes visibility is separate from microphone consent. It always starts off and
    /// never reads the legacy persisted switch as permission to open the microphone.
    @Published var showLiveTinkering = false {
        didSet { showPauseAside(explicit: showLiveTinkering) }
    }

    /// Read by the bubble. This class only ever sets it to false.
    @Published var tinkeringWorking = false

    // Not read or written anywhere else in this class.
    private var tinkeringSessions: Set<UUID> = []

    /// Thinking pause length for scripted previews; nil while "speaking".
    @Published var previewThinkingSeconds: Double?


    // One talk — identity, target, stop gate and recovery


    /// The one owner of the microphone and the speech recognizer.
    let audio = AudioCapture()

    // Callbacks the app wires up: lab window, voice commands, history list.
    var onLabVisibilityChange: ((Bool) -> Void)?

    var onVoiceCommand: ((VoiceCommand) -> Void)?

    var onHistoryExpansionChange: ((Bool) -> Void)?

    /// The global key monitor: talk key edges, Return held back during delivery, and
    /// ⌘C / Escape while held words show.
    let input = GlobalKeyMonitor()

    /// Reads the frontmost app's text field when Stop happens.
    let recoveryWindows = RecoveryWindowController()
    @Published var destinationLabel = "Choose a text field"
    /// Presentation-only: a failed overlay that has completed its own visibility lifecycle
    /// yields to compact standby without clearing the error or any retained words on Home.
    @Published var bubbleStandbyOverride = false {
        didSet {
            if oldValue != bubbleStandbyOverride { syncDestinationPreview() }
        }
    }
    var persistentDestinationPreviewEnabled = false
    var destinationPreviewSuspended = false
    var destinationPreviewTimer: Timer?
    var destinationPreviewGeneration: UUID?
    var destinationPreviewInFlight = false
    var destinationPreviewRefreshPending = false
    /// Passing misses in a row (build 81): the box stays through up to three of them.
    var destinationPreviewRetries = 0
    let targets = TargetTracker()

    /// Where this talk's words go; copied from stopTarget at Stop. nil means nowhere: hold them.
    var target: CapturedTarget?

    var stopTarget = StopTarget<CapturedTarget>()

    /// This talk's id; nil between talks. Every timer and async callback compares against
    /// it, so work left over from an older talk does nothing.
    var sessionID: UUID?

    /// Talks already delivered. deliver() inserts first, so a talk is delivered at most once.
    var completedSessionIDs: Set<UUID> = []

    // Written by retainForRecovery, begin and resetSession; not read anywhere in this class.
    var retainedSendReturn = false

//
// :)
//
//
    /*
    Microphone ownership by the lab, and by voice copy after a failure
    (recoveryOwnsCommandCapture is never set to true in this class).
    */
    var labOwnsSignalCapture = false

    var recoveryOwnsCommandCapture = false

    /// Each completed segment is handled once.
    var observedSegmentIDs: Set<UUID> = []

    /// A talk is written to history at most once.
    var historyRecordedSessionIDs: Set<UUID> = []

    /*
    Each talk's History row id (build 81). The recovery journal keeps it beside the talk's
    words, and trims an old sent-but-unconfirmed talk only while that row is confirmed in the
    saved History file (HistoryRowsOnDisk), never because a save was merely attempted.
    */
    var historyRowIDs: [UUID: UUID] = [:]

    /// False after the history file failed to load or save; then nothing overwrites it.
    var historyStoreWritable = true

    /// Fails the talk if no audio arrives within 8 s of begin().
    var startupDeadline: DispatchWorkItem?

    /// The tap/hold mode this talk began with; key edges during the talk use it.
    var activeSessionMode: RightOptionMode?

    /// System uptime at Stop. The gate, the 1 s formatter budget and stop timing logs
    /// all measure from it.
    var stopRequestedUptime: TimeInterval?

    var finishGate = FinishGate<PendingDelivery>()

    /// Ticks every 50 ms while the countdown runs.
    var finishGateTimer: Timer?

    /// The words captured at Stop; the gate releases these if final words have not arrived.
    var finishFallback: PendingDelivery?

    /// An explicit payload passed to finish(); it replaces recognized words for early release.
    var finishPayloadOverride: String?

    /**
    Recovery journal in Application Support/<bundle id>. A talk's words are checkpointed
    as it runs; entries not resolved by a verified delivery or a discard are offered for
    Copy latest at the next launch (see init).
    */
    let transcriptRecovery = TranscriptRecoveryStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tinkr.tokens.community.lab.macos"))

    // Daily allowance — a ledger of verified deliveries; it never limits Tokens

    /// A local ledger of verified deliveries. shouldDecorateDelivery always returns true
    /// for a real Tokens talk, so the ledger never limits formatting.
    let dailyAllowance = DailyAllowance()

    @Published var dailyAllowanceMessage = "Tokens formatting always on · lowercase · metadata · pause traces · AI summary"

    @Published var dailyDeliveryNotice = ""


    // Recovery checkpoints — timers and retained delivery state


    /// Recording length frozen at Stop; the receipt uses this, not the live value.
    var frozenRecordingDurationSeconds: TimeInterval?

    /// Drives scripted preview waves; invalidated on discard.
    var previewWaveTimer: Timer?

    // Staged delivery state (see beginStagedTokensDelivery, which nothing here calls).
    var stagedHeader: String?

    var stagedCommitted: String?

    var stagedFailed = false
    /// An immutable marker posted at Stop. An uncertain marker stops all further paste.
    /// The gate holds final delivery while asynchronous marker acknowledgement is pending.
    var stopStream = StopStreamState<PendingDelivery>()

//
// :)
//
//
    // Throttled recovery checkpoints while talking (see scheduleCaptureCheckpoint).
    var captureCheckpointWork: DispatchWorkItem?

    var pendingCaptureCheckpointText = ""

    var lastCaptureCheckpointText = ""

    var subscriptions: Set<AnyCancellable> = []
    /// Dev-only live-QA talk-key edges (QATalkTrigger); nil in the public download.
    var qaTalkObserver: NSObjectProtocol?
    var qaTalk = QATalkState()
    /// The talk a talk-key press began; only that talk is discarded by a chord on that press.
    var keyBeganSession: UUID?
    /// A talk-key press made while the last talk was finishing (build 81; DeferredTalkPress).
    var deferredTalkPress = DeferredTalkPress()

    // Accessibility polling after System Settings is opened (see startShortcutAccessPoll).
    var shortcutAccessPollTimer: Timer?

    var shortcutAccessPollAttempts = 0

    // Temporary key-access status owns only its message, never the held transcript.
    var shortcutAccessFailure: ShortcutAccessFailure?

    /// True for launch-argument proofs and previews (see init). Guards across this class
    /// then skip history, recovery journal and settings writes, and idle listening.
    let isSyntheticRun: Bool


    // Startup — settings, recovery and callback wiring


    /**
    Loads settings, history and the recovery journal, then connects the key
    monitor and AudioCapture to this model. isSyntheticRun is decided first; most steps
    below skip work when it is true.
    */
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        /*
        Any of these launch arguments, or a proof-output default, makes this a synthetic run.
        The proof routes count only where AppDelegate would run them (ProofRoutes): in the public
        download a stray flag or setting must not leave a normal app with history switched off.
        */
        let proofRun = ProofRoutes.isAllowed && (
            (SinglePasteFixtureProof.allowed(distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String,
                proofRoutesAllowed: ProofRoutes.isAllowed, continuousReveal: arguments.contains("--continuous-reveal"),
                devChannel: DevChannel.isActive) && arguments.contains("--single-paste-fixture-proof")) ||
            UserDefaults.standard.string(forKey: "TTTAmbientMicrophoneProofOutput.v1") != nil ||
            arguments.contains("--ambient-microphone-proof") || arguments.contains("--takeoff-now-proof") ||
            arguments.contains("--dictation-file-proof") || arguments.contains("--legacy-dictation-file-proof") || arguments.contains("--microphone-pause-proof") ||
            UserDefaults.standard.string(forKey: "TTTMicrophonePauseProofOutput.v1") != nil)
        let localSpeechFixture = DevChannel.isActive &&
            ["--local-speech-fixture-proof", "--fixture-audio"].allSatisfy { flag in
                guard let index = arguments.firstIndex(of: flag) else { return false }
                return index + 1 < arguments.count
            }
        isSyntheticRun = localSpeechFixture || (DevChannel.isActive && arguments.contains("--native-editor-fixture-proof")) ||
            // The Dev --qa-talk launch only posts an edge and exits: it loads no history and starts nothing.
            (QATalkTrigger.isAvailable && arguments.contains("--qa-talk")) || ProofRoutes.nativeBubblePreview || arguments.contains("--staged-scratch-proof") || bubbleInteractivePreview || arguments.contains("--demo") ||
            arguments.contains("--render-preview-frames") ||
            arguments.contains("--controls-preview") ||
            (ProofRoutes.isAllowed && arguments.contains("--held-words-preview")) || proofRun
        // Tokens always uses the terminal look; the choice is written back unless previewing.
        dictationStyle = .terminal
        if !bubbleInteractivePreview { UserDefaults.standard.set(TalkStyle.terminal.rawValue, forKey: "TTTDictationStyle.v1") }
        rightOptionMode = RightOptionMode(
            rawValue: UserDefaults.standard.string(forKey: "TTTRightOptionMode.v1") ?? ""
        ) ?? .tap
        metadataEnabled     = UserDefaults.standard.bool(forKey: TokensOutputOptions.metadataKey)
        characterTagsEnabled = TokensOutputOptions.characterTags(in: .standard)
        numberTagsEnabled   = TokensOutputOptions.numberTags(in: .standard)
        markdownEnabled     = TranscriptRenderMode.current() == .markdown
        speedOfSoundEnabled = SpeedOfSoundPreference.isEnabled()
        configureStartup()
    }

}


/// A journal entry offered on Home as an earlier talk: its session and exact words.
struct RecoveredTalk: Equatable {
    let id: UUID
    let text: String
}
