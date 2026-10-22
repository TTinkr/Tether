


//
import Foundation
import TokensCore

enum InlineTalkMarkdown {
    /*
    Launch composition accepts speech only. Old typed/AI history stays in storage;
    it cannot enter a new capture through a hidden editor or stale preference.
    */
    static func authoredPrompt(_ envelope: String, spokenText: String) -> AuthoredPrompt {
        AuthoredPrompt(transcript: TokensDecoration.decoratePrompt(envelope, decorated: false),
                       spokenText: spokenText)
    }

    /*
    Whole-line recognition keeps ordinary prose mentioning THINK untouched.
    Placed pauses start a new line; the following words share the marker line. Unplaced timing remains in the measured
    envelope and capture diagnostics; it never acquires a guessed transcript position.
    */
    static func render(_ body: String) -> String {
        transformProse(body) { prose in
            // Normalize our own already-rendered line prefix for idempotent re-rendering.
            let input = prose.replacingOccurrences(
                of: #"(?m)^\*\[pause (\d+\.\d{4})\]\* ?"#,
                with: "THINK ($1s)\n", options: .regularExpression)
            var output = "", words = ""
            func flushWords() {
                var normalized = words.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                if output.hasSuffix(" ") { normalized = String(normalized.drop(while: { $0 == " " })) }
                output += normalized
                words = ""
            }
            for (index, line) in input.components(separatedBy: .newlines).enumerated() {
                let tag = line.range(of: #"^<thinking duration="\d+\.\d{4}s"(?: placement="unplaced" count="\d+")?/>$"#, options: .regularExpression) != nil
                guard ThinkingComposer.isAnnotation(line) || tag else {
                    words += (index == 0 ? "" : "\n") + line
                    continue
                }
                if line.contains("unplaced ×") || line.contains("placement=\"unplaced\"") { continue }
                flushWords()
                let number = line.range(of: #"\d+\.\d+(?=\s*s)"#, options: .regularExpression)
                guard let number, let seconds = Double(line[number]) else { continue }
                output = output.trimmingCharacters(in: .whitespaces)
                output += "\n*[pause " + String(format: "%.4f", seconds) + "]* "
            }
            flushWords()
            return output
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /*
    Thinking traces off (build 88): each placed pause note and the line break render() put before
    it become one space, so the words read as one run; unplaced and historical markers go too
    (removingMarkers). Code and spelling spans keep their bytes (transformProse).
    */
    /// Thinking traces on: each placed pause note reads "[thinking 5.24s]"; code keeps its bytes.
    static func thinkingLines(_ body: String) -> String {
        transformProse(body) { prose in
            var out = prose
            let range = NSRange(prose.startIndex..., in: prose)
            for match in pauseNote.matches(in: prose, range: range).reversed() {
                guard let whole = Range(match.range, in: out), let number = Range(match.range(at: 1), in: prose),
                      let seconds = Double(prose[number]) else { continue }
                out.replaceSubrange(whole, with: String(format: "[thinking %.2fs]", seconds))
            }
            return out
        }
    }

    private static let pauseNote = try! NSRegularExpression(pattern: #"\*\[pause (\d+\.\d+)\]\*"#)

    static func joiningPauseNotes(_ body: String) -> String {
        let joined = transformProse(body) { prose in
            prose.replacingOccurrences(of: #"[ \t]*\n?[ \t]*\*\[pause \d+\.\d{4}\]\*[ \t]?"#, with: " ",
                                       options: .regularExpression)
        }
        return removingMarkers(joined).trimmingCharacters(in: .whitespaces)
    }

    /*
    Only exact generated tags and historical dash-delimited markers are stripped by spoken-only
    readers. A bare TK identifier or literal parenthesized duration survives.
    */
    static func removingMarkers(_ body: String) -> String {
        transformProse(body) { prose in prose.replacingOccurrences(
            of: #" ?(?:\*\[pause \d+\.\d{4}\]\*|<thinking duration="\d+\.\d{4}s"(?: placement="unplaced" count="\d+")?/>|— \(TK-(?:\d+\.\d{4}s|unplaced ×\d+ · \d+\.\d{4}s · measured silence, position not aligned to words)\) —) ?"#,
            with: " ", options: .regularExpression)
                .components(separatedBy: "\n")
                .filter { !ThinkingComposer.isAnnotation($0) }
                .joined(separator: "\n")
        }
    }

    /*
    Only unmarked speech whitespace is normalized. Explicit code/spelling spans retain
    their bytes: flattening a fenced program would silently change its meaning.
    */
    private static func transformProse(_ text: String, _ transform: (String) -> String) -> String {
        let pattern = #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|`[^`]*(?:`|\z)|<num>.*?(?:</num>|\z)|<char>.*?(?:</char>|\z)|<TC>.*?(?:</TC>|\z)|<TN>.*?(?:</TN>|\z)"#
        let source = text as NSString
        let matches = try! NSRegularExpression(pattern: pattern)
        var result = "", cursor = 0
        for match in matches.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += transform(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            result += source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + transform(source.substring(from: cursor))
    }

}

