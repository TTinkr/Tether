


//
import ApplicationServices
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// FirstRunStage — the two set-up steps, in the order they are done


/// The two set-up steps. The raw value is the step's number ("Step 1 of 2"). The community build
/// has no Terms step: no account, no telemetry, nothing to agree to before Access.
enum FirstRunStage: Int, CaseIterable {
    case access = 1, talk

    /// The step's full name, used where a sentence is wanted.
    var title: String {
        switch self {
        case .access: return "Allow Accessibility"
        case .talk:   return "Talk"
        }
    }

    /// The one-word name in the setup rail.
    var railName: String {
        switch self {
        case .access: return "Access"
        case .talk:   return "Talk"
        }
    }

    /// The rail icon (DESIGN.md §5.12).
    var symbol: String {
        switch self {
        case .access: return "hand.raised"
        case .talk:   return "mic"
        }
    }

    /// What VoiceOver reads for this step's rail row while `current` is being worked on.
    func railLabel(current: FirstRunStage) -> String {
        let state = rawValue < current.rawValue ? "done" : self == current ? "now" : "next"
        return "Step \(rawValue) of \(Self.allCases.count), \(railName), \(state)"
    }

    /*
    Theorem: the Accessibility step is passed only by macOS granting it and both audio permissions.
    Nothing on this page can skip it by itself; "Skip for now" leaves the page, it does not mark
    the step done.
    */
    /// Only actual authorized statuses permit Talk; undecided/restricted are not grants.
    static func after(accessGranted: Bool,
                      microphone: AVAuthorizationStatus,
                      speech: SFSpeechRecognizerAuthorizationStatus,
                      needsRelaunch: Bool = false, speechRequired: Bool = true) -> FirstRunStage {
        accessGranted && !needsRelaunch && microphone == .authorized && (!speechRequired || speech == .authorized)
            ? .talk : .access
    }
}


// FirstRunRing — the red pen's ring (kept for the pen marks; the V3 setup rail does not draw it)


/*
One hand-drawn circle, a little more than a full turn so the ends overlap, the way a teacher rings
an answer. Every point's wobble comes from TokensPencil.unit, so a given seed always draws the
same ring (no randomness; the shape never jitters between redraws).
*/
/// The red pen's ring: a hand-drawn circle around a mark.
struct FirstRunRing: Shape {
    var seed = 0

    func path(in rect: CGRect) -> Path {
        var path   = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        let steps  = 28
        let sweep  = 2 * CGFloat.pi * 1.07                  // a little past one turn: the tail overlaps the start
        let start  = -CGFloat.pi * 0.62                     // begins at about eleven o'clock
        var points: [CGPoint] = []
        for i in 0...steps {
            let t      = CGFloat(i) / CGFloat(steps)
            let angle  = start + sweep * t
            let wobble = (TokensPencil.unit(seed, i) - 0.5) * 1.2
            let drift  = t > 0.88 ? (t - 0.88) * 7 : 0     // the overlapping tail drifts outward
            let r      = radius + wobble + drift
            points.append(CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)))
        }
        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}


// Shared set-up geometry and the short-window flag


private struct TokensSetupCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True in the short-window branch (logical sheet under 440 tall): set-up buttons draw 36
    /// tall instead of 48. Set by firstRunPage; it changes size only, never an action.
    var tokensSetupCompact: Bool {
        get { self[TokensSetupCompactKey.self] }
        set { self[TokensSetupCompactKey.self] = newValue }
    }
}

/*
Set-up geometry in sheet coordinates (DESIGN.md §6.7, §7). Rule n is y = 56n. The headline
sits on rule 2, or rule 1 when the logical window is under 560 tall.
*/
/// Where the set-up headline goes for a logical sheet height, and the set-up column widths.
enum TokensSetupLayout {
    /// The short-window branch: compact buttons, no blank square before Start.
    static let compactBelow: CGFloat = 440
    /// Below this the headline moves up to rule 1.
    static let roomyFrom: CGFloat = 560
    /// The Done column; the Access step's guide needs the wider one.
    static let columnMaximum: CGFloat = 616
    static let accessColumnMaximum: CGFloat = 712

    static func headlineRule(sheetHeight: CGFloat) -> CGFloat { sheetHeight < roomyFrom ? 1 : 2 }
}

/// Reads the logical sheet size TokensHome put in the environment. No GeometryReader is needed:
/// the first-run frame is exactly that size.
private struct TokensSetupSheetSize<Content: View>: View {
    @Environment(\.tokensSheetSize) private var size
    @ViewBuilder let content: (CGSize) -> Content
    var body: some View { content(size) }
}


// FirstRunActionButton — the set-up buttons


/// Setup actions: red fill marks the one next action, quiet buttons keep the optional ones
/// visible without competing. This style changes no permission or consent state.
struct FirstRunActionButton: View {
    let title: String
    var symbol: String? = nil
    var primary = false
    /// Stretch to the column's width (the Access step's stacked actions beside its guide, and
    /// Agree and Decline, which share one width).
    var fill = false
    var disabled = false
    /// The drawn button's narrowest width; Start asks for 200 through `minimumWidth(_:)`.
    var widthFloor: CGFloat = 168
    let action: () -> Void
    @Environment(\.tokensSetupCompact) private var compact

    init(_ title: String, symbol: String? = nil, primary: Bool = false, fill: Bool = false,
         disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.primary = primary
        self.fill = fill
        self.disabled = disabled
        self.action = action
    }

    /// The same button with a wider minimum (the whole drawn shape, padding included).
    func minimumWidth(_ width: CGFloat) -> FirstRunActionButton {
        var copy = self
        copy.widthFloor = width
        return copy
    }

    var body: some View {
        /*
        Agree must be at least as large as Decline. Every set-up action is 48
        tall (36 in the short-window branch) with a 15 medium label; the consent gates (checkbox,
        reached end) stay on the caller. The minimum is for the whole shape, so the label's own
        minimum leaves out the style's side padding.
        */
        let size: TokensButtonSize = compact ? .compact : .large
        let button = Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
                Text(title)
            }
            .font(TokensType.labelLarge)
            .frame(minWidth: max(0, widthFloor - 2 * size.padding), maxWidth: fill ? .infinity : nil)
        }
        Group {
            if primary { button.buttonStyle(TokensPrimaryButtonStyle(size: size)) }
            else { button.buttonStyle(TokensQuietButtonStyle(size: size)) }
        }
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}


// TokensSetupRail — the wordmark and the three steps, down the left


/*
The setup rail (DESIGN.md §5.1, §5.12): solid rail colour, a 1-point seam on its trailing edge, no
grid. Wide (216): the wordmark 132 wide at x = 24 with its letters on y = 112, then the three
steps with their label baselines on y = 168, 224 and 280 (icon at x = 28, label at x = 60). The
current step has the red bar at x = 12, a red icon and a 14 medium red label; a done step is ink2
with a small secondary checkmark at x = 188; a step still to come is secondary. Compact (72): the
logo π (TokensBrandMark, build 82) centred at (36, 96) and the icons alone, centred at x = 36 and 5
above each rule; a done step shows a checkmark. These rows are not buttons.
*/
/// The set-up rail: where you are in Access and Talk.
struct TokensSetupRail: View {
    let current: FirstRunStage
    let wide: Bool
    let appName: String

    static let wordmarkWidth: CGFloat = 132
    static let wordmarkLeading: CGFloat = 24
    /// The wordmark's letters and the first step's label rest on these rules.
    static let wordmarkRule: CGFloat = 2

    var body: some View {
        ZStack(alignment: .topLeading) {
            brand
            VStack(alignment: .leading, spacing: 0) {
                TokensRuleSpacer(cells: Self.wordmarkRule)
                ForEach(FirstRunStage.allCases, id: \.rawValue) { stage in
                    row(stage).tokensOnRule()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TokensUI.paper)
        .overlay(alignment: .trailing) {
            Rectangle().fill(TokensUI.seam).frame(width: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var brand: some View {
        if wide {
            let rest = Self.wordmarkRule * TokensUI.paperCell
            TokensBrandWordmark(width: Self.wordmarkWidth)
                .padding(.leading, Self.wordmarkLeading)
                .padding(.top, rest - Self.wordmarkWidth * TokensWordmarkRule.baselineFraction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appName)
        } else {
            TokensBrandMark(size: 28)
                .padding(.leading, 36 - 14)
                .padding(.top, 96 - 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appName)
        }
    }

    private func row(_ stage: FirstRunStage) -> some View {
        let done = stage.rawValue < current.rawValue
        let now = stage == current
        let ink = now ? TokensUI.red : done ? TokensUI.ink2 : TokensUI.secondary
        // Wide: bar 12, icon column 28-48, label 60-188, check 188. Compact: bar 6, icon 26-46.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Capsule().fill(TokensUI.red)
                .frame(width: 2.5, height: 20)
                .opacity(now ? 1 : 0)
                .tokensControlOnBaseline()
                .padding(.leading, wide ? 12 : 6)
            Image(systemName: done && !wide ? "checkmark" : stage.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(ink)
                .frame(width: 20)
                .tokensControlOnBaseline()
                .padding(.leading, wide ? 28 - 14.5 : 26 - 8.5)
            if wide {
                Text(stage.railName)
                    .font(.system(size: 14, weight: now ? .medium : .regular))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .frame(width: 188 - 48, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TokensUI.secondary)
                    .opacity(done ? 1 : 0)
                    .tokensControlOnBaseline()
            }
        }
        .frame(width: wide ? TokensRail.wideWidth : TokensRail.iconWidth, alignment: .leading)
        .help(wide ? "" : stage.railLabel(current: current))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.railLabel(current: current))
    }
}


/// The set-up step title: 28 regular ink, one line (it scales down to 0.75 before it would wrap).
/// Every step draws its title with it, so the headline never changes size or weight between
/// steps; the Access step places its own (DESIGN.md §6.7, §6.9).
struct TokensSetupTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TokensType.headline)
            .foregroundStyle(TokensUI.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The step headline: the set-up title with its baseline on `rule`.
struct TokensSetupHeadline: View {
    let text: String
    let rule: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TokensRuleSpacer(cells: rule - 1)
            TokensSetupTitle(text: text)
                .tokensOnRule()
        }
    }
}

extension TokensHome {

    // MARK: First run

    /*
    The setup rail, then the graph sheet with only the current step on it, its headline on rule 2
    (rule 1 in a short window). Every step starts at the same y, so nothing jumps between steps;
    nothing is vertically centred. The order is: allow Accessibility, then start talking.
    */
    /// No macOS prompt runs until a step's own button is pressed.
    /// `sheetWidth` is the logical window width; the sheet height comes from tokensSheetSize.
    func firstRunPage(sheetWidth: CGFloat) -> some View {
        TokensSetupSheetSize { sheet in
            let railWidth = TokensRail.width(sheetWidth: sheetWidth)
            let column = TokensColumn.layout(sheetWidth: max(1, sheetWidth - railWidth),
                                             maxWidth: firstRunStage == .access ? TokensSetupLayout.accessColumnMaximum
                                                                                : TokensSetupLayout.columnMaximum)
            let compact = sheet.height < TokensSetupLayout.compactBelow
            let rule = TokensSetupLayout.headlineRule(sheetHeight: sheet.height)
            let width = column.width
            HStack(alignment: .top, spacing: 0) {
                TokensSetupRail(current: firstRunStage, wide: railWidth >= TokensRail.wideWidth, appName: appName)
                    .frame(width: railWidth)
                ZStack(alignment: .topLeading) {
                    TokensSheetGrid()
                    if firstRunStage == .access {
                        // Access places its own column: when it scrolls, the scroll view spans the
                        // sheet, so its scroller sits at the window's edge, not over the ticks.
                        accessStage(rule: rule, column: column, compact: compact, sheetHeight: sheet.height)
                    } else {
                        talkStage(rule: rule, compact: compact, sheetHeight: sheet.height)
                        .frame(width: width, alignment: .topLeading)
                        .padding(.leading, column.leading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
            .environment(\.tokensSetupCompact, compact)
        }
        .onAppear { refreshFirstRunPresentation() }
        .onChange(of: model.shortcutAccessGranted) { _, _ in refreshFirstRunPresentation() }
        // Audio authorization has no published property here. Poll only this visible setup
        // surface so prompt completion/revocation updates the stage without toggling the key.
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refreshFirstRunPresentation()
        }
    }

    /// The step headline: 28 regular ink, one line, its baseline on `rule`.
    private func setupHeadline(_ text: String, rule: CGFloat) -> some View {
        TokensSetupHeadline(text: text, rule: rule)
    }

    /*
    Step 1, chrome only: the Access step's own title is the headline, so its first baseline goes
    on the headline's rule and there is no second title. The step draws all its words at every
    size (build 82; small windows used to move them into tooltips). Where it fits with half a
    square to spare it stands still, as at 1040 × 720 and larger; otherwise it scrolls, resting on
    whole squares, and a line, button or row the window's bottom edge would cut is hidden whole
    until scrolled to (FirstRunWholeAtRest). The scroll view is not the sheet's first child (the
    grid is) and nothing in it is sized by a GeometryReader (DESIGN.md §8.1).
    */
    @ViewBuilder private func accessStage(rule: CGFloat, column: (leading: CGFloat, width: CGFloat),
                                          compact: Bool, sheetHeight: CGFloat) -> some View {
        let access = FirstRunAccessSnapshot.current(model: model)
        ViewThatFits(in: .vertical) {
            accessContent(access, rule: rule, column: column, compact: compact, bottom: TokensUI.halfCell)
            ScrollView(.vertical) {
                accessContent(access, rule: rule, column: column, compact: compact,
                              bottom: TokensFirstRunAccessStep.scrollBottom(sheetHeight: sheetHeight))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tokensRuledScroll()
            .tokensRestingEdge()
        }
    }

    /// The step from the sheet's top: blank squares down to the headline's rule, the step in the
    /// page column, then `bottom` points of paper (the margin it must fit with, or the scroll's end).
    private func accessContent(_ access: FirstRunAccessSnapshot, rule: CGFloat, column: (leading: CGFloat, width: CGFloat),
                               compact: Bool, bottom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TokensRuleSpacer(cells: rule - 1)
            // The step's title already stands on its first rule, so this wrapper moves nothing.
            TokensFirstRunAccessStep(access: access, inner: column.width, compact: compact, actions: accessActions)
                .tokensOnRule()
            Color.clear.frame(height: bottom).accessibilityHidden(true)
        }
        .frame(width: column.width, alignment: .topLeading)
        .padding(.leading, column.leading)
    }

    /// The Access step's buttons: the model calls they made before the guide, and this page's
    /// refresh (Check again, Continue) and exit (Skip for now).
    private var accessActions: FirstRunAccessActions {
        FirstRunAccessActions(openAccessibility: { beginSetup(); model.openShortcutAccessibilitySettings() },
                              retryAccess: { beginSetup(); model.retryShortcutAccess() },
                              relaunch: { beginSetup(); model.relaunchForShortcutAccess() },
                              relaunchDisabled: model.reconnectDisabled,
                              prepareSpeech: { beginSetup(); model.prepareSpeech() },
                              checkAgain: { refreshFirstRunPresentation() },
                              skip: { leaveFirstRun() })
    }

    /*
    The person's first press of an Access action is the consent boundary: only then does Tokens
    attach its key monitor and ask macOS for Accessibility, Microphone and Speech. Opening the app
    alone asks for nothing. Open at login stays off until chosen in Settings.
    */
    private func beginSetup() {
        guard TalkModel.tokensFirstRunPending else { return }
        model.completeTokensFirstRun(openAtLogin: false)
    }

    /// Read-only snapshot: never requests a permission or changes capture state.
    var actualFirstRunStage: FirstRunStage {
        FirstRunStage.after(accessGranted: model.shortcutAccessGranted && AXIsProcessTrusted(),
                            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                            speech: SFSpeechRecognizer.authorizationStatus(),
                            needsRelaunch: model.shortcutAccessNeedsRelaunch,
                            speechRequired: SpeechEngineChoice.appleSpeechNeeded(setupPending: TalkModel.tokensSetupInProgress))
    }

    /// Manual reopening/activation resumes missing permissions.
    /// This does not order a window forward or change the app's quiet-launch policy.
    func refreshFirstRunPresentation() {
        guard !ProcessInfo.processInfo.arguments.contains("--render-preview-frames"),
              model.phase != .capturing, model.phase != .finalizing else { return }
        // Reconcile a grant made while Settings was open without asking macOS again.
        if !model.isSyntheticRun && !model.reconnectDisabled
            && !TalkModel.tokensFirstRunPending && AXIsProcessTrusted()
            && !model.shortcutAccessGranted && !model.shortcutAccessNeedsRelaunch {
            model.startMonitoring(promptForAccessibility: false, reportFailure: false)
        }
        firstRunStage = actualFirstRunStage
        if firstRunStage != .talk { detail = .firstRun }
    }

    /// Leaves set-up for Home. Used by Start, and by Skip for now on the Accessibility step.
    private func leaveFirstRun() {
        detail  = nil
        section = .home
    }

//
// :)
//
//
    /*
    Step 2: what macOS is asking and the one button that opens the right pane. The model's poll
    (startShortcutAccessPoll) flips shortcutAccessGranted when the switch is turned on, and the
    page rechecks all three permissions before moving to step 3. Trap: after the grant the event tap can still need a relaunch
    (shortcutAccessNeedsRelaunch); then the primary action is Relaunch. The Microphone and Speech
    Recognition prompts were requested on Agree; remaining audio grants expose their own next action.
    The relaunch title matches Home and Settings ("Relaunch to finish"); the set-up copy calls the
    thing you press "the key", never "the shortcut" (2026-10-16).
    */
    static func accessTitle(trusted: Bool, monitorReady: Bool, microphone: Bool, speech: Bool, speechRequired: Bool = true) -> String {
        if !trusted { return "Allow Accessibility" }
        if !monitorReady { return "Relaunch to finish" }
        if !microphone { return "Allow Microphone" }
        if speechRequired && !speech { return "Allow Speech Recognition" }
        return "Permissions ready"
    }

    /*
    Step 3 (DESIGN.md §6.10), one line per square: the headline, how to dictate (17 secondary on
    the 28-point pitch), the key, a line about the voice model while it downloads after install,
    then the first-dictation card (a blank square for its label, two
    squares of card) where the sheet has the room, the start-at-login switch when this Mac can
    register one, a blank square (not in the short window, nor beside the card), then Start. Two
    red marks: the rail's Talk and Start. The tallest version whose whole height fits wins;
    nothing scrolls.
    */
    @ViewBuilder private func talkStage(rule: CGFloat, compact: Bool, sheetHeight: CGFloat) -> some View {
        if compact {
            talkContent(rule: rule, card: false, compact: true)
        } else {
            // Bounded by the sheet: the stage's own container proposes no height to measure against.
            ViewThatFits(in: .vertical) {
                talkContent(rule: rule, card: true, compact: false)
                talkContent(rule: rule, card: false, compact: false)
            }
            .frame(maxHeight: sheetHeight, alignment: .top)
        }
    }

    private func talkContent(rule: CGFloat, card: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            setupHeadline(speechModels.selectedSetupLine == nil ? "You're ready" : "Getting the voice model ready", rule: rule)
            Text(TokensDictationHint(phase: model.phase, mode: model.rightOptionMode).instruction)
                .font(TokensType.lead)
                .foregroundStyle(TokensUI.secondary)
                .tokensReadingPitch(size: 17)
                .fixedSize(horizontal: false, vertical: true)
                .tokensOnRule()
            TokensKeyChip(name: model.shortcutName, size: 20)
                .tokensOnRule()
            // The selected model must be ready before the first dictation.
            if let line = speechModels.selectedSetupLine {
                Text(line)
                    .font(TokensType.caption)
                    .foregroundStyle(TokensUI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .tokensOnRule()
                    .accessibilityIdentifier("tokens.firstrun.orukeet-download")
            }
            if card {
                TokensRuleSpacer(cells: 1)
                TokensFirstDictationCard(shortcutName: model.shortcutName)
            }
            if LoginItem.canRegister {
                TokensLoginSwitchRow()
                    .tokensOnRule()
            }
            if !compact && !card { TokensRuleSpacer(cells: 1) }
            FirstRunActionButton("Start", symbol: "arrow.right", primary: true) {
                // The displayed ready state can be stale after Settings changes. Re-read every
                // requirement at the action boundary; preview pages never waive real consent.
                let current = actualFirstRunStage
                guard current == .talk else { firstRunStage = current; return }
                TalkModel.markSetupFinished()
                leaveFirstRun()
            }
            .minimumWidth(200)
            .keyboardShortcut(.defaultAction)
            .tokensOnRule()
            // The card's version keeps a square under Start's row (the button hangs below its
            // rule), so the card only appears where Start still clears the sheet's bottom.
            if card { TokensRuleSpacer(cells: 1) }
        }
    }
}

/*
The first-dictation card (variant 5C, build 77): what talking looks like, drawn with the real
paste marker. Two squares of paper framed by the same dotted coral corners and "π <key>" label the
app draws around a text box while you talk (PasteMarkerView, so the two never drift apart), with
the first words standing on the box's first rule and a caret after them. No filled box, no bubble
and no motion: it is a still picture of where the words land, and VoiceOver reads it as one line.
*/
struct TokensFirstDictationCard: View {
    let shortcutName: String
    /// Wording (build 77): talking to Tokens, never "dictation".
    static let sample = "I'm talking to Tokens."
    static let cells: CGFloat = 2
    /// The words start this far inside the corners, like a composer's text inset.
    static let inset: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(Self.sample)
                .font(TokensType.lead)
                .foregroundStyle(TokensUI.ink)
            // The caret: the system's 1.5-point bar at the line's cap height and a little under.
            Rectangle()
                .fill(TokensUI.ink.opacity(0.75))
                .frame(width: 1.5, height: 20)
                .tokensControlOnBaseline(4)
        }
        .tokensOnRule()
        .padding(.leading, Self.inset)
        .frame(maxWidth: .infinity, minHeight: Self.cells * TokensUI.paperCell,
               maxHeight: Self.cells * TokensUI.paperCell, alignment: .topLeading)
        .overlay {
            // The marker's panel is the box grown by the corners' outset and the label's margin.
            let x = PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.width
            let y = PasteMarkerGeometry.outset + PasteMarkerGeometry.margin.height
            PasteMarkerView(shortcutName: shortcutName)
                .padding(EdgeInsets(top: -y, leading: -x, bottom: -y, trailing: -x))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("While you talk, dotted corners and \(shortcutName) mark the text box your words land in.")
    }
}

