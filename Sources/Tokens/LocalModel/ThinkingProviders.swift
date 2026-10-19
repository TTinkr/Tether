


//
/*
ThinkingProviders.swift

Owns: Loopback Ollama requests and deterministic offline preview responses.
Never: Persist streamed text or contact a remote model; delivery only receives validated metadata.
See: Sources/Tokens/LocalModel/ThinkingStream.swift and the related responsibility files below.
Related: ThinkingStream.swift
         ThinkingStream+Session.swift
         ThinkingStream+Execution.swift
         ThinkingStream+Content.swift
Port provenance: Sources/System/TokensThinkingStream.swift, donor 2ac14df.
*/


import Combine
import Foundation


// TokensOllamaThinkingProvider — streams a lane's answer from Ollama on this Mac (127.0.0.1)


struct TokensOllamaThinkingProvider: TokensThinkingProvider {

    // Setup — limits, model lookup and request building


    /// Must equal the context the runners are already loaded with (the
    /// formatter and the live workspace use 2048); a different num_ctx makes
    /// Ollama reload the model, which is the thrash this lane must not cause.
    nonisolated static let contextTokens = 2048
    /*
    Safety limits for one streamed answer: a line over 16 KB, or more than 1,200 characters of output, fails
    the call.
    */
    nonisolated static let maximumLineBytes        = 16_384
    nonisolated static let maximumOutputCharacters = 1_200


    nonisolated init() {}


    /*
    Lists every usable installed model name (same filters as OllamaThinkingProvider.resolveModel: no tiny
    rows, no remote_host, no ":cloud"), so each lane can check its own model. nil means Ollama did not answer
    within 2 s.
    */
    func installedModels() async -> Set<String>? {
        let session = OllamaThinkingProvider.session(timeout: 2)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: URL(string: OllamaThinkingProvider.endpoint + "/api/tags")!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["models"] as? [[String: Any]] else { return nil }
        return Set(rows.compactMap { row in
            guard let name = row["name"] as? String, let size = row["size"] as? NSNumber,
                  size.int64Value > 1_000_000, row["remote_host"] == nil, !name.hasSuffix(":cloud") else { return nil }
            return name
        })
    }


    /*
    Chat request body. `stream` is a parameter so warm() can send the same shape without streaming. think is
    false, keep_alive is 10m, and num_ctx is always contextTokens.
    */
    nonisolated static func requestBody(model: String, messages: [[String: String]], maxTokens: Int,
                                        temperature: Double, stream: Bool) -> [String: Any] {
        ["model": model, "stream": stream, "think": false, "keep_alive": "10m", "messages": messages,
         "options": ["temperature": temperature, "num_predict": maxTokens, "num_ctx": contextTokens]]
    }


    private static func request(_ body: [String: Any]) throws -> URLRequest {
        var request        = URLRequest(url: URL(string: OllamaThinkingProvider.endpoint + "/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

//
// :)
//
//
    // Calls — warm a model, read one stream line, stream an answer


    /*
    Best effort: one tiny request (no messages, 1 token, 10 s limit) whose only job is to get Ollama to load
    the model. Errors are ignored.
    */
    func warm(model: String) async {
        // Empty messages: Ollama loads the model (with this num_ctx) and returns.
        guard let request = try? Self.request(Self.requestBody(model: model, messages: [], maxTokens: 1,
                                                               temperature: 0, stream: false)) else { return }
        let session = OllamaThinkingProvider.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(for: request)
    }


    /// One NDJSON line: a content delta, and/or the terminal done reason.
    nonisolated static func parse(line: String) throws -> (delta: String?, doneReason: String?) {
        guard !line.isEmpty else { return (nil, nil) }
        guard line.utf8.count <= maximumLineBytes, let data = line.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["error"] == nil else { throw URLError(.cannotParseResponse) }
        let delta = (event["message"] as? [String: Any])?["content"] as? String
        let done  = event["done"] as? Bool == true ? (event["done_reason"] as? String ?? "") : nil
        return (delta, done)
    }


    /*
    Streams one answer. Ollama sends one JSON object per line; each content piece goes to onDelta on the main
    actor. The call ends cleanly only on a done line whose reason is "stop" or "length". Anything else
    throws:
     - a status other than 200, an unreadable line, or an error line;
     - more than 1,200 characters of output;
     - a stream that ends without a done line (a dropped connection).
    Temperature is 0.3 for questions and 0.2 for reflection.
    */
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]],
                maxTokens: Int, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        let request = try Self.request(Self.requestBody(model: model, messages: messages, maxTokens: maxTokens,
                                                        temperature: lane == .questions ? 0.3 : 0.2, stream: true))
        let session = OllamaThinkingProvider.session(timeout: timeout)
        defer { session.invalidateAndCancel() }
        /*
        If the surrounding task is cancelled the session is cancelled at once, so the byte loop ends now
        instead of waiting for the next line to arrive.
        */
        try await withTaskCancellationHandler(operation: {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            var count = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let event = try Self.parse(line: line)
                if let delta = event.delta, !delta.isEmpty {
                    count += delta.count
                    guard count <= Self.maximumOutputCharacters else { throw URLError(.dataLengthExceedsMaximum) }
                    onDelta(delta)
                }
                if let reason = event.doneReason {
                    // "length" is a clean num_predict cap; the display keeps complete lines only.
                    guard reason == "stop" || reason == "length" else { throw URLError(.cannotParseResponse) }
                    return
                }
            }
            throw URLError(.networkConnectionLost) // a dropped stream is not a finished answer
        }, onCancel: { session.invalidateAndCancel() })
    }


}

//
// :)
//
//
// TokensThinkingCannedProvider — offline stand-in for tests and the --temple-preview proof


/// Deterministic, offline provider for tests and the --temple-preview proof.
/// Output is built from the transcript's own words, so validators accept it.
struct TokensThinkingCannedProvider: TokensThinkingProvider {
    var installed: Set<String>?
    var chunkDelayNanoseconds: UInt64
    // By default it reports both lane models as installed, so both lanes are eligible.
    nonisolated init(installed: Set<String>? = [TokensThinkingStream.Tuning().questionsModel, TokensThinkingStream.Tuning().reflectionModel],
                     chunkDelayNanoseconds: UInt64 = 25_000_000) {
        self.installed             = installed
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }
    func installedModels() async -> Set<String>? { installed }
    func warm(model: String) async {}
    func stream(lane: TokensThinkingLane, model: String, messages: [[String: String]],
                maxTokens: Int, timeout: TimeInterval,
                onDelta: @escaping @MainActor (String) -> Void) async throws {
        /*
        Builds a fixed answer from the transcript's own words (the last two distinct words of five or more
        letters), so the grounding checks in TokensThinkingStream.display accept it. It is sent 4 characters
        at a time with a short pause between pieces to imitate streaming.
        */
        let source = TokensThinkingStream.transcript(inUserMessage: messages.last?["content"] ?? "")
        var seen   = Set<String>()
        let words  = LexicalFidelity.words(in: source)
            .filter { $0.count >= 5 && $0.allSatisfy(\.isLetter) && seen.insert($0).inserted }
        let a    = words.last ?? "this", b = words.dropLast().last ?? a
        let text = lane == .questions
            ? "What matters most about \(a)?\nWhich part of \(b) comes first?\nHow do \(a) and \(b) fit together?"
            : "TITLE: \(b.capitalized) and \(a)\nSUMMARY: Working out \(b) and \(a).\n- Open: what comes after \(a).\n- Settled: \(b) stays in."
        var index = text.startIndex
        while index < text.endIndex {
            try Task.checkCancellation()
            let next = text.index(index, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            onDelta(String(text[index..<next]))
            index = next
            try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
        }
    }
}

