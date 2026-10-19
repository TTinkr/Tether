


//
import CoreGraphics
import Foundation


// DeliveryReturnGate — holds back Return/Enter between the stop edge and finished delivery


/// Hold a physical Return across asynchronous stop/finalization so it cannot
/// edit or submit the destination before insertion. Key-up is paired even if
/// delivery completed between the two edges.
struct DeliveryReturnGate {
    /*
    pending:   between the stop edge (begin) and the end of delivery (finish).
    requested: a Return was swallowed while pending, so the app owes the target one Return.
    heldCodes: Return keys whose key-down was swallowed; their key-up is swallowed too.
    */
    private(set) var pending          = false
    private(set) var requested        = false
    private var heldCodes: Set<Int64> = []
    /// When pending began (system uptime); a hold past `limit` ends by itself.
    private var beganAt: TimeInterval = 0
    /*
    Safety net (build 81): a talk that fails between Stop and delivery used to leave Return
    swallowed in every app until the next talk. The model releases it on failure; this cap
    catches any path that still forgets. Long enough for a slow final decode.
    */
    static let limit: TimeInterval = 30
    mutating func begin(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pending = true; requested = false; beganAt = now
    }
    mutating func finish() { pending = false; requested = false }
    /*
    Only Return (36) and keypad Enter (76) are ever touched. Returns true when the event
    should be swallowed: a key-down while pending (or a repeat of a held one), or the
    key-up of a key whose key-down was swallowed, even after finish.
    */
    mutating func handle(keyCode: Int64, down: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        if !down { return heldCodes.remove(keyCode) != nil }
        if pending, now - beganAt > Self.limit {
            pending = false; requested = false
            Diagnostics.event("delivery_return_released reason=expired")
        }
        guard pending || heldCodes.contains(keyCode) else { return false }
        heldCodes.insert(keyCode)
        if pending { requested = true }
        return true
    }
}


// StagedPrompt — text written straight into the editor at stop: header, finished words, rest


/// Append-only presentation: final statistics follow the body so the first
/// bytes are immutable while the recognizer drains the last spoken words.
enum StagedPrompt {
    /// AX writability is not evidence of editor support (Codex may advertise it
    /// while rejecting selected-text writes). Only opt in a proven native editor.
    static func allowsDirectInsertion(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.TextEdit"
    }

    static let header = "# π Talked to tinkr\n\n"
    /*
    The first two blocks of the formatted prompt (title, then the time/words/wpm lines) for
    the words heard so far, so the header can be written first and never changed after.
    Falls back to the plain header when the formatted prompt has fewer than three blocks.
    */
    static func snapshotHeader(body: String, duration: Double) -> String {
        let wrapped  = TokensPrompt.format(body, durationSeconds: duration, countTranscript: body)
        let sections = wrapped.components(separatedBy: "\n\n")
        guard sections.count >= 3 else { return header }
        return sections[0] + "\n\n" + sections[1] + "\n\n"
    }
    static func render(body: String, duration: Double, frozenHeader: String? = nil) -> String {
        (frozenHeader ?? snapshotHeader(body: body, duration: duration)) + body
    }
    /*
    The first wordCount words of raw, with their exact spacing and the whitespace after
    the last one. The recognizer reports how many leading words are final.
    */
    static func stablePrefix(_ raw: String, wordCount: Int) -> String {
        guard wordCount > 0 else { return "" }
        var words  = 0
        var inWord = false
        for i in raw.indices {
            if raw[i].isWhitespace { inWord = false }
            else if !inWord {
                words += 1
                if words > wordCount { return String(raw[..<i]) }
                inWord = true
            }
        }
        return raw
    }

//
// :)
//
//
    static func chunks(stableText: String) -> [String] {
        // One short, finalized sentence only; never expose a volatile ASR tail.
        guard let end = stableText.firstIndex(where: { ".!?".contains($0) }),
              !CharacterTalk.render(stableText).hasProtectedSpan else { return [] }
        let sentence = String(stableText[...end])
        let words    = sentence.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { return [] }
        /*
        Keep exact whitespace/graphemes. At most 4 chunks / 120ms of animation.
        Each chunk is two words plus the space after them. Words after the last full
        two-word chunk are not returned; they arrive later with the remainder.
        */
        var chunks: [String] = []
        var start            = stableText.startIndex
        var wordCount        = 0
        var wasSpace         = true
        for i in stableText.indices {
            let space = stableText[i].isWhitespace
            if !space && wasSpace { wordCount += 1 }
            if wordCount > 2 {
                chunks.append(String(stableText[start..<i]))
                start = i; wordCount = 1
                if chunks.count == 4 { break }
            }
            wasSpace = space
            if i == end { break }
        }
        return chunks
    }
    /*
    What is left to write once the final text is known. nil when the final text no longer
    starts with what was already written (the recognizer revised it), so nothing is added.
    */
    static func remainder(final: String, committed: String) -> String? {
        guard final.hasPrefix(committed) else { return nil }
        return String(final.dropFirst(committed.count))
    }
}


// ThreeStepPaste — splits a finished prompt into header, opening words, and the rest


/// Three-step delivery: pi marker and opening fragment, a short opening stream, then the rest
/// including final metadata. A plan only re-cuts the final text; joined back
/// together the steps are that text, character for character.
struct ThreeStepPaste: Equatable, Sendable {
    static let bodyMarker               = "## Transcript\n\n"
    private static let legacyBodyMarker = "## Your words\n\n"
    static let maximumOpeningWords      = 6
    static let minimumOpeningWords      = 2

    let header: String
    let opening: [String]
    let rest: String

    /// First word and half the next arrive with the pi marker, then a short opening
    /// stream, then every remaining word and the final metadata in one paste.
    /// Swift Character boundaries avoid splitting an emoji or composed character.
    var steps: [String] {
        guard opening.count >= 2 else { return [header + opening.joined() + rest] }
        let second = opening[1]
        let split = second.index(second.startIndex, offsetBy: max(1, second.count / 2))
        return [header + opening[0] + second[..<split],
                String(second[split...]) + opening.dropFirst(2).joined(), rest]
    }

    /// Nil when the text has no header, or its opening is too short or not plain words; such a
    /// prompt is delivered in one piece.
    static func plan(_ text: String) -> Self? {
        // Current minimal format, plus legacy history formats. Preserve the optional
        // separator preparedText inserts after an existing word byte-for-byte.
        let bodyStart: String.Index
        if let prefix = ["# π\n", " # π\n"].first(where: { text.hasPrefix($0) }) {
            bodyStart = text.index(text.startIndex, offsetBy: prefix.count)
        } else {
            let markerText = text.range(of: Self.bodyMarker) == nil ? Self.legacyBodyMarker : Self.bodyMarker
            guard text.hasPrefix("# π ") || text.hasPrefix(" # π "),
                  let marker = text.range(of: markerText) else { return nil }
            let head = text[..<marker.lowerBound]
            guard head.contains("\n> *") || (head.hasSuffix("\n\n") && !head.dropLast(2).contains("\n")) else { return nil }
            bodyStart = marker.upperBound
        }
        let body = text[bodyStart...]
        var opening: [String] = []
        var cursor            = body.startIndex
        while opening.count < maximumOpeningWords {
            guard let space = body[cursor...].firstIndex(of: " ") else { break }
            let word = body[cursor..<space]
            // Plain spoken words only: markup, notation and line breaks stay in the final piece.
            guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "'’,.?!-".contains($0) }) else { break }
            let next = body.index(after: space)
            guard next < body.endIndex, !body[next].isWhitespace else { break }
            opening.append(String(body[cursor...space]))
            cursor = next
        }
        let rest = String(body[cursor...])
        guard opening.count >= minimumOpeningWords, rest.contains(where: { !$0.isWhitespace }) else { return nil }
        let plan = Self(header: String(text[..<bodyStart]), opening: opening, rest: rest)
        return plan.steps.joined() == text ? plan : nil
    }
}

/// Gradually accelerate the minimal prompt instead of showing three large blocks.
/// The original parser owns the safe opening and legacy compatibility; splitting
/// only changes delivery boundaries, never content. Final metadata remains intact.
struct AcceleratingPaste {
    let steps: [String]
    static let gapsMicroseconds: [UInt32] = [30_000, 45_000, 25_000, 10_000, 0]
    static let maximumPieces = 6
    static let deliveryBudgetSeconds: TimeInterval = 0.260

    static func plan(_ text: String) -> Self? {
        guard let base = ThreeStepPaste.plan(text) else { return nil }
        guard text.hasPrefix("# π\n") || text.hasPrefix(" # π\n") else {
            return Self(steps: base.steps)
        }
        // Instant marker; then two slow words, medium groups, and one ultrafast
        // remainder. Bound the number of external writes to fit a ~300ms reveal.
        let first = base.header
        let remaining = String(text.dropFirst(first.count))
        var cursor = remaining.startIndex
        var pieces = [first]
        for groupSize in [1, 1, 3, 6] {
            let start = cursor
            var count = 0
            for _ in 0..<groupSize {
                guard cursor < remaining.endIndex,
                      let space = remaining[cursor...].firstIndex(of: " ") else { break }
                let word = remaining[cursor..<space]
                // Keep markup, pause tags, spelled/number spans, emoji and newlines
                // in the final piece intact. Only plain words are revealed early.
                guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "'’,.?!-".contains($0) }) else { break }
                let next = remaining.index(after: space)
                guard next < remaining.endIndex, !remaining[next].isWhitespace else { break }
                cursor = next
                count += 1
            }
            if cursor > start { pieces.append(String(remaining[start..<cursor])) }
            if count < groupSize { break }
        }
        let tail = String(remaining[cursor...])
        if !tail.isEmpty { pieces.append(tail) }
        guard pieces.count > 1, pieces.allSatisfy({ !$0.isEmpty }), pieces.joined() == text else { return nil }
        return Self(steps: pieces)
    }

    /// An already acknowledged stop prefix may end inside the first piece.
    /// Retain every later boundary instead of collapsing back into two pastes.
    static func remainder(prefix: String, payload: String) -> [String]? {
        guard payload.hasPrefix(prefix), let plan = plan(payload) else { return nil }
        var consumed = prefix.count
        var result: [String] = []
        for piece in plan.steps {
            if consumed >= piece.count { consumed -= piece.count }
            else {
                result.append(String(piece.dropFirst(consumed)))
                consumed = 0
            }
        }
        guard result.count > 1, result.joined() == String(payload.dropFirst(prefix.count)) else { return nil }
        return result
    }
}

//
// :)
//
//
// StagedPasteDriver — posts pieces one at a time, each only after the last is seen to land


/// The order of a staged paste, kept apart from the clipboard and keyboard so it can be tested:
/// post a piece, wait until the editor shows it, then post the next. A piece is never posted while
/// an earlier one may still be reading the clipboard.
enum StagedPasteDriver {
    enum Outcome: Equatable {
        /// Every piece was posted. `acknowledged` pieces were seen to land before the last one went.
        case posted(acknowledged: Int)
        /// Nothing was posted; the editor is untouched.
        case failedBeforeAnything(String)
        /// Some pieces are in the editor and the rest are not. Never replay or submit.
        case failedPartway(String, posted: Int)
    }
    // Read immediately, then watch for up to 50 × 8 ms = 400 ms before the existing
    // 250 ms grace. A ready editor never incurs an unconditional polling sleep.
    static let pollsPerPiece = 50
    static let pollMicroseconds: UInt32 = 8_000
    static let unacknowledgedGraceMicroseconds: UInt32 = 250_000
    static let revealBudgetSeconds: TimeInterval = 0.05
    /// Visual beat after the middle piece is confirmed.
    static let finalRevealHoldMicroseconds: UInt32 = 150_000

    /// `post(piece, expecting)` puts one piece into the editor and returns nil, or a reason it could
    /// not; `expecting` is the editor text as last read (nil for the first piece, which runs the
    /// caller's full preflight). `read` returns the editor's text, or nil when it cannot be read.
    static func run(pieces: [String], initial: String?, selection: NSRange? = nil, post: (String, String?) -> String?,
                    read: () -> String?, sleep: (UInt32) -> Void,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    finalRevealHold: UInt32 = 0, minimumAcknowledgedPieces: Int = 1,
                    interPieceHolds: [UInt32] = [], budgetSeconds: TimeInterval = revealBudgetSeconds,
                    accepts: (String, NSRange, String, String) -> Bool = { before, range, piece, after in
                        after == (before as NSString).replacingCharacters(in: range, with: piece)
                    }) -> Outcome {
        guard !pieces.isEmpty else { return .failedBeforeAnything("nothing_to_insert") }
        if pieces.count > 1 {
            guard let initial, let selection, selection.location >= 0, selection.length >= 0,
                  selection.location <= (initial as NSString).length,
                  selection.length <= (initial as NSString).length - selection.location else {
                return .failedBeforeAnything("unreadable_selection")
            }
        }
        /*
        More than one piece needs a readable editor text and a valid caret, checked above;
        that is what makes `seen!` below safe, since the loop only runs for two or more.
        After each landed piece the caret moves to just past it.
        */
        var caret     = selection ?? NSRange(location: 0, length: 0)
        var remaining = pieces
        var seen      = initial
        var posted    = 0, acknowledged = 0
        let revealStarted = now()
        while remaining.count > 1 {
            let piece    = remaining.removeFirst()
            if let failure = post(piece, posted == 0 ? nil : seen) {
                return posted == 0 ? .failedBeforeAnything(failure) : .failedPartway(failure, posted: posted)
            }
            posted += 1
            var landed = false
            for poll in 0...pollsPerPiece {
                if let observed = read(), observed != seen {
                    guard accepts(seen!, caret, piece, observed) else { return .failedPartway("unexpected_editor_text", posted: posted) }
                    seen = observed; landed = true; break
                }
                if poll < pollsPerPiece { sleep(pollMicroseconds) }
            }
            guard landed else {
                /*
                Not seen in time: give the editor a moment. If the piece shows up late, everything
                left goes as one piece. If it never shows, its Command-V may still be waiting to read
                the clipboard, so nothing more is posted.
                */
                sleep(unacknowledgedGraceMicroseconds)
                guard let now = read(), now != seen else { return .failedPartway("unacknowledged", posted: posted) }
                guard accepts(seen!, caret, piece, now) else { return .failedPartway("unexpected_editor_text", posted: posted) }
                seen      = now
                remaining = [remaining.joined()]
                break
            }
            acknowledged += 1
            // Delays only follow verified delivery. The next post still rechecks
            // focus, caret, text and clipboard ownership after this visual wait.
            if acknowledged <= interPieceHolds.count {
                let delay = interPieceHolds[acknowledged - 1]
                if acknowledged >= max(1, minimumAcknowledgedPieces),
                   now() - revealStarted + Double(delay) / 1_000_000 >= budgetSeconds {
                    remaining = [remaining.joined()]
                    break
                }
                if delay > 0 { sleep(delay) }
            }
            caret = NSRange(location: caret.location + (piece as NSString).length, length: 0)
            // The reveal budget is cosmetic, not acknowledgement evidence. Only an
            // accepted piece permits replacing the clipboard with the remaining text.
            // Production preserves the opening-word tier even when the title ACK
            // consumes the cosmetic budget; a real ACK timeout still falls back above.
            if acknowledged >= max(1, minimumAcknowledgedPieces),
               now() - revealStarted >= budgetSeconds {
                remaining = [remaining.joined()]
                break
            }
        }
        // This is visual pacing, never proof that the paste landed. Only a confirmed
        // preceding piece earns the hold; lease/clipboard checks still run afterward.
        if acknowledged > 0, finalRevealHold > 0 { sleep(finalRevealHold) }
        if let failure = post(remaining[0], posted == 0 ? nil : seen) {
            return posted == 0 ? .failedBeforeAnything(failure) : .failedPartway(failure, posted: posted)
        }
        return .posted(acknowledged: acknowledged)
    }
}

//
// :)
//
//
// PasteAckHistory — per-app count of single pastes seen to land; staging needs one exact acknowledged paste


/// Which editors have shown, on ordinary single pastes, that their readable text moves when a paste
/// lands. Staged delivery is offered only there. Holds bundle identifiers and small counts.
enum PasteAckHistory {
    // Prior history rejected rich-editor sentinels that this policy now verifies.
    static let preferenceKey = "TokensPasteAckHistory.v3"
    /// Consecutive acknowledged single pastes needed before an editor is staged.
    static let required = 1

    /// Rich composers have an explicit per-piece text/caret acknowledgement policy.
    /// Native fields use the same one-paste calibration; opaque editors never reach this check.
    static func allowsStaging(bundle: String?, richComposer: Bool,
                              in defaults: UserDefaults = .standard) -> Bool {
        guard let bundle, !bundle.isEmpty else { return false }
        // Editors with a final-reveal breaker must use that guarded route exclusively.
        // Otherwise a later single-paste success bypasses their build latch through
        // generic history, and also enables the speculative early-prefix path.
        guard !finalRevealBundles.contains(bundle) else { return false }
        /*
        A rich composer needs one verified paste into a rich composer of this app, not just any
        field of it (build 81): a verified plain <textarea> or search box in Chrome used to arm
        piecewise reveal for ChatGPT, Claude.ai or Gmail composers, which could not acknowledge
        the pieces and ended as "Partial text inserted". Unfamiliar editors never risk a partial
        insertion on their first dictation.
        */
        /*
        Browsers fail closed for rich composers: every site shares one
        bundle, so a verified ChatGPT composer would arm Gmail's or any other site's, including
        the stop prefix. Tokens never reads page URLs, so there is no private, stable per-site
        key: browser composers always take one full paste.
        */
        if richComposer, browserBundles.contains(bundle) { return false }
        let richCount = (defaults.dictionary(forKey: preferenceKey) as? [String: Int])?[richKey(bundle)] ?? 0
        return richComposer ? richCount >= 1 : trusts(bundle: bundle, in: defaults)
    }

    /// Codex cannot reliably acknowledge the speculative marker with its trailing
    /// newline. The final authored plan can carry that whitespace into the next
    /// acknowledged write. Build49 live trials verified this distinct transport;
    /// ordinary history must still never re-enable the early-prefix path above.
    static let codexFinalRevealDisabledKey = "TokensCodexFinalRevealDisabled.v1"
    static var runningBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unversioned"
    }

    /// Rich composers that may earn the authored final reveal. Claude desktop joins Codex
    /// (it behaves like Codex); each still needs a verified
    /// ordinary paste first, so an editor whose readback never verifies never streams.
    static let finalRevealBundles: Set<String> = ["com.openai.codex", "com.anthropic.claudefordesktop"]

    /// Codex keeps its original key so an existing build latch still applies; other editors
    /// get their own key, so one editor's failure never switches another off.
    static func finalRevealDisabledKey(bundle: String) -> String {
        bundle == "com.openai.codex" ? codexFinalRevealDisabledKey : "TokensFinalRevealDisabled.v1.\(bundle)"
    }

    static func disableCodexFinalReveal(bundle: String = "com.openai.codex", build: String = runningBuild,
                                       in defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: finalRevealDisabledKey(bundle: bundle))
    }

    /// Stop the current delivery in every case. Environmental interruptions are
    /// not evidence that Codex cannot acknowledge the transport: require a fresh
    /// verified single paste before the next reveal, rather than disabling the
    /// feature for the entire build. Unknown/transport failures stay latched.
    @discardableResult
    static func recordCodexFinalRevealFailure(reason: String, bundle: String = "com.openai.codex",
                                              build: String = runningBuild,
                                              in defaults: UserDefaults = .standard) -> Bool {
        record(bundle: bundle, acknowledged: false, in: defaults)
        switch reason {
        case "clipboard_changed_during_reveal", "clipboard_changed_during_reveal_ack",
             "target_changed_during_reveal", "target_changed_during_reveal_ack",
             "target_or_clipboard_changed_between_steps", "clipboard_changed_between_steps",
             "target_changed_between_steps", "target_changed_before_clipboard", "target_changed_before_paste",
             "focus_changed", "window_changed", "cancelled":
            return false
        default:
            disableCodexFinalReveal(bundle: bundle, build: build, in: defaults)
            return true
        }
    }

    static func allowsCodexFinalReveal(bundle: String?, richComposer: Bool,
                                      exactPlan: Bool, continuation: Bool,
                                      build: String = runningBuild,
                                      in defaults: UserDefaults = .standard) -> Bool {
        guard let bundle, finalRevealBundles.contains(bundle) else { return false }
        return richComposer && exactPlan && !continuation
            && trusts(bundle: bundle, in: defaults)
            && defaults.string(forKey: finalRevealDisabledKey(bundle: bundle)) != build
    }

    /// The production gate combines transport prerequisites with the two trust routes.
    /// Keep it shared with regression tests so a generic-history bypass is observable.
    static func deliveryStagingEligibility(bundle: String?, richComposer: Bool,
                                          exactPlan: Bool, continuation: Bool,
                                          threeSteps: Bool, stageable: Bool, boundaryTrial: Bool,
                                          build: String = runningBuild,
                                          in defaults: UserDefaults = .standard)
        -> (historyAllows: Bool, finalRevealAllows: Bool, mayStage: Bool) {
        let history = allowsStaging(bundle: bundle, richComposer: richComposer, in: defaults)
        let finalReveal = allowsCodexFinalReveal(bundle: bundle, richComposer: richComposer,
            exactPlan: exactPlan, continuation: continuation, build: build, in: defaults)
        return (history, finalReveal, threeSteps && stageable && (boundaryTrial || history || finalReveal))
    }

    /// Web browsers: one bundle, many sites (rich composers there never stage).
    static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "ai.perplexity.comet", "com.openai.atlas",
    ]

    /// The rich-composer count's own key beside the app's (build 81).
    static func richKey(_ bundle: String) -> String { bundle + "#rich" }

    /*
    A landed paste adds one (capped at 99); any paste that did not land resets to zero. The app's
    count moves on every result, as before (the Codex/Claude final reveal reads it); a rich
    composer's result also moves its own count, and any failure resets both.
    */
    static func record(bundle: String?, acknowledged: Bool, richComposer: Bool = false,
                       in defaults: UserDefaults = .standard) {
        guard let bundle, !bundle.isEmpty else { return }
        var history     = defaults.dictionary(forKey: preferenceKey) as? [String: Int] ?? [:]
        history[bundle] = acknowledged ? min((history[bundle] ?? 0) + 1, 99) : 0
        if richComposer || !acknowledged {
            let rich = richKey(bundle)
            history[rich] = acknowledged ? min((history[rich] ?? 0) + 1, 99) : 0
        }
        defaults.set(history, forKey: preferenceKey)
    }

    /// The current consecutive-acknowledgement count, for diagnostics.
    static func count(bundle: String?, in defaults: UserDefaults = .standard) -> Int {
        guard let bundle else { return 0 }
        return (defaults.dictionary(forKey: preferenceKey) as? [String: Int])?[bundle] ?? 0
    }

    static func trusts(bundle: String?, in defaults: UserDefaults = .standard) -> Bool {
        guard let bundle else { return false }
        return ((defaults.dictionary(forKey: preferenceKey) as? [String: Int])?[bundle] ?? 0) >= required
    }
}

