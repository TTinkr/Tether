


//
/*
TokenPauseAsides+Content.swift

Owns: Numeric fidelity and output shape checks, header notes, and Markdown formatting.
Never: Delay delivery, collect telemetry, or contact anything beyond loopback Ollama.
See: Sources/Tokens/LocalModel/TokenPauseAsides.swift and the related responsibility files below.
Related: TokenPauseAsides.swift
         TokenPauseAsides+Requests.swift
Port provenance: Sources/System/TTTTinkering.swift, donor 2ac14df.
*/


import Combine
import Foundation


extension TokenPauseAsides {


    // Checks — numbers, safety and shape of model text


    /// Conservative numeric/unit fidelity check, not factuality verification.
    /// Numbered-list prefixes are formatting; all other numeric expressions
    /// must occur literally (case/spacing-insensitively) in the source.
    static func preservesNumbers(_ output: String, source: String) -> Bool {
        /*
        Collects numeric expressions such as 5, 2.5, 30% or 10ms (lowercased, spaces removed). Numbered-list
        markers at the start of a line are stripped from the model output only.
        */
        func values(_ text: String, stripListNumbers: Bool) -> Set<String> {
            let content = stripListNumbers
                ? text.replacingOccurrences(of: "(?m)^\\s*[0-9]+[.)]\\s+", with: "", options: .regularExpression)
                : text
            let pattern = #"(?i)(?<![\p{L}\p{N}])[-+]?\d+(?:[.,]\d+)*(?:\s?(?:%|[a-zµμ]+))?"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = content as NSString
            return Set(expression.matches(in: content, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range).lowercased().filter { !$0.isWhitespace }
            })
        }
        return values(output, stripListNumbers: true).isSubset(of: values(source, stripListNumbers: false))
    }
    /*
    Table mode: at most 700 characters, at most 12 lines, no control characters except newline. Looser than
    validated(): there is no character or phrase blocklist here. The rows are checked later by
    TinkeringDocument.parse.
    */
    static func validatedWorkspace(_ output: String) -> String? {
        guard output.count <= ThoughtsPrompt.maximumOutputCharacters,
              output.components(separatedBy: .newlines).count <= 12,
              !output.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 10 }) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /*
    The basic safety check for model text shown as an aside: at most 700 characters, no control characters
    except newline, none of < > ` [ ] { } \, at most 130 words and 6 non-blank lines, and none of a blocklist
    of phrases (about the speaker's feelings or thoughts, sounds such as breath or laughter, role labels,
    links, "ignore previous").
    */
    static func validated(_ output: String) -> String? {
        guard output.count <= ThoughtsPrompt.maximumOutputCharacters,
              !output.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 10 }),
              !output.contains(where: { "<>`[]{}\\".contains($0) }) else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        guard !value.isEmpty, value.split(whereSeparator: { $0.isWhitespace }).count <= 130,
              value.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count <= 6,
              !["detect", "diagnos", "you feel", "you think", "your thoughts", "you are", "you're", "breath", "laughter", "instruction", "system:", "assistant:", "user:", "http", "ignore previous"].contains(where: lower.contains) else { return nil }
        return value
    }


    // Output — header notes, workspace title and the Markdown appendix


    /// Header form of the summary for the presented copy: the validated
    /// Takeaway and its Next move/Question as AI-labelled lines, or nothing.
    /// A live workspace table is never flattened into a summary here.
    static func headerNotes(_ asides: [Aside]) -> [String] {
        guard let latest = asides.last, let useful = UsefulSummary.validated(latest.text) else { return [] }
        let lines = useful.components(separatedBy: "\n")
        /*
        Only the strict two-bullet shape produces notes (a Takeaway, then a Next move or Question); anything
        else gives none.
        */
        guard lines.count == 2, lines[0].hasPrefix("- **Takeaway:** ") else { return [] }
        let model    = String(latest.model.filter { $0.isLetter || $0.isNumber || ":.-_/".contains($0) }.prefix(80))
        let takeaway = String(lines[0].dropFirst("- **Takeaway:** ".count))
        let second   = lines[1].hasPrefix("- **Question:** ")
            ? ("AI question", String(lines[1].dropFirst("- **Question:** ".count)))
            : ("AI next move", String(lines[1].dropFirst("- **Next move:** ".count)))
        /*
        Two note lines at most: the AI summary, and the second bullet labelled "AI question" or "AI next
        move". ThinkingHeaderNote.line drops any line that fails its own checks.
        */
        return [ThinkingHeaderNote.line(label: "AI summary · \(model.isEmpty ? "local model" : model) · may be inaccurate", text: takeaway),
                ThinkingHeaderNote.line(label: second.0, text: second.1)].compactMap { $0 }
    }

//
// :)
//
//
    /// Grounded TITLE from the newest completed workspace table, if any.
    var latestWorkspaceTitle: String? {
        guard let latest = recentWorkspaceResponses.first else { return nil }
        let title = TinkeringDocument.parse(latest.text, source: latest.source).title
        return title.isEmpty ? nil : title
    }


    /*
    Markdown appendix text for a saved or presented copy. It uses only the newest aside, checked again. The
    heading says it is AI-generated and may be inaccurate. A proper Takeaway plus Next move or Question gets
    the heading "Summary + useful angle"; anything else is flattened into one "Summary" paragraph.
    */
    static func markdown(_ asides: [Aside]) -> String? {
        let valid = asides.suffix(1).compactMap { validated($0.text) }
        guard !valid.isEmpty else { return nil }
        let model = String((asides.last?.model ?? "local model").filter { $0.isLetter || $0.isNumber || ":.-_/ ".contains($0) }.prefix(80))
        let latest = valid.joined(separator: "\n")
        let useful = UsefulSummary.validated(latest)
        let body = useful ?? latest
            .replacingOccurrences(of: #"(?m)^\s*\d+[.)]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = useful == nil ? "Summary" : "Summary + useful angle"
        return "## \(heading) · AI-generated by \(model)\n\n*May be inaccurate; the transcript above is authoritative.*\n\n" + body


    }


}

