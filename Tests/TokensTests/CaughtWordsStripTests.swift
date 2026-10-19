
import AppKit
import SwiftUI
import Testing
@testable import Tokens

struct CaughtWordsGeometryTests {
    private func word(end: Double, final: Bool = false) -> TimedWord {
        TimedWord(text: "w", start: max(0, end - 0.3), end: end, isFinal: final)
    }

    @Test func newestWordSitsAtTheNewestEdge() {
        let marks = CaughtWordsStrip.marks(words: [word(end: 6), word(end: 5)], stableWordCount: 0,
                                           now: 6, window: 4, length: 66)
        #expect(marks.count == 2)
        #expect(marks[0].position == 66)
        #expect(abs(marks[1].position - 0.75 * 66) < 0.0001)
    }

    @Test func wordsOlderThanTheWindowAreCulled() {
        let marks = CaughtWordsStrip.marks(words: [word(end: 1.9), word(end: 2)], stableWordCount: 0,
                                           now: 6, window: 4, length: 66)
        #expect(marks.count == 1)
        #expect(marks[0].position == 0)
    }

    @Test func aWordEndingJustAfterNowClampsToTheNewestEdge() {
        let marks = CaughtWordsStrip.marks(words: [word(end: 6.05)], stableWordCount: 0,
                                           now: 6, window: 4, length: 66)
        #expect(marks == [CaughtWordsStrip.Mark(position: 66, final: false)])
    }

    @Test func untimedEmptyAndDegenerateInputsDrawNothing() {
        let untimed = TimedWord(text: "w", start: -1, end: -1, isFinal: false)
        #expect(CaughtWordsStrip.marks(words: [untimed, untimed], stableWordCount: 2, now: 6, window: 4, length: 66).isEmpty)
        let mixed = CaughtWordsStrip.marks(words: [untimed, word(end: 5.5)], stableWordCount: 0, now: 6, window: 4, length: 66)
        #expect(mixed.count == 1)
        #expect(CaughtWordsStrip.marks(words: [], stableWordCount: 0, now: 6, window: 4, length: 66).isEmpty)
        #expect(CaughtWordsStrip.marks(words: [word(end: 5.5)], stableWordCount: 0, now: .nan, window: 4, length: 66).isEmpty)
        #expect(CaughtWordsStrip.marks(words: [word(end: 5.5)], stableWordCount: 0, now: .infinity, window: 4, length: 66).isEmpty)
        #expect(CaughtWordsStrip.marks(words: [word(end: 5.5)], stableWordCount: 0, now: 6, window: 4, length: 0).isEmpty)
        #expect(CaughtWordsStrip.marks(words: [word(end: 5.5)], stableWordCount: 0, now: 6, window: 0, length: 66).isEmpty)
    }

    @Test func settledPrefixOrFinalFlagFillsTheDotOtherwiseHollow() {
        let words = [word(end: 5.0), word(end: 5.2), word(end: 5.4, final: true), word(end: 5.6)]
        let marks = CaughtWordsStrip.marks(words: words, stableWordCount: 2, now: 6, window: 4, length: 66)
        #expect(marks.map(\.final) == [true, true, true, false])
        // A settled count larger than the word list is fine: everything is settled.
        let all = CaughtWordsStrip.marks(words: words, stableWordCount: 99, now: 6, window: 4, length: 66)
        #expect(all.map(\.final) == [true, true, true, true])
        // No latch: the same word goes hollow again if the next snapshot un-settles it.
        let revised = CaughtWordsStrip.marks(words: [word(end: 5.0)], stableWordCount: 0, now: 6, window: 4, length: 66)
        #expect(revised.map(\.final) == [false])
    }

    @Test func dotTrackRunsFromTheEnvelopesOldestStrokeToItsNewest() {
        // Horizontal readout 70pt: the envelope is inset 2pt at each end → 2…68.
        let h = CaughtWordsStrip.track(along: 70)
        #expect(h.start == 2 && h.length == 66)
        // Upright readout 42pt → 2…40.
        let v = CaughtWordsStrip.track(along: 42)
        #expect(v.start == 2 && v.length == 38)
        let inner = TinyEnvelope.track(along: 66)
        #expect(inner.start == 0 && inner.length == 66)
    }

    @Test func switchIsOffUntilTurnedOn() {
        let suite = "live-surface-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!LiveSurfacePreference.load(.caughtWords, defaults))
        LiveSurfacePreference.save(true, for: .caughtWords, defaults)
        #expect(LiveSurfacePreference.load(.caughtWords, defaults))
        LiveSurfacePreference.save(false, for: .caughtWords, defaults)
        #expect(!LiveSurfacePreference.load(.caughtWords, defaults))
    }
}

// MARK: - Offscreen renders

private enum CaughtFixture {
    static let now = 6.0
    /// Four settled words then three still provisional; the 4 s window shows six, the 3 s window five.
    static var words: [TimedWord] {
        let ends: [(Double, Bool)] = [(1.5, true), (2.9, true), (3.6, true), (4.2, true), (4.9, false), (5.4, false), (5.85, false)]
        return ends.map { TimedWord(text: "w", start: $0.0 - 0.3, end: $0.0, isFinal: false) }
    }
    static var caught: CaughtWords { CaughtWords(words: words, stableWordCount: 4, now: now) }
    /// Fast speech: twelve provisional words a quarter second apart, the newest ending now.
    static var dense: CaughtWords {
        CaughtWords(words: (0..<12).reversed().map { i in
            let end = now - Double(i) * 0.25
            return TimedWord(text: "w", start: end - 0.2, end: end, isFinal: false)
        }, stableWordCount: 0, now: now)
    }
    static func wave(_ level: Double) -> [Double] { (0..<40).map { level * (0.55 + 0.45 * abs(sin(Double($0) * 0.9))) } }
}

private struct CaughtWordsRenderHost: View {
    let vertical: Bool
    var audioConfirmed = true
    var pause: LiveThinkingPause? = nil
    var waveform: [Double] = CaughtFixture.wave(0.75)
    var caught: CaughtWords?
    var dark = false
    var body: some View {
        let size = vertical ? BubbleLayout.compactVerticalSize : panelDefaultSize
        BubbleControlSurface(vertical: vertical, cancelLabel: "Discard talk", finishLabel: "Finish and paste",
                             cancel: {}, finish: {}, showsControls: false,
                             ghost: TokensThinkingBubble.isGhost(audioConfirmed: audioConfirmed, pause: pause)) {
            TokensBubbleReadout(vertical: vertical, dev: false, shortcutName: "Left Option",
                                destinationLabel: "Claude · text area", audioConfirmed: audioConfirmed,
                                pause: pause, waveform: waveform, caught: caught)
        }
        .frame(width: size.width, height: size.height)
        .padding(18)
        // Light: the existing bubble render page. Dark: a dark desktop / dark app behind the pill.
        .background(dark ? Color(red: 0.11, green: 0.12, blue: 0.13) : Color(red: 0.93, green: 0.93, blue: 0.92))
    }
}

@Suite(.serialized) @MainActor struct CaughtWordsRenderTests {
    private func render(_ view: CaughtWordsRenderHost) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let fit = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; host.frame = NSRect(origin: .zero, size: fit)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func write(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 500)
        if let out = ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        }
    }

    /// Coral-ish pixels (red well above green) inside a rectangle given in points of the render.
    private func coralPixels(_ bitmap: NSBitmapImageRep, points rect: CGRect, width: CGFloat) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / width
        var count = 0
        for y in Int((rect.minY * scale).rounded(.up))..<Int((rect.maxY * scale).rounded(.down)) {
            for x in Int((rect.minX * scale).rounded(.up))..<Int((rect.maxX * scale).rounded(.down)) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent - c.greenComponent > 0.12, c.redComponent > 0.25 { count += 1 }
            }
        }
        return count
    }

    @Test func rendersEveryState() throws {
        let cases: [(String, CaughtWordsRenderHost)] = [
            ("h-talking", CaughtWordsRenderHost(vertical: false, caught: CaughtFixture.caught)),
            ("h-pause", CaughtWordsRenderHost(vertical: false, pause: LiveThinkingPause(seconds: 2.1, estimated: false),
                                              caught: CaughtFixture.caught)),
            ("h-starting", CaughtWordsRenderHost(vertical: false, audioConfirmed: false, waveform: [],
                                                 caught: CaughtWords(words: [], stableWordCount: 0, now: 0.4))),
            ("h-dense", CaughtWordsRenderHost(vertical: false, waveform: CaughtFixture.wave(0.95), caught: CaughtFixture.dense)),
            ("h-loudfull", CaughtWordsRenderHost(vertical: false, waveform: Array(repeating: 1, count: 40),
                                                 caught: CaughtFixture.caught)),
            ("v-talking", CaughtWordsRenderHost(vertical: true, caught: CaughtFixture.caught)),
            ("v-pause", CaughtWordsRenderHost(vertical: true, pause: LiveThinkingPause(seconds: 2.1, estimated: false),
                                              caught: CaughtFixture.caught)),
            ("v-loudfull", CaughtWordsRenderHost(vertical: true, waveform: Array(repeating: 1, count: 40),
                                                 caught: CaughtFixture.caught)),
        ]
        for (name, host) in cases {
            try write(try render(host), "caught-words-\(name)")
            var dark = host; dark.dark = true
            try write(try render(dark), "caught-words-\(name)-dark")
        }
        // Switched off: the plain talking envelope (compare TinyEnvelopeRenderTests' bubble-h-loud.png).
        try write(try render(CaughtWordsRenderHost(vertical: false, caught: nil)), "caught-words-h-off")
    }

    /*
    Clear air between the wave and the dots at full loudness. Render coordinates in points:
    host padding 18. Horizontal readout is x 27…97 of the pill; with the 4pt gutter the bar caps
    end at readout y 19 and dot edges start at y 22.2 (centres 23), so y 19.6…21.8 must hold no
    coral. Upright readout starts at pill x 5 and y 27; caps end at readout x 15 and dot edges
    start at x 18.2 (centres 19), so x 15.6…17.8 must hold none.
    */
    @Test func wavesAndDotsNeverTouchAtFullLoudness() throws {
        let h = try render(CaughtWordsRenderHost(vertical: false, waveform: Array(repeating: 1, count: 40),
                                                 caught: CaughtFixture.caught))
        let hWidth = panelDefaultSize.width + 36
        #expect(coralPixels(h, points: CGRect(x: 18 + 27, y: 18 + 19.6, width: 70, height: 2.2), width: hWidth) == 0)
        // Nothing below the dots either: the rim stays clear.
        #expect(coralPixels(h, points: CGRect(x: 18 + 27, y: 18 + 24.4, width: 70, height: 1.6), width: hWidth) == 0)
        // Sanity: the bars and the dots themselves are there.
        #expect(coralPixels(h, points: CGRect(x: 18 + 27, y: 18 + 4, width: 70, height: 14), width: hWidth) > 0)
        #expect(coralPixels(h, points: CGRect(x: 18 + 27, y: 18 + 22, width: 70, height: 2), width: hWidth) > 0)

        let v = try render(CaughtWordsRenderHost(vertical: true, waveform: Array(repeating: 1, count: 40),
                                                 caught: CaughtFixture.caught))
        let vWidth = BubbleLayout.compactVerticalSize.width + 36
        #expect(coralPixels(v, points: CGRect(x: 18 + 5 + 15.6, y: 18 + 27, width: 2.2, height: 42), width: vWidth) == 0)
        #expect(coralPixels(v, points: CGRect(x: 18 + 5 + 20.4, y: 18 + 27, width: 1.6, height: 42), width: vWidth) == 0)
        #expect(coralPixels(v, points: CGRect(x: 18 + 5 + 18, y: 18 + 27, width: 2, height: 42), width: vWidth) > 0)
    }
}
