


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TokensThinkingBubble — the glass capture bubble: discard, live readout, finish


struct TokensThinkingBubble: View {


    // Shape and layout of the bubble


    @ObservedObject var model: TalkModel
    @ObservedObject var audio: AudioCapture
    @ObservedObject private var layout = BubbleLayout.shared
    // Dev-channel builds mark the bubble "DEV", except in the production-style preview.
    private var dev: Bool { DevChannel.isActive && !bubblePreviewProduction }

    // Off unless TokensLiveSurface.caughtWords.v1 is set; read once per construction (cached defaults).
    private let caughtWordsEnabled = LiveSurfacePreference.load(.caughtWords)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let pause = model.previewThinkingSeconds.map { LiveThinkingPause(seconds: $0, estimated: false) }
                ?? audio.bubbleThinkingPause
            // Quiet (still starting, or a real pause): the whole bubble fades to a faint ghost.
            // Ordinary gaps between words no longer dim it (Self.isGhost).
            let quiet = Self.isGhost(audioConfirmed: model.audioIsConfirmed, pause: pause)
            // Recognition timing only, on the tap's audio clock (the same clock as the word times).
            // Never during a pause or start-up: those pills stay exactly the plain envelope.
            let caught: CaughtWords? = caughtWordsEnabled && model.audioIsConfirmed && pause == nil ? {
                let measured = audio.thinking.snapshot()
                return CaughtWords(words: audio.timedWords, stableWordCount: audio.stableWordCount,
                                   now: measured.clock + measured.hostSinceLastBuffer(at: ProcessInfo.processInfo.systemUptime))
            }() : nil
            BubbleControlSurface(vertical: layout.vertical,
                cancelLabel: bubbleInteractivePreview ? "Close preview" : "Discard talk",
                finishLabel: bubbleInteractivePreview ? "Finish preview" :
                    (model.autoSendAfterPasting ? "Finish, paste and send" : "Finish and paste"),
                cancel: model.discardBubbleCapture, finish: model.finishBubbleCapture, ghost: quiet) {
                    TokensBubbleReadout(vertical: layout.vertical, dev: dev, shortcutName: model.shortcutName,
                        destinationLabel: model.destinationLabel, audioConfirmed: model.audioIsConfirmed,
                        pause: pause, waveform: model.previewWaveform ?? audio.waveform, caught: caught)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bubbleInteractivePreview ? "Tokens interactive preview. Synthetic audio. Click the middle to cycle screen edges." : "\(appName) listening. Click the middle to cycle screen edges.")
    }

    /*
    The ghost dim (the fade in and out is deliberate): only while the microphone
    is still starting or after a real pause (ThinkingPauseTracker.minimumAnnotatedPause, 1 s). The
    pause detector reports gaps from 0.2 s, so dimming on every report made the bubble breathe
    between ordinary words and fought the wave.
    */
    static func isGhost(audioConfirmed: Bool, pause: LiveThinkingPause?) -> Bool {
        guard audioConfirmed else { return true }
        guard let pause else { return false }
        return pause.seconds >= BubblePauseCounter.showsAfter
    }

}

/// The actual capture readout is also renderable without creating a recorder or reading history.
struct TokensBubbleReadout: View {
    let vertical: Bool
    let dev: Bool
    let shortcutName: String
    let destinationLabel: String
    let audioConfirmed: Bool
    let pause: LiveThinkingPause?
    let waveform: [Double]
    /// Caught-words dots (Dev experiment); nil keeps the readout exactly as before.
    var caught: CaughtWords? = nil

    var body: some View {
        center(pause: pause)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: vertical ? .trailing : .bottom) {
                // Ticks live only under a live wave: starting and pauses keep today's ghost pill.
                if let caught, audioConfirmed, pause == nil {
                    // Full readout length, so the strip's dot track lines up with the wave's bars;
                    // 1pt in from the rim so the dots never crowd the pill's edge.
                    CaughtWordsStrip(caught: caught, vertical: vertical)
                        .frame(width: vertical ? 4 : nil, height: vertical ? nil : 4)
                        .padding(vertical ? .trailing : .bottom, 1)
                }
            }
            .help("\(dev ? "DEV · " : "")\(shortcutName) · \(destinationLabel). Destination is checked again when you stop.")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(dev ? "Development, " : "")\(shortcutName), \(destinationLabel)")
            .accessibilityIdentifier("tokens.destination.preview")
    }

    // The centre readout


    /*
    Envelope only: no words or numbers in the bubble. Talking and pauses draw the
    same left-to-right red-pen envelope, so a pause simply writes flat baseline from the right and the
    shape never swaps; starting draws the bare baseline. The measured pause length stays in the
    accessibility label. With caught-words dots switched on (off by default, Dev experiment, hearing
    only) the talking envelope moves up (or left) to clear the dot gutter.
    */
    @ViewBuilder private func center(pause: LiveThinkingPause?) -> some View {
        if !audioConfirmed {
            TinyEnvelope(samples: [], vertical: vertical)
                .padding(talkingInsets)
                .accessibilityLabel("Microphone starting")
        } else if let pause, pause.seconds >= BubblePauseCounter.showsAfter {
            BubblePauseCounter(seconds: pause.seconds, vertical: vertical)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pause.estimated ? "Estimated speech gap" : "Measured microphone silence") \(String(format: "%.4f", pause.seconds)) seconds")
        } else if let pause {
            TinyEnvelope(samples: waveform, vertical: vertical)
                .padding(talkingInsets)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pause.estimated ? "Estimated speech gap" : "Measured microphone silence") \(String(format: "%.4f", pause.seconds)) seconds")
        } else {
            TinyEnvelope(samples: waveform, vertical: vertical)
                .padding(caught == nil ? talkingInsets : stripInsets)
        }
    }

    /// The envelope's room when the 4pt caught-words gutter sits below (or right of) it. It keeps
    /// about 90% of its talking height, so loud speech still nearly fills the line.
    private var stripInsets: EdgeInsets {
        vertical ? EdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 6)
                 : EdgeInsets(top: 2, leading: 2, bottom: 6, trailing: 2)
    }
    /// The envelope's room in the pill: a little air at the ends so strokes never touch the controls.
    private var talkingInsets: EdgeInsets {
        vertical ? EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
                 : EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2)
    }


}


/// The pause readout: the logo π and the pause so far in hundredths, in the envelope's coral ink.
/// It sits in the ghost-dimmed pill, so it stays quiet; vertical pills stack the π above the digits.
struct BubblePauseCounter: View {
    /// The counter and the ghost dim start half a second into a pause (UX review:
    /// "start at zero point five seconds"), sooner than the 1 s pause notes in the text.
    static let showsAfter = 0.5
    let seconds: Double
    let vertical: Bool

    var body: some View {
        let digits = Text(String(format: "%.2f", seconds))
            .font(.system(size: vertical ? 8.5 : 10, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(TinyEnvelope.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        let piSize = LogoPi.size(inkHeight: vertical ? 8 : 9, lineWidth: 1.3)
        let pi = LogoPi()
            .stroke(TinyEnvelope.ink, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            .frame(width: piSize.width, height: piSize.height)
            .padding(0.65)
        if vertical {
            VStack(spacing: 3) { pi; digits }.padding(.horizontal, 2)
        } else {
            HStack(spacing: 4) { pi; digits }
        }
    }
}
