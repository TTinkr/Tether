


import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// Exercise TextKit's rendered wrapping and editing geometry without using the user's clipboard,
/// dictionary, microphone or production preferences. One leading paper row leaves caret clearance; the first baseline is y=112.
@Suite(.serialized) @MainActor struct PencilEditorBaselineTests {
    @Test(arguments: [false, true]) func explicitAndWrappedLinesRemainOnPaperRules(startsAtFirstRule: Bool) async throws {
        _ = NSApplication.shared
        let text = "Green notebook\nCafé and blue pencil\nA longer fictional dictionary term that wraps across several paper rows"
        let host = NSHostingView(rootView: TokensPencilEditor(text: .constant(text), label: "Fictional dictionary", startsAtFirstRule: startsAtFirstRule))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 168),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 168)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let view = try #require(editor(in: host))
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        var baselines: [CGFloat] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
            rect, _, _, glyphs, _ in
            baselines.append(view.textContainerOrigin.y + rect.minY + layout.location(forGlyphAt: glyphs.location).y)
        }
        let scroll = try #require(view.enclosingScrollView)
        #expect(scroll.contentView is TokensPaperClipView)
        #expect(abs(scroll.contentView.bounds.minY - (startsAtFirstRule ? TokensUI.paperCell : 0)) < 0.5)
        for offset in [17.0, 113.0, 10000.0] {
            let constrained = scroll.contentView.constrainBoundsRect(NSRect(x: 0, y: offset, width: 180, height: 168))
            #expect(abs(constrained.origin.y / TokensUI.paperCell - (constrained.origin.y / TokensUI.paperCell).rounded()) < 0.001)
        }
        #expect(view.string == text)
        #expect(baselines.count >= 5)
        for (index, baseline) in baselines.enumerated() {
            #expect(abs(baseline - CGFloat(index + 2) * TokensUI.paperCell) < 0.5)
        }
    }
}

