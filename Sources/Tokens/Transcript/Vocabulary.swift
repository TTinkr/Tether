


//
import CoreGraphics
import Foundation
import TokensCore


// TalkVocabulary — Recognition hint phrases and the closed list of spelling corrections


/// Conservative punctuation gate: case and separators may vary; words,
/// repetitions and ordering may not. The raw transcript is the fallback.
enum TalkVocabulary {


    // Recognition hints — phrases that help the recognizer hear project words


    /*
    Short, project-relevant phrases for Apple's recognition context. Hints
    change likelihood only; exact corrections below are a separate stage.
    */
    static let hints = [
        // Assistants, labs, and local model families.
        "Claude Code", "Claude", "Codex", "OpenAI", "Anthropic", "ChatGPT", "GPT",
        "Gemini", "Qwen", "Qwen Coder", "Qwen VL", "Kimi", "Kimi K2", "DeepSeek",
        "DeepSeek R1", "DeepSeek V3", "Llama", "Mistral", "Mixtral", "Gemma", "Phi",
        // Local inference runtimes, formats, and model tooling.
        "MLX", "MLX Swift", "Ollama", "LM Studio", "llama.cpp", "vLLM", "GGUF", "GGML",
        "Safetensors", "Hugging Face", "Transformers", "PyTorch", "Core ML", "Metal",
        // Language-model vocabulary used by Talk's token-maxing audience.
        "token", "tokens", "tokenizer", "token maxer", "token maxing", "context window",
        "context length", "inference", "quantization", "four bit", "eight bit", "LoRA", "QLoRA",
        "fine-tuning", "distillation", "embeddings", "vector database", "RAG",
        "retrieval augmented generation", "system prompt", "prompt engineering", "tool call",
        "function calling", "agentic", "agents", "chain of thought", "KV cache",
        "mixture of experts", "MoE", "multimodal", "vision language model", "VLM",
        // Tinkr, speech, and software vocabulary.
        "Tinkr", "SpeechAnalyzer", "SpeechTranscriber", "Apple Speech",
        "speech to text", "text to speech", "API", "SDK", "CLI", "MCP", "LLM", "ASR",
        "GitHub", "Git", "GitLab", "Xcode", "Swift", "SwiftUI", "macOS", "iOS", "Python",
        "JavaScript", "TypeScript", "Rust", "React", "Cursor", "VS Code", "terminal",
        // The spoken control phrases of Character Talk (see CharacterTalk.explicitPattern).
        "talk characters", "end talk characters", "start T C", "end T C"
    ]


    // Spelling corrections — correctionAliases and normalizeRecognizedText()


    /// Closed allowlist of observed ASR spellings. This is deliberately not a
    /// fuzzy/vector rewrite: raw recognition stays available for provenance,
    /// and every nonlisted phrase passes through unchanged.
    /// Each pair is (case-insensitive pattern, replacement). They are applied one after another in
    /// this order, each on the output of the one before. Patterns are whole-word (\b) so a match
    /// never starts or ends in the middle of another word.
    static let correctionAliases: [(pattern: String, replacement: String)] = [
        (#"(?i)\b(?:clawed|clod)\s+code\b"#, "Claude Code"),
        (#"(?i)\bclaude\s+codron\b"#, "Claude Code"),
        // "open a i" (also with dots or tabs between the letters) is OpenAI spelled out.
        (#"(?i)\bopen[\t .]+a[\t .]*i\b"#, "OpenAI"),
        (#"(?i)\banthropic\b"#, "Anthropic"),
        (#"(?i)\bchat\s+gpt\b"#, "ChatGPT"),
        (#"(?i)\bquen\b"#, "Qwen"),
        /*
        Spacing the canonical letters intentionally routes Kimi through
        Character Talk: plain delivery is KIMI and Tokens markdown is
        exactly `<TC> KIMI </TC>`.
        */
        (#"(?i)\b(?:kimi|kimmy)\b"#, "K I M I"),
        /*
        Never inside a path or file name: a slash, backslash or dot touching the word
        (~/Documents/Tinkr, Tinkr.app) keeps the spelling exactly as recognized.
        */
        (#"(?i)(?<![/\\.])\btinke?r\b(?![/\\]|\.\w)"#, "tinkr")
    ]

    /*
    Step 1: apply every alias above. Step 2, only when the person turned on "Fix Agent Names"
    (AgentNameFixes, default off so the raw path stays faithful): the context-gated agent names
    in ContextualAlias (Claude Code, Codex), which change only in an agent sentence and
    never next to a blocked word such as "audio" or "music", or inside a link, path or code.
    Step 3: the "Quinn" rule below. Anything not matched is returned exactly as it came in.
    */
    static func normalizeRecognizedText(_ text: String) -> String {
        normalizeRecognizedText(text, agentNameFixes: AgentNameFixes.isEnabled)
    }

    static func normalizeRecognizedText(_ text: String, agentNameFixes: Bool) -> String {
        let aliased = correctionAliases.reduce(text) { result, alias in
            result.replacingOccurrences(
                of: alias.pattern,
                with: alias.replacement,
                options: .regularExpression
            )
        }
        let corrected = agentNameFixes ? ContextualAlias.apply(aliased) : aliased
        /*
        Quinn is also a person's name. Only reinterpret it in the same
        short sentence as explicit local-model vocabulary.
        `left` and `right` are the pieces of the sentence on each side of the match (cut at
        . ! ? or a line break); at most 96 characters of each are searched for a model word.
        Matches are handled last-to-first so earlier ranges stay valid while text is replaced.
        */
        guard let quinn = try? NSRegularExpression(pattern: #"(?i)\bquinn\b"#) else { return corrected }
        let source  = corrected as NSString
        let mutable = NSMutableString(string: corrected)
        for match in quinn.matches(in: corrected, range: NSRange(location: 0, length: source.length)).reversed() {
            let before = source.substring(to: match.range.location)
            let after  = source.substring(from: NSMaxRange(match.range))
            let left   = before.split(whereSeparator: { ".!?\n".contains($0) }).last.map(String.init) ?? ""
            let right  = after.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
            let nearby = String(left.suffix(96)) + " " + String(right.prefix(96))
            if nearby.range(of: #"(?i)\b(?:model|models|llm|ollama|qwen|coder|inference)\b"#,
                            options: .regularExpression) != nil {
                mutable.replaceCharacters(in: match.range, with: "Qwen")
            }
        }
        return mutable as String
    }


}

//
// :)
//
//
// BrandVocabulary — Applies the name corrections; the raw recognition stays available


/*
Opt-in switch for the context-gated agent names (Claude Code, Codex). Off by default: a
word like "codecs" can be meant literally, so Tokens changes it only after the person
asks. The key is a saved-setting string on people's Macs.
*/
enum AgentNameFixes {
    static let key = "TokensAgentNameFixes.v1"
    static var isEnabled: Bool {
        get { isEnabled(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func isEnabled(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
}

/// Delivery-facing name normalization; raw recognition remains available.
enum BrandVocabulary {
    static func apply(to text: String) -> String {
        TalkVocabulary.normalizeRecognizedText(text)
    }
}


// PersonalDictionary — The user's own spellings, saved and offered to the recognizer


// Personal spellings bias recognition; they never rewrite recognized words.
enum PersonalDictionary {
    /*
    The key and the suite names below are saved-setting strings on people's Macs. Changing
    one would make an existing personal dictionary disappear.
    */
    static let key = "TTTPersonalDictionary.v1"
    static var suite: String {
        // Tokens and Tokens Dev each keep their own dictionary.
        guard let identity = Bundle.main.bundleIdentifier,
              ["com.tinkr.tokens.community.macos", "com.tinkr.tokens.community.dev.macos", "com.tinkr.tokens.community.preview", FreshStart.bundleIdentifier].contains(identity) else {
            return "com.tinkr.tokens.community.preferences" // Keep the existing non-Tokens identity.
        }
        return "\(identity).preferences"
    }
    /*
    One term per line: trimmed, Unicode-composed, blank lines dropped, and repeats removed
    ignoring case (the first spelling wins). Order is kept.
    */
    static func normalize(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }
    static func load(in defaults: UserDefaults) -> [String] {
        normalize((defaults.stringArray(forKey: key) ?? []).joined(separator: "\n"))
    }
    static func save(_ text: String, in defaults: UserDefaults) {
        defaults.set(normalize(text), forKey: key)
    }
    // Talk and Tokens send personal terms to the recognizer as hints; other products get none.
    static func hints(for product: String, in defaults: UserDefaults) -> [String] {
        ["Talk", "Tokens"].contains(product) ? load(in: defaults) : []
    }
    /*
    Personal terms first, then the built-in hints, with duplicates removed (so a personal
    spelling wins over a built-in one that differs only by case).
    */
    static func recognitionHints(_ personal: [String]) -> [String] {
        normalize((personal + TalkVocabulary.hints).joined(separator: "\n"))
    }
}

