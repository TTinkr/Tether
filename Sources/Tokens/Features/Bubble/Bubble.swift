


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkBubbleSheet — the bubble's content: picks which surface shows for the current state


struct TalkBubbleSheet: View {


    // Which surface the bubble shows


    @ObservedObject var model: TalkModel
    @ObservedObject private var audio: AudioCapture
    @ObservedObject private var bubbleLayout = BubbleLayout.shared

    init(model: TalkModel) {
        /*
        This view borrows the existing TalkModel; it must not create a second recording session.
        Observe its AudioCapture separately because microphone levels change independently of
        model-level UI state. Both references still point at the same talk's objects.
        */
        self.model = model
        _audio     = ObservedObject(wrappedValue: model.audio)
    }

    var body: some View {
        /*
        Only one surface shows at a time. The chain below is checked top to bottom and the first case
        that matches wins, so an earlier case hides every later one.
        */
        Group {
            if model.tinkeringWorking {
                // Local tinkering is running: show its status line.
                TinyStatusSurface(text: "Tinkering locally · up to 3 s")
            } else if model.heldWordsVisible {
                /*
                Words that had nowhere to be pasted stay available until copied or dismissed.
                */
                HeldWordsSurface(model: model)
            } else if let recoveryText, !recoveryText.isEmpty {
                // A failed talk's message, or "microphone access unavailable" (see recoveryText below).
                TinyStatusSurface(text: recoveryText)
            } else if let seconds = model.finishCountdownSeconds, model.phase == .finalizing {
                /*
                Stop was pressed and the send delay is counting down: a discard button, then the
                countdown capsule. The discard button is hidden and disabled once delivery has been
                launched.
                */
                if model.thinkingExperience {
                    BubbleFinalizingSurface(vertical: bubbleLayout.vertical, seconds: seconds,
                        launching: model.finishLaunching, canTakeOffNow: model.canTakeOffNow,
                        cancel: model.discardBubbleCapture, takeOffNow: model.takeOffNow)
                } else {
                    HStack(spacing: 4) {
                        BubbleAction(symbol: "xmark", label: "Discard talk", action: model.discardBubbleCapture)
                            .frame(width: 24, height: 28)
                            .opacity(model.finishLaunching ? 0 : 1)
                            .disabled(model.finishLaunching)
                        FinishCountdownSurface(
                            seconds: seconds,
                            progress: model.finishCountdownProgress,
                            launching: model.finishLaunching,
                            canTakeOffNow: model.canTakeOffNow,
                            takeOffNow: model.takeOffNow
                        )
                        .frame(width: 190, height: 36)
                    }
                }
            } else if model.previewIsHidden || model.phase != .capturing {
                // Nothing to show: the preview is hidden, or no talk is capturing. The bubble is blank.
                Color.clear
            } else if model.thinkingExperience {
                /*
                Thinking experience on: the glass bubble, sized from BubbleLayout (which changes when the
                bubble is stood upright).
                */
                TokensThinkingBubble(model: model, audio: audio)
                    .frame(width: bubbleLayout.size.width, height: bubbleLayout.size.height)
            } else {
                /*
                The ordinary capture bubble: discard, the live capsule, and finish. The
                model.preview... values stand in for the real microphone readings when the
                interactive preview supplies them.
                */
                HStack(spacing: 4) {
                    BubbleAction(symbol: "xmark", label: "Discard talk", action: model.discardBubbleCapture)
                        .frame(width: 24, height: 28)
                    TinyGlassSurface(
                        text: liveText,
                        phase: model.phase,
                        inputLevel: model.previewInputLevel ?? audio.inputLevel,
                        pauseRevision: model.previewPauseRevision ?? audio.speechPauseRevision,
                        audioConfirmed: model.audioIsConfirmed
                    )
                    .frame(width: 190, height: 36)
                    BubbleAction(symbol: "checkmark", label: "Finish, paste and send", action: model.finishBubbleCapture)
                        .frame(width: 24, height: 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bubble is always drawn in the light appearance.
        .preferredColorScheme(.light)
        .onAppear { updateReadableSize() }
        .onChange(of: needsReadableSurface) { _, _ in updateReadableSize() }

    }

//
// :)
//
//
    // The text shown on the surface


    private var needsReadableSurface: Bool {
        !model.thinkingExperience || model.heldWordsVisible || model.tinkeringWorking || recoveryText != nil
    }

    private func updateReadableSize() {
        bubbleLayout.expanded = needsReadableSurface
        guard !bubbleInteractivePreview, let window = compactWindow(), let screen = window.screen else { return }
        let size = bubbleLayout.size
        window.minSize = panelMinimumSize
        window.maxSize = panelMaximumSize
        window.setFrame(NSRect(origin: BubbleGeometry.origin(BubblePlacement.loadPreset(), custom: nil,
            size: size, visible: screen.visibleFrame), size: size), display: false)
    }

    private var recoveryText: String? {
        Self.recoveryText(phase: model.phase, retainedFailureText: model.retainedFailureText,
                          permissionMessage: audio.permissionMessage, captureError: audio.captureError)
    }

    /*
    Failed talk: show the text the model kept. Otherwise, while this talk's own microphone error
    stands and its message says denied, unavailable or failed, show a fixed "microphone access
    unavailable". Otherwise nil.
    The message alone is not enough: it outlives its talk, so the next talk opened as a wide
    "microphone access unavailable" capsule until the microphone was live (build 81). The error
    itself is cleared as each talk starts.
    */
    static func recoveryText(phase: TalkPhase, retainedFailureText: String,
                             permissionMessage: String, captureError: String?) -> String? {
        if phase == .failed {
            return retainedFailureText
        } else if captureError != nil,
                  permissionMessage.contains("denied") ||
                  permissionMessage.contains("unavailable") ||
                  permissionMessage.contains("failed") {
            return "microphone access unavailable"
        }
        return nil
    }

    /*
    The words so far: the microphone's own transcript if it has one, otherwise the model's display
    text. They are then run through BrandVocabulary and CharacterTalk before they are shown.
    */
    private var liveText: String {
        // Orukeet cold load: the microphone is already recording (pre-roll), so say why no words yet.
        if audio.transcript.isEmpty && audio.speechModelLoading { return "Loading speech model…" }
        let source  = audio.transcript.isEmpty ? model.displayText : audio.transcript
        let branded = BrandVocabulary.apply(to: source)
        return CharacterTalk.render(branded).displayText
    }


}

