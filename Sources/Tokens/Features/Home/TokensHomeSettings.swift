


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension TokensHome {

    /*
    Section label on a rule, its rows on the rules after it, one blank square between sections
    (DESIGN.md §6.4). The ScrollView is not the page slot's first child: the header stays above it.
    */
    var settingsPage: some View {
        // busy: a talk is running, which locks the microphone switch and auto-send.
        let busy = model.phase == .capturing || model.phase == .finalizing
        // Proof renders of the Ready state (--public-preview-ready) hide the Accessibility recovery row.
        let accessOff = !model.shortcutAccessGranted && !TokensPreview.forcesReady
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                TokensSettingsSection(title: "General") {
                    TokensSettingsRow(title: "Theme", caption: "How the window looks. The bubble keeps its own look.") {
                        TokensThemeMenu(selection: themeChoice) { raw in
                            if let theme = TokensTheme(rawValue: raw) { TokensTheme.choose(theme) }
                            themeChoice = raw
                        }
                        .accessibilityIdentifier("tokens.settings.theme")
                    }
                    TokensSettingsRow(title: "Text size",
                                      caption: "Makes the words in this window larger or smaller. ⌘0 or ⌃0 goes back to 100%.",
                                      value: "⌘ or ⌃ with + −") {
                        TokensZoomStepper(zoom: sheetZoom, change: changeSheetZoom)
                    }
                    TokensLoginSwitchRow()
                    TokensSettingsRow(title: "Talk key",
                                      caption: model.rightOptionMode == .tap ? "Press once to talk, press again to paste."
                                                                             : "Hold to talk, let go to paste.") {
                        HStack(alignment: .center, spacing: 12) {
                            TokensKeyChip(name: model.shortcutName, size: 14)
                                .accessibilityIdentifier("tokens.settings.dictation-key")
                            Button("Change…") { detail = .shortcut }
                                .buttonStyle(TokensQuietButtonStyle())
                                .accessibilityIdentifier("tokens.settings.dictation-key-change")
                        }
                    }
                    /*
                    Only the four edge presets appear, drawn as a tiny 72 × 46 screen. A choice saves
                    immediately and moves the existing bubble without showing it or taking focus;
                    the picker is locked while a talk is finishing. The row stays one square.
                    */
                    TokensSettingsRow(title: "Bubble position",
                                      caption: "Where the bubble sits while you talk. A choice moves it right away.",
                                      value: TokensBubblePickerGeometry.caption(bubblePlacement)) {
                        TokensBubblePlacementPicker(selection: bubblePlacement) { placeBubble($0) }
                            .disabled(model.phase == .finalizing)
                    }
                    // Switches use an empty label: the spoken name is set explicitly on each one.
                    TokensSettingsRow(title: "Auto-send after pasting",
                                      caption: "Press Return after a confirmed paste. Turn off to review first.") {
                        Toggle(isOn: $model.autoSendAfterPasting) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled(busy)
                            .accessibilityLabel("Auto-send after pasting")
                            .accessibilityValue(model.autoSendAfterPasting ? "On" : "Off")
                            .accessibilityIdentifier("tokens.auto-send")
                    }
                    TokensSettingsRow(title: "Show where words land",
                                      caption: "Dotted corners and a small π mark the text box your words go into.") {
                        Toggle(isOn: $showPasteMarker) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .accessibilityLabel("Show where words land")
                            .accessibilityValue(showPasteMarker ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.paste-marker")
                    }
                    TokensSettingsRow(title: "Show a ring at the pointer",
                                      caption: "A dotted circle follows your pointer when no text box is ready.") {
                        Toggle(isOn: $showCursorRing) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .accessibilityLabel("Show a ring at the pointer")
                            .accessibilityValue(showCursorRing ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.cursor-ring")
                    }
                }
                TokensRuleSpacer(cells: 1)
                TokensSettingsSection(title: "Transcript extras") {
                    TokensSettingsRow(title: "Include thinking traces",
                                      caption: "Mark long pauses as [thinking 2.40s] between your words.") {
                        Toggle(isOn: Binding(get: { model.thinkingTracesEnabled }, set: { model.selectThinkingTracesEnabled($0) })) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled(busy)
                            .accessibilityLabel("Include thinking traces")
                            .accessibilityValue(model.thinkingTracesEnabled ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.thinking")
                    }
                    TokensSettingsRow(title: "Include metadata",
                                      caption: "End with one line: words per minute, seconds and characters.") {
                        Toggle(isOn: Binding(get: { model.metadataEnabled }, set: { model.selectMetadataEnabled($0) })) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled(busy)
                            .accessibilityLabel("Include metadata")
                            .accessibilityValue(model.metadataEnabled ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.metadata")
                    }
                    TokensSettingsRow(title: "Include character tags",
                                      caption: "Mark spelled letters for AI tools. Off keeps plain text.") {
                        Toggle(isOn: Binding(get: { model.characterTagsEnabled }, set: { model.selectCharacterTagsEnabled($0) })) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled(busy)
                            .accessibilityLabel("Include character tags")
                            .accessibilityValue(model.characterTagsEnabled ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.character-tags")
                    }
                    TokensSettingsRow(title: "Include number tags",
                                      caption: "Mark spoken number runs for AI tools. Off keeps plain digits.") {
                        Toggle(isOn: Binding(get: { model.numberTagsEnabled }, set: { model.selectNumberTagsEnabled($0) })) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled(busy)
                            .accessibilityLabel("Include number tags")
                            .accessibilityValue(model.numberTagsEnabled ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.number-tags")
                    }
                }
                TokensRuleSpacer(cells: 1)
                TokensSettingsSection(title: "Microphone") {
                    // Build 82: the menu switches models in place; "Manage models…" opens the Models tab.
                    TokensSettingsRow(title: "Speech engine",
                                      caption: OrukeetAttribution.engineCaption,
                                      value: speechEngineValue) {
                        HStack(spacing: 8) {
                            if orukeetChosen, case .failed = orukeetDownload.state {
                                Button("Retry") { orukeetDownload.retry() }
                                    .buttonStyle(TokensQuietButtonStyle())
                                    .accessibilityIdentifier("tokens.settings.orukeet-retry")
                            }
                            TokensModelMenu(look: .settings, store: speechModels, talking: busy, talkingWith: talkingModelID,
                                            choose: chooseSpeechModel(id:)) { select(.models) }
                        }
                    }
                    // The device name truncates in the middle, so both ends of a long name stay readable.
                    TokensSettingsRow(title: model.effectiveInputDeviceName,
                                      caption: "\(appName) listens with this microphone. Reconnect restarts it.",
                                      flagged: audio.captureError != nil,
                                      value: audio.captureError == nil ? "Input ready" : "Reconnect needed") {
                        Button("Reconnect") { model.reconnectMicrophone() }
                            .buttonStyle(TokensQuietButtonStyle())
                            .disabled(model.reconnectDisabled)
                            .accessibilityIdentifier("tokens.settings.reconnect")
                    }
                    TokensSettingsRow(title: "Keep the mic on between talks",
                                      caption: model.ambientStatus + ". Off each launch; turning it on asks first.",
                                      value: Self.keepMicValue(status: model.ambientStatus, enabled: model.ambientEnabled)) {
                        Toggle(isOn: model.backgroundListeningBinding) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled(busy && !model.ambientEnabled)
                            .accessibilityLabel("Keep the mic on between talks")
                            .accessibilityValue(model.ambientEnabled ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.keep-mic-on")
                    }
                    // The page's one red action: the way back to a working dictation key.
                    if accessOff {
                        TokensSettingsRow(title: "Accessibility",
                                          caption: model.shortcutAccessNeedsRelaunch ? "Allowed. Relaunch to finish."
                                                                                     : "Off, so the key does nothing yet.",
                                          flagged: true,
                                          value: model.shortcutAccessNeedsRelaunch ? "Allowed, relaunch" : "Off") {
                            HStack(alignment: .center, spacing: 12) {
                                if model.shortcutAccessNeedsRelaunch {
                                    Button("Relaunch") { model.relaunchForShortcutAccess() }
                                        .buttonStyle(TokensPrimaryButtonStyle())
                                        .disabled(model.reconnectDisabled)
                                } else {
                                    Button("Try again") { model.retryShortcutAccess() }
                                        .buttonStyle(TokensQuietButtonStyle())
                                    Button("Open Settings") { model.openShortcutAccessibilitySettings() }
                                        .buttonStyle(TokensPrimaryButtonStyle())
                                }
                            }
                        }
                    }
                }
                TokensRuleSpacer(cells: 1)
                TokensSettingsSection(title: "About") {
                    if model.updater.isConfigured {
                        UpdateRow(updater: model.updater)
                    }
                    // CC BY-SA 4.0 credit for the bundled speech model, with its model page.
                    TokensSettingsRow(title: "Speech model",
                                      caption: "Orukeet's weights are shared under \(OrukeetAttribution.license).",
                                      value: OrukeetAttribution.line) {
                        Button("Learn more") { NSWorkspace.shared.open(OrukeetAttribution.modelPage) }
                            .buttonStyle(TokensQuietButtonStyle())
                            .accessibilityIdentifier("tokens.settings.orukeet-credit")
                    }
                    // What this build stores on the Mac and which network requests it can make.
                    TokensSettingsRow(title: "Privacy",
                                      caption: "No account and no analytics. Read what stays on this Mac.") {
                        Button("Read") { NSWorkspace.shared.open(LaunchLinks.privacy) }
                            .buttonStyle(TokensQuietButtonStyle())
                            .accessibilityIdentifier("tokens.settings.privacy")
                    }
                    // App name, version and build number from the app bundle's Info.plist.
                    TokensSettingsRow(title: Self.versionLine,
                                      caption: "Open source under the MIT license.") {
                        Button("Quit \(appName)") { NSApp.terminate(nil) }
                            .buttonStyle(TokensQuietButtonStyle())
                    }
                }
            }
            .tokensPageColumn()
        }
        .tokensRuledScroll()
    }

    /// "Tokens 1.0 (30)". A bare debug binary has no Info.plist values, so empty parts are left out.
    static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return [appName, version, build.isEmpty ? "" : "(\(build))"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /*
    The keep-mic-on row shows the model's status only when it says more than the switch does:
    "Connecting microphone…", a capture error, or "enabled · microphone stopped". Off, live and
    talking statuses add nothing beside an on/off switch, so they stay in the tooltip.
    */
    static func keepMicValue(status: String, enabled: Bool) -> String? {
        guard enabled else { return nil }
        let plain: Set<String> = ["Background listening off", "Listening · on this Mac",
                                  "Microphone live · on this Mac", "Talking · on this Mac"]
        return plain.contains(status) ? nil : status
    }

    /// Persist a preset and move the existing bubble without showing it. Same steps as the Home
    /// helper (`selectBubblePlacement`), kept here so Settings does not depend on Home's file.
    func placeBubble(_ placement: BubblePlacement) {
        BubblePlacement.save(placement)
        bubblePlacement = placement
        if let window = compactWindow(), let visible = window.screen?.visibleFrame {
            BubbleWindowPlacement.apply(placement, to: window, visible: visible)
        }
    }

//
// :)
//
//
    /*
    The Models tab (build 82; before, Settings › Speech engine › Change…). This adapter says where
    each model stands on this Mac and what each row's action does. A verified download selects that model unless the user chose another while it ran.
    */
    var modelsPage: some View {
        let talking = model.phase == .capturing || model.phase == .finalizing
        return ScrollView(.vertical) {
            TokensModelsPage(models: SpeechModelCatalog.all,
                             availability: speechModelAvailability,
                             actions: SpeechModelActions(
                                use: chooseSpeechModel,
                                download: { speechModels.downloadIfMissing($0.id, selectWhenReady: true) },
                                cancel: { speechModels.cancel($0.id) },
                                remove: { speechModels.remove($0.id) }),
                             talking: talking)
                .tokensPageColumn()
        }
        .tokensRuledScroll()
    }

    /*
    The Speech engine row's words beside the menu: only what the menu's name does not say already
    (Orukeet's download, a model loading or unavailable). "Orukeet · ready on this Mac" next to a
    menu reading "Orukeet" said it twice.
    */
    var speechEngineValue: String? {
        if orukeetChosen, let line = orukeetDownload.statusLine { return line }
        // Only news the menu's name cannot carry: loading, or why it cannot be used. "· ready on
        // this Mac", "· local model" and "Apple · on this Mac" only repeated it (review, 2026-10-17).
        return Self.speechEngineNews(audio.speechEngineStatus)
    }

    /// The part of AudioCapture's engine status worth a line beside the menu: loading or unavailable.
    static func speechEngineNews(_ status: String) -> String? {
        status.hasPrefix("Loading") || status.contains("unavailable") ? status : nil
    }

    /// A talk is capturing or finishing right now.
    var talkingNow: Bool { model.phase == .capturing || model.phase == .finalizing }

    /// The model the running talk uses: Apple when it started on Apple, else the chosen local model.
    var talkingModelID: String? {
        guard talkingNow else { return nil }
        return audio.sessionSpeechEngine == .apple ? SpeechModelCatalog.appleID : SpeechEngineChoice.selectedModelID()
    }

    /// The menus' switch: checked against the talk phase at the moment of the click.
    func chooseSpeechModel(id: String) {
        guard !talkingNow else { return }
        speechModels.choose(id)
    }

    /// Orukeet is the chosen model (its download line and Retry belong to it alone).
    var orukeetChosen: Bool {
        _ = storedSpeechEngine
        return SpeechEngineChoice.selectedModelID() == SpeechModelCatalog.orukeetID
    }

    func speechModelAvailability(_ info: SpeechModelEntry) -> SpeechModelAvailability {
        _ = storedSpeechEngine  // read so a new choice redraws the page
        if let fixture = TokensHomePreview.modelAvailability(model, id: info.id) { return fixture }
        let selected = SpeechEngineChoice.selectedModelID()
        switch speechModels.state(for: info.id) {
        case .builtIn, .ready:
            return info.id == selected ? .inUse : .ready
        case .notDownloaded: return .downloadable
        case .downloading(let fraction): return .downloading(fraction)
        // A full disk is said as such: freeing space, not waiting, is what gets it going (build 81).
        case .failed(let reason): return OrukeetDownloadFailure.isNoSpace(reason) ? .noSpace : .paused
        case .comingSoon: return .notYet
        }
    }

    /// Use: only a model on this Mac, and never during a talk. The page redraws through storedSpeechEngine.
    func chooseSpeechModel(_ info: SpeechModelEntry) {
        guard model.phase != .capturing, model.phase != .finalizing else { return }
        speechModels.choose(info.id)
    }

    // The key picker. Choosing a key is switched off while a talk is running.
    var shortcutPage: some View {
        ScrollView(.vertical) {
            TokensShortcutPicker(model: model)
                .tokensPageColumn()
        }
        .tokensRuledScroll()
    }
}

/*
DESIGN.md §6.6. Rule 3 says what the page is for; rules 4-8 are the five recommended keys
(chip, name, and a tick on the one in use or "Used by …" on a key a sibling app owns); the next
rule is "Show all keys", which opens the whole keyboard in one inset panel. A key macOS also
acts on (Fn) gets a note with a red dot after that. Selecting goes through model.selectShortcut,
exactly as the keyboard does, and is locked while a talk is capturing or finishing.
*/
struct TokensShortcutPicker: View {
    @ObservedObject var model: TalkModel
    @State private var expanded: Bool
    /// Keys sibling apps own (Tokens and Tokens Dev); listed, but not selectable.
    private let reserved = TalkShortcut.siblingReservedKeys()

    /// The recommended keys, in the order DESIGN.md §6.6 lists them.
    static let recommended: [TalkShortcut] = [.leftOption, .rightOption, .rightCommand, .leftControl, .globe]
    /// Render-only: --shortcut-preview-hover draws the first key row as if the pointer were over it
    /// (same gate as History's fixtures: --render-preview-frames in a proof-allowed build).
    static let previewHover = TokensHistoryPreview.flag("--shortcut-preview-hover")

    init(model: TalkModel) {
        self.model = model
        _expanded = State(initialValue: Self.opensExpanded(keyCode: model.shortcutKeyCode))
    }

    /*
    The keyboard starts open when the key in use is not one of the five, so it is always visible,
    or in a proof render with --public-preview-all-keys (render-only, proof-allowed builds, never
    saved anywhere).
    */
    static func opensExpanded(keyCode: UInt16, arguments: [String] = ProcessInfo.processInfo.arguments,
                              allowed: Bool = ProofRoutes.isAllowed) -> Bool {
        if !recommended.contains(where: { $0.keyCode == keyCode }) { return true }
        return allowed && arguments.contains("--render-preview-frames") && arguments.contains("--public-preview-all-keys")
    }

    /// The word printed on the keycap; the row's name says which side.
    static func legend(_ shortcut: TalkShortcut) -> String {
        switch shortcut.keyCode {
        case 58, 61: return "Option"
        case 54, 55: return "Command"
        case 59, 62: return "Control"
        case 63:     return "Fn"
        default:     return shortcut.displayName
        }
    }

    private var selectionEnabled: Bool { model.phase != .capturing && model.phase != .finalizing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pick the key you press to talk.")
                .font(TokensType.body)
                .foregroundStyle(TokensUI.secondary)
                .tokensOnRule()
            // The rows are centred in their own squares, so a blank square keeps the first one
            // (and its hover wash) clear of the line above.
            TokensRuleSpacer(cells: 1)
            ForEach(Self.recommended, id: \.keyCode) { shortcut in
                recommendedRow(shortcut)
            }
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(expanded ? "Hide all keys" : "Show all keys")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .font(TokensType.caption)
            }
            .buttonStyle(TokensLinkButtonStyle())
            .accessibilityIdentifier("tokens.shortcut.all-keys")
            .accessibilityValue(expanded ? "Shown" : "Hidden")
            .tokensOnRule()
            if expanded { keyboardPanel }
            // A key macOS also acts on (Fn opening Emoji & Symbols) is allowed, but said out loud.
            if let conflict = TalkShortcut.systemConflict(keyCode: model.shortcutKeyCode) {
                conflictNote(conflict)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One recommended key: chip, name, then a tick (in use) or who owns it (reserved).
    private func recommendedRow(_ shortcut: TalkShortcut) -> some View {
        let current = model.shortcutKeyCode == shortcut.keyCode
        let owner = reserved[shortcut.keyCode]
        let usable = owner == nil && selectionEnabled
        return Button {
            guard !current else { return }
            model.selectShortcut(shortcut)
        } label: {
            TokensHistoryCellLayout {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // Two squares wide, so every name starts on the same vertical rule.
                    TokensKeyChip(name: Self.legend(shortcut), size: 14)
                        .tokensControlOnBaseline()
                        .frame(width: 2 * TokensUI.paperCell, alignment: .leading)
                    Text(shortcut.displayName)
                        .font(TokensType.body)
                        .foregroundStyle(usable || current ? TokensUI.ink : TokensUI.secondary)
                    Spacer(minLength: 16)
                    if current {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TokensUI.ink)
                    } else if let owner {
                        Text("Used by \(owner)").font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(TokensKeyRowStyle(proofHover: Self.previewHover && shortcut.keyCode == Self.recommended.first?.keyCode))
        .disabled(!selectionEnabled || owner != nil)
        .help(owner.map { "Used by \($0)" } ?? "")
        .accessibilityLabel(shortcut.displayName)
        .accessibilityValue(current ? "Selected talk key" : owner.map { "Used by \($0)" } ?? "")
        .accessibilityAddTraits(current ? [.isSelected] : [])
        .accessibilityIdentifier("tokens.shortcut.key.\(shortcut.keyCode)")
    }

    /*
    The whole keyboard in the one inset panel this page allows. The panel's top sits on the
    half-rule after "Show all keys"; its height rounds to half squares and the block to whole
    squares, so the note after it lands back on a rule (DESIGN.md §4.2 R3).
    */
    private var keyboardPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TokensRuleSpacer(cells: 0.5)
            TokensCard(padding: 16) {
                ShortcutKeyboard(selectedKeyCode: model.shortcutKeyCode,
                                 compact: true,
                                 selectionEnabled: selectionEnabled) { shortcut in
                    model.selectShortcut(shortcut)
                }
                .fixedSize(horizontal: false, vertical: true)
                .tokensWholeSquares(step: TokensUI.halfCell, chrome: 32, centred: true)
            }
        }
        .tokensWholeSquares(step: TokensUI.paperCell)
    }

    /// Red dot, the words at the 28-point pitch, then the Keyboard Settings link on the next line.
    private func conflictNote(_ conflict: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TokensStatusDot(color: TokensUI.red)
            VStack(alignment: .leading, spacing: TokensType.lineSpacing(size: 13)) {
                Text(conflict)
                    .foregroundStyle(TokensUI.secondary)
                    .tokensReadingPitch(size: 13)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("Open Keyboard Settings")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(TokensLinkButtonStyle())
                .accessibilityIdentifier("tokens.shortcut.keyboard-settings")
            }
            .font(TokensType.caption)
        }
        .tokensOnRule()
        .accessibilityIdentifier("tokens.shortcut.system-conflict")
    }
}

/*
A list row's hover wash: ink at 4% (6% pressed). The row's chip and name are centred in its
own grid square (like History's rows), so the wash and the click area are exactly that square,
square-cornered, on the same grid lines as the column: adjacent rows tile without overlapping
(build 77: the old wash was a rounded band 12 points past the column, off the grid).
*/
private struct TokensKeyRowStyle: ButtonStyle {
    /// Render-only hover fixture (--shortcut-preview-hover).
    var proofHover = false

    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, proofHover: proofHover) }

    private struct Chrome: View {
        let configuration: Configuration
        let proofHover: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            let alpha = !enabled ? 0 : configuration.isPressed ? 0.06 : hovered || proofHover ? 0.04 : 0
            configuration.label
                .background { Rectangle().fill(TokensInk.primary.color.opacity(alpha)) }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/*
Rounds a block's height up to whole steps (DESIGN.md §4.2 R3): `chrome` is padding drawn
outside the child (a card's 16 + 16), so the drawn panel, not just its content, is whole
steps tall. A centred child shares the extra space above and below it.
*/
private struct TokensWholeSquaresLayout: Layout {
    var step: CGFloat
    var chrome: CGFloat = 0
    var centred = false

    private func height(for child: CGFloat) -> CGFloat {
        max(0, ceil((child + chrome - 0.5) / step) * step - chrome)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: height(for: size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let extra = centred ? ((bounds.height - size.height) / 2).rounded() : 0
        view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + max(0, extra)),
                   proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

private extension View {
    func tokensWholeSquares(step: CGFloat, chrome: CGFloat = 0, centred: Bool = false) -> some View {
        TokensWholeSquaresLayout(step: step, chrome: chrome, centred: centred) { self }
    }
}

//
// :)
//

/// A section label on its own rule, then its rows on the rules after it. No card, no hairlines.
struct TokensSettingsSection<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(TokensType.captionStrong)
                .foregroundStyle(TokensUI.secondary)
                .accessibilityAddTraits(.isHeader)
                .tokensOnRule()
            rows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/*
One Settings row, one square (DESIGN.md §5.3): the 15-point title on the rule at the column's
leading edge, then at the right an optional 13-point value on the same baseline and the control
centred 5 points above it, 12 apart. `caption` is never drawn: it is the row's tooltip and the
control's spoken hint. `flagged` means something needs doing: a red dot goes before the value,
or, with no value, the caption becomes the note line. `note` is a second line on the next rule:
a red dot and 13-point secondary words. When the value does not fit beside the title (narrow
or zoomed windows), it moves to its own rule under the title instead of crowding it. When the
control itself does not fit beside the title (a wide key name such as Right Option at 150%), the
control moves to the next rule at the trailing edge, so the title is never cut ("Dict…n key").
*/
struct TokensSettingsRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    var flagged = false
    var value: String? = nil
    var note: String? = nil
    /// Layout evidence hook: tests read the title's drawn width. Nothing is stored or sent.
    var onTitleLayout: ((CGFloat) -> Void)? = nil
    @ViewBuilder let control: Control

    private var hint: String? { caption.flatMap { $0.isEmpty ? nil : $0 } }
    private var noteText: String? { note ?? (flagged && value == nil ? hint : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The first arrangement whose natural width fits the column wins; each later one
            // takes one more rule rather than truncating the title.
            ViewThatFits(in: .horizontal) {
                line(value: value)
                if let value {
                    VStack(alignment: .leading, spacing: 0) {
                        line(value: nil)
                        statusText(value, dot: flagged).tokensOnRule()
                    }
                }
                if Control.self != EmptyView.self { stacked }
            }
            if let noteText {
                statusText(noteText, dot: true).tokensOnRule()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(hint ?? "")
    }

    /// The title: one line, cut in the middle only when even its own rule is too narrow.
    private var titleText: some View {
        Text(title)
            .font(TokensType.body)
            .foregroundStyle(TokensUI.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .background {
                if let onTitleLayout {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { onTitleLayout(geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in onTitleLayout(width) }
                    }
                }
            }
    }

    /// The narrowest arrangement: the title alone on its rule, then the value (leading, as when
    /// it moves under the title) and the control (trailing, where every row's control ends).
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleText.tokensOnRule()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let value { statusText(value, dot: flagged).padding(.trailing, 16) }
                Spacer(minLength: 0)
                control
                    .tokensControlOnBaseline()
                    .tokensHint(hint)
                    .fixedSize()
            }
            .tokensOnRule()
        }
    }

    /// Title, then at least the 16-point gap (DESIGN.md §4.5), then the value and control. The
    /// gap is the spacer's own minimum: an HStack spacing would count it on both sides (32).
    private func line(value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            titleText
            Spacer(minLength: 16)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let value { statusText(value, dot: flagged) }
                // A row with nothing to press (a login item outside Applications) passes EmptyView,
                // so the value ends on the column's trailing edge like every control does.
                if Control.self != EmptyView.self {
                    control
                        .tokensControlOnBaseline()
                        .tokensHint(hint)
                }
            }
            .fixedSize()
        }
        .tokensOnRule()
    }

    /// 13-point secondary words, with the 6-point red dot when something needs doing.
    private func statusText(_ text: String, dot: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if dot { TokensStatusDot(color: TokensUI.red) }
            Text(text)
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
                .tokensReadingPitch(size: 13)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    /// The old visible caption, spoken after the control's own label.
    @ViewBuilder func tokensHint(_ hint: String?) -> some View {
        if let hint { accessibilityHint(hint) } else { self }
    }
}

/*
Settings ▸ Theme as a quiet menu button: the current theme's name and an up-down chevron. The
menu lists all four themes with a tick on the current one; choosing calls the caller's closure,
which saves and applies it exactly as before (TokensTheme.choose, then the stored key).
*/
struct TokensThemeMenu: View {
    let selection: String
    let choose: (String) -> Void

    private var current: TokensTheme { TokensTheme(rawValue: selection) ?? TokensTheme.current }

    var body: some View {
        Menu {
            Picker("Theme", selection: Binding(get: { selection }, set: { choose($0) })) {
                ForEach(TokensTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(current.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TokensUI.secondary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TokensQuietButtonStyle())
        .fixedSize()
        .accessibilityLabel("Theme")
        .accessibilityValue(current.title)
    }
}

/// − / 100% / + on one raised track, 28 tall. Same `changeSheetZoom` steps as ⌘− / ⌘0 / ⌘+.
struct TokensZoomStepper: View {
    let zoom: CGFloat
    let change: (Int) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 0) {
            segment("−", width: 30, disabled: zoom <= TokensSheetZoom.minimum) { change(-1) }
                .accessibilityLabel("Make text smaller")
                .accessibilityIdentifier("tokens.settings.zoom-out")
            divider
            segment("\(Int((zoom * 100).rounded()))%", width: 56) { change(0) }
                .accessibilityLabel("Reset text size to 100 percent")
                // The size in use, which the label alone never said (TOK-QA-004).
                .accessibilityValue("Text size \(Int((zoom * 100).rounded())) percent")
                .accessibilityIdentifier("tokens.settings.zoom-reset")
            divider
            segment("+", width: 30, disabled: zoom >= TokensSheetZoom.maximum) { change(1) }
                .accessibilityLabel("Make text larger")
                .accessibilityIdentifier("tokens.settings.zoom-in")
        }
        .frame(height: 28)
        .background(TokensUI.raised, in: shape)
        .overlay { shape.strokeBorder(TokensUI.controlEdge, lineWidth: 1) }
    }

    private var divider: some View {
        Rectangle().fill(TokensInk.primary.color.opacity(0.12)).frame(width: 1, height: 16)
    }

    private func segment(_ text: String, width: CGFloat, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(TokensType.label.monospacedDigit())
                .foregroundStyle(disabled ? TokensUI.secondary : TokensUI.ink)
                .frame(width: width, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/*
The start-at-login row for the Tokens window. Same behaviour as LoginItemRow (App/LoginItem.swift),
drawn as a Settings row: the switch is bound to the real system state, turning it calls
LoginItem.set and then re-reads the state; the state is read on appear and on activation only
(each read is an XPC call). A copy outside /Applications cannot register: it shows no switch,
only the words "Move to Applications to turn on". Needing approval, or a failed change, adds a
note line and an Open Login Items button.
*/
struct TokensLoginSwitchRow: View {
    @State private var enabled          = false
    @State private var requiresApproval = false
    @State private var errorText        = ""

    private var isOn: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { on in
                // The raw error is logged by set(); the row shows fixed words.
                errorText = LoginItem.set(on) == nil ? "" : "That didn't work. Try Login Items."
                refresh()
            })
    }

    /// The row's tooltip and spoken hint (the words the row used to print under its title).
    private var caption: String {
        if !LoginItem.canRegister { return "Drag \(appName) into Applications to use this." }
        if requiresApproval { return "Almost: allow \(appName) in Login Items." }
        return errorText.isEmpty ? "\(appName) starts quietly when you log in." : errorText
    }

    /// Something to do in System Settings: approve the item, or the fixed error words.
    private var note: String? {
        guard LoginItem.canRegister else { return nil }
        if requiresApproval { return "Allow it in Login Items" }
        return errorText.isEmpty ? nil : errorText
    }

    var body: some View {
        Group {
            if LoginItem.canRegister {
                TokensSettingsRow(title: LoginItemRow.label, caption: caption, note: note) {
                    HStack(alignment: .center, spacing: 12) {
                        if note != nil {
                            Button("Open Login Items") { LoginItem.openLoginItems() }
                                .buttonStyle(TokensQuietButtonStyle())
                        }
                        Toggle(isOn: isOn) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .accessibilityLabel(LoginItemRow.label)
                            .accessibilityValue(enabled ? "On" : "Off")
                            .accessibilityIdentifier("tokens.settings.open-at-login")
                    }
                }
            } else {
                TokensSettingsRow(title: LoginItemRow.label, caption: caption,
                                  value: "Move to Applications to turn on") { EmptyView() }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    // Re-reads the state from macOS. Clears an old error once the switch is actually on.
    private func refresh() {
        enabled          = LoginItem.isEnabled
        requiresApproval = LoginItem.requiresApproval
        if enabled { errorText = "" }
    }
}

// UpdateRow — one line in Settings: check, or install the update that was found

/// Watches the updater directly, so its label and buttons change without reloading the page.
struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        TokensSettingsRow(title: updater.label) {
            HStack(alignment: .center, spacing: 12) {
                if updater.available {
                    Button("Later") { updater.dismissAvailable() }.buttonStyle(TokensQuietButtonStyle())
                    Button("Install") { updater.installAvailable() }.buttonStyle(TokensPrimaryButtonStyle())
                } else if updater.canRetryRestart {
                    Button("Restart \(appName)") { updater.retryRestart() }.buttonStyle(TokensPrimaryButtonStyle())
                } else if updater.canCancel {
                    Button("Cancel") { updater.cancel() }.buttonStyle(TokensQuietButtonStyle())
                } else {
                    Button("Check") { updater.check() }
                        .buttonStyle(TokensQuietButtonStyle())
                        .disabled(updater.busy)
                }
            }
        }
    }
}

