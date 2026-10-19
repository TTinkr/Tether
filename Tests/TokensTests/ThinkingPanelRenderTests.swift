


//
/*
ThinkingPanelRenderTests.swift
Owns: optional offscreen native layout evidence with fictional content only.
Never: order a window forward, capture the desktop, or access a microphone.
*/


import AppKit
import SwiftUI
import Testing
@testable import Tokens

@Suite(.serialized) struct ThinkingPanelRenderTests {
    @Test @MainActor func renderQuestionPages() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_PANEL_RENDER_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state   = ThinkingPanelState()
        state.notes = ""
        state.receive(.init(text: "Where should the switch go?\nCould the base be smaller?",
                            state: .done, model: "fictional fixture", generation: 1))
        for (name, size) in [("question-pages", NSSize(width: 560, height: 364)),
                             ("question-pages-dark", NSSize(width: 560, height: 364)),
                             ("question-pages-narrow", NSSize(width: 340, height: 500)),
                             ("question-pages-tiny", NSSize(width: 88, height: 56))] {
            let view = NSHostingView(rootView: ThinkingPanelView(state: state, collapse: {}, expand: {}, dismiss: {}))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance           = NSAppearance(named: name.hasSuffix("dark") ? .darkAqua : .aqua)
            window.contentView          = view
            view.frame                  = NSRect(origin: .zero, size: size)
            try await Task.sleep(nanoseconds: 150_000_000)
            view.layoutSubtreeIfNeeded()
            if name == "question-pages" {
                let editor   = try #require(Self.editor(in: view))
                let original = state.notes
                editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
                editor.insertText("\nNative editor check.", replacementRange: editor.selectedRange())
                try await Task.sleep(nanoseconds: 50_000_000)
                #expect(state.notes == original + "\nNative editor check.")
                state.notes = original
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"))
            #expect(!window.isVisible)
            window.close()
        }
    }

    @MainActor private static func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        for child in view.subviews {
            if let text = editor(in: child) { return text }
        }
        return nil
    }
}

