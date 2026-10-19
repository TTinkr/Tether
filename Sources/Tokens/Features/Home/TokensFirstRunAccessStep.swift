


//
import ApplicationServices
import AVFoundation
import AppKit
import Speech
import TokensCore
import SwiftUI

/*
The Access step's five readings (Accessibility trust, the key monitor, a pending relaunch,
microphone and speech status), taken once per draw so the title, buttons, guide and ticks agree.
Proof renders may draw a fictional reading with --public-preview-access NAME so every branch can
be seen on any Mac; it needs --render-preview-frames and distribution builds ignore it.
*/
/// What the Access step draws from.
struct FirstRunAccessSnapshot: Equatable {
    var trusted: Bool
    var monitorReady: Bool
    var needsRelaunch: Bool
    var microphone: AVAuthorizationStatus
    var speech: SFSpeechRecognizerAuthorizationStatus
    var speechRequired = true

    /// Live readings, unless a proof render asked for a fictional one.
    @MainActor static func current(model: TalkModel) -> FirstRunAccessSnapshot {
        proofOverride ?? FirstRunAccessSnapshot(
            trusted: AXIsProcessTrusted(), monitorReady: model.shortcutAccessGranted,
            needsRelaunch: model.shortcutAccessNeedsRelaunch,
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            speech: SFSpeechRecognizer.authorizationStatus(),
            speechRequired: SpeechEngineChoice.appleSpeechNeeded(setupPending: TalkModel.tokensSetupInProgress))
    }

    /// The buttons' branch order: relaunch first, then audio once the key works, else Accessibility.
    var relaunchIsNext: Bool { needsRelaunch || (trusted && !monitorReady) }
    var audioIsNext: Bool { monitorReady && trusted }
    /// Every permission the selected engine needs is allowed by macOS: the same test the stage gate
    /// (FirstRunStage.after) applies, so this step never reads ready while Talk would refuse.
    var allAllowed: Bool {
        !relaunchIsNext && audioIsNext && microphone == .authorized && (!speechRequired || speech == .authorized)
    }

    /// Which picture the guide shows; nil when the next action is a relaunch or nothing is missing.
    var guide: AccessGuidePane? {
        if relaunchIsNext { return nil }
        guard audioIsNext else { return .accessibility }
        if microphone == .notDetermined || (speechRequired && speech == .notDetermined) { return .prompt }
        if microphone != .authorized { return .microphone }
        if speechRequired && speech != .authorized { return .speechRecognition }
        return nil
    }

    static func preview(_ name: String) -> FirstRunAccessSnapshot? {
        switch name.lowercased() {
        case "orukeet-microphone":
            return .init(trusted: true, monitorReady: true, needsRelaunch: false, microphone: .denied, speech: .denied, speechRequired: false)
        case "orukeet-prompt":
            return .init(trusted: true, monitorReady: true, needsRelaunch: false, microphone: .notDetermined, speech: .notDetermined, speechRequired: false)
        case "orukeet-ready":
            return .init(trusted: true, monitorReady: true, needsRelaunch: false, microphone: .authorized, speech: .denied, speechRequired: false)
        case "accessibility":
            return .init(trusted: false, monitorReady: false, needsRelaunch: false, microphone: .authorized, speech: .authorized)
        case "microphone":
            return .init(trusted: true, monitorReady: true, needsRelaunch: false, microphone: .denied, speech: .authorized)
        case "speech":
            return .init(trusted: true, monitorReady: true, needsRelaunch: false, microphone: .authorized, speech: .denied)
        case "prompt":
            return .init(trusted: true, monitorReady: true, needsRelaunch: false, microphone: .notDetermined, speech: .notDetermined)
        case "relaunch":
            return .init(trusted: true, monitorReady: false, needsRelaunch: false, microphone: .authorized, speech: .authorized)
        default:
            return nil
        }
    }

    static func proofOverride(arguments: [String], allowed: Bool) -> FirstRunAccessSnapshot? {
        guard allowed, arguments.contains("--render-preview-frames"),
              let flag = arguments.firstIndex(of: "--public-preview-access"), flag + 1 < arguments.count
        else { return nil }
        return preview(arguments[flag + 1])
    }

    static let proofOverride = proofOverride(arguments: ProcessInfo.processInfo.arguments, allowed: ProofRoutes.isAllowed)
}

//
// :)
//

/*
The Access step on the set-up sheet, in whole squares like Terms and Done (DESIGN.md §4.2, §6.9,
build 82). A state says the same words in every window and at every zoom: the 28-point title on
the step's first rule, a 17-point line saying what to click (the Done step's lead), the actions,
the advice for when that does not work, "Where things stand", and each permission with its reason
under its name. Nothing is left to a tooltip (build 81 RC5 review): a window too short for the
step scrolls it instead (TokensHome.accessStage). With room beside the actions, the moving picture
shows where to click (as in standard Mac apps), and the advice sits under it.
*/
/// What the Access step's buttons do. The caller hands in exactly the model calls the buttons made
/// before the guide, so the step itself holds no model and its layout can be measured on its own.
struct FirstRunAccessActions {
    var openAccessibility: () -> Void = {}
    var retryAccess: () -> Void = {}
    var relaunch: () -> Void = {}
    var relaunchDisabled = false
    var prepareSpeech: () -> Void = {}
    /// Re-read the readings now (the caller's refresh); used by Check again and Continue.
    var checkAgain: () -> Void = {}
    /// Leave set-up for Home without marking the step done.
    var skip: () -> Void = {}
}

/// The Access step's content on the set-up sheet.
struct TokensFirstRunAccessStep: View {
    let access: FirstRunAccessSnapshot
    /// The page column's width, which the guided layout divides between the actions and the picture.
    var inner: CGFloat = 0
    /// The short-window branch: 36-point buttons and no picture.
    var compact = false
    var actions = FirstRunAccessActions()

    // MARK: Words (the same at every size)

    /// One sentence that matches the picture and names the button to press.
    static func instruction(_ guide: AccessGuidePane, appName: String, speechRequired: Bool = true) -> String {
        switch guide {
        case .accessibility:     return "Click Open Accessibility Settings, then turn on \(appName) in the list."
        case .microphone:        return "Click Open Microphone Settings, then turn on \(appName) in the list."
        case .speechRecognition: return "Click Open Speech Settings, then turn on \(appName) in the list."
        case .prompt:            return speechRequired ? "Click Allow microphone and speech, then choose Allow when macOS asks." : "Click Allow microphone, then choose Allow when macOS asks."
        }
    }

    /// The advice for when the first way does not work.
    static func hint(_ guide: AccessGuidePane, appName: String) -> String {
        switch guide {
        case .accessibility:
            return "Already on? Remove \(appName) with \u{2212}, add it again from Applications with +, then turn it on."
        case .microphone, .speechRecognition:
            return "If access is restricted, your Mac administrator may need to allow it."
        case .prompt:
            return "If you choose Don\u{2019}t Allow, this step shows the System Settings switch instead."
        }
    }

    /// The ready state's line: which permissions macOS reports allowed for this engine.
    static func readyNote(speechRequired: Bool) -> String {
        speechRequired ? "Accessibility, Microphone and Speech Recognition are allowed."
                       : "Accessibility and Microphone are allowed."
    }

    /// What Continue does, said in the ready line over it (it was only the button's tooltip).
    static let continueNote = "Continue checks macOS again, then goes to the last step."

    /// The label over the permission rows, in every state.
    static let eyebrow = "Where things stand"

    static func stepTitle(_ access: FirstRunAccessSnapshot) -> String {
        TokensHome.accessTitle(trusted: access.trusted, monitorReady: access.monitorReady,
                               microphone: access.microphone == .authorized,
                               speech: access.speech == .authorized, speechRequired: access.speechRequired)
    }

    /*
    The line under the title: what to click, or what is already true. It is the picture's
    instruction whenever there is a picture, and the same words when the window is too small for
    one, so a smaller window never says less (it said "This copy needs Accessibility…" in the short
    column and kept the advice in a tooltip). The relaunch line names "the key", as the
    Accessibility row and the Done step do (2026-10-16: it said "the shortcut connection").
    */
    static func statusLine(_ access: FirstRunAccessSnapshot, appName: String) -> String {
        if !access.trusted { return instruction(.accessibility, appName: appName) }
        if access.relaunchIsNext {
            return "Accessibility is allowed. Relaunch \(appName) so the key works; you do not need to allow it again."
        }
        if access.allAllowed { return readyNote(speechRequired: access.speechRequired) + " " + continueNote }
        return access.guide.map { instruction($0, appName: appName, speechRequired: access.speechRequired) }
            ?? "Accessibility is allowed. Complete the remaining audio permission below."
    }

    /// The advice after the actions: the picture's hint for when the first way does not work. The
    /// relaunch and the ready state have none; their line says it all.
    static func advice(_ access: FirstRunAccessSnapshot, appName: String) -> String? {
        if let pane = access.guide { return hint(pane, appName: appName) }
        if !access.trusted { return hint(.accessibility, appName: appName) }
        return nil
    }

    /// One permission row: what it is, why the app needs it, and whether macOS allows it.
    struct Permission: Equatable {
        let symbol: String
        let name: String
        let reason: String
        let allowed: Bool
        /// Draws the empty circle in red: this is the one being waited on.
        var urgent = false
    }

    static func permissions(_ access: FirstRunAccessSnapshot) -> [Permission] {
        var rows = [Permission(symbol: "keyboard", name: "Accessibility",
                               reason: "To notice the key and paste where you are typing.",
                               allowed: access.trusted, urgent: true),
                    Permission(symbol: "mic", name: "Microphone", reason: "To hear you.",
                               allowed: access.microphone == .authorized)]
        if access.speechRequired {
            rows.append(Permission(symbol: "waveform", name: "Speech Recognition", reason: "To turn your voice into words.",
                                   allowed: access.speech == .authorized))
        }
        return rows
    }

    /// Every word of guidance the step draws for a reading, in reading order (the buttons' labels
    /// aside). It takes no size: every window and zoom draws all of it.
    static func guidance(_ access: FirstRunAccessSnapshot, appName: String) -> [String] {
        [stepTitle(access), statusLine(access, appName: appName)] + [advice(access, appName: appName)].compactMap { $0 }
            + [eyebrow] + permissions(access).flatMap { [$0.name, $0.reason] }
    }

    // MARK: Geometry

    /// Beside the picture, seven squares hold Open Accessibility Settings over Check access again
    /// and Skip for now side by side, which keeps the Accessibility state inside 1040 × 720 with a
    /// square to spare; a narrower column keeps the three stacked at 312 (the widest label whole).
    static let pairedActions: CGFloat = 392
    static let stackedActions: CGFloat = 312
    static let gap: CGFloat = 24
    static let pictureWidths: ClosedRange<CGFloat> = 200...340

    /// How a column splits between the actions and the picture; nil when the picture does not fit.
    static func split(inner: CGFloat) -> (actions: CGFloat, picture: CGFloat)? {
        for actions in [pairedActions, stackedActions] where inner - gap - actions >= pictureWidths.lowerBound {
            return (actions, min(pictureWidths.upperBound, inner - gap - actions))
        }
        return nil
    }

    /// Whether this column and window draw the picture.
    static func showsPicture(_ access: FirstRunAccessSnapshot, inner: CGFloat, compact: Bool) -> Bool {
        !compact && access.guide != nil && split(inner: inner) != nil
    }

    /// The squares the picture keeps before the advice's first rule: its top is half a square above
    /// the title's baseline, and the advice's capitals stand 12 points under it.
    static func pictureSquares(width: CGFloat) -> CGFloat {
        let below = 12 + NSFont.systemFont(ofSize: 13).capHeight
        return ((TokensUI.halfCell + AccessGuideAnimation.height(for: width) + below) / TokensUI.paperCell).rounded(.up) - 1
    }

    /*
    A 48-point button hangs about 19 points under its rule, so the line after the last one goes a
    square further down: half a square of paper under the button (it was 4.5 points at 760 × 520
    at 150%, review 2026-10-16). A 36-point button hangs 13, so in the short window the next rule
    already leaves more than half a square.
    */
    static func squaresAfterActions(compact: Bool) -> CGFloat { compact ? 0 : 1 }

    /// Paper under the scrolling step: one square plus the sheet's remainder, so its last position
    /// also rests on a rule (the scroll view starts at the sheet's top, rule 0).
    static func scrollBottom(sheetHeight: CGFloat) -> CGFloat {
        let cell = TokensUI.paperCell
        return cell + (sheetHeight - floor(sheetHeight / cell) * cell)
    }

    // MARK: Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pane = access.guide, !compact, let split = Self.split(inner: inner) {
                guided(pane, split: split)
            } else {
                single
            }
            FirstRunPermissionRows(access: access)
        }
    }

    private var title: String { Self.stepTitle(access) }

    /// The title on the step's first rule and the line on the rules under it.
    @ViewBuilder private var heading: some View {
        TokensSetupTitle(text: title)
            .tokensOnRule()
            .firstRunWholeAtRest()
        Self.lead(Self.statusLine(access, appName: appName))
            .frame(maxWidth: Self.measure, alignment: .leading)
    }

    /// The single column's words keep the page column's measure (616, as Terms and Done), so a
    /// 17-point line in the wider Access column does not run to 85 letters and leave a widow;
    /// the buttons and rows keep the whole column.
    static let measure = TokensUI.pageMaxWidth

    /// Title, line and actions on the left; the picture and the advice under it on the right.
    private func guided(_ pane: AccessGuidePane, split: (actions: CGFloat, picture: CGFloat)) -> some View {
        let cell = TokensUI.paperCell
        return HStack(alignment: .top, spacing: Self.gap) {
            VStack(alignment: .leading, spacing: 0) {
                heading
                FirstRunAccessButtons(access: access, fixedWidth: true, compact: compact, actions: actions)
                TokensRuleSpacer(cells: Self.squaresAfterActions(compact: compact))
            }
            .frame(width: split.actions, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                // The picture's top on the half-rule above the title's baseline; it may run into
                // the advice's first square, whose words start under it.
                AccessGuideAnimation(pane: pane, width: split.picture, speechRequired: access.speechRequired)
                    .padding(.top, TokensUI.halfCell)
                    .firstRunWholeAtRest()
                    .frame(height: Self.pictureSquares(width: split.picture) * cell, alignment: .top)
                if let advice = Self.advice(access, appName: appName) { Self.note(advice) }
            }
            .frame(width: split.picture, alignment: .leading)
        }
        // The block's first baseline is the title's, at the bottom of its first square.
        .alignmentGuide(.firstTextBaseline) { _ in cell }
    }

    /// The column without the picture: the short window, the relaunch and the ready state.
    @ViewBuilder private var single: some View {
        heading
        FirstRunAccessButtons(access: access, fixedWidth: false, compact: compact, actions: actions)
        TokensRuleSpacer(cells: Self.squaresAfterActions(compact: compact))
        if let advice = Self.advice(access, appName: appName) {
            Self.note(advice).frame(maxWidth: Self.measure, alignment: .leading)
        }
    }

    // MARK: Words on the grid

    /// The line under the title: 17-point secondary on the 28-point pitch, in whole squares, as the
    /// Done step's instruction (DESIGN.md §3 "setup lead line", §4.2 R2).
    static func lead(_ text: String) -> some View {
        Text(text)
            .font(TokensType.lead)
            .foregroundStyle(TokensUI.secondary)
            .tokensReadingPitch(size: 17)
            .fixedSize(horizontal: false, vertical: true)
            .tokensOnRule()
            .firstRunWholeAtRest()
    }

    /// The advice: 13-point secondary on the 28-point pitch, in whole squares.
    static func note(_ text: String) -> some View {
        Text(text)
            .font(TokensType.caption)
            .foregroundStyle(TokensUI.secondary)
            .tokensReadingPitch(size: 13)
            .fixedSize(horizontal: false, vertical: true)
            .tokensOnRule()
            .firstRunWholeAtRest()
    }
}

/*
The Access step's actions, the same calls as before the guide. Each button's label on a rule of
its own, or side by side on one rule when every label fits whole. Stacked buttons share one
width: the picture's column beside them, the short window's column (as before), or else the
widest label's, so no label is cut short.
*/
struct FirstRunAccessButtons: View {
    let access: FirstRunAccessSnapshot
    /// Beside the picture: the column's width is fixed and the stacked buttons fill it.
    var fixedWidth = false
    var compact = false
    var actions = FirstRunAccessActions()

    var body: some View {
        if access.relaunchIsNext {
            relaunchButton().firstRunWholeAtRest().tokensOnRule()
        } else if access.allAllowed {
            FirstRunActionButton("Continue", symbol: "arrow.right", primary: true) { actions.checkAgain() }
                .help(TokensFirstRunAccessStep.continueNote)
                .firstRunWholeAtRest()
                .tokensOnRule()
        } else if access.audioIsNext {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    audioPrimaryButton()
                    FirstRunActionButton("Check again") { actions.checkAgain() }
                }
                .firstRunWholeAtRest()
                .tokensOnRule()
                stacked(fixedWidth: fixedWidth) {
                    audioPrimaryButton(fill: true).firstRunWholeAtRest().tokensOnRule()
                    FirstRunActionButton("Check again", fill: true) { actions.checkAgain() }.firstRunWholeAtRest().tokensOnRule()
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    openAccessibilityButton()
                    checkAccessButton()
                    skipButton()
                }
                .firstRunWholeAtRest()
                .tokensOnRule()
                stacked(fixedWidth: fixedWidth) {
                    openAccessibilityButton(fill: true).firstRunWholeAtRest().tokensOnRule()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        checkAccessButton(fill: true)
                        skipButton()
                    }
                    .firstRunWholeAtRest()
                    .tokensOnRule()
                }
                stacked(fixedWidth: fixedWidth) {
                    openAccessibilityButton(fill: true).firstRunWholeAtRest().tokensOnRule()
                    checkAccessButton(fill: true).firstRunWholeAtRest().tokensOnRule()
                    skipButton(fill: true).firstRunWholeAtRest().tokensOnRule()
                }
            }
        }
    }

    /// Buttons one per rule at one width (see above).
    @ViewBuilder private func stacked<Content: View>(fixedWidth: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        let column = VStack(alignment: .leading, spacing: 0) { content() }
        if fixedWidth || compact { column } else { column.fixedSize(horizontal: true, vertical: false) }
    }

    /// After the grant the event tap can still need a fresh process.
    private func relaunchButton() -> some View {
        FirstRunActionButton("Relaunch \(appName)", symbol: "arrow.clockwise", primary: true,
                             disabled: actions.relaunchDisabled) { actions.relaunch() }
    }

    /// Microphone and speech: ask macOS if either is undecided, else open the pane still missing.
    @ViewBuilder private func audioPrimaryButton(fill: Bool = false) -> some View {
        if access.microphone == .notDetermined || (access.speechRequired && access.speech == .notDetermined) {
            FirstRunActionButton(access.speechRequired ? "Allow microphone and speech" : "Allow microphone", symbol: "mic", primary: true, fill: fill) {
                actions.prepareSpeech()
            }
        } else if access.microphone != .authorized || (access.speechRequired && access.speech != .authorized) {
            let microphoneMissing = access.microphone != .authorized
            FirstRunActionButton(microphoneMissing ? "Open Microphone Settings" : "Open Speech Settings",
                                 symbol: "gearshape", primary: true, fill: fill) {
                let pane = microphoneMissing ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Open Accessibility Settings, the one red action; then the quiet retry and skip.
    private func openAccessibilityButton(fill: Bool = false) -> FirstRunActionButton {
        FirstRunActionButton("Open Accessibility Settings", symbol: "gearshape", primary: true, fill: fill) {
            actions.openAccessibility()
        }
    }

    private func checkAccessButton(fill: Bool = false) -> FirstRunActionButton {
        FirstRunActionButton("Check access again", symbol: "arrow.clockwise", fill: fill) { actions.retryAccess() }
    }

    private func skipButton(fill: Bool = false) -> FirstRunActionButton {
        FirstRunActionButton("Skip for now", fill: fill) { actions.skip() }
    }
}

/*
Where each permission stands (DESIGN.md §5.3): "Where things stand" on its rule, then one square
per permission bounded by the grid lines, which are the separators (no hairline; each used to
double a grid line). In a square the 15-point name stands on the half-rule with its icon, and on
the right a check when macOS reports it allowed or an empty circle when not yet (red for the one
being waited on); the 13-point reason stands on the rule under it. A reason too long for the
column wraps on the 28-point pitch and its row takes a second square. Every state and size draws
the label and every reason; VoiceOver reads each row as name, reason and status.
*/
/// The ticks under the Access step.
struct FirstRunPermissionRows: View {
    let access: FirstRunAccessSnapshot

    var body: some View {
        let rows = TokensFirstRunAccessStep.permissions(access)
        VStack(alignment: .leading, spacing: 0) {
            // The label is hidden with its first row, so it never stands alone at the window's edge.
            VStack(alignment: .leading, spacing: 0) {
                TokensEyebrow(TokensFirstRunAccessStep.eyebrow)
                    .tokensOnRule()
                if let first = rows.first { FirstRunPermissionRow(permission: first) }
            }
            .firstRunWholeAtRest()
            ForEach(rows.dropFirst(), id: \.name) { FirstRunPermissionRow(permission: $0) }
        }
    }
}

/// One permission in whole squares: the name on the half-rule, its reason on the rule under it.
struct FirstRunPermissionRow: View {
    let permission: TokensFirstRunAccessStep.Permission

    var body: some View {
        FirstRunWholeSquares {
            line
        }
        .accessibilityElement(children: .combine)
        .firstRunWholeAtRest()
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 14))
                .foregroundStyle(TokensUI.secondary)
                .frame(width: 20)
                .tokensControlOnBaseline()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(permission.name)
                    .font(TokensType.body)
                    .foregroundStyle(TokensUI.ink)
                    .tokensOnRule(cell: TokensUI.halfCell)
                Text(permission.reason)
                    .font(TokensType.caption)
                    .foregroundStyle(TokensUI.secondary)
                    .tokensReadingPitch(size: 13)
                    .fixedSize(horizontal: false, vertical: true)
                    .tokensOnRule(cell: TokensUI.halfCell)
            }
            Spacer(minLength: 0)
            ZStack {
                if permission.allowed {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(TokensUI.ink)
                } else {
                    Circle().strokeBorder(permission.urgent ? TokensUI.red : TokensUI.ink.opacity(0.25),
                                          lineWidth: permission.urgent ? 1.5 : 1)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 20, height: 20)
            .tokensControlOnBaseline()
            .accessibilityElement()
            .accessibilityLabel(permission.allowed ? "Allowed" : permission.urgent ? "Not allowed yet, waiting" : "Not allowed yet")
        }
    }
}

/// Rounds a block's height up to whole squares without moving it, and passes its baselines on.
struct FirstRunWholeSquares: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let cell = TokensUI.paperCell
        let height = max(cell, ((size.height - TokensOnRuleLayout.tolerance) / cell).rounded(.up) * cell)
        return CGSize(width: proposal.width ?? size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard let view = subviews.first, guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        return view.dimensions(in: ProposedViewSize(width: bounds.width, height: nil))[guide]
    }
}

/*
In the scrolling step (TokensHome.accessStage names its slot with tokensRestingEdge), a title,
line, button, picture or row that the window's bottom edge would cut is not drawn and takes no
clicks until it is scrolled into view, as History's rows do. A button counts its whole shape,
so a 36-point button hanging 13 points under the sheet's last rule is never shown sliced
(760 × 520 at 150%). The set-up sheet has no header for scrolled words to pass under, so the
top edge does the same: what has started to scroll past it goes whole (a button's last 13
points and the title's descenders showed at the scroll's end). Outside the scroll view nothing
changes. Drawing only, never layout: no GeometryReader is tied to the scroll content (DESIGN.md §8.1).
*/
struct FirstRunWholeAtRest: ViewModifier {
    @State private var underEdge = false

    func body(content: Content) -> some View {
        content
            .visualEffect { effect, proxy in effect.opacity(Self.underEdge(proxy) ? 0 : 1) }
            .allowsHitTesting(!underEdge)
            .onGeometryChange(for: Bool.self) { Self.underEdge($0) } action: { underEdge = $0 }
    }

    nonisolated static func underEdge(_ proxy: GeometryProxy) -> Bool {
        guard let slot = proxy.bounds(of: .named(TokensRestingEdgeMask.space)) else { return false }
        return hides(top: -slot.minY, height: proxy.size.height, slotHeight: slot.height)
    }

    /// Whether something drawn from `top`, `height` tall, plus a line's descenders, passes the
    /// slot's resting edge, or has begun to pass its top.
    nonisolated static func hides(top: CGFloat, height: CGFloat, slotHeight: CGFloat) -> Bool {
        top < -0.5 || top + height + TokensRestingEdgeMask.descender > TokensRestingEdgeMask.cut(height: slotHeight) + 0.5
    }
}

extension View {
    /// Not drawn while the scrolling Access step's bottom edge would cut it (FirstRunWholeAtRest).
    func firstRunWholeAtRest() -> some View { modifier(FirstRunWholeAtRest()) }
}

