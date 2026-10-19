


//
import Foundation

/// Finds the spoken phrases that point at something on screen ("this file", "the terminal").
public enum DeicticSpeech {
    public static let phrases: [String] = [
        "this file", "that file", "the open file", "the file on screen", "the file i'm looking at",
        "this function", "this test", "that test", "this folder", "this directory", "this repo",
        "the terminal", "this terminal", "this one here", "what's on my screen", "what i'm looking at",
        "on my screen", "on screen",
    ]

    /// Phrase token arrays keyed by first word, longest first so "what's on my screen"
    /// wins over "on my screen". One dictionary lookup per spoken word keeps long talks fast.
    private static let byFirstWord: [String: [(phrase: String, words: [String])]] = Dictionary(
        grouping: phrases.map { (phrase: $0, words: LexicalFidelity.words(in: $0)) },
        by: { $0.words[0] }
    ).mapValues { $0.sorted { $0.words.count > $1.words.count } }

    private static let pauseTag = try? NSRegularExpression(pattern: #"\*\[pause \d+\.\d{4}\]\* ?"#)

    /*
    Whole-word match on LexicalFidelity tokens after measured pause tags are removed, so
    "This FILE," matches and "thistle" does not. A match consumes its words, so a longer
    phrase is not also reported as the shorter phrase inside it. Order is first occurrence.
    */
    public static func detect(in text: String) -> [String] {
        var source = text
        if text.contains("[pause "), let pauseTag {
            source = pauseTag.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        let words = LexicalFidelity.words(in: source)
        var found: [String] = []
        var index = 0
        scan: while index < words.count {
            for candidate in byFirstWord[words[index]] ?? [] where index + candidate.words.count <= words.count {
                if words[index..<(index + candidate.words.count)].elementsEqual(candidate.words) {
                    if !found.contains(candidate.phrase) { found.append(candidate.phrase) }
                    index += candidate.words.count
                    continue scan
                }
            }
            index += 1
        }
        return found
    }
}


//
/// One file or folder named by a window title.
public struct WindowTitleReference: Equatable, Sendable {
    public enum Kind: String, Sendable { case file, directory }
    public var kind: Kind
    public var name: String
    public var app: String

    public init(kind: Kind, name: String, app: String) {
        self.kind = kind
        self.name = name
        self.app  = app
    }
}

/// Reads editor and terminal window titles. Anything that does not fit a known shape is nil.
public enum WindowTitleParser {
    /// Chats, browsers, Messages, Tokens itself and Finder: their titles are private or carry no path.
    public static let excludedBundleIDs: Set<String> = [
        "com.openai.codex", "com.anthropic.claudefordesktop", "com.apple.Safari", "com.google.Chrome",
        "org.mozilla.firefox", "com.apple.MobileSMS", "com.tinkr.tokens.community.macos",
        "com.tinkr.tokens.community.dev.macos", "com.apple.finder",
    ]

    private enum Grammar { case firstFile, anyFile, path, iTermPath }

    /*
    Allow-list: an app not named here yields nil, so a browser or chat whose page title looks
    like "example.com - Brave" never reaches a paste. The VS Code forks and Sublime Text use
    the "file — folder — app" shape; their titles were not checked live.
    */
    private static let known: [String: (app: String, grammar: Grammar)] = [
        "com.todesktop.230313mzl4w4u92": ("Cursor", .firstFile),
        "com.microsoft.VSCode": ("VS Code", .firstFile),
        "com.microsoft.VSCodeInsiders": ("VS Code", .firstFile),
        "com.vscodium": ("VSCodium", .firstFile),
        "com.exafunction.windsurf": ("Windsurf", .firstFile),
        "com.sublimetext.4": ("Sublime Text", .firstFile),
        "com.apple.dt.Xcode": ("Xcode", .anyFile),
        "com.apple.Terminal": ("Terminal", .path),
        "com.googlecode.iterm2": ("iTerm", .iTermPath),
        "com.mitchellh.ghostty": ("Ghostty", .path),
        "dev.warp.Warp-Stable": ("Warp", .path),
        "dev.zed.Zed": ("Zed", .firstFile),
    ]

    /// No spaces, and an extension that starts with a letter, so "v1.2" is not a file.
    private static let fileShape = try? NSRegularExpression(pattern: #"^\S*\.[A-Za-z]\w{0,9}$"#)
    private static let iTermShape = try? NSRegularExpression(pattern: #"\(((?:~|/)[^()]*)\)\s*$"#)

    public static func parse(title: String, bundleIdentifier: String?) -> WindowTitleReference? {
        if let bundleIdentifier, excludedBundleIDs.contains(bundleIdentifier) { return nil }
        let segments = segments(of: title)
        guard let first = segments.first,
              let bundleIdentifier, let entry = known[bundleIdentifier] else { return nil }
        switch entry.grammar {
        case .firstFile:
            return looksLikeFile(first) ? reference(.file, first, entry.app) : nil
        case .anyFile:
            return segments.first(where: looksLikeFile).flatMap { reference(.file, $0, entry.app) }
        case .path:
            return isPath(first) ? reference(.directory, first, entry.app) : nil
        case .iTermPath:
            if isPath(first) { return reference(.directory, first, entry.app) }
            guard let iTermShape,
                  let match = iTermShape.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
                  let range = Range(match.range(at: 1), in: first) else { return nil }
            return reference(.directory, String(first[range]), entry.app)
        }
    }

    /// Splits on " — " and " - ", trims, and drops the unsaved-change dot.
    static func segments(of title: String) -> [String] {
        title.replacingOccurrences(of: " — ", with: "\u{1F}")
            .replacingOccurrences(of: " - ", with: "\u{1F}")
            .split(separator: "\u{1F}")
            .map { segment in
                var text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                for dot in ["● ", "• "] where text.hasPrefix(dot) { text.removeFirst(dot.count) }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    static func looksLikeFile(_ segment: String) -> Bool {
        guard let fileShape else { return false }
        return fileShape.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)) != nil
    }

    static func isPath(_ segment: String) -> Bool {
        segment.hasPrefix("~") || segment.hasPrefix("/")
    }

    private static func reference(_ kind: WindowTitleReference.Kind, _ raw: String, _ app: String)
        -> WindowTitleReference? {
        sanitized(raw).map { WindowTitleReference(kind: kind, name: $0, app: app) }
    }

    /// Markdown and table characters dropped from names and the note. Not "_" (see sanitized).
    public static let strippedCharacters = "*`<>[]{}\\|#"

    /*
    Removes markdown characters and newlines, squeezes whitespace, caps at 120 characters.
    "_" is kept: source_map.py must stay greppable, and intraword "_" is not emphasis.
    */
    static func sanitized(_ raw: String) -> String? {
        let squeezed = raw.filter { !strippedCharacters.contains($0) }
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let capped = String(squeezed.prefix(120)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }
}


//
/// Formats the `> *On screen at key press:* …` metadata line.
public enum ScreenReferenceNote {
    public static let label = "On screen at key press"
    public static let maximumCharacters = 320
    public static let maximumReferences = 3

    /// Nil unless the speech pointed at the screen and at least one title named a file or folder.
    public static func line(deictics: [String], references: [WindowTitleReference]) -> String? {
        guard !deictics.isEmpty, !references.isEmpty else { return nil }
        var unique: [WindowTitleReference] = []
        for reference in references where !unique.contains(reference) { unique.append(reference) }
        let text = unique.prefix(maximumReferences).map { reference in
            reference.kind == .file ? "\(reference.name) in \(reference.app)"
                : "\(reference.app) at \(reference.name)"
        }.joined(separator: " · ")
        // ThinkingHeaderNote.line's set minus "_", so snake_case names survive; one line.
        let body = text.filter { !WindowTitleParser.strippedCharacters.contains($0) }
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard body.contains(where: \.isLetter) else { return nil }
        let line = "> *\(label):* \(body)"
        return line.count <= maximumCharacters ? line : nil
    }
}

