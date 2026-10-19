


import AppKit
import SwiftUI
import Testing
@testable import Tokens

@MainActor private final class CopyRenderFixture: ObservableObject {
    @Published var active = false
    @Published var revision = UUID()
}

private struct CopyRenderHost: View {
    @ObservedObject var fixture: CopyRenderFixture
    let reduceMotion: Bool
    var body: some View {
        TokensWritingBox(text: .constant("Green notebook. Blue pencil.\nKeep every word I say."),
                         editable: false, label: "Copy feedback fixture")
            .tokensCopyFeedback(active: fixture.active, revision: fixture.revision, reduceMotionOverride: reduceMotion)
            .padding(24).background(TokensPaper())
    }
}

@Suite(.serialized) @MainActor struct CopyFeedbackRenderTests {
    @Test func surfacePulseSettlesAndReducedMotionStaysSteady() async throws {
        _ = NSApplication.shared
        for reduced in [false, true] {
            let fixture = CopyRenderFixture()
            let host = NSHostingView(rootView: CopyRenderHost(fixture: fixture, reduceMotion: reduced).preferredColorScheme(.light))
            let size = NSSize(width: 600, height: 240)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
            func render(_ phase: String? = nil) throws -> Data {
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                if let phase, let out = ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"] {
                    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("copy-\(reduced ? "reduced" : "animated")-\(phase).png"))
                }
                return data
            }
            // The first bitmap can itself finish TextKit layout and move the clip viewport.
            // Warm up the inactive fixture until both its geometry and pixels agree across
            // main-queue turns. Never let initial editor reflow become the pulse baseline.
            func editor(in view: NSView) -> NSTextView? {
                if let editor = view as? NSTextView { return editor }
                return view.subviews.compactMap { editor(in: $0) }.first
            }
            var previousPixels: Data?
            var previousGeometry: [CGRect]?
            var stablePasses = 0
            for _ in 0..<12 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
                host.layoutSubtreeIfNeeded()
                let textView = try #require(editor(in: host))
                let layout = try #require(textView.layoutManager)
                let container = try #require(textView.textContainer)
                let scroll = try #require(textView.enclosingScrollView)
                layout.ensureLayout(for: container)
                let pixels = try render()
                let geometry = [textView.frame, scroll.contentView.bounds,
                                CGRect(origin: textView.textContainerOrigin, size: container.size),
                                layout.usedRect(for: container)]
                if pixels == previousPixels && geometry == previousGeometry {
                    stablePasses += 1
                } else {
                    stablePasses = 0
                }
                previousPixels = pixels
                previousGeometry = geometry
                if stablePasses == 3 { break }
            }
            try #require(stablePasses == 3, "Inactive copy fixture must settle before taking its baseline")
            let before = try render("before")
            fixture.active = true; fixture.revision = UUID()
            try await Task.sleep(for: .milliseconds(180))
            let during = try render("during")
            #expect(before != during)
            try await Task.sleep(for: .milliseconds(700))
            let settled = try render("settled")
            #expect(reduced ? during == settled : before == settled)
            fixture.active = false
            try await Task.sleep(for: .milliseconds(100))
            #expect(try render("cleared") == before)
        }
    }
}

