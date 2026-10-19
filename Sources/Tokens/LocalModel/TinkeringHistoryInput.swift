


//
import Foundation


extension TinkeringPrompts {
    static func calibrationInput(entries: [PromptHistoryEntry]) -> (text: String, count: Int) {
        calibrationInput(spokenHistory: entries.map { entry in
            /*
            A structural spoken field is already authoritative. Even a literal
            whole-line ## Typed is speech here and must survive model input.
            */
            (date: entry.createdAt, text: entry.authored?.spokenText ?? spokenText(entry.text))
        })
    }

    /// Both APIs share ordering and size limits; only legacy input needs parsing.
    static func calibrationInput(spokenHistory: [(date: Date, text: String)]) -> (text: String, count: Int) {
        let stamp           = ISO8601DateFormatter()
        var lines: [String] = []
        var total           = 0
        for entry in spokenHistory.sorted(by: { $0.date > $1.date }) {
            guard lines.count < maximumEntries else { break }
            let normalized = entry.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let spoken     = String(normalized.prefix(maximumEntryCharacters))
            guard spoken.split(separator: " ").count >= 3 else { continue }
            let line = "[\(stamp.string(from: entry.date))] \(spoken)"
            guard total + line.count <= maximumInputCharacters else { break }
            lines.append(line)
            total += line.count
        }
        return (lines.joined(separator: "\n"), lines.count)
    }
}

