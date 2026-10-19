


//
/*
AudioCapture.swift

Owns: Published microphone state, per-talk storage, and observer lifetime.
Never: Paste words, choose a delivery target, or save microphone audio.
See: Sources/Tokens/Speech/AudioCapture.swift and the related responsibility files below.
Related: AudioCapture+Hardware.swift
         AudioCapture+Signal.swift
         AudioCapture+Recognition.swift
         AudioCapture+Finish.swift
         AudioCapture+Demo.swift
         AudioCapture+Measurement.swift
         AudioCapture+Features.swift
Port provenance: Sources/Audio/TTTAudioCapture.swift, donor 2ac14df.
*/


/*
Shared state remains on one owner. Internal members support its cross-file extensions;
they are not a public API or permission to bypass the owner lifecycle.
*/

import AVFoundation
import AppKit
import TokensCore
import CoreAudio
import Foundation
import Speech


// AudioCapture — the microphone and recognizer for each talk; publishes live words and level


/*
Threads: state lives on main. The exceptions are the tap closure built in startEngine (the
audio thread) and measure() (the analysis queue); system callbacks hop to main before they
touch state. Async callbacks carry the talk's `generation` and check it against `session`,
so a late callback from an old talk cannot touch a newer one.
*/
final class AudioCapture: ObservableObject {


    // Live state — what the bubble and the app read while you talk


    @Published var isRecording = false
    @Published var captureError: String?
    @Published var speechEngineStatus = "Orukeet · local model"
    /// True while a recording's Orukeet model is still loading; audio is being kept (pre-roll).
    @Published var speechModelLoading = false
    // Frozen at capture admission. Settings affect only the next recording.
    var sessionSpeechEngine: SpeechEngineChoice = .defaultChoice
    var speechPrewarmTask: Task<Void, Never>?
    var speechPreferenceObserver: NSObjectProtocol?
    var observedSpeechEngine = SpeechEngineChoice.load()
    /// Build 82: the chosen model as well as the route, so switching between two local models in
    /// the in-place menu reloads and re-states the Settings line (it collapsed to `.orukeet` before).
    var observedSpeechModel = SpeechEngineChoice.selectedModelID()
    @Published var permissionMessage = "microphone idle"
    @Published var features          = AudioFeatures.silence
    @Published var inputLevel        = 0.0
    var inputMeter                   = InputMeter()
    @Published var waveform          = Array(repeating: 0.0, count: 96)
    /*
    Every change to the words notes when it happened and records an arrival anchor
    on the audio clock (used to place thinking pauses when word times are missing).
    */
    @Published var transcript = "" {
        didSet {
            guard oldValue != transcript else { return }
            transcriptChangedAt = Date()
            thinkingAnchors.record(text: transcript, at: thinking.snapshot().clock)
        }
    }
    // How many leading words of `transcript` the recognizer has made final.
    @Published var stableWordCount          = 0
    @Published var voiceCommandsAvailable   = false
    @Published var isSignalActive           = false
    @Published var liveCandidate: Candidate = .silence
    @Published var labCommand: LabCommandEvent?
    @Published var completedSegment: CompletedSegment?
    @Published var hasReceivedAudio = false
    @Published var inputDeviceName  = "System microphone"
    // Goes up by one each time a quiet stretch passes 1 s (see startEngine).
    @Published var speechPauseRevision = 0
    /// Recognizer timestamps for `transcript`'s words; empty when unavailable.
    var timedWords: [TimedWord] = []
    var legacyTranscript = TokensCore.LegacyTranscriptAccumulator()

//
// :)
//
//
    let thinking                = LockedThinkingPauses()
    /*
    thinkingOpenPauseIsEstimated: true when no measured thinking pause is open but a gap
    between recognised words gives an estimate instead (for example when room noise
    hides the silence).
    */
    /// Measured silence in progress (audio clock), for the live Tokens bubble.
    /// Read on every display frame: elapsed comes from the measured clocks, not from buffer arrivals.
    var thinkingOpenPauseIsEstimated: Bool { liveThinkingPause?.estimated ?? false }
    var thinkingOpenPauseSeconds: Double? { liveThinkingPause?.seconds }

    /// Seconds and provenance come from the same snapshot. A slower display-level
    /// RMS measurement must not overrule the audio tap's pause or hide a noise-room estimate.
    var liveThinkingPause: LiveThinkingPause? {
        LiveThinkingPause.resolve(recording: isRecording, measured: thinking.snapshot(),
            words: timedWords, revisionAge: Date().timeIntervalSince(transcriptChangedAt),
            host: ProcessInfo.processInfo.systemUptime)
    }
    private var bubblePauseDisplay = LiveThinkingPauseDisplay()
    var bubbleThinkingPause: LiveThinkingPause? {
        bubblePauseDisplay.read(recording: isRecording, measured: thinking.snapshot(),
            words: timedWords, revisionAge: Date().timeIntervalSince(transcriptChangedAt),
            host: ProcessInfo.processInfo.systemUptime)
    }
    var thinkingPauses: [ThinkingPause] { thinking.snapshot().pauses }
    /// Capture-clock arrival of each transcript revision; fallback placement
    /// for recognizers without word times. Holds times and hashes only.
    var thinkingAnchors = ThinkingArrivalAnchors()
    // The quiet run behind speechPauseRevision, on the audio clock (main thread only).
    var displayQuietStart: Double?
    var displayPauseEmitted = false
    var displayLastAudioEnd = 0.0
    /*
    Stop readiness is written by the tap and read once at the stop edge. The three values
    after it are kept only to log how long the stop took and how many words arrived.
    */
    let stopReadiness = LockedStopReadiness()
    var stopRequestedAt: TimeInterval?
    var stopDecision: StopDecision?
    var stopWordCount = 0


    /// Wall-clock elapsed time since this talk started the engine or attached to it.
    /// TalkModel+Capture.swift freezes this value at Stop for the receipt; this getter
    /// itself keeps advancing until reset and is separate from the measured audio clock.
    var recordingDurationSeconds: TimeInterval {
        startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
    }


    // Microphone hardware — one engine and tap, kept open between talks if asked; sleep/wake


    /*
    The tap stays on the engine for as long as the engine runs; each talk only swaps the
    router's consumer. With keepMicrophoneOpen the hardware keeps running between talks and
    the next talk starts without restarting it; without it, the engine and tap stop at the
    end of each talk. hardwareStarts counts real engine starts.
    */
    let tapRouter                  = AudioTapRouter()
    var keepMicrophoneOpen         = false
    @Published var hardwareRunning = false
    var hardwareStarts             = 0
    // A buffer reached the tap within the last 2 s.
    var hasRecentHardwareSamples: Bool { hardwareRunning && tapRouter.sampleAge < 2 }


    // Turning this off while no talk is active stops the hardware right away.
    func keepMicrophoneOpenWhileIdle(_ enabled: Bool) {
        keepMicrophoneOpen = enabled
        if !enabled && session.id == nil { stopEngineCapture(force: true) }
    }

//
// :)
//
//
    private var deviceListener: AudioObjectPropertyListenerBlock?
    var routeChangeWork: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    // True between sleep and wake. No talk can start while suspended.
    var suspended = false


    /*
    Sleep ends any talk (without pasting) and stops the hardware; wake rebuilds the engine
    for the current input. A change of the system's default input device is handled after
    a short delay (scheduleInputChange).
    */
    init() {
        refreshInputDevice()
        refreshSpeechEngineStatus()
        speechPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let choice = SpeechEngineChoice.load()
            let model = SpeechEngineChoice.selectedModelID()
            guard choice != self.observedSpeechEngine || model != self.observedSpeechModel else { return }
            self.observedSpeechEngine = choice
            self.observedSpeechModel = model
            if self.session.id == nil { self.prewarmRecognition() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.suspended = true
            self.interruptCapture(message: "Mac went to sleep. Copy latest, then tap to resume.")
            self.routeChangeWork?.cancel()
            self.routeChangeWork = nil
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.suspended = false
            self.refreshInputDevice()
            Diagnostics.event("microphone_wake_ready")
        })
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.scheduleInputChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                               DispatchQueue.main, listener) == noErr {
            deviceListener = listener
        }
    }


    deinit {
        speechPrewarmTask?.cancel()
        if let speechPreferenceObserver { NotificationCenter.default.removeObserver(speechPreferenceObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        routeChangeWork?.cancel()
        if let deviceListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                    DispatchQueue.main, deviceListener)
        }
    }


    // Engine and talk state — private fields for the engine and the current talk


    lazy var hardwareOwner = AudioHardwareOwner { [weak self, tapRouter] queue in
        EngineAudioHardwareBackend(router: tapRouter, queue: queue) { [weak self] in self?.scheduleInputChange() }
    }
    var hardwareStartupTimeout: TimeInterval = 8
    var hardwareStartupDeadline: DispatchWorkItem?
    var quiescingGeneration: UUID?
    var quiescenceDeadline: DispatchWorkItem?
    var deviceNameRevision = UUID()
    let deviceNameQueue = DispatchQueue(label: "Tokens.audio-device-name", qos: .utility)
    var deviceNameReadPending = false
    /*
    Level analysis runs off main, one buffer at a time: a buffer that arrives while the
    slot is taken skips analysis (it still reaches the recognizer and pause trackers).
    */
    let analysisQueue = DispatchQueue(label: "TTT.lab.audio-features", qos: .userInitiated)
    let analysisSlot  = DispatchSemaphore(value: 1)
    /*
    One recognizer per talk: either the older SFSpeech request and task, or the fast
    macOS 26 streaming pipeline.
    */
    var speechRequest: SFSpeechAudioBufferRecognitionRequest?

//
// :)
//
//
    var speechTask: SFSpeechRecognitionTask?
    var streamingPipeline: StreamingSpeechPipeline?
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    var startedAt: Date?
    var rmsHistory: [Double] = []
    var aggregateCount       = 0.0
    var aggregate            = AudioFeatures.silence
    var demoTimer: Timer?
    var startupTask: Task<Void, Never>?
    // The current talk's id and phase (awaiting access, starting, recording, finalizing).
    var session = CaptureSession()
    var finishTimeout: DispatchWorkItem?
    var finishCompletion: ((CompletedSegment) -> Void)?
    let demoMode = ProcessInfo.processInfo.arguments.contains("--demo")
    var segmentStartedAt: Date?
    var lastSignalAt: Date?
    var emittedDemoSegment            = false
    var previousRMSDB                 = -80.0
    var displayedCandidate: Candidate = .silence
    var candidateHoldUntil            = Date.distantPast
    /*
    requiresLocalRecognition: this talk must be recognised on this Mac (localOnly).
    signalSession: a level-only session that may run with no recognizer at all.
    labSession: the voice lab; adds sound classes, pitch and lab voice commands.
    */
    var requiresLocalRecognition = false
    var signalSession            = false
    var labSession               = false
    var recognitionHints         = TalkVocabulary.hints
    var utterances               = CommandUtteranceTracker()
    var transcriptChangedAt      = Date.distantPast
    var labCommandTimer: Timer?
    var labCommands = LabCommandTracker()


}

