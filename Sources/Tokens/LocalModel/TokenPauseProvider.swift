


//
/*
TokenPauseProvider.swift

Owns: Pause-provider contract and its bounded loopback Ollama implementation.
Never: Delay delivery, collect telemetry, or contact anything beyond loopback Ollama.
See: Sources/Tokens/LocalModel/TokenPauseAsides.swift and the related responsibility files below.
Related: TokenPauseAsides.swift
         TokenPauseAsides+Requests.swift
         TokenPauseAsides+Content.swift
Port provenance: Sources/System/TTTTinkering.swift, donor 2ac14df.
*/


import Combine
import Foundation


// TokenPauseProvider — contract for the model behind ephemeral reflections of an active talk


@MainActor protocol TokenPauseProvider {
    func resolveModel() async -> String?
    /// Distinguishes "Ollama not running" from "running without the model".
    func resolvePresence() async -> TokenPauseAsides.OllamaPresence
    /*
    Streams the model's reply for one transcript; onDelta receives each piece on the main actor. It must
    throw if the reply does not finish cleanly (see OllamaTokenPauseProvider.stream).
    */
    func stream(transcript: String, model: String, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws
    /// Audit metadata only; never shown or delivered.
    nonisolated var promptVersion: String { get }
    nonisolated var structuredWorkspace: Bool { get }
    // How many tokens the model may use so that its reply fits inside the given time budget, in seconds.
    nonisolated func maxTokens(for budget: TimeInterval) -> Int
}


// TokenPauseProvider (extension) — defaults for providers without a probe or audit details


extension TokenPauseProvider {
    /// Providers without a reachability probe only know whether a model resolved.
    func resolvePresence() async -> TokenPauseAsides.OllamaPresence {
        if let model = await resolveModel() { return .ready(model) }
        return .notRunning
    }
    // Defaults for simple providers. OllamaTokenPauseProvider replaces all of them.
    nonisolated var promptVersion: String { "unversioned" }
    nonisolated var structuredWorkspace: Bool { false }
    nonisolated func maxTokens(for budget: TimeInterval) -> Int { 0 }
}


// OllamaTokenPauseProvider — streams the live table or final summary from Ollama on this Mac


struct OllamaTokenPauseProvider: TokenPauseProvider {

    // Setup — model choice, token budget and the Ollama presence check


    /*
    preferredModel is the one exact model name this provider uses (default qwen3.5:4b); it does not search
    for another. structuredWorkspace true means live-table mode (last 900 characters, temperature 0, context
    2048). False means final-summary mode (last 6,000 characters, temperature 0.25, context 4096).
    */
    private let preferredModel: String

//
// :)
//
//
    nonisolated let structuredWorkspace: Bool
    private let tokensPerSecond: Double
    /// Conservative decode-rate estimates for this Mac class, not a benchmark.
    nonisolated init(model: String = "qwen3.5:4b", tokensPerSecond: Double? = nil, structuredWorkspace: Bool = false) {
        preferredModel           = model
        self.structuredWorkspace = structuredWorkspace
        /*
        A rough speed guess by model size: 90 tokens per second for the 0.8b model, 36 for others. It only
        sizes the token budget, so a reply can finish before the deadline.
        */
        self.tokensPerSecond = tokensPerSecond ?? (model.contains("0.8b") ? 90 : 36)
    }
    nonisolated var promptVersion: String { structuredWorkspace ? "workspace-v1-extractive" : ThoughtsPrompt.version }
    /// Room the model can actually finish inside the remaining budget, so a
    /// coherent stop is reached instead of a cut-off at the deadline.
    nonisolated func maxTokens(for budget: TimeInterval) -> Int {
        Self.maxTokens(budget: budget, tokensPerSecond: tokensPerSecond)
    }
    nonisolated static func maxTokens(budget: TimeInterval, tokensPerSecond: Double) -> Int {
        /*
        Time budget to token cap: (seconds left minus 0.45 s) times the speed, never below 32 and never above
        180. Values that are not finite give 32.
        */
        guard budget.isFinite, tokensPerSecond.isFinite else { return 32 }
        // Reserve prompt evaluation and first-token latency.
        return min(180, max(32, Int(max(0, budget - 0.45) * max(1, tokensPerSecond))))
    }
    func resolveModel() async -> String? { await resolvePresence().model }
    /// Unreachable or malformed /api/tags is "not running"; rows without the
    /// exact local name are "no model". Never pulls.
    func resolvePresence() async -> TokenPauseAsides.OllamaPresence {
        let session = OllamaThinkingProvider.session(timeout: 2)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: URL(string: OllamaThinkingProvider.endpoint + "/api/tags")!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["models"] as? [[String: Any]] else { return .notRunning }
        // Exact-name match only; rows with a remote_host (cloud-hosted) do not count.
        guard rows.contains(where: { ($0["name"] as? String) == preferredModel && $0["remote_host"] == nil }) else {
            return .noModel(preferredModel)
        }
        return .ready(preferredModel)
    }


    // Streaming — one request, and the check that a reply really finished


    /*
    Streams one reply. The transcript goes in as a JSON string. num_predict comes from maxTokens(for:
    timeout), so the model is asked for no more than it can say in the time left. Anything that is not a
    clean finish throws: a status other than 200, a line over 16 KB, an error line, more than 700 characters
    of output, a done line that fails the completion check (see below), or a stream that just ends.
    */
    func stream(transcript: String, model: String, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        var request        = URLRequest(url: URL(string: OllamaThinkingProvider.endpoint + "/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "think": false, "keep_alive": "10m",
            "messages": [
                ["role": "system", "content": structuredWorkspace ? TinkeringDocument.systemPrompt : ThoughtsPrompt.system],
                ["role": "user", "content": "Transcript data (JSON string): " + String(data: try JSONEncoder().encode(String(transcript.suffix(structuredWorkspace ? 900 : 6000))), encoding: .utf8)!]
            ],
            "options": ["temperature": structuredWorkspace ? 0.0 : 0.25,
                        "num_predict": maxTokens(for: timeout), "num_ctx": structuredWorkspace ? 2048 : 4096]
        ] as [String: Any])
        let session = OllamaThinkingProvider.session(timeout: timeout)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler(operation: {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            var count      = 0
            var fullOutput = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.utf8.count <= 16384,
                      let data = line.data(using: .utf8),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["error"] == nil else { throw URLError(.cannotParseResponse) }
                if let message = event["message"] as? [String: Any], let delta = message["content"] as? String {
                    count += delta.count
                    guard count <= ThoughtsPrompt.maximumOutputCharacters else { throw URLError(.dataLengthExceedsMaximum) }
                    fullOutput += delta
                    onDelta(delta)
                }
                if event["done"] as? Bool == true {
                    /*
                    The done line decides whether the reply counts as finished. Live table: done reason
                    "stop" and at least one row that survives TinkeringDocument.parse. Summary: isComplete
                    (below). Otherwise throw.
                    */
                    let completed = structuredWorkspace
                        ? event["done_reason"] as? String == "stop" && !TinkeringDocument.parse(fullOutput, source: transcript).rows.isEmpty
                        : Self.isComplete(event: event, output: fullOutput, source: transcript)
                    guard completed else {
                        throw URLError(.cannotParseResponse)
                    }
                    return
                }
            }
            // A dropped stream is not a completed machine response.
            throw URLError(.networkConnectionLost)
        }, onCancel: { session.invalidateAndCancel() })
    }

//
// :)
//
//
    /// A token-limit finish or malformed terminal fragment never replaces the
    /// last completed response, even if it happened to end with punctuation.
    nonisolated static func isComplete(event: [String: Any], output: String, source: String? = nil) -> Bool {
        /*
        All of these must hold: done with reason "stop" (not "length"), no error, the text passes
        UsefulSummary.validated, no list marker dangling at the end, ** and _ marks come in pairs, and
        nothing but closing marks, quotes or a trailing emoji follows the last . ! ? or …
        */
        guard event["done"] as? Bool == true, event["done_reason"] as? String == "stop",
              event["error"] == nil,
              UsefulSummary.validated(output, source: source) != nil else { return false }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A dangling list marker ("3.") ends in punctuation but is unfinished.
        let lastLine = text.components(separatedBy: .newlines).last ?? ""
        guard lastLine.range(of: #"^\s*\d+[.)]?\s*$"#, options: .regularExpression) == nil,
              text.filter({ $0 == "*" }).count.isMultiple(of: 2),
              text.filter({ $0 == "_" }).count.isMultiple(of: 2),
              let boundary = text.lastIndex(where: { ".!?…".contains($0) }) else { return false }
        /*
        Permit closing emphasis/quotes and a trailing emoji, but not an
        unfinished phrase after the final sentence boundary.
        */
        return text[text.index(after: boundary)...].unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return false
            default: return true
            }
        }
    }


}

