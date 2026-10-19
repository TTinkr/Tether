


//
import Foundation
import Testing
@testable import TokensCore

@Suite("Screen reference")
struct ScreenReferenceTests {
    static let cursor = "com.todesktop.230313mzl4w4u92"
    let cursorRef = WindowTitleReference(kind: .file, name: "TalkModel+Capture.swift", app: "Cursor")
    let terminalRef = WindowTitleReference(kind: .directory, name: "~/Documents/Tinkr", app: "Terminal")

    func parse(_ title: String, _ bundle: String?) -> WindowTitleReference? {
        WindowTitleParser.parse(title: title, bundleIdentifier: bundle)
    }

    @Test func everyGrammarParses() {
        let file = WindowTitleReference.Kind.file, dir = WindowTitleReference.Kind.directory
        let cases: [(String, String?, WindowTitleReference)] = [
            ("● TalkModel.swift — Tokens — Cursor", Self.cursor, .init(kind: file, name: "TalkModel.swift", app: "Cursor")),
            ("TalkModel.swift — Tokens — Cursor", Self.cursor, .init(kind: file, name: "TalkModel.swift", app: "Cursor")),
            ("• notes.md — Tokens — Cursor", Self.cursor, .init(kind: file, name: "notes.md", app: "Cursor")),
            ("file.swift - repo - Visual Studio Code", "com.microsoft.VSCode", .init(kind: file, name: "file.swift", app: "VS Code")),
            ("Tokens — TalkModel.swift", "com.apple.dt.Xcode", .init(kind: file, name: "TalkModel.swift", app: "Xcode")),
            ("Tokens — TalkModel.swift — Edited", "com.apple.dt.Xcode", .init(kind: file, name: "TalkModel.swift", app: "Xcode")),
            ("~/Documents/Tinkr — zsh — 80×24", "com.apple.Terminal", .init(kind: dir, name: "~/Documents/Tinkr", app: "Terminal")),
            ("/usr/local — zsh — 80×24", "com.apple.Terminal", .init(kind: dir, name: "/usr/local", app: "Terminal")),
            ("~/Documents/Tinkr — zsh", "com.googlecode.iterm2", .init(kind: dir, name: "~/Documents/Tinkr", app: "iTerm")),
            ("zsh (~/Documents/Tinkr)", "com.googlecode.iterm2", .init(kind: dir, name: "~/Documents/Tinkr", app: "iTerm")),
            ("~/code/tokens", "com.mitchellh.ghostty", .init(kind: dir, name: "~/code/tokens", app: "Ghostty")),
            ("~/code/tokens — zsh", "dev.warp.Warp-Stable", .init(kind: dir, name: "~/code/tokens", app: "Warp")),
            ("file.swift — repo", "dev.zed.Zed", .init(kind: file, name: "file.swift", app: "Zed")),
            ("main.py - Sublime Text", "com.sublimetext.4", .init(kind: file, name: "main.py", app: "Sublime Text")),
            ("source_map.py — Tinkr — Cursor", Self.cursor, .init(kind: file, name: "source_map.py", app: "Cursor")),
            ("~/Documents/my_project — -zsh — 80×24", "com.apple.Terminal",
             .init(kind: dir, name: "~/Documents/my_project", app: "Terminal")),
            ("__init__.py — api — VSCodium", "com.vscodium", .init(kind: file, name: "__init__.py", app: "VSCodium")),
            ("app.tsx — web — Windsurf", "com.exafunction.windsurf", .init(kind: file, name: "app.tsx", app: "Windsurf")),
        ]
        for (title, bundle, expected) in cases {
            #expect(parse(title, bundle) == expected, "\(title)")
        }
    }

    @Test func privateAppsAndUnparsedTitlesAreNil() {
        for bundle in ["com.openai.codex", "com.anthropic.claudefordesktop", "com.apple.Safari", "com.google.Chrome",
                       "com.apple.finder", "com.tinkr.tokens.community.macos", "com.tinkr.tokens.community.dev.macos",
                       "org.mozilla.firefox", "com.apple.MobileSMS"] {
            #expect(parse("● TalkModel.swift — Tokens — Cursor", bundle) == nil, "\(bundle)")
            #expect(parse("~/Documents/Tinkr — zsh — 80×24", bundle) == nil, "\(bundle)")
        }
        #expect(parse("Tinkr — -zsh — 80×24", "com.apple.Terminal") == nil)
        #expect(parse("Welcome — Cursor", Self.cursor) == nil)
        // Allow-list only: browsers and unknown apps are nil even for domain- or file-shaped titles.
        for bundle in ["com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac",
                       "com.google.Chrome.canary", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
                       "com.unknown.app"] {
            #expect(parse("example.com - Brave", bundle) == nil, "\(bundle)")
            #expect(parse("main.py - Some Editor", bundle) == nil, "\(bundle)")
        }
        #expect(parse("main.py - Sublime Text", nil) == nil)
        #expect(parse("Tokens — v1.2 — Edited", "com.apple.dt.Xcode") == nil)  // extension must start with a letter
        #expect(parse("general - Team - Slack", "com.tinyspeck.slackmacgap") == nil)
        #expect(parse("Re: report.pdf — Inbox", nil) == nil)          // spaces → not a file
        #expect(parse("", Self.cursor) == nil)
    }

    @Test func detectsWholeWordPhrasesInOrder() {
        #expect(DeicticSpeech.detect(in: "Please fix this file, and run the test that's on screen.")
            == ["this file", "on screen"])
        #expect(DeicticSpeech.detect(in: "*[pause 1.5000]* this file") == ["this file"])
        #expect(DeicticSpeech.detect(in: "This FILE, then THE terminal") == ["this file", "the terminal"])
        #expect(DeicticSpeech.detect(in: "a thistle in this filed report").isEmpty)
        #expect(DeicticSpeech.detect(in: "fix what's on my screen") == ["what's on my screen"])
        #expect(DeicticSpeech.detect(in: "fix this file then this file again") == ["this file"])
    }

    @Test func ordinaryTalkIsFastAndEmpty() {
        let vocabulary = ["please", "make", "the", "build", "green", "and", "check", "tests", "again", "now"]
        let text = (0..<2_000).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")
        let clock = ContinuousClock()
        var result: [String] = ["unset"]
        let elapsed = clock.measure { result = DeicticSpeech.detect(in: text) }
        #expect(result.isEmpty)
        #expect(elapsed < .milliseconds(100))   // generous for loaded CI; 200k words is ~240 ms, so a quadratic regression still fails
    }

    @Test func noteIsExact() {
        #expect(ScreenReferenceNote.line(deictics: ["this file"], references: [cursorRef, terminalRef])
            == "> *On screen at key press:* TalkModel+Capture.swift in Cursor · Terminal at ~/Documents/Tinkr")
    }

    @Test func snakeCaseNamesSurviveToTheLine() throws {
        let file = try #require(parse("source_map.py — Tinkr — Cursor", Self.cursor))
        let dir = try #require(parse("~/Documents/my_project — -zsh — 80×24", "com.apple.Terminal"))
        #expect(ScreenReferenceNote.line(deictics: ["this file"], references: [file, dir])
            == "> *On screen at key press:* source_map.py in Cursor · Terminal at ~/Documents/my_project")
    }

    @Test func noteNeedsBothPartsAndCapsAtThree() {
        #expect(ScreenReferenceNote.line(deictics: ["this file"], references: []) == nil)
        #expect(ScreenReferenceNote.line(deictics: [], references: [cursorRef]) == nil)
        let refs = (1...4).map { WindowTitleReference(kind: .file, name: "f\($0).swift", app: "Zed") }
        let line = ScreenReferenceNote.line(deictics: ["this file"], references: refs)
        #expect(line == "> *On screen at key press:* f1.swift in Zed · f2.swift in Zed · f3.swift in Zed")
    }

    @Test func hostileTitlesAreSanitised() throws {
        let long = String(repeating: "x", count: 400)
        let parsed = try #require(parse("*`<b>\(long).swift — repo — Cursor", Self.cursor))
        #expect(parsed.name.count <= 120)
        #expect(!parsed.name.contains(where: { "*`<>".contains($0) }))
        let hostile = WindowTitleReference(kind: .file, name: "a*b`c<d\ne#[x]\(long)", app: "Cursor")
        let line = ScreenReferenceNote.line(deictics: ["this file"], references: [hostile])
        #expect(line == nil)                                             // > 320 characters
        let short = WindowTitleReference(kind: .file, name: "a*b`c<d\ne#[x]_|{}.swift", app: "Cursor")
        let note = try #require(ScreenReferenceNote.line(deictics: ["this file"], references: [short]))
        let text = try #require(note.components(separatedBy: ":* ").last)
        #expect(!note.contains(where: { $0.isNewline }))
        #expect(!text.contains(where: { WindowTitleParser.strippedCharacters.contains($0) }))
        #expect(note.count <= 320)
        #expect(note == "> *On screen at key press:* abcd ex_.swift in Cursor")
    }
}

