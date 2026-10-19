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
        return text
    }

    /// `headerNotes` are one-line `> *…*` notes appended to the metadata block (for example
    /// ScreenReferenceSampler.lines). With metadata off they are dropped: raw stays raw.
    static func parts(_ rendered: String, metadata: Bool, headerNotes: [String] = []) -> TokensPromptParts {
        metadata ? TokensDecoration.parts(rendered, decorated: false, headerNotes: headerNotes)
            : TokensPromptParts(marker: "", body: rendered, metadata: "")
    }
}
