


//
import Foundation
import Testing
@testable import Tokens

@MainActor
@Suite("Screen reference sampler")
struct ScreenReferenceSamplerTests {
    static let cursorLine = "> *On screen at key press:* TalkModel+Capture.swift in Cursor"
    static let injected: [(bundleIdentifier: String?, title: String)] = [
        ("com.todesktop.230313mzl4w4u92", "● TalkModel+Capture.swift — Tokens — Cursor"),
        ("com.openai.codex", "Codex — some private thread name"),
    ]

    func withSuite(_ body: (UserDefaults, ScreenReferenceSampler) throws -> Void) throws {
        let suite = "ScreenReferenceSamplerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, ScreenReferenceSampler(defaults: defaults))
    }

    @Test func offByDefaultAndKeepsNothing() throws {
        try withSuite { defaults, sampler in
            #expect(defaults.object(forKey: ScreenReferenceSampler.key) == nil)
            #expect(!sampler.enabled)
            sampler.handle(.capturing)
            #expect(sampler.samples.isEmpty)
            sampler.inject(Self.injected)
            #expect(sampler.lines(for: "fix this file") == [])
        }
    }

    @Test func samplesLiveUntilTheTalkEnds() throws {
        try withSuite { defaults, sampler in
            defaults.set(true, forKey: ScreenReferenceSampler.key)
            sampler.inject(Self.injected)
            sampler.handle(.finalizing)
            sampler.handle(.delivered)
            #expect(sampler.samples.count == 2)
            #expect(sampler.lines(for: "fix this file") == [Self.cursorLine])
            sampler.handle(.idle)
            #expect(sampler.samples.isEmpty)
            #expect(sampler.lines(for: "fix this file") == [])
            sampler.inject(Self.injected)
            sampler.handle(.failed)
            #expect(sampler.samples.isEmpty)
        }
    }

    @Test func chatTitlesNeverAppearAndPlainTalkGetsNoNote() throws {
        try withSuite { defaults, sampler in
            defaults.set(true, forKey: ScreenReferenceSampler.key)
            sampler.inject(Self.injected)
            let lines = sampler.lines(for: "fix this file")
            #expect(lines == [Self.cursorLine])
            #expect(!lines.joined().contains("private thread"))
            #expect(!lines.joined().contains("Codex"))
            #expect(sampler.lines(for: "fix the build please") == [])
            sampler.inject([Self.injected[1]])
            #expect(sampler.lines(for: "fix this file") == [])
        }
    }

    /// Fixture title source that counts calls; never touches Accessibility.
    final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let titles: [[(bundleIdentifier: String?, title: String)]]
        /// When set, the first read waits here, so a test can hold an earlier talk's read open.
        let firstReadGate: DispatchSemaphore?
        init(_ titles: [[(bundleIdentifier: String?, title: String)]], holdFirstRead: Bool = false) {
            self.titles = titles
            firstReadGate = holdFirstRead ? DispatchSemaphore(value: 0) : nil
        }
        var count: Int { lock.withLock { calls } }
        func read() -> [(bundleIdentifier: String?, title: String)] {
            let (call, result) = lock.withLock { () -> (Int, [(bundleIdentifier: String?, title: String)]) in
                calls += 1; return (calls, titles[min(calls - 1, titles.count - 1)])
            }
            if call == 1 { firstReadGate?.wait() }
            return result
        }
        /// Waits (bounded) until `n` reads have started.
        func waitForReads(_ n: Int) async {
            for _ in 0..<2_000 where count < n { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    func withSource(_ source: Source, trusted: Bool = true,
                    _ body: (UserDefaults, ScreenReferenceSampler) async throws -> Void) async throws {
        let suite = "ScreenReferenceSamplerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sampler = ScreenReferenceSampler(defaults: defaults, isTrusted: { trusted },
                                             titleSource: { source.read() })
        try await body(defaults, sampler)
    }

    @Test func asyncSampleLandsWhileTheTalkIsLive() async throws {
        let source = Source([Self.injected])
        try await withSource(source) { defaults, sampler in
            defaults.set(true, forKey: ScreenReferenceSampler.key)
            sampler.handle(.capturing)
            await sampler.pendingSample?.value
            #expect(source.count == 1)
            #expect(sampler.samples.map(\.title) == Self.injected.map(\.title))
            #expect(sampler.lines(for: "fix this file") == [Self.cursorLine])
        }
    }

    @Test func lateSampleNeverLandsAfterIdleOrFailed() async throws {
        let source = Source([Self.injected])
        try await withSource(source) { defaults, sampler in
            defaults.set(true, forKey: ScreenReferenceSampler.key)
            for end in [TalkPhase.idle, .failed] {
                sampler.handle(.capturing)
                sampler.handle(end)
                await sampler.pendingSample?.value
                #expect(sampler.samples.isEmpty, "\(end)")
                #expect(sampler.lines(for: "fix this file") == [])
            }
            #expect(source.count == 2)
        }
    }

    @Test func staleSampleFromAnEarlierTalkNeverLands() async throws {
        let later = [(bundleIdentifier: Optional("com.apple.Terminal"), title: "~/Documents/Tinkr — zsh — 80×24")]
        // The first talk's read is held open until the second talk has landed, so the stale
        // result always arrives last; without the gate the two detached reads could swap order.
        let source = Source([Self.injected, later], holdFirstRead: true)
        try await withSource(source) { defaults, sampler in
            defaults.set(true, forKey: ScreenReferenceSampler.key)
            sampler.handle(.capturing)
            let first = sampler.pendingSample
            await source.waitForReads(1)
            sampler.handle(.idle)
            sampler.handle(.capturing)
            let second = sampler.pendingSample
            await second?.value
            #expect(sampler.samples.map(\.title) == later.map(\.title))
            source.firstReadGate?.signal()
            await first?.value
            #expect(source.count == 2)
            #expect(sampler.samples.map(\.title) == later.map(\.title))
        }
    }

    @Test func offOrUntrustedNeverReadsTitles() async throws {
        let source = Source([Self.injected])
        try await withSource(source) { _, sampler in
            sampler.handle(.capturing)                                    // option off
            #expect(sampler.pendingSample == nil)
        }
        try await withSource(source, trusted: false) { defaults, sampler in
            defaults.set(true, forKey: ScreenReferenceSampler.key)
            sampler.handle(.capturing)
            #expect(sampler.pendingSample == nil)
        }
        #expect(source.count == 0)
    }

    @Test func partsAppendsNotesOnlyWithMetadata() {
        let rendered = "# π T\n\n> *1.0s · 2 words · 120 wpm*\n\nhello there"
        let note = Self.cursorLine
        let with = TokensOutputOptions.parts(rendered, metadata: true, headerNotes: [note])
        #expect(with.metadata.hasSuffix("\n" + note))
        #expect(TokensOutputOptions.parts(rendered, metadata: false, headerNotes: [note]).metadata.isEmpty)
        let old = TokensDecoration.parts(rendered, decorated: false)
        let new = TokensOutputOptions.parts(rendered, metadata: true)
        #expect(new.text == old.text && new.marker == old.marker && new.body == old.body
            && new.metadata == old.metadata)
        #expect(TokensOutputOptions.parts(rendered, metadata: false).text == rendered)
    }
}

