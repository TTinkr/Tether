import Foundation

/// New opt-in keys intentionally do not inherit the old always-on envelope.
/// Reading missing preferences has no side effects.
enum TokensOutputOptions {
    static let metadataKey = "TokensIncludeMetadata.v1"
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
    static func parts(_ rendered: String, metadata: Bool, headerNotes: [String] = []) -> TokensPromptParts {
        guard metadata else { return TokensPromptParts(marker: "", body: thinkingMarkers(rendered), metadata: "") }
        let full = TokensDecoration.parts(rendered, decorated: false, headerNotes: headerNotes)
        let words = full.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return TokensPromptParts(marker: "", body: thinkingMarkers(words) + footer(full.metadata, body: words), metadata: "")
    }

    /// Pause notes are delivered as plain "[thinking 5.24s]" (UX review). Only this delivery
    /// edge changes them; history readers and the envelope still see the internal "*[pause 5.2400]*".
    static func thinkingMarkers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = text
        for match in pauseMarker.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range, in: out), let number = Range(match.range(at: 1), in: text),
                  let seconds = Double(text[number]) else { continue }
            out.replaceSubrange(whole, with: String(format: "[thinking %.2fs]", seconds))
        }
        return out
    }

    private static let pauseMarker = try! NSRegularExpression(pattern: #"\*\[pause (\d+\.\d+)\]\*"#)
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
