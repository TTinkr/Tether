


//
import CoreGraphics
import Foundation


// CharacterTalkRendering — The three views of one text, plus flags for what was found in it


/*
displayText: what the live screen shows, with ⟦TC⟧ / ⟦TN⟧ markers around found spans.
deliveryText: what is put into the target app, with controls and markers removed.
markdownText: generated spans use italic `*<char>RILEY</char>*` and `*<num>1 2 3</num>*`. Legacy TC literals remain unchanged.
*/
struct CharacterTalkRendering: Equatable {
    let displayText: String
    let deliveryText: String
    let markdownText: String
    let hasCharacterSpan: Bool
    let hasNumberSpan: Bool
    let isCharacterModeActive: Bool
    var hasProtectedSpan: Bool { hasCharacterSpan || hasNumberSpan }
}


// NumberTalk — Turns a run of three or more spoken numbers into digits


/// Talked Numbers is a derived view over immutable recognition. A run of at
/// least three consecutive spoken number tokens is unambiguous enough to
/// normalize to digits. Isolated prose numbers remain exactly as recognized.
enum NumberTalk {
    struct Rendering {
        let display: String
        let delivery: String
        let markdown: String
        let hasSpan: Bool
    }

    static let openMarker  = "⟦TN⟧"
    static let closeMarker = "⟦/TN⟧"
    /*
    One number token: a run of digits, or a spoken number word from zero ("oh" also means 0)
    up to ninety. There is no "hundred" or "thousand", so those words end a run.
    The word list comes from `values`, longest word first, so a whole word always wins over
    its prefix: "nineteen" is 19, never "nine" + "teen"; "sixty" is 60, never "six" + "ty".
    */
    private static let numberWords = values.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    private static let token = "(?:\\d+|" + numberWords.joined(separator: "|") + ")"
    /*
    A run is one token followed by two or more further tokens, each separated by whitespace or
    a comma, and not touching a letter or digit on either side. Two numbers in a row stay prose.
    */
    private static let expression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])"# + token + #"(?:(?:\s*,\s*|\s+)"# + token + #"){2,}(?![\p{L}\p{N}])"#
    )
    /*
    decode() finds tokens inside a found run with the same letter/digit boundaries as the run
    detector, so a token never starts or ends inside a longer word.
    */
    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])"# + token + #"(?![\p{L}\p{N}])"#,
        options: [.caseInsensitive]
    )
    private static let values: [String: String] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3",
        "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16",
        "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60",
        "seventy": "70", "eighty": "80", "ninety": "90"
    ]

    /*
    Each found run becomes digits separated by spaces ("one two three" gives "1 2 3"); text
    between runs is copied unchanged into all three views.
    */
    static func render(_ text: String) -> Rendering {
        let source  = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return Rendering(display: text, delivery: text, markdown: text, hasSpan: false) }
        var display  = ""
        var delivery = ""
        var markdown = ""
        var cursor   = 0
        for match in matches {
            let prefix = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            display += prefix
            delivery += prefix
            markdown += prefix
            let digits = decode(source.substring(with: match.range))
            display += openMarker + digits + closeMarker
            delivery += digits
            markdown += "*<num>" + digits + "</num>*"
            cursor = NSMaxRange(match.range)
        }
        let tail = source.substring(from: cursor)
        display += tail
        delivery += tail
        markdown += tail
        return Rendering(display: display, delivery: delivery, markdown: markdown, hasSpan: true)
    }

//
// :)
//
//
    /*
    Turns one found run into digits separated by spaces. Each token decodes as itself; a spoken
    tens word (twenty to ninety) followed directly by a spoken unit word (one to nine) joins
    into one number: "twenty one twenty two" gives "21 22", "two twenty five" gives "2 25".
    Digit tokens never join ("20 1 2" stays), and "sixty ten" stays "60 10". Only plain spaces
    join: a comma or any other mark between the words is a list boundary the speaker chose, so
    "twenty, one, two" stays three items, "20 1 2".
    */
    private static func decode(_ source: String) -> String {
        let text = source as NSString
        var numbers: [String] = []
        var pendingTens: Int? = nil
        var previousEnd = 0
        for match in tokenExpression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range)
            let gap = text.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
            previousEnd = match.range.location + match.range.length
            guard let decoded = values[token.lowercased()], let value = Int(decoded) else {
                numbers.append(token)
                pendingTens = nil
                continue
            }
            if let tens = pendingTens, (1...9).contains(value),
               gap.allSatisfy({ $0 == " " || $0 == "\t" }) {
                numbers[numbers.count - 1] = String(tens + value)
                pendingTens = nil
                continue
            }
            numbers.append(decoded)
            pendingTens = (20...90).contains(value) && value % 10 == 0 ? value : nil
        }
        return numbers.joined(separator: " ")
    }
}


// CharacterTalk — Finds spelled-out characters and renders them in three views


/// Character Talk is a derived view over immutable recognition. Explicit
/// boundaries are control phrases; an isolated run of at least three spoken
/// single characters is also unambiguous enough to annotate. Delivery removes
/// the controls and markers while the live display makes the mode visible.
enum CharacterTalk {


    // Patterns and render() — protected text passes through untouched


    static let openMarker  = "⟦TC⟧"
    static let closeMarker = "⟦/TC⟧"

    /*
    Spoken controls. Opens on "talk characters", "start talk characters" or "start t c", or on a
    bare "t c" at the very start of the text when at least three single characters follow it.
    Everything after the cue (capture group 1) is the spelled text, up to a closing cue
    ("end", "close" or "stop" plus "talk characters" or "t c") or the end of the text. A span
    that opens and never closes therefore runs to the end of the text.
    */
    private static let explicitPattern =
        #"(?is)(?:\b(?:talk\s+characters|start\s+(?:talk\s+characters|t[\s.\-]*c))\b|^\s*t[\s.\-]*c\b(?=\s+[\p{L}\p{N}](?:[\s.\-]+[\p{L}\p{N}]){2}))(.*?)(?:\b(?:end|close|stop)\s+(?:talk\s+characters|t[\s.\-]*c)\b|$)"#
    /*
    Spelling with no cue: either two or more all-capital groups of up to 12 letters separated by
    spaces, commas or hyphens, or three or more single letters/digits separated by spaces, dots
    or hyphens. This is a loose first net; renderAutomatic() filters out what is not spelling.
    */
    private static let automaticPattern =
        #"(?<![\p{L}\p{N}])(?:[A-Z]{1,12}(?:[,\s\-]+)){1,}[A-Z]{1,12}(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])(?:[\p{L}\p{N}](?:[\s.\-]+)){2,}[\p{L}\p{N}](?![\p{L}\p{N}])"#

    /*
    Opaque transcript literals are never input to automatic TC/TN parsing.
    Fence alternatives come first so the inline-code alternative cannot
    consume only the opening run of a fenced block.
    */
    private static let protectedPattern = try! NSRegularExpression(
        pattern: #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|<num>.*?(?:</num>|\z)|<char>.*?(?:</char>|\z)|<TC>.*?(?:</TC>|\z)|⟦TC⟧.*?(?:⟦/TC⟧|\z)|<TN>.*?(?:</TN>|\z)|⟦TN⟧.*?(?:⟦/TN⟧|\z)|`[^`\n]*(?:`|$)|!?\[[^\]\n]*\]\([^\n)]*\)"#,
        options: [.caseInsensitive]
    )

    /*
    Entry point. Splits the text around protected literals (above); the pieces between them go
    through renderUnprotected(), and each protected literal is copied unchanged into all three
    views. If the literal is itself a TC or TN tag, the matching "has span" flag is set.
    */
    static func render(_ raw: String) -> CharacterTalkRendering {
        let source    = raw as NSString
        let protected = protectedPattern.matches(in: raw, range: NSRange(location: 0, length: source.length))
        guard !protected.isEmpty else { return renderUnprotected(raw) }
        var display       = ""
        var delivery      = ""
        var markdown      = ""
        var hasCharacters = false
        var hasNumbers    = false
        var active        = false
        var cursor        = 0

        func appendUnprotected(_ range: NSRange) {
            guard range.length > 0 else { return }
            let rendering = renderUnprotected(source.substring(with: range))
            display += rendering.displayText
            delivery += rendering.deliveryText
            markdown += rendering.markdownText
            hasCharacters = hasCharacters || rendering.hasCharacterSpan
            hasNumbers    = hasNumbers || rendering.hasNumberSpan
            active        = active || rendering.isCharacterModeActive
        }

        for match in protected {
            appendUnprotected(NSRange(location: cursor, length: match.range.location - cursor))
            let literal = source.substring(with: match.range)
            display += literal
            delivery += literal
            markdown += literal
            let lowered   = literal.lowercased()
            hasCharacters = hasCharacters || lowered.hasPrefix("<char>") || lowered.hasPrefix("<tc>") || lowered.hasPrefix("⟦tc⟧")
            hasNumbers    = hasNumbers || lowered.hasPrefix("<num>") || lowered.hasPrefix("<tn>") || lowered.hasPrefix("⟦tn⟧")
            cursor        = NSMaxRange(match.range)
        }
        appendUnprotected(NSRange(location: cursor, length: source.length - cursor))
        return CharacterTalkRendering(displayText: display, deliveryText: delivery,
                                          markdownText: markdown, hasCharacterSpan: hasCharacters,
                                          hasNumberSpan: hasNumbers, isCharacterModeActive: active)
    }

//
// :)
//
//
    // Explicit control phrases — renderUnprotected()


    /*
    Handles text with no protected literal inside. Explicit cue spans are rendered here; the
    plain text between them goes to renderAutomatic(). If the text is empty or a pattern fails
    to compile, the text comes back unchanged with every flag off.
    */
    private static func renderUnprotected(_ raw: String) -> CharacterTalkRendering {
        guard !raw.isEmpty,
              let explicit = try? NSRegularExpression(pattern: explicitPattern),
              let automatic = try? NSRegularExpression(pattern: automaticPattern) else {
            return CharacterTalkRendering(
                displayText: raw,
                deliveryText: raw,
                markdownText: raw,
                hasCharacterSpan: false,
                hasNumberSpan: false,
                isCharacterModeActive: false
            )
        }

        let source        = raw as NSString
        let matches       = explicit.matches(in: raw, range: NSRange(location: 0, length: source.length))
        var display       = ""
        var delivery      = ""
        var markdown      = ""
        var cursor        = 0
        var hasSpan       = false
        var hasNumberSpan = false
        var active        = false

        func appendPlain(_ range: NSRange) {
            guard range.length > 0 else { return }
            let plain    = source.substring(with: range)
            let rendered = renderAutomatic(plain, expression: automatic)
            display += rendered.display
            delivery += rendered.delivery
            markdown += rendered.markdown
            hasSpan       = hasSpan || rendered.hasSpan
            hasNumberSpan = hasNumberSpan || rendered.hasNumberSpan
        }

        for match in matches {
            appendPlain(NSRange(location: cursor, length: match.range.location - cursor))
            let bodyRange = match.range(at: 1)
            let body      = bodyRange.location == NSNotFound ? "" : source.substring(with: bodyRange)
            let decoded   = decode(body)
            let full      = source.substring(with: match.range).lowercased()
            /*
            Whether the speaker closed the span. With a closing cue the span ends there and the
            closing marker is written; without one, character mode is still active
            (`active`), which the live display uses to show that the mode is on.
            */
            let hasClosingCue = full.range(
                of: #"\b(?:end|close|stop)\s+(?:talk\s+characters|t[\s.\-]*c)\b"#,
                options: .regularExpression
            ) != nil
            let closing = hasClosingCue ? closeMarker : ""
            display += openMarker + decoded + closing
            delivery += decoded
            markdown += "*<char>" + decoded + "</char>*"
            hasSpan = true
            active  = active || !hasClosingCue
            cursor  = NSMaxRange(match.range)
        }
        appendPlain(NSRange(location: cursor, length: source.length - cursor))

        return CharacterTalkRendering(
            displayText: display,
            deliveryText: delivery,
            markdownText: markdown,
            hasCharacterSpan: hasSpan,
            hasNumberSpan: hasNumberSpan,
            isCharacterModeActive: active
        )
    }

//
// :)
//
//
    // Automatic spelled-out runs — renderAutomatic() and decode()


    /*
    Takes the loose matches from automaticPattern and keeps only those that look like spelling:
     - all-digit groups are never characters (they are left to NumberTalk);
     - hyphenated capital groups of up to three letters, such as "U-S-B", are kept;
     - three or more single characters with at least one letter are kept;
     - otherwise a group of three or more letters is kept only if it is a straight run of the alphabet.
    Text outside the kept matches is passed to NumberTalk. The tuple's last two values say
    whether a character span and a number span were found.
    */
    private static func renderAutomatic(
        _ text: String,
        expression: NSRegularExpression
    ) -> (display: String, delivery: String, markdown: String, hasSpan: Bool, hasNumberSpan: Bool) {
        let source = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).filter { match in
            let body   = source.substring(with: match.range)
            let groups = body.split { !$0.isLetter && !$0.isNumber }
            if groups.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
            if body.contains("-"), groups.count >= 2, groups.allSatisfy({ $0.count <= 3 && $0.allSatisfy({ $0.isUppercase }) }) { return true }
            if groups.count >= 3 && groups.allSatisfy({ $0.count == 1 }) && groups.contains(where: { $0.first?.isLetter == true }) { return true }
            /*
            Apple sometimes emits alphabet recitation as grouped tokens.
            Require a contiguous alphabet run; ordinary API/SDK names stay prose.
            */
            let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            return groups.contains { $0.count >= 3 && alphabet.contains(String($0)) }
        }
        guard !matches.isEmpty else {
            let numbers = NumberTalk.render(text)
            return (numbers.display, numbers.delivery, numbers.markdown, false, numbers.hasSpan)
        }
        var display    = ""
        var delivery   = ""
        var markdown   = ""
        var cursor     = 0
        var hasNumbers = false
        func appendNumbers(_ range: NSRange) {
            guard range.length > 0 else { return }
            let numbers = NumberTalk.render(source.substring(with: range))
            display += numbers.display
            delivery += numbers.delivery
            markdown += numbers.markdown
            hasNumbers = hasNumbers || numbers.hasSpan
        }
        for match in matches {
            let prefix = NSRange(location: cursor, length: match.range.location - cursor)
            appendNumbers(prefix)
            let decoded = decode(source.substring(with: match.range))
            display += openMarker + decoded + closeMarker
            delivery += decoded
            markdown += "*<char>" + decoded + "</char>*"
            cursor = NSMaxRange(match.range)
        }
        let tail = NSRange(location: cursor, length: source.length - cursor)
        appendNumbers(tail)
        return (display, delivery, markdown, true, hasNumbers)
    }

    /*
    Spelled text to the characters it stands for: letters and digits only, uppercased, with all
    separators dropped ("r. i-l e y" gives "RILEY").
    */
    private static func decode(_ source: String) -> String {
        let scalars = source.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars)).uppercased()
    }


}

