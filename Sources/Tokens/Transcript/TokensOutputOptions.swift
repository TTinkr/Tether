import Foundation

/// New opt-in keys intentionally do not inherit the old always-on envelope.
/// Reading missing preferences has no side effects.
enum TokensOutputOptions {
    static let metadataKey = "TokensIncludeMetadata.v1"
    /// "[thinking 5.24s]" pause lines in what is pasted; off unless turned on (build 88).
    static let thinkingKey = "TokensIncludeThinking.v1"
    static let characterTagsKey = "TokensIncludeCharacterTags.v1"
    static let numberTagsKey = "TokensIncludeNumberTags.v1"

    /// Character tags (spelled letters) are on until the person turns them off
    /// (since 2026-10-14). A saved choice always wins; metadata stays opt-in.
    static func characterTags(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: characterTagsKey) as? Bool ?? true
    }

    /// Number tags got their own switch on 2026-10-14. Until it is set, it follows the old shared
    /// character-tags switch, so anyone who turned tags off keeps both off.
    static func numberTags(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: numberTagsKey) as? Bool ?? characterTags(in: defaults)
    }

    /// Saving the letters switch first pins the number switch's current value, so turning
    /// letters off never also turns numbers off on the next launch.
    static func setCharacterTags(_ enabled: Bool, in defaults: UserDefaults) {
        if defaults.object(forKey: numberTagsKey) == nil {
            defaults.set(numberTags(in: defaults), forKey: numberTagsKey)
        }
        defaults.set(enabled, forKey: characterTagsKey)
    }

    static func body(_ raw: String, characterTags: Bool, numberTags: Bool) -> String {
        let talk = CharacterTalk.render(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characterTags || numberTags else { return talk.deliveryText }
        return tags(in: talk.markdownText, characters: characterTags, numbers: numberTags)
    }

    /// CharacterTalk writes its spans as italic `*<char>RILEY</char>*` and `*<num>1 2 3</num>*`.
    /// Tokens delivers plain `<char>RILEY</char>` and `<num>1 2 3</num>` (since 2026-10-14); a kind
    /// that is switched off is unwrapped to its letters or digits, exactly as deliveryText has them.
    static func tags(in markdown: String, characters: Bool, numbers: Bool) -> String {
        var text = markdown
        for (name, on) in [("char", characters), ("num", numbers)] {
            text = text.replacingOccurrences(of: #"\*<\#(name)>(.*?)</\#(name)>\*"#,
                                             with: on ? "<\(name)>$1</\(name)>" : "$1",
                                             options: .regularExpression)
        }
        // No spaces in number tags (UX review): single digits join, <num>1234567</num>; a run
        // with a longer number joins with commas, <num>9,10,11</num>, so it never reads as 91011.
        guard numbers else { return text }
        let spans = try! NSRegularExpression(pattern: #"<num>(.*?)</num>"#)
        for match in spans.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let inner = Range(match.range(at: 1), in: text) else { continue }
            let items = text[inner].split(whereSeparator: \.isWhitespace)
            guard items.count > 1 else { continue }
            let digits = items.allSatisfy { $0.count == 1 && $0.first!.isNumber }
            text.replaceSubrange(inner, with: items.joined(separator: digits ? "" : ","))
        }
        return text
    }

    /// `headerNotes` are one-line `> *…*` notes appended to the metadata block (for example
    /// ScreenReferenceSampler.lines). With metadata off they are dropped: raw stays raw.
    /*
    Build 88: two independent switches, both off by default. `thinking` keeps the pause
    notes as "[thinking 5.24s]" lines; off, they are taken out (History keeps them). `metadata`
    adds the one footer line. The thinking layout ("# π …" with its receipt) is split here and
    only its words are delivered; plain text passes through unchanged.
    */
    static func parts(_ rendered: String, metadata: Bool, thinking: Bool = false,
                      headerNotes: [String] = []) -> TokensPromptParts {
        let full = rendered.hasPrefix("# π ") ? TokensDecoration.parts(rendered, decorated: false, headerNotes: headerNotes) : nil
        let words = full.map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) } ?? rendered
        let shown = thinking ? thinkingMarkers(words) : InlineTalkMarkdown.joiningPauseNotes(words)
        let tail = metadata ? (full.map { footer($0.metadata, body: words) } ?? "") : ""
        return TokensPromptParts(marker: "", body: shown + tail, metadata: "")
    }

    /// Build 89 hard rule: a talk pastes only when it has spoken words. Pause notes,
    /// punctuation, tags and the footer are generated, so on their own they are not words.
    static func hasWords(_ spoken: String) -> Bool {
        ThinkingComposer.removingAnnotations(spoken)
            .replacingOccurrences(of: #"\[thinking \d+(?:\.\d+)?s\]"#, with: "", options: .regularExpression)
            .unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    /// Pause notes are delivered as plain "[thinking 5.24s]" (UX review). Only this delivery
    /// edge changes them; history readers and the envelope still see the internal "*[pause 5.2400]*".
    static func thinkingMarkers(_ text: String) -> String {
        // Prose only: a code span that quotes "*[pause 1.0000]*" keeps its bytes (build 88).
        InlineTalkMarkdown.thinkingLines(text)
    }

    private static let stats = try! NSRegularExpression(pattern: #"> \*(\d+(?:\.\d+)?)s · (\d+) words? · (\d+) wpm"#)

    /*
    Metadata stays chill (UX review): no "# π" heading and no "# Metadata" section.
    The footer is the last line, "— π [253 wpm, 19.42s, 412 characters]" (its own line, 2026-10-18).
    One paste, like metadata off, so the editor can read it back and Auto-send still works.
    Characters are the words without pause notes. With no receipt line, nothing is added.
    */
    static func footer(_ metadata: String, body: String) -> String {
        let range = NSRange(metadata.startIndex..., in: metadata)
        guard let match = stats.firstMatch(in: metadata, range: range) else { return "" }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: metadata).map { String(metadata[$0]) } }
        guard let seconds = group(1).flatMap(Double.init), let wpm = group(3) else { return "" }
        let characters = ThinkingComposer.removingAnnotations(body)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").count
        return "\n— π [\(wpm) wpm, \(String(format: "%.2fs", seconds)), \(characters) \(characters == 1 ? "character" : "characters")]"
    }
}
