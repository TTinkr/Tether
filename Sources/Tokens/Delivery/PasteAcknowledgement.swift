

import Foundation

/// FOR CONTRIBUTORS: distinguishes a missing word from a missing/moved caret without logging
/// either text. This is the same strict acceptance rule for every readable editor.
/// Do not trim, normalize or accept a substring: those can hide partial delivery.
enum PasteAcknowledgement {
    /*
    The target consumed the Command-V (build 81): around the captured selection the text before
    and after is unchanged, and what now stands in its place is the inserted words, allowing only
    the case and spacing changes editors make (a field that uppercases).
    Diagnostic grade, never acknowledgement: it only lets Tokens give the user's clipboard back.
    No length guess (an unrelated edit of a similar size could restore
    the old clipboard before a delayed Command-V read it). No captured selection: hold it.
    */
    static func pasteConsumed(before: String?, selection: NSRange?, after: String?,
                              observedChange: Bool, inserted: String) -> Bool {
        func folded(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard observedChange, let before, let selection, let after, !folded(inserted).isEmpty else { return false }
        let old = before as NSString, new = after as NSString
        guard selection.location >= 0, selection.length >= 0, NSMaxRange(selection) <= old.length else { return false }
        let prefix = old.substring(to: selection.location)
        let suffix = old.substring(from: NSMaxRange(selection))
        let prefixLength = (prefix as NSString).length, suffixLength = (suffix as NSString).length
        guard new.length >= prefixLength + suffixLength, after.hasPrefix(prefix), after.hasSuffix(suffix) else { return false }
        let middle = new.substring(with: NSRange(location: prefixLength, length: new.length - prefixLength - suffixLength))
        return folded(middle) == folded(inserted)
    }

    /// A rich editor can briefly expose a redraw instead of the inserted text.
    /// Waiting never promotes the lease: only exact text+caret verification does.
    static func waitsForReadback(_ result: Result, richComposer: Bool) -> Bool {
        result != .verified && (richComposer || result == .caretMismatch || result == .unreadableCaret)
    }

    enum Result: String {
        case invalidSelection, unreadableValue, textMismatch, unreadableCaret, caretMismatch, verified
    }

    static func evaluate(before: String, selection: NSRange, inserted: String,
                         after: String?, caret: NSRange?, richComposer: Bool = false,
                         caretSkipsLineBreaks: Bool = false) -> Result {
        let source = before as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= source.length,
              selection.length <= source.length - selection.location else { return .invalidSelection }
        guard let after else { return .unreadableValue }
        if caretSkipsLineBreaks, richComposer,
           let verdict = lineBreakFreeClaudePaste(before: before, caretOffset: selection, inserted: inserted,
                                                  after: after ?? "", caret: caret), after != nil {
            return verdict
        }
        if caretSkipsLineBreaks, richComposer,
           lineBreakSkippingInsertion(before: before, caretOffset: selection, inserted: inserted, after: after) != nil {
            guard let caret else { return .unreadableCaret }
            // Both offsets are in the editor's own caret space, so plain inserted text moves it by its length.
            return caret.length == 0 && caret.location == selection.location + (inserted as NSString).length
                ? .verified : .caretMismatch
        }
        let expected = source.replacingCharacters(in: selection, with: inserted)
        guard after == expected
              || (richComposer && fillsEmptyLastLine(source, selection: selection, inserted: inserted, after: after))
              || (richComposer && replacesEmptyStateText(source, selection: selection, inserted: inserted, after: after))
        else { return .textMismatch }
        guard let caret else { return .unreadableCaret }
        guard caret.length == 0,
              caret.location == selection.location + (inserted as NSString).length else { return .caretMismatch }
        return .verified
    }

    /*
    Claude desktop (UX review: every finished dictation should auto-send, onto a typed
    draft too). Its caret counts characters but not line breaks. Its readback text is exact,
    line breaks included (UX review's live logs, 2026-10-18: every verified paste read back as the
    pasted text alone or the draft up to the caret plus the pasted text); only the measured
    serialisations in claudeReadbackMatches may differ. So the text is compared exactly, line
    breaks and all, apart from those; the caret is compared in
    Claude's own line-break-free count. A lost, added or moved line break anywhere fails (Codex
    QA of b2c1196: the first version set every line break aside). nil: not this shape.
    */
    static func lineBreakFreeClaudePaste(before: String, caretOffset: NSRange, inserted: String,
                                         after: String, caret: NSRange?) -> Result? {
        guard caretOffset.length == 0, !before.contains("\r"), !after.contains("\r"),
              let split = utf16Index(before, skippingLineBreaksTo: caretOffset.location) else { return nil }
        let units = Array(before.utf16)
        let prefix = String(decoding: units[..<split], as: UTF16.self)
        let suffix = String(decoding: units[split...], as: UTF16.self)
        guard claudeReadbackMatches(prefix: prefix, inserted: inserted, suffix: suffix, after: after) else { return nil }
        guard let caret else { return .unreadableCaret }
        let expected = caretOffset.location + inserted.utf16.filter { $0 != 10 }.count
        return caret.length == 0 && caret.location == expected ? .verified : .caretMismatch
    }

    /*
    The serialisations measured in Claude (2026-10-18), and no others: the trailing placeholder line
    break of an empty or draft composer may go, and a paste at the end of a line may start a new
    paragraph (one or two line breaks where the draft and the paste meet). The draft before the
    caret, the pasted text and the rest of the draft must otherwise read back character for character.
    */
    static func claudeReadbackMatches(prefix: String, inserted: String, suffix: String, after: String) -> Bool {
        let tails = suffix.hasSuffix("\n") ? [suffix, String(suffix.dropLast())] : [suffix]
        let atLineEnd = prefix.isEmpty || prefix.hasSuffix("\n") || suffix.isEmpty || suffix.hasPrefix("\n")
        let joins = atLineEnd && !prefix.isEmpty && !prefix.hasSuffix("\n") ? ["", "\n", "\n\n"] : [""]
        for join in joins { for tail in tails where after == prefix + join + inserted + tail { return true } }
        return false
    }

    /// The UTF-16 index in `text` that sits after `count` characters other than line breaks (the
    /// first such index, so a caret before a line break stays before it); nil when out of range.
    static func utf16Index(_ text: String, skippingLineBreaksTo count: Int) -> Int? {
        guard count >= 0 else { return nil }
        var seen = 0
        for (index, unit) in text.utf16.enumerated() {
            if seen == count { return index }
            if unit != 10 { seen += 1 }
        }
        return seen == count ? text.utf16.count : nil
    }

    /*
    Diagnostics only, booleans and no text: which readback shape this paste produced, so one real
    dictation shows whether each Chromium rule matches the editor before it is trusted further.
    */
    static func shapeFlags(before: String, selection: NSRange, inserted: String, after: String?) -> String {
        let source = before as NSString
        guard let after, selection.location >= 0, selection.length >= 0,
              selection.location + selection.length <= source.length else { return "shape=unreadable" }
        let exact = after == source.replacingCharacters(in: selection, with: inserted)
        let prefixPlus = after == source.substring(to: selection.location) + inserted
        let caretBeforeFinalLF = selection.length == 0 && source.length > 0
            && selection.location == source.length - 1 && source.substring(from: selection.location) == "\n"
        return "exact=\(exact) after_eq_inserted=\(after == inserted) after_eq_prefix_plus_inserted=\(prefixPlus) caret_before_final_lf=\(caretBeforeFinalLF) before_ends_lf=\(before.hasSuffix("\n"))"
    }

    /*
    Diagnostics only: where a rich editor's readback first differs from the expected text and
    what kind of characters it dropped or added. Letters and digits are never logged, only
    their class (a / 9); markdown punctuation and whitespace are named so one dictation shows
    which serialization rule an editor such as Claude needs.
    */
    static func mismatchShape(before: String, selection: NSRange, inserted: String, after: String?) -> String {
        let source = before as NSString
        guard let after, selection.location >= 0, selection.length >= 0,
              selection.location + selection.length <= source.length else { return "diff=unreadable" }
        let expected = Array(source.replacingCharacters(in: selection, with: inserted).utf16)
        let actual = Array(after.utf16)
        var prefix = 0
        while prefix < expected.count, prefix < actual.count, expected[prefix] == actual[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < expected.count - prefix, suffix < actual.count - prefix,
              expected[expected.count - 1 - suffix] == actual[actual.count - 1 - suffix] { suffix += 1 }
        func classes(_ units: ArraySlice<UInt16>) -> String {
            String(String(decoding: units, as: UTF16.self).prefix(16).map { c -> Character in
                switch c {
                case "\n": return "n"
                case " ": return "s"
                case "\t": return "t"
                case "\u{00A0}": return "b"
                case "-", "*", ">", "#", "_", "`", "[", "]", "(", ")", "|", "~", ".", ",", ":": return c
                default: return c.isLetter ? "a" : c.isNumber ? "9" : "p"
                }
            })
        }
        let line = expected[..<prefix].filter { $0 == 10 }.count
        let removed = classes(expected[prefix..<(expected.count - suffix)])
        let added = classes(actual[prefix..<(actual.count - suffix)])
        return "diff_prefix=\(prefix) diff_suffix=\(suffix) diff_line=\(line) removed=[\(removed)] added=[\(added)]"
    }

    /*
    Chromium rich editors (Codex, ChatGPT in Chrome) show an empty last line as one "\n" at the
    very end, with the caret just before it. Pasting into that line fills it, so the "\n" goes:
    the editor then reads exactly the old text up to the caret plus the pasted text. Nothing else
    may differ, and the caret check that follows is unchanged.
    */
    /*
    Codex's empty composer reads as a constant line of empty-state text ending in "\n" (measured
    2026-10-12: 18 characters every time, caret 0/0, not equal to AXPlaceholderValue). A paste at
    caret 0 cannot delete text, so when the field then reads exactly the pasted words, what was
    there was the empty-state line. Anything else (any leftover, missing or extra character)
    still fails, and the caret check that follows is unchanged.
    */
    /*
    Claude desktop reports its caret in an offset space that skips line breaks: a caret at the
    end of "a\nb" reads 2, not 3 (measured 2026-10-13 from Production60 and Dev logs: every paste
    into a Claude composer that already held text failed this way while empty composers
    verified 18 of 18). The mapping is deterministic: caret offset c is the position right after
    the c-th character that is not a line break. The only thing it cannot tell apart is a line
    end from the start of the next line, so the candidates are that index plus any line breaks
    that immediately follow it. A paste is accepted only when, exactly:
    - the inserted text has no line break (raw output) and nothing was selected;
    - inserting it at exactly ONE of those candidate indices reproduces the editor's text.
    The caret check that follows stays exact in the editor's own caret space. Anything else
    (an insertion anywhere else, two matching candidates, a caret past the text) returns nil.
    Returns the value-space insertion index.
    */
    static func lineBreakSkippingInsertion(before: String, caretOffset: NSRange, inserted: String,
                                           after: String) -> Int? {
        guard caretOffset.length == 0, caretOffset.location >= 0, !inserted.isEmpty,
              !inserted.contains("\n"), !inserted.contains("\r"),
              // CRLF drafts are not part of the measured model; leave them to the exact rule.
              !before.contains("\r") else { return nil }
        let old = Array(before.utf16), new = Array(after.utf16), add = Array(inserted.utf16)
        guard new.count == old.count + add.count else { return nil }
        // Map the caret: walk to just after the c-th non-line-break unit.
        var index = 0, counted = 0
        while counted < caretOffset.location {
            guard index < old.count else { return nil }
            if old[index] != 10 { counted += 1 }
            index += 1
        }
        var candidates = [index]
        var next = index
        while next < old.count, old[next] == 10 { next += 1; candidates.append(next) }
        // Inserting at i reproduces `after` iff old[..<i] and old[i...] frame `add` inside `new`.
        var prefix = 0
        while prefix < old.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        func reproduces(_ i: Int) -> Bool {
            guard i <= prefix, old.count - i <= suffix else { return false }
            for k in 0..<add.count where new[i + k] != add[k] { return false }
            return true
        }
        let matches = candidates.filter(reproduces)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func replacesEmptyStateText(_ source: NSString, selection: NSRange, inserted: String,
                                               after: String) -> Bool {
        selection.location == 0 && selection.length == 0 && source.length > 0
            && source.hasSuffix("\n") && after == inserted
    }

    private static func fillsEmptyLastLine(_ source: NSString, selection: NSRange, inserted: String,
                                           after: String) -> Bool {
        guard selection.length == 0, source.length > 0,
              selection.location == source.length - 1,
              source.substring(from: selection.location) == "\n" else { return false }
        return after == source.substring(to: selection.location) + inserted
    }
}
