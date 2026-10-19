


//
import AVFoundation
import AppKit
import Combine
import Speech
import TokensCore
import SwiftUI


extension TokensHome {
    /*
    Home (DESIGN.md §6.1), build 83 (approved mock): the talk line ("Tap
    [key] to talk", the verb switches tap and hold) over a resting chalk line, or the live block
    while talking; then the talks grouped by day beside a small card (words this week, usual
    speed, streak, speech model). First launch shows how to try a first talk instead. Blocked:
    the blocked hero alone. One spacing-0 column of whole squares, every baseline on a rule.
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
        return homeColumn(live: live, hint: hint, fixture: fixture, detail: detail,
                          confirmed: confirmed, controls: controls)
        .modifier(TokensHistoryPreviewFixtures(model: model, apply: {
            applyHistoryPreviewFixtures()
            TokensHomePreview.applyHistory(model)
        }))
    }

    /// The header (talk line, or the live block), the board of talks and the side card, or the
    /// blocked hero, in Home's ruled column.
    private func homeColumn(live: Bool, hint: TokensDictationHint, fixture: TokensHomePreview.Live?,
                            detail: TokensHomePreview.LiveDetail?, confirmed: Bool,
                            controls: TokensHomeLiveControls) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if live || heroReady {
                    // top, one rule, then the talks on the left and the card on the right.
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
                                TokensHomeRestHead(keyName: TokensHomePreview.keyName(model) ?? model.shortcutName,
                                                   tap: (TokensHomePreview.mode(model) ?? model.rightOptionMode) == .tap) {
                                    keyChipButton
                                }
                            }
                    }
                    TokensHairline(strong: true)
                        .tokensOnRule()
                    TokensHomeBoard(talks: { homeTalks }, card: { homeSideCard })
                } else {
                    homeHero(hint: hint)
                }
            }
            .modifier(TokensHomeColumn())
        }
        .tokensRuledScroll()
        .tokensRestingEdge()
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
    Blocked (a grant or setup step stops talking): "Almost ready", the first blocker with its one
    red button, then "Then tap [key] to talk". Ready Home is TokensHomeRestHead instead. Proof
    renders can force Ready with --public-preview-ready, or a blocker with --home-preview-blocker.
    */
    private func homeHero(hint: TokensDictationHint) -> some View {
        let tap = (TokensHomePreview.mode(model) ?? model.rightOptionMode) == .tap
        return VStack(alignment: .leading, spacing: 0) {
            TokensHomeHeading(ready: false)
            homeStatusLine
            dictateLine(lead: "Then " + (tap ? "tap" : "hold"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.home.hero")
    }

    /*
    Under the talk space and its rule: the talks, newest first and grouped by day like History,
    on the left; the side card (TokensHomeSideCard) on the right (UX review). Words that did not land lead the list as their own rows. With no
    talks yet (first launch) the list is three steps to a first talk. A column too narrow for both
    keeps the list and drops the card (Stats and Models still have it all).
    */

    private var homeSideCard: some View {
        _ = storedSpeechEngine  // redraw when the choice changes
        let mode = TokensHomePreview.mode(model) ?? model.rightOptionMode
        return TokensHomeSideCard(summary: TokensHomeCardSummary.cached(history: model.promptHistory),
                                  mode: Binding(get: { mode }, set: { chosen in
                                      // Fixtures never act (DESIGN.md §8.3).
                                      guard !model.isSyntheticRun else { return }
                                      model.selectRightOptionMode(chosen)
                                  })) {
            TokensModelMenu(look: .home, store: speechModels, talking: talkingNow, talkingWith: talkingModelID,
                            choose: chooseSpeechModel(id:), manage: { select(.models) },
                            shown: TokensHomePreview.engine(model))
        }
    }

    @ViewBuilder
    private var homeTalks: some View {
        VStack(alignment: .leading, spacing: 0) {
            heldRow
            earlierRow
            if !model.historyStorageError.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TokensStatusDot(color: TokensUI.red)
                    Text(model.historyStorageError)
                        .font(TokensType.body)
                        .foregroundStyle(TokensUI.ink2)
                        .lineLimit(2)
                }
                .tokensOnRule()
            } else if model.promptHistory.isEmpty {
                TokensHomeFirstTalk(keyName: TokensHomePreview.keyName(model) ?? model.shortcutName,
                                    tap: (TokensHomePreview.mode(model) ?? model.rightOptionMode) == .tap)
            } else {
                TokensHistoryCard(entries: Array(model.promptHistory.prefix(TokensHomeLayout.talkRows)),
                                  model: model, previewLines: 1, grouped: true)
                    .accessibilityLabel("Talks")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /*
    The newest talk's words that did not paste, as the list's first row (no
    red "Paste unavailable" line): "Didn't paste" in red, the words' first line, then Copy, which
    copies exactly those words (copyLatestTranscript puts them first). A talk kept on purpose is
    already in the list below; a failure with no words shows its reason, no Copy.
    */
    @ViewBuilder
    private var heldRow: some View {
        let fixture = TokensHomePreview.heldText(model)
        let stored = fixture ?? model.retainedFailureText
        if !stored.isEmpty && stored != TalkModel.keptInAppMessage {
            let words = fixture != nil ? "Move the reading list under the heading and keep the link."
                                       : model.retainedFailurePayload
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if words.isEmpty {
                    TokensStatusDot(color: TokensUI.red)
                    Text(TokensHomeNote.reason(stored))
                        .foregroundStyle(TokensUI.ink2)
                } else {
                    Text("Didn't paste")
                        .foregroundStyle(TokensUI.red)
                        .fixedSize()
                    Text(words)
                        .foregroundStyle(TokensUI.ink)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button(model.copyFeedbackKey == "latest" ? "Copied" : "Copy") {
                        if !model.retainedFailurePayload.isEmpty { model.copyLatestTranscript() }
                    }
                    .buttonStyle(TokensLinkButtonStyle())
                    .fixedSize()
                    .help("Copy the words that did not paste")
                    .accessibilityIdentifier("tokens.home.held-copy")
                }
            }
            .font(TokensType.body)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
        }
    }

    /// An earlier talk that never landed, with Copy and Forget: Home is the only place it is offered.
    @ViewBuilder
    private var earlierRow: some View {
        if let earlier = TokensHomePreview.earlierRecovery(model) ?? model.earlierRecovery {
            let copied = model.copyFeedbackKey == TalkModel.earlierCopyKey(earlier)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // A Copy or Forget that could not be saved says so right here.
                Text(copied ? "Earlier talk copied"
                     : TokensHomePreview.earlierNote(model) ?? model.earlierRecoveryNote ?? "An earlier talk was not pasted")
                    .foregroundStyle(TokensUI.ink2)
                Spacer(minLength: 8)
                if !copied {
                    Button("Copy") { model.copyEarlierRecovery() }
                        .buttonStyle(TokensLinkButtonStyle())
                        .accessibilityIdentifier("tokens.home.earlier-copy")
                    Button("Forget") { model.forgetEarlierRecovery() }
                        .buttonStyle(TokensLinkButtonStyle())
                        .accessibilityIdentifier("tokens.home.earlier-forget")
                }
            }
            .font(TokensType.body)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
        }
    }

    /// Ready unless a grant or setup step blocks talking (or a proof render forces either state).
    private var heroReady: Bool {
        (homeReady || TokensPreview.forcesReady) && TokensHomePreview.blocker(model) == nil
    }

    /// "Then tap [⌥ Right Option] to talk" in the 17-point lead, the chip centred on the line.
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

    /// Shared by Settings: persist a preset and move the existing bubble without showing it.
    func selectBubblePlacement(_ placement: BubblePlacement) {
        BubblePlacement.save(placement)
        bubblePlacement = placement
        if let window = compactWindow(), let visible = window.screen?.visibleFrame {
            BubbleWindowPlacement.apply(placement, to: window, visible: visible)
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
Home's measures. Home's column starts where every other page's does and may run up to 14
squares wide. The talks list scrolls with the page, so there is no row budget.
*/
enum TokensHomeLayout {
    static let columnMaxWidth: CGFloat = 14 * TokensUI.paperCell
    /// Home lists at most this many talks; History has the rest. Home redraws while a talk records,
    /// so the list stays short (build 83 CPU fix).
    static let talkRows = 12

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

}

/// A stored failure reason without its menu-bar copy hint (" · Copy latest"), for Home's note.
enum TokensHomeNote {
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

/*
Build 83 resting head (approved mock): "Tap [⌥ Right Option] to talk" in the
title size on the first rule. The verb is the tap/hold switch: dashed-underlined, a click flips
"Tap" and "Hold" (the same preference as Settings). The key chip opens the key picker. Under it,
the same space the live block takes (TokensHomeLiveLayout): a resting chalk line where the wave
rises, a faint quote where the words will be written, and the stop line's empty rule. Starting a
talk changes what is drawn, never where the talks below sit.
*/
enum TokensHomeLiveLayout {
    static let waveCells: CGFloat = 1
    /// The words: the newest four lines at the 28-point pitch.
    static let wordsCells: CGFloat = 2
    static let wordsLines = 4
    /// What the resting space says (a short quote, "Solve Navier–Stokes.").
    static let restingQuote = "\u{201C}Solve Navier\u{2013}Stokes.\u{201D}"
}

struct TokensHomeRestHead<Chip: View>: View {
    let keyName: String
    let tap: Bool
    @ViewBuilder let chip: () -> Chip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tap ? "Tap" : "Hold")
                chip()
                    .tokensControlOnBaseline()
                Text("to talk")
            }
            .font(TokensType.title)
            .foregroundStyle(TokensUI.ink)
            .lineLimit(1)
            .tokensOnRule()
            // The live block's shape exactly (TokensHomeLiveLayout), so starting a talk moves nothing.
            TokensChalkWave(samples: [], live: true, confirmed: false)
                .frame(height: TokensHomeLiveLayout.waveCells * TokensUI.paperCell)
            Text(TokensHomeLiveLayout.restingQuote)
                .font(TokensType.lead)
                .foregroundStyle(TokensUI.secondary.opacity(0.7))
                .lineLimit(1)
                .tokensReadingPitch(size: 17)
                .tokensOnRule()
                .frame(height: TokensHomeLiveLayout.wordsCells * TokensUI.paperCell, alignment: .top)
            TokensRuleSpacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.home.hero")
    }
}

/*
The waveform drawn like chalk on graph paper. Resting: one hand-drawn line on the frame's bottom rule.
Live: that same line bends with your voice, one smooth stroke.
Ink colour, so it is white chalk on the dark themes and pencil on Paper. It only draws the
existing input envelope; no second microphone session.
*/
struct TokensChalkWave: View {
    let samples: [Double]
    let live: Bool
    var confirmed = true

    /// A fixed, per-index wobble in -1...1 (no randomness, so a redraw never flickers).
    static func wobble(_ index: Int, _ salt: Double) -> Double {
        let x = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }

    var body: some View {
        Canvas { context, size in
            let ink = TokensUI.ink
            if !live || !confirmed {
                // One chalk line, gently uneven, on the bottom rule (resting) or the middle (arming).
                let y = live ? size.height / 2 : size.height - 1
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                var index = 0
                while x < size.width {
                    x = min(size.width, x + 6)
                    line.addLine(to: CGPoint(x: x, y: y + CGFloat(Self.wobble(index, 1)) * 0.6))
                    index += 1
                }
                context.stroke(line, with: .color(ink.opacity(0.42)),
                               style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                return
            }
            /*
            Live: one smooth line that
            traces the voice. The resting line's own stroke, bent by a gentle carrier whose height
            follows the input envelope, interpolated between samples so it never steps.
            */
            let raw = samples.suffix(96).map { $0.isFinite ? min(1, max(0, $0)) : 0 }
            // A light five-point average, so a sudden level step bends the line instead of kinking it.
            let source = raw.indices.map { i -> Double in
                let window = raw[max(0, i - 2)...min(raw.count - 1, i + 2)]
                return window.reduce(0, +) / Double(window.count)
            }
            let mid = size.height / 2
            let reach = mid - 3
            func envelope(at x: CGFloat) -> Double {
                guard source.count > 1 else { return source.first ?? 0 }
                let position = Double(x / max(1, size.width)) * Double(source.count - 1)
                let low = Int(position.rounded(.down)), high = min(source.count - 1, low + 1)
                let fraction = position - Double(low)
                return source[low] * (1 - fraction) + source[high] * fraction
            }
            var line = Path()
            var x: CGFloat = 0
            while x <= size.width {
                let y = mid + CGFloat(sin(Double(x) * 0.16)) * CGFloat(envelope(at: x)) * reach
                if x == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                x += 2
            }
            context.stroke(line, with: .color(ink.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityLabel(live ? (confirmed ? "Microphone waveform" : "Microphone arming") : "Ready to talk")
    }
}

/// The talks beside the side card when Home's column has room for both (at least 6 squares of
/// talks), else the talks alone. Widths come from tokensSheetSize, never a GeometryReader (§8.1).
struct TokensHomeBoard<Talks: View, Card: View>: View {
    @ViewBuilder let talks: () -> Talks
    @ViewBuilder let card: () -> Card
    @Environment(\.tokensSheetSize) private var sheet

    static var cardCells: CGFloat { 4 }
    static func showsCard(columnWidth: CGFloat) -> Bool {
        columnWidth >= (6 + cardCells + 0.5) * TokensUI.paperCell
    }

    var body: some View {
        let cell = TokensUI.paperCell
        let column = TokensHomeLayout.column(sheetWidth: sheet.width).width
        if Self.showsCard(columnWidth: column) {
            HStack(alignment: .top, spacing: 0) {
                talks().frame(width: column - (Self.cardCells + 0.5) * cell)
                TokensDottedRule(vertical: true)
                    .frame(width: cell / 2)
                card().frame(width: Self.cardCells * cell)
            }
        } else {
            talks()
        }
    }
}

/// A dotted chalk line, like the paste marker's corners: the one divider Home uses instead of boxes.
struct TokensDottedRule: View {
    var vertical = false
    var body: some View {
        Canvas { context, size in
            var line = Path()
            if vertical {
                line.move(to: CGPoint(x: size.width / 2, y: 0)); line.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            } else {
                line.move(to: CGPoint(x: 0, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            context.stroke(line, with: .color(TokensUI.secondary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.01, 5]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TokensHomeModeSwitch: View {
    @Binding var mode: RightOptionMode
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            word(.tap, "Tap")
            Text("·").foregroundStyle(TokensUI.secondary)
            word(.hold, "Hold")
        }
        .font(TokensType.body)
        .fixedSize()
    }

    private func word(_ option: RightOptionMode, _ label: String) -> some View {
        let on = mode == option
        return Button(label) { mode = option }
            .buttonStyle(.plain)
            .fontWeight(on ? .medium : .regular)
            .foregroundStyle(on ? TokensUI.ink : TokensUI.secondary)
            .accessibilityLabel(option == .tap ? "Tap to talk" : "Hold to talk")
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("tokens.home.talk-mode.\(label.lowercased())")
    }
}

/// The side card's numbers, from saved talks only (Stats' rules: words as Home counts them, speed
/// only from receipt-stated wpm, never estimated).
struct TokensHomeCardSummary: Equatable {
    var weekWords = 0
    var usualWPM: Int?
    var streakDays = 0
    var hasTalks = false

    static func make(history: [PromptHistoryEntry], now: Date = Date(),
                     calendar: Calendar = .current) -> TokensHomeCardSummary {
        guard !history.isEmpty else { return TokensHomeCardSummary() }
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let speedStart = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        let recent = history.filter { $0.createdAt >= speedStart }
        let speeds = TokensStatsSource.entries(recent, events: [], now: now, appName: { _ in nil })
            .compactMap { $0.record?.wpm }
        let week = history.filter { $0.createdAt >= weekStart }.reduce(0) { $0 + TokensHistoryText.words($1) }
        return TokensHomeCardSummary(weekWords: week, usualWPM: median(speeds),
                                     streakDays: streak(days: history.map(\.createdAt), now: now, calendar: calendar),
                                     hasTalks: true)
    }

    /*
    Home redraws on every microphone level while a talk records; make() reads two weeks of
    receipts, so redoing it per frame pinned Tokens at 100% CPU (UX review). The numbers
    only change with the history or the day, so one copy is kept for that key.
    */
    private static var memo: (key: String, summary: TokensHomeCardSummary)?
    @MainActor static func cached(history: [PromptHistoryEntry], now: Date = Date(),
                                  calendar: Calendar = .current) -> TokensHomeCardSummary {
        let key = "\(history.count)|\(history.first?.id.uuidString ?? "-")|\(history.last?.id.uuidString ?? "-")|"
            + "\(Int(calendar.startOfDay(for: now).timeIntervalSince1970))"
        if let memo, memo.key == key { return memo.summary }
        let summary = make(history: history, now: now, calendar: calendar)
        memo = (key, summary)
        return summary
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Days in a row with at least one talk, ending today, or yesterday when today has none yet.
    static func streak(days: [Date], now: Date, calendar: Calendar) -> Int {
        let talked = Set(days.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: now)
        if !talked.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while talked.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

/*
Home's side card (approved mock): words this week, usual speed and streak, each value in
the title size with its label after it on one rule, then two labelled controls: Model (the
speech-model menu, plain text) and Talk ("Tap · Hold", the same preference as Settings). No
outline: a dotted line separates it from the talks. A thin rounded
edge. Before any talk: "0 words so far" and one line saying speed and streak start with the
first talk.
*/
struct TokensHomeSideCard<Menu: View>: View {
    let summary: TokensHomeCardSummary
    @Binding var mode: RightOptionMode
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if summary.hasTalks {
                stat(summary.weekWords.formatted(), summary.weekWords == 1 ? "word this week" : "words this week")
                stat(summary.usualWPM.map { "\($0)" } ?? "–", "words a minute")
                stat("\(summary.streakDays)", summary.streakDays == 1 ? "day in a row" : "days in a row")
            } else {
                stat("0", "words so far")
                Text("Speed and streak start with your first talk.")
                    .font(TokensType.caption)
                    .foregroundStyle(TokensUI.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .tokensOnRule()
            }
            // Model selection and tap/hold mode use plain labelled controls.
            control("Model") { menu() }
            control("Talk") { TokensHomeModeSwitch(mode: $mode) }
        }
        .padding(.leading, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.home.side-card")
    }

    private func control<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
            Spacer(minLength: 8)
            content()
                .tokensControlOnBaseline()
        }
        .lineLimit(1)
        .tokensOnRule()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(TokensType.title.monospacedDigit())
                .foregroundStyle(TokensUI.ink)
            Text(label)
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
        }
        .lineLimit(1)
        .tokensOnRule()
    }
}

/*
First launch (no talks yet, approved mock): "Try your first talk" and three short steps,
then where talks will appear. No placeholder inside the wave.
*/
struct TokensHomeFirstTalk: View {
    let keyName: String
    let tap: Bool

    static func steps(keyName: String, tap: Bool) -> [String] {
        ["1   Click into any text box: Notes, Mail, Codex.",
         "2   " + (tap ? "Tap " : "Hold ") + keyName + " and say a sentence.",
         tap ? "3   Tap it again. Your words paste right there." : "3   Let go. Your words paste right there."]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Try your first talk")
                .font(TokensType.labelLarge)
                .foregroundStyle(TokensUI.ink)
                .tokensOnRule()
            // One rule each (a Group would hand all three to one rule and stack them).
            ForEach(Self.steps(keyName: keyName, tap: tap), id: \.self) { step in
                Text(step)
                    .font(TokensType.body)
                    .foregroundStyle(TokensUI.secondary)
                    .lineLimit(1)
                    .tokensOnRule()
            }
            Text("Your talks will be listed here, by day.")
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
                .tokensOnRule()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.home.first-talk")
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
  --home-preview-key left-option|right-command|globe|f5     the talk key Home's keycap draws (build 83)
  --home-preview-mode tap|hold                              the key mode Home's words and link follow (build 83)
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
    /// "right-command" → "Right Command"; "f5" → "F5".
    static func keyName(_ model: TalkModel) -> String? {
        guard model.isSyntheticRun, let raw = value(after: "--home-preview-key") else { return nil }
        return raw.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    static func mode(_ model: TalkModel) -> RightOptionMode? {
        model.isSyntheticRun ? value(after: "--home-preview-mode").flatMap(RightOptionMode.init(rawValue:)) : nil
    }
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
(or "Finishing…"), the chalk wave in the next square, the newest four lines of
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
    static let stopHelp = "Stop and keep the words in History"
    static let stopLabel = "Stop talk"
    static let stopHint = "Keeps the words in History. Nothing is pasted."
    static let discardTitle = "Discard"
    static let discardHelp = "End this talk without pasting or saving the words"
    static let discardLabel = "Discard talk"
    static let discardHint = "Ends this talk. The words are not pasted or saved."
    static let keptCaption = "Your words will be saved to History."

    /// The line under the words: how to stop, or where the words go once finishing.
    static func stopLine(phase: TalkPhase, mode: RightOptionMode, keyName: String, keepsInApp: Bool) -> String {
        if phase == .finalizing { return keepsInApp ? keptCaption : "Your words will paste when ready." }
        return (mode == .tap ? "Press " : "Release ") + keyName + " to stop."
    }

    private static let liveFont = NSFont.systemFont(ofSize: 17)

    private var shownText: String {
        // The newest measured lines (four), so a long talk keeps its latest words in view.
        let tail = textWidth > 0
            ? latestMeasuredLines(in: text, font: Self.liveFont, width: max(1, textWidth - 12),
                                count: TokensHomeLiveLayout.wordsLines)
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
            TokensChalkWave(samples: samples, live: true, confirmed: confirmed)
                .frame(maxWidth: .infinity)
                .frame(height: TokensHomeLiveLayout.waveCells * TokensUI.paperCell)
            // Always the same three squares, so the talks below never move (build 83). A ZStack, not
            // a Group: an empty Group took its frame with it, so the list jumped up before the
            ZStack(alignment: .topLeading) {
                Color.clear
                if !text.isEmpty {
                    Text(Self.styled(shownText))
                        .font(TokensType.lead)
                        .foregroundStyle(TokensUI.ink)
                        .lineLimit(TokensHomeLiveLayout.wordsLines)
                        .tokensReadingPitch(size: 17)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Live transcript")
                        .accessibilityValue(String(Self.styled(text).characters))
                        .tokensOnRule()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: TokensHomeLiveLayout.wordsCells * TokensUI.paperCell, alignment: .top)
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
