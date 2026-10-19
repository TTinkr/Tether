
import AppKit
import SwiftUI
import Testing
@testable import Tokens

struct TinyEnvelopeTests {
    @Test func strokeCountFollowsTheLengthAtTheOriginalPenDensity() {
        #expect(TinyEnvelope.sampleCount(along: 0) == 2)
        #expect(TinyEnvelope.sampleCount(along: 66) == 49)
        #expect(TinyEnvelope.sampleCount(along: 38) == 29)
        // Never more than the original 56 strokes, however long the readout.
        #expect(TinyEnvelope.sampleCount(along: 400) == 56)
    }

    @Test func newestSoundIsOnTheRightAndSilenceIsBare() {
        let along: CGFloat = 66
        let count = TinyEnvelope.sampleCount(along: along)
        // Silence and no history draw nothing but the baseline.
        #expect(TinyEnvelope.reaches(samples: [], along: along).allSatisfy { $0 == 0 })
        #expect(TinyEnvelope.reaches(samples: Array(repeating: 0, count: 96), along: along).allSatisfy { $0 == 0 })
        // A single new sound appears at the right (newest) edge, not the left.
        let fresh = TinyEnvelope.reaches(samples: Array(repeating: 0, count: 95) + [0.8], along: along)
        #expect(fresh.count == count)
        #expect(fresh.last == 1 && fresh.dropLast().allSatisfy { $0 == 0 })
        // A short history is right-aligned too.
        let short = TinyEnvelope.reaches(samples: [0.2, 0.3], along: along)
        #expect(short.count == count && short[count - 1] > 0 && short[count - 2] > 0 && short[0] == 0)
        // Each new buffer pushes the old sound one stroke to the left.
        let next = TinyEnvelope.reaches(samples: Array(repeating: 0, count: 95) + [0.8, 0], along: along)
        #expect(next[count - 2] == 1 && next[count - 1] == 0)
    }

    @Test func loudSpeechFillsButNeverExceedsTheLineAndBadLevelsAreIgnored() {
        let loud = TinyEnvelope.reaches(samples: Array(repeating: 0.95, count: 96), along: 66)
        #expect(loud.allSatisfy { $0 == 1 })
        let odd = TinyEnvelope.reaches(samples: [Double.nan, -0.5, .infinity, 0.8], along: 66)
        #expect(odd.suffix(4) == [0, 0, 0, 1])
    }
}

struct BubbleGhostTests {
    @Test func onlyStartingOrARealPauseFadesTheBubble() {
        #expect(TokensThinkingBubble.isGhost(audioConfirmed: false, pause: nil))
        #expect(!TokensThinkingBubble.isGhost(audioConfirmed: true, pause: nil))
        // Ordinary gaps between words (the detector reports from 0.2 s) keep the bubble steady.
        for seconds in [0.2, 0.3, 0.49] {
            #expect(!TokensThinkingBubble.isGhost(audioConfirmed: true, pause: LiveThinkingPause(seconds: seconds, estimated: false)))
            #expect(!TokensThinkingBubble.isGhost(audioConfirmed: true, pause: LiveThinkingPause(seconds: seconds, estimated: true)))
        }
        for seconds in [0.5, 0.6, 1.2, 4.0] {
            #expect(TokensThinkingBubble.isGhost(audioConfirmed: true, pause: LiveThinkingPause(seconds: seconds, estimated: false)))
        }
    }
}

@MainActor struct BubbleHoverTrackerTests {
    @Test func trackingAreaWorksWhileTokensIsInactiveAndNeverTakesClicks() throws {
        let view = BubbleHoverTrackingView(frame: NSRect(x: 0, y: 0, width: 124, height: 26))
        let area = try #require(view.trackingAreas.first)
        #expect(area.options.contains(.activeAlways))
        #expect(area.options.contains(.mouseEnteredAndExited))
        #expect(area.options.contains(.inVisibleRect))
        #expect(view.hitTest(NSPoint(x: 60, y: 13)) == nil)
    }

    @Test func enterAndExitReportOnceEach() throws {
        let view = BubbleHoverTrackingView(frame: NSRect(x: 0, y: 0, width: 124, height: 26))
        var reports: [Bool] = []
        view.onChange = { reports.append($0) }
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: enter)
        view.mouseEntered(with: enter)
        view.mouseExited(with: exit)
        #expect(reports == [true, false])
    }
}

private struct BubbleRenderHost: View {
    let vertical: Bool
    let level: Double?
    let controls: Bool
    /// Silence, then speech at about `level` arriving from the right.
    static func samples(_ level: Double) -> [Double] {
        (0..<96).map { (i: Int) -> Double in
            guard i >= 40 else { return 0 }
            let shape: Double = 0.55 + 0.45 * abs(sin(Double(i) * 0.9))
            return level * shape
        }
    }
    var body: some View {
        let size = vertical ? BubbleLayout.compactVerticalSize : panelDefaultSize
        let samples: [Double] = level.map(Self.samples) ?? []
        let pause = level == nil ? LiveThinkingPause(seconds: 5.24, estimated: false) : nil
        BubbleControlSurface(vertical: vertical, cancelLabel: "Discard talk", finishLabel: "Finish and paste",
                             cancel: {}, finish: {}, showsControls: controls,
                             ghost: TokensThinkingBubble.isGhost(audioConfirmed: true, pause: pause)) {
            TokensBubbleReadout(vertical: vertical, dev: false, shortcutName: "Left Option",
                                destinationLabel: "Claude · text area", audioConfirmed: true,
                                pause: pause, waveform: samples)
        }
        .frame(width: size.width, height: size.height)
        .padding(18)
        .background(Color(red: 0.93, green: 0.93, blue: 0.92))
    }
}

@Suite(.serialized) @MainActor struct TinyEnvelopeRenderTests {
    @Test func rendersEveryState() throws {
        _ = NSApplication.shared
        let cases: [(String, Bool, Double?, Bool)] = [
            ("h-loud", false, 0.75, false), ("h-soft", false, 0.18, false), ("h-quiet", false, nil, false),
            ("h-hover", false, 0.5, true), ("v-loud", true, 0.75, false), ("v-quiet", true, nil, false),
            ("v-hover", true, 0.5, true),
        ]
        for (name, vertical, level, controls) in cases {
            let host = NSHostingView(rootView: BubbleRenderHost(vertical: vertical, level: level, controls: controls))
            let fit = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; host.frame = NSRect(origin: .zero, size: fit)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 500)
            if let out = ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"] {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("bubble-\(name).png"))
            }
        }
    }
}
