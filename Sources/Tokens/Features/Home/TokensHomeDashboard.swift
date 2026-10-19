


//
import AVFoundation
import AppKit
import Combine
import Speech
import TokensCore
import SwiftUI


extension TokensHome {
    /*
    Home (DESIGN.md §6.1): the hero lines (or the live block while talking), the one rule, then
    Recent. One spacing-0 column of whole squares, so every single line's baseline is on a rule.
    The heading sits on rule 2, level with the other pages' titles (TokensHomeHeroStart lifts
    it). The column starts at the other pages' left edge and may run up to 14 squares wide.
    `inner` (the sheet width) is kept for the shell's call; the column reads tokensSheetSize.
    */
    func homePage(inner: CGFloat) -> some View {
        let fixture = TokensHomePreview.live(model)
        let live = shownLive != nil
        let phase: TalkPhase = fixture == .listening ? .capturing : fixture == .finishing ? .finalizing : model.phase
        let hint = TokensDictationHint(phase: phase, mode: model.activeSessionMode ?? model.rightOptionMode)
        // Fixtures never act: their Stop and Discard are drawn but do nothing (TOK-QA-005).
        let detail = TokensHomePreview.liveDetail(model)
        let confirmed = fixture == nil ? model.audioIsConfirmed : detail != .arming
        let controls = TokensHomeLiveControls.shown(phase: phase, audioConfirmed: confirmed,
                                                    heldByKey: fixture == nil && model.talkIsHeldByKey)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if live {
                    TokensHomeLiveCard(hint: hint,
                                       keyName: model.shortcutName,
                                       text: fixture == nil ? mainLiveText : TokensHomePreview.liveText,
                                       samples: fixture == nil ? model.previewWaveform ?? audio.waveform
                                                               : TokensHomePreview.liveSamples,
                                       confirmed: confirmed,
                                       controls: controls,
                                       keepsInApp: fixture == nil ? model.finishKeepsWordsInApp : detail == .kept,
                                       stop: fixture == nil ? { model.stopTalkFromHome() } : {},
                                       discard: fixture == nil ? { model.discardTalkFromHome() } : {})
                } else {
                    homeHero(hint: hint)
                }
                // The board's one rule, drawn over the grid line under the hero.
                TokensHairline(strong: true)
                    .tokensOnRule()
                recentHome
            }
            .modifier(TokensHomeColumn())
        }
        .tokensRuledScroll()
        .tokensRestingEdge()
        .modifier(TokensHistoryPreviewFixtures(model: model, apply: {
            applyHistoryPreviewFixtures()
            TokensHomePreview.applyHistory(model)
        }))
    }

    /// The talk the rail and Home draw: the model's phase, else a render-only live fixture.
    var shownLive: TokensHomePreview.Live? {
        switch model.phase {
        case .capturing:  return .listening
        case .finalizing: return .finishing
        default:          return TokensHomePreview.live(model)
        }
    }

    // MARK: Hero

    /*
    Ready: "Time to talk", "Hold [key] to talk", Speech model, any held-words line (with its
    Copy), any earlier-talk line, then the Today line (TokensHomeTodayLine, a link to Stats).
    Blocked: "Almost ready", the first blocker with its one red button, then "Then hold [key]
    to talk" and Speech model. One heading line in both states, never a greeting above it.
    TokensHomeLayout.heroCells counts these same lines for Recent's row budget (build 81).
    Proof renders can force Ready with --public-preview-ready, or a blocker with
    --home-preview-blocker.
    */
    private func homeHero(hint: TokensDictationHint) -> some View {
        let ready = heroReady
        return VStack(alignment: .leading, spacing: 0) {
            TokensHomeHeading(ready: ready)
            if ready {
                dictateLine(lead: hint.verb)
                engineLine
                heldWordsLine
                earlierTalkLine
                TokensHomeTodayLine(today: TokensHomeToday.summary(history: model.promptHistory,
                                                                   wordsTotal: wordsTotal)) {
                    select(.stats)
                }
                .tokensOnRule()
            } else {
                homeStatusLine
                dictateLine(lead: "Then " + hint.verb.lowercased())
                engineLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.home.hero")
    }

    /// Ready unless a grant or setup step blocks talking (or a proof render forces either state).
    private var heroReady: Bool {
        (homeReady || TokensPreview.forcesReady) && TokensHomePreview.blocker(model) == nil
    }

    /// What the hero draws above the rule, so Recent asks for only the rows that fit (build 81).
    var heroLines: TokensHomeHeroLines {
        let held = shownHeld
        return TokensHomeHeroLines(ready: heroReady, held: held.reason, heldCopy: held.copyable,
                                   earlier: (TokensHomePreview.earlierRecovery(model) ?? model.earlierRecovery) != nil,
                                   today: wordsTotal > 0)
    }

    /// "Hold [⌥ Left Option] to dictate" in the 17-point lead, the chip centred on the line.
    private func dictateLine(lead: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(lead)
            keyChipButton
                .tokensControlOnBaseline()
            Text("to talk")
        }
        .font(TokensType.lead)
        .foregroundStyle(TokensUI.secondary)
        .lineLimit(1)
        .help("Listening through " + model.effectiveInputDeviceName)
        .accessibilityElement(children: .contain)
        .tokensOnRule()
    }

    /// "Speech model  Orukeet ⌃⌄": the model your words go through, switched right here (build 82).
    private var engineLine: some View {
        _ = storedSpeechEngine  // redraw when the choice changes
        return TokensHomeEngineLine(store: speechModels, shown: TokensHomePreview.engine(model),
                                    talking: talkingNow, talkingWith: talkingModelID,
                                    choose: chooseSpeechModel(id:)) {
            select(.models)
        }
        .tokensOnRule()
    }

    /// The dictation key, shown as a chip. Choosing it opens the key picker straight away.
    private var keyChipButton: some View {
        Button {
            select(.settings)
            detail = .shortcut
        } label: {
            TokensKeyChip(name: model.shortcutName, size: 15, interactive: true)
        }
        .buttonStyle(.plain)
        .help("Change the talk key")
        .accessibilityLabel("Talk key")
        .accessibilityValue(model.shortcutName)
        .accessibilityHint("Opens the key picker")
        .accessibilityIdentifier("tokens.home.dictation-key")
    }

    /*
    Words held back by a failed paste, on the rule after the Speech model line: a red dot, the
    reason in ink2 text at the 28-point pitch, then a quiet Copy that copies exactly those held
    words. Build 81: the line used to end "· Copy latest", naming a control Home did not have
    (the menu bar calls it Copy Last Talk). A talk kept in the app on purpose ("Saved to Recent
    below") is information, so its dot and text are secondary, never red, and it has no Copy:
    its Recent row right below copies it. A failure with no words (a key or microphone error)
    has no Copy either.
    */
    @ViewBuilder
    private var heldWordsLine: some View {
        let held = shownHeld
        if !held.reason.isEmpty {
            let kept = held.reason == TalkModel.keptInAppMessage
            // "latest" is the feedback key copyLatestTranscript sets, menu bar included.
            let copied = model.copyFeedbackKey == "latest"
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TokensStatusDot(color: kept ? TokensUI.secondary : TokensUI.red)
                Text(held.reason)
                    .font(TokensType.body)
                    .foregroundStyle(kept ? TokensUI.secondary : TokensUI.ink2)
                    .tokensReadingPitch()
                    .fixedSize(horizontal: false, vertical: true)
                if held.copyable {
                    Button(copied ? "Copied" : "Copy") { copyHeldWords() }
                        .buttonStyle(TokensLinkButtonStyle())
                        .fixedSize()
                        .help("Copy the words that did not paste")
                        .accessibilityLabel(copied ? "Copied" : "Copy held words")
                        .accessibilityIdentifier("tokens.home.held-copy")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
        }
    }

    /// The held-words line as Home shows it: the reason, and whether there are words to copy.
    private var shownHeld: (reason: String, copyable: Bool) {
        let fixture = TokensHomePreview.heldText(model)
        let reason = TokensHomeHeld.reason(fixture ?? model.retainedFailureText)
        let words = fixture != nil || !model.retainedFailurePayload.isEmpty
        return (reason, words && reason != TalkModel.keptInAppMessage)
    }

    /// Copy latest puts the held words first (TalkModel.latestTranscript), so this copies exactly
    /// them; with nothing held it does nothing rather than copy some other talk.
    private func copyHeldWords() {
        guard !model.retainedFailurePayload.isEmpty else { return }
        model.copyLatestTranscript()
    }

    /*
    Words from an earlier talk that never landed, older than the newest talk (build 81): one quiet
    line with Copy and Forget, so they stay reachable without taking Copy latest from the newest
    talk. Copy resolves them; Forget is the only other way they go.
    */
    @ViewBuilder
    private var earlierTalkLine: some View {
        if let earlier = TokensHomePreview.earlierRecovery(model) ?? model.earlierRecovery {
            let copied = model.copyFeedbackKey == TalkModel.earlierCopyKey(earlier)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TokensStatusDot(color: TokensUI.secondary)
                // A Copy or Forget that could not be saved says so right here, whatever else Home shows.
                Text(copied ? "Earlier talk copied"
                     : TokensHomePreview.earlierNote(model) ?? model.earlierRecoveryNote ?? "An earlier talk was not pasted")
                    .font(TokensType.body)
                    .foregroundStyle(TokensUI.ink2)
                    .lineLimit(1)
                if !copied {
                    Button("Copy") { model.copyEarlierRecovery() }
                        .buttonStyle(TokensLinkButtonStyle())
                        .accessibilityIdentifier("tokens.home.earlier-copy")
                    Button("Forget") { model.forgetEarlierRecovery() }
                        .buttonStyle(TokensLinkButtonStyle())
                        .accessibilityIdentifier("tokens.home.earlier-forget")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
        }
    }

    /// Shared by Settings: persist a preset and move the existing bubble without showing it.
    func selectBubblePlacement(_ placement: BubblePlacement) {
        BubblePlacement.save(placement)
        bubblePlacement = placement
        if let window = compactWindow(), let visible = window.screen?.visibleFrame {
            BubbleWindowPlacement.apply(placement, to: window, visible: visible)
        }
    }

    // MARK: Recent

    /*
    "Recent" (15 medium ink) with "See all ›" trailing, then one-line rows: as many as the sheet
    shows below the hero (TokensHomeLayout.recentRows, 3 to 8). Rows show the time for today,
    otherwise the day ("Yesterday", "Oct 10"). Today's counts live on the Today line above.
    */
    private var recentHome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Recent")
                    .font(TokensType.labelLarge)
                    .foregroundStyle(TokensUI.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                if !model.promptHistory.isEmpty {
                    Button { select(.history) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("See all")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                        }
                    }
                    .font(TokensType.caption)
                    .buttonStyle(TokensLinkButtonStyle(tone: .quiet))
                    .accessibilityLabel("See all")
                    .accessibilityIdentifier("tokens.home.see-all")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
            if model.promptHistory.isEmpty {
                if model.historyStorageError.isEmpty {
                    Text("Your words, kept here")
                        .font(TokensType.body)
                        .foregroundStyle(TokensUI.secondary)
                        .tokensOnRule()
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TokensStatusDot(color: TokensUI.red)
                        Text(model.historyStorageError)
                            .font(TokensType.body)
                            .foregroundStyle(TokensUI.ink2)
                            .tokensReadingPitch()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tokensOnRule()
                }
            } else {
                TokensHomeRecentRows(model: model, hero: heroLines)
                    .accessibilityLabel("Recent")
            }
        }
    }

    // MARK: Status and permissions

    /// Readiness describes the checked grants and setup state, never a promise of delivery.
    private var homeReady: Bool {
        !TalkModel.tokensFirstRunPending && model.shortcutAccessGranted
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && (!SpeechEngineChoice.appleSpeechNeeded(setupPending: TalkModel.tokensSetupInProgress)
                || SFSpeechRecognizer.authorizationStatus() == .authorized)
    }

    /*
    First blocker retains the existing permission recovery priority and model actions. A
    render-only --home-preview-blocker fixture picks which pair is drawn; it never changes what
    the buttons do.
    */
    @ViewBuilder
    private var homeStatusLine: some View {
        let forced = TokensHomePreview.blocker(model)
        if forced == .access || forced == .relaunch || (forced == nil && !model.shortcutAccessGranted) {
            let relaunch = forced == .relaunch || (forced == nil && model.shortcutAccessNeedsRelaunch)
            recoveryLine(relaunch ? "Accessibility allowed. Relaunch to finish."
                                  : "Accessibility is off, so the key does nothing yet.",
                         button: relaunch ? "Relaunch \(appName)" : "Allow Accessibility") {
                if model.shortcutAccessNeedsRelaunch { model.relaunchForShortcutAccess() }
                else { model.openShortcutAccessibilitySettings() }
            }
        } else if forced == .mic || (forced == nil && AVCaptureDevice.authorizationStatus(for: .audio) == .denied) {
            recoveryLine("Microphone is off for \(appName).", button: "Allow microphone") {
                openPrivacyPane("Privacy_Microphone")
            }
        } else if forced == .speech || (forced == nil && SpeechEngineChoice.appleSpeechNeeded(setupPending: TalkModel.tokensSetupInProgress) && SFSpeechRecognizer.authorizationStatus() == .denied) {
            recoveryLine("Speech Recognition is off for \(appName).", button: "Allow speech") {
                openPrivacyPane("Privacy_SpeechRecognition")
            }
        } else if forced == .setup || !homeReady {
            recoveryLine("Finish setup before you talk.", button: "Continue setup") {
                firstRunStage = actualFirstRunStage
                detail = .firstRun
            }
        }
    }

    /*
    The blocker: the message in 15-point ink2, 16 points, then the screen's one red button
    (regular, 32 tall), all on one rule. When that does not fit the column, the button moves
    to the next rule.
    */
    private func recoveryLine(_ message: String, button: String, action: @escaping () -> Void) -> some View {
        let words = Text(message).font(TokensType.body).foregroundStyle(TokensUI.ink2)
        let control = Button(button, action: action)
            .buttonStyle(TokensPrimaryButtonStyle())
            .fixedSize()
            .tokensControlOnBaseline()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                words.lineLimit(1).fixedSize()
                control
            }
            .tokensOnRule()
            VStack(alignment: .leading, spacing: 0) {
                words
                    .tokensReadingPitch()
                    .fixedSize(horizontal: false, vertical: true)
                    .tokensOnRule()
                control
                    .tokensOnRule()
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private var mainLiveText: String {
        let source = audio.transcript.isEmpty ? model.displayText : audio.transcript
        let branded = BrandVocabulary.apply(to: source)
        let characterTalk = CharacterTalk.render(branded)
        return ParagraphFormatter.format(characterTalk.displayText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/*
Home's heading sits on rule 2 at every sheet size, level with the other pages' titles and the
rail's wordmark: TokensHome shrinks Home's empty header strip by one rule whenever this says so
(the strip stays in the tree, §8.1). Before 2026-10-14 only sheets under 400 lifted, which left
an empty band above "Time to talk" on ordinary windows (the heading sat too low).
*/
enum TokensHomeHeroStart {
    static func liftsHero(sheetHeight: CGFloat) -> Bool { true }
}

/*
Home's measures. The column is up to 14 squares (784) so Recent fills the sheet; TokensColumn
still centres it on the rules and keeps a square of margin. Recent shows the rows that land
above the resting edge. The page slot starts on rule 1 and the hero fills whole squares from
there, so in the plain Ready layout the heading is rule 2, the dictate line 3, Speech model 4,
Today 5, the board's rule 6, "Recent" 7 and the first row ends on rule 8. Build 81: the build-80
Speech model line and the held-words and earlier-talk lines each push Recent down a square, and
the budget used to ignore them, so one row too many sat hidden under the bottom edge. At least
3 rows (shorter sheets scroll), at most 8.
*/
enum TokensHomeLayout {
    static let columnMaxWidth: CGFloat = 14 * TokensUI.paperCell
    static let minRows = 3
    static let maxRows = 8
    /// The plain Ready hero: heading, dictate line, Speech model line and Today line.
    static let readyHeroCells = 4
    /// Where the first row ends below the plain Ready hero (rule 8).
    static var firstRowRule: Int { firstRowRule(heroCells: readyHeroCells) }

    /// The hero's squares from rule 1, then the board's rule, "Recent" and the first row.
    static func firstRowRule(heroCells: Int) -> Int { 1 + heroCells + 3 }

    /*
    The hero's squares, counted from the same conditions that draw it (homeHero). Blocked: the
    heading, the blocker, "Then hold [key] to talk" and Speech model; the blocker counts as one
    square because it only wraps in columns so narrow that Recent is already at its 3-row
    minimum. Ready: heading, dictate, Speech model, then the held-words line (more squares when
    its reason wraps at the 28-point pitch), the earlier-talk line and the Today line when shown.
    */
    static func heroCells(_ hero: TokensHomeHeroLines, columnWidth: CGFloat) -> Int {
        guard hero.ready else { return 4 }
        var cells = 3 + (hero.earlier ? 1 : 0) + (hero.today ? 1 : 0)
        if !hero.held.isEmpty {
            // The dot and its gap take 14 points; the quiet Copy at most a square.
            let words = columnWidth - 14 - (hero.heldCopy ? TokensUI.paperCell : 0)
            cells += heldCells(hero.held, width: words)
        }
        return cells
    }

    /// Lines at the 28-point pitch: one line is one square, two or three are two, more are three.
    static func heldCells(_ text: String, width: CGFloat) -> Int {
        guard TokensHistoryRowLayout.isTruncated(text, width: width, lineLimit: 1, size: 15) else { return 1 }
        return TokensHistoryRowLayout.isTruncated(text, width: width, lineLimit: 3, size: 15) ? 3 : 2
    }

    /*
    Home's column starts where every other page's does (TokensColumn's leading edge), so switching
    pages never moves the content sideways. It may then run wider to the right, up to 14 squares,
    keeping a square of margin on the right.
    */
    static func column(sheetWidth W: CGFloat) -> (leading: CGFloat, width: CGFloat) {
        let cell = TokensUI.paperCell
        let page = TokensColumn.layout(sheetWidth: W)
        let room = floor((W - page.leading - cell) / cell) * cell
        return (page.leading, min(columnMaxWidth, max(page.width, room)))
    }

    static func recentRows(sheetHeight: CGFloat, heroCells: Int = readyHeroCells) -> Int {
        let lastRule = Int(floor((sheetHeight - TokensRestingEdgeMask.below) / TokensUI.paperCell))
        return min(maxRows, max(minRows, lastRule - firstRowRule(heroCells: heroCells) + 1))
    }
}

/*
What Home's hero draws above the board's rule, for Recent's row budget. A live talk keeps the
count of the hero it replaces, so Recent does not reshuffle while you talk; rows it pushes under
the bottom edge take no clicks (tokensQuietUnderRestingEdge).
*/
struct TokensHomeHeroLines: Equatable {
    var ready = true
    /// The held-words reason as shown, empty when there is none.
    var held = ""
    var heldCopy = false
    var earlier = false
    var today = true
}

/*
Home's held-words reason (build 81): the stored message without its trailing copy hint
(" · Copy latest" names the menu bar's command), because the line carries its own Copy. The
stored text stays as it is: the recovery pop-up matches on it.
*/
enum TokensHomeHeld {
    static let copyHints = [" · Copy latest", " · Copy captured words"]

    static func reason(_ message: String) -> String {
        for hint in copyHints where message.hasSuffix(hint) { return String(message.dropLast(hint.count)) }
        return message
    }
}

/// Home's page column (TokensHomeLayout.column), with the same bottom padding as every page.
struct TokensHomeColumn: ViewModifier {
    @Environment(\.tokensSheetSize) private var sheet

    func body(content: Content) -> some View {
        let column = TokensHomeLayout.column(sheetWidth: sheet.width)
        content
            .frame(width: column.width, alignment: .leading)
            .padding(.leading, column.leading)
            .padding(.bottom, TokensColumn.bottomPadding(sheetHeight: sheet.height))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Recent's rows: the newest entries, as many as TokensHomeLayout fits below this hero on this
/// sheet. The count reads tokensSheetSize from the environment, never a GeometryReader (§8.1).
struct TokensHomeRecentRows: View {
    @ObservedObject var model: TalkModel
    let hero: TokensHomeHeroLines
    @Environment(\.tokensSheetSize) private var sheet

    var body: some View {
        let column = TokensHomeLayout.column(sheetWidth: sheet.width).width
        let rows = TokensHomeLayout.recentRows(sheetHeight: sheet.height,
                                               heroCells: TokensHomeLayout.heroCells(hero, columnWidth: column))
        TokensHistoryCard(entries: Array(model.promptHistory.prefix(rows)),
                          model: model, previewLines: 1, grouped: false)
    }
}

/*
Home's one heading, `display` 44 ink on the hero's first rule: "Time to talk" when every grant
and setup step is done, "Almost ready" while one blocks dictation. It names the state and invites
the action; there is no greeting above it and no second heading line (2026-10-13).
*/
struct TokensHomeHeading: View {
    static let readyText = "Time to talk"
    static let blockedText = "Almost ready"
    static func text(ready: Bool) -> String { ready ? readyText : blockedText }

    let ready: Bool

    var body: some View {
        Text(Self.text(ready: ready))
            .font(TokensType.display)
            .tracking(TokensType.displayTracking)
            .foregroundStyle(TokensUI.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityAddTraits(.isHeader)
            .tokensOnRule()
    }
}

/*
Render-only Home fixtures (DESIGN.md §8.3), so every changed state can be looked at before it
ships. Each is honoured only with --render-preview-frames in a proof-allowed build on a
synthetic run; none of them writes preferences, consent, history or the clipboard, and none
changes what a button does.
  --home-preview-blocker access|relaunch|mic|speech|setup   which blocker pair Home draws
  --home-preview-live listening|finishing                   the live block with fictional words
  --home-preview-live-detail arming|kept                    with --home-preview-live: no audio yet (Discard only),
                                                            or a stop that keeps the words
  --home-preview-held failed|kept                           the held-words line (with --public-preview-ready)
  --home-preview-history full                               ten fictional talks, six of them timed today
*/
enum TokensHomePreview {
    enum Blocker: String { case access, relaunch, mic, speech, setup }
    enum Live: String { case listening, finishing }
    enum LiveDetail: String { case arming, kept }
    enum Held: String { case failed, kept, unsent }
    enum History: String { case full }

    static func value(after flag: String, arguments: [String] = ProcessInfo.processInfo.arguments,
                      allowed: Bool = ProofRoutes.isAllowed) -> String? {
        guard allowed, arguments.contains("--render-preview-frames"),
              let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1].lowercased()
    }

    private static let blockerFlag = value(after: "--home-preview-blocker").flatMap(Blocker.init(rawValue:))
    private static let liveFlag = value(after: "--home-preview-live").flatMap(Live.init(rawValue:))
    private static let liveDetailFlag = value(after: "--home-preview-live-detail").flatMap(LiveDetail.init(rawValue:))
    private static let heldFlag = value(after: "--home-preview-held").flatMap(Held.init(rawValue:))
    private static let historyFlag = value(after: "--home-preview-history").flatMap(History.init(rawValue:))

    static func blocker(_ model: TalkModel) -> Blocker? { model.isSyntheticRun ? blockerFlag : nil }
    /// --home-preview-engine <id>:<ready|paused|none|percent>, render proofs of the speech-model line.
    static func engine(_ model: TalkModel) -> TokensHomeEngine? {
        guard model.isSyntheticRun, let raw = value(after: "--home-preview-engine") else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let state: SpeechModelStore.State
        switch parts.count == 2 ? parts[1] : "ready" {
        case "ready":  state = .ready
        case "paused": state = .failed("preview")
        case "none":   state = .notDownloaded
        case let p:    state = .downloading((Double(p) ?? 0) / 100)
        }
        return TokensHomeEngine.describe(chosenID: parts[0], state: state)
    }
    /// --models-preview mix, render proofs of the Models tab: the states a real Mac shows (a bare render
    /// binary ships no speech workers, so every download row would read "Coming soon").
    static func modelAvailability(_ model: TalkModel, id: String) -> SpeechModelAvailability? {
        guard model.isSyntheticRun, value(after: "--models-preview") == "mix" else { return nil }
        switch id {
        case SpeechModelCatalog.orukeetID: return .inUse
        case SpeechModelCatalog.appleID, "parakeet-tdt-0.6b-v2": return .ready
        case "whisper-small.en": return .downloading(0.42)
        case "whisper-base.en": return .paused
        default: return .downloadable
        }
    }
    static func live(_ model: TalkModel) -> Live? { model.isSyntheticRun ? liveFlag : nil }
    static func liveDetail(_ model: TalkModel) -> LiveDetail? { model.isSyntheticRun ? liveDetailFlag : nil }
    /// --home-preview-earlier note|discard: the line after a Forget, or a discard, that could not be saved.
    static func earlierNote(_ model: TalkModel) -> String? {
        guard model.isSyntheticRun else { return nil }
        switch value(after: "--home-preview-earlier") {
        case "note":    return "Not forgotten · words kept"
        case "discard": return TalkModel.discardKeptNote
        default:        return nil
        }
    }
    /// --home-preview-earlier: a fictional earlier unsent talk, for render proofs of its Home line.
    static func earlierRecovery(_ model: TalkModel) -> RecoveredTalk? {
        guard model.isSyntheticRun, value(after: "--home-preview-earlier") != nil else { return nil }
        return RecoveredTalk(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!,
                             text: "Fictional earlier talk that never landed.")
    }
    static func heldText(_ model: TalkModel) -> String? {
        guard model.isSyntheticRun, let heldFlag else { return nil }
        switch heldFlag {
        case .kept: return TalkModel.keptInAppMessage
        case .unsent: return TalkModel.unconfirmedPasteMessage(sendWithheld: true)
        case .failed: return "Paste unavailable · Copy latest"
        }
    }

    /*
    --home-preview-history full: replaces this synthetic run's in-memory history (never saved)
    with ten fictional talks, newest first. The six from today carry π receipts so the Today line
    shows talk time; the rest are from earlier days. Assigns only on a difference, so it settles
    when the controls preview script replaces the history.
    */
    @MainActor
    static func applyHistory(_ model: TalkModel) {
        guard model.isSyntheticRun, historyFlag == .full else { return }
        if model.promptHistory.count != fictionalTalks.count || model.promptHistory.first?.text != fictionalTalks[0].text {
            model.promptHistory = history(now: Date())
        }
    }

    static let fictionalTalks: [(text: String, minutesAgo: Double, seconds: Double?)] = [
        ("Keep every recognized word, including the correction I just made.", 2, 4.1),
        ("Make the tiny recording capsule feel immediate and calm.", 9, 3.4),
        ("Green notebook, blue pencil, and the margin notes from Tuesday's review.", 26, 5.2),
        ("Move the reading list under the heading and keep the links as they are.", 48, 4.6),
        ("Draft a short reply to the design thread and say Thursday works for me.", 95, 5.0),
        ("Show all previous prompts without deleting older entries.", 130, 3.3),
        ("Rename the export folder to match the project and keep the old one for a week.", 1_500, nil),
        ("Check the spacing on the settings page at the smallest window size.", 1_620, nil),
        ("Add a note that the café order is ready at noon.", 2_950, nil),
        ("Summarize the three open questions before the planning call.", 4_400, nil),
    ]

    static func history(now: Date, calendar: Calendar = .current) -> [PromptHistoryEntry] {
        // Today's talks squeeze into the time since midnight, so a render just after 00:00 still has them.
        let elapsed = now.timeIntervalSince(calendar.startOfDay(for: now))
        let span = (fictionalTalks.compactMap { $0.seconds == nil ? nil : $0.minutesAgo }.max() ?? 1) * 60 + 60
        return fictionalTalks.map { talk in
            let words = talk.text.split(separator: " ").count
            let text: String = talk.seconds.map { seconds in
                "# π\n" + talk.text + "\n\n---\n\n" + AuthoredPrompt.metadataHeading + "\n\n"
                    + String(format: "> *%.4fs · %d words · %d wpm · 0x thinking (0.0000s)*",
                             seconds, words, Int((Double(words) * 60 / seconds).rounded()))
            } ?? talk.text
            let ago = talk.seconds == nil ? talk.minutesAgo * 60 : talk.minutesAgo * 60 * min(1, elapsed / span)
            return PromptHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-ago), text: text)
        }
    }

    /// Fictional words and a fictional level envelope for the live fixture.
    static let liveText = "Green notebook, blue pencil. Keep every word I say and paste it where I was typing."
    static let liveSamples: [Double] = (0..<96).map { index in
        let t = Double(index)
        return min(1, 0.18 + 0.55 * abs(sin(t * 0.37)) * (0.65 + 0.35 * sin(t * 0.11)))
    }
}

/// Which live-block links Home shows (TOK-QA-005). Hidden, never disabled, when they cannot act.
struct TokensHomeLiveControls: Equatable {
    var stop = false
    var discard = false
    static let none = TokensHomeLiveControls()
    static func shown(phase: TalkPhase, audioConfirmed: Bool, heldByKey: Bool) -> Self {
        guard phase == .capturing, !heldByKey else { return .none }
        return TokensHomeLiveControls(stop: audioConfirmed, discard: true)
    }
}

/*
While a talk runs, Home's hero lines become this block, with no card: a dot and "Listening"
(or "Finishing…"), the red level band centred in the next square, the newest six lines of
words at the 28-point pitch, and how to stop. It only observes the existing capture stream; it
never starts a capture or a second microphone session. While Listening, quiet Stop and Discard
links trail the first rule like Recent's See all (TOK-QA-005): Stop (after the first audio) keeps
the words in Recent and never pastes; Discard ends the talk and keeps nothing.
*/
struct TokensHomeLiveCard: View {
    let hint: TokensDictationHint
    let keyName: String
    let text: String
    let samples: [Double]
    let confirmed: Bool
    var controls: TokensHomeLiveControls = .none
    var keepsInApp = false
    var stop: () -> Void = {}
    var discard: () -> Void = {}
    @State private var textWidth: CGFloat = 0

    static let stopTitle = "Stop"
    static let stopHelp = "Stop and keep the words in Recent"
    static let stopLabel = "Stop talk"
    static let stopHint = "Keeps the words in Recent. Nothing is pasted."
    static let discardTitle = "Discard"
    static let discardHelp = "End this talk without pasting or saving the words"
    static let discardLabel = "Discard talk"
    static let discardHint = "Ends this talk. The words are not pasted or saved."
    static let keptCaption = "Your words will be saved to Recent."

    /// The line under the words: how to stop, or where the words go once finishing.
    static func stopLine(phase: TalkPhase, mode: RightOptionMode, keyName: String, keepsInApp: Bool) -> String {
        if phase == .finalizing { return keepsInApp ? keptCaption : "Your words will paste when ready." }
        return (mode == .tap ? "Press " : "Release ") + keyName + " to stop."
    }

    private static let liveFont = NSFont.systemFont(ofSize: 17)

    private var shownText: String {
        // The newest six measured lines, so a long talk keeps its latest words in view.
        let tail = textWidth > 0
            ? latestMeasuredLines(in: text, font: Self.liveFont, width: max(1, textWidth - 12), count: 6)
            : text
        return tail + (hint.isFinishing ? "" : "│")
    }

    /// Character Talk wraps spelled letters and talked numbers in ⟦TC⟧ / ⟦TN⟧ display markers.
    /// Show those spans in red instead of printing the markers; the words themselves are unchanged.
    static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        var highlighted = false
        var rest = Substring(text)
        let markers: [(String, Bool)] = [("⟦TC⟧", true), ("⟦/TC⟧", false), ("⟦TN⟧", true), ("⟦/TN⟧", false)]
        while !rest.isEmpty {
            let next = markers.compactMap { marker, opens in
                rest.range(of: marker).map { (range: $0, opens: opens) }
            }.min { $0.range.lowerBound < $1.range.lowerBound }
            let end = next?.range.lowerBound ?? rest.endIndex
            var run = AttributedString(String(rest[rest.startIndex..<end]))
            if highlighted { run.foregroundColor = TokensUI.red }
            result += run
            guard let next else { break }
            highlighted = next.opens
            rest = rest[next.range.upperBound...]
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TokensStatusDot(color: hint.isFinishing ? TokensUI.secondary : TokensUI.red)
                Text(hint.isFinishing ? "Finishing…" : "Listening")
                    .font(TokensType.labelLarge)
                    .foregroundStyle(TokensUI.ink)
                Spacer(minLength: 12)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    if controls.stop {
                        Button(Self.stopTitle, action: stop)
                            .buttonStyle(TokensLinkButtonStyle())
                            .fixedSize()
                            .lineLimit(1)
                            .help(Self.stopHelp)
                            .accessibilityLabel(Self.stopLabel)
                            .accessibilityHint(Self.stopHint)
                            .accessibilityIdentifier("tokens.home.live-stop")
                    }
                    if controls.discard {
                        Button(Self.discardTitle, action: discard)
                            .buttonStyle(TokensLinkButtonStyle())
                            .fixedSize()
                            .lineLimit(1)
                            .help(Self.discardHelp)
                            .accessibilityLabel(Self.discardLabel)
                            .accessibilityHint(Self.discardHint)
                            .accessibilityIdentifier("tokens.home.live-discard")
                    }
                }
                .font(TokensType.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
            TokensHomeWaveform(samples: samples, confirmed: confirmed)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .frame(height: TokensUI.paperCell)
            if !text.isEmpty {
                Text(Self.styled(shownText))
                    .font(TokensType.lead)
                    .foregroundStyle(TokensUI.ink)
                    .lineLimit(6)
                    .tokensReadingPitch(size: 17)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Live transcript")
                    .accessibilityValue(String(Self.styled(text).characters))
                    .tokensOnRule()
            }
            Text(Self.stopLine(phase: hint.phase, mode: hint.mode, keyName: keyName, keepsInApp: keepsInApp))
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
                .lineLimit(2)
                .tokensOnRule()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { textWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in textWidth = width }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.home.live-center")
    }
}

/// The existing input envelope as a band of 2pt red bars with 2pt gaps, drawn without an invented
/// oscillation or a second microphone session. Silence shows as a faint dotted baseline.
struct TokensHomeWaveform: View {
    let samples: [Double]
    let confirmed: Bool
    var body: some View {
        Canvas { context, size in
            let bar: CGFloat = 2, gap: CGFloat = 2
            let count = max(1, Int((size.width + gap) / (bar + gap)))
            let source = confirmed ? samples.suffix(96).map { $0.isFinite ? min(1, max(0, $0)) : 0 } : []
            let mid = size.height / 2
            for index in 0..<count {
                // Stretch the newest envelope across the band; the oldest sample sits at the left.
                var value = 0.0
                if !source.isEmpty {
                    let position = Int(Double(index) / Double(count) * Double(source.count))
                    value = source[min(source.count - 1, max(0, position))]
                }
                let height = max(bar, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(index) * (bar + gap), y: mid - height / 2, width: bar, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2),
                             with: .color(value > 0.02 ? TokensUI.red : TokensUI.red.opacity(0.22)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(confirmed ? "Microphone waveform" : "Microphone arming")
    }
}


/// Presentation follows the real shortcut edges. Finalizing ignores keys, so it must
/// show a waiting state instead of asking for a second stop or a new recording.
/*
Home's speech-model line (build 80; a fundamental thing to show). It names the model that
will turn the next words into text. While a selected local model downloads, its name
stays selected and a small pill shows progress; dictation waits. Its model menu switches models; "Manage models…" opens the Models tab (build 82).
*/
struct TokensHomeEngine: Equatable {
    var name: String
    var pill: String?

    @MainActor static func current(store: SpeechModelStore) -> TokensHomeEngine {
        let id = SpeechEngineChoice.selectedModelID()
        return describe(chosenID: id, state: store.state(for: id))
    }

    static func describe(chosenID: String, state: SpeechModelStore.State) -> TokensHomeEngine {
        guard let entry = SpeechModelCatalog.entry(chosenID), entry.runtime != .apple else {
            return TokensHomeEngine(name: "Apple", pill: nil)
        }
        switch state {
        case .builtIn, .ready:
            return TokensHomeEngine(name: entry.name, pill: nil)
        case .downloading(let fraction):
            return TokensHomeEngine(name: entry.name, pill: "\(Int(fraction * 100))%")
        case .failed:
            return TokensHomeEngine(name: entry.name, pill: "Download paused")
        case .notDownloaded:
            return TokensHomeEngine(name: entry.name, pill: "Not downloaded")
        case .comingSoon:
            return TokensHomeEngine(name: entry.name, pill: "Unavailable in this build")
        }
    }

    var spoken: String { "Speech model: " + name + (pill.map { ", " + $0 } ?? "") }
}

/*
Home's speech-model line (build 82): "Speech model" and the in-place menu. Choosing a model on this
Mac switches here; "Manage models…" opens the Models tab (no detour to switch).
*/
struct TokensHomeEngineLine: View {
    @ObservedObject var store: SpeechModelStore
    /// Render fixtures only: the line's name and pill instead of the store's.
    var shown: TokensHomeEngine? = nil
    var talking = false
    var talkingWith: String? = nil
    let choose: (String) -> Void
    let manage: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Speech model")
                .font(TokensType.body)
                .foregroundStyle(TokensUI.secondary)
                .padding(.trailing, 14)
                .accessibilityHidden(true)
            TokensModelMenu(look: .home, store: store, talking: talking, talkingWith: talkingWith,
                            choose: choose, manage: manage, shown: shown)
            if talkingWith == nil, let pill = (shown ?? TokensHomeEngine.current(store: store)).pill {
                // The little bubble: a chosen model still downloading, while Apple carries the words.
                Text(pill)
                    .font(TokensType.caption.monospacedDigit())
                    .foregroundStyle(TokensUI.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TokensUI.chip))
                    .padding(.leading, 10)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct TokensDictationHint {
    let phase: TalkPhase
    let mode: RightOptionMode

    var isFinishing: Bool { phase == .finalizing }
    var verb: String {
        if phase == .capturing { return mode == .tap ? "Press" : "Release" }
        return mode == .tap ? "Press" : "Hold"
    }
    var purpose: String { phase == .capturing ? "to stop" : "to talk" }
    var instruction: String {
        if isFinishing { return "Finishing your transcript. Your words will paste when ready." }
        if phase == .capturing {
            return mode == .tap ? "Recording. Press the key again to stop and paste."
                                : "Recording. Let go of the key to stop and paste."
        }
        return mode == .tap
            ? "Click into any text field, press the key, talk, then press it again to paste."
            : "Click into any text field, hold the key, talk, then let go to paste."
    }
}
