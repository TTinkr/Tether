


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// StyleChooser


struct StyleChooser: View {
    @State private var dictionaryPresented = false
    @State private var keyboardPresented   = false
    @ObservedObject var model: TalkModel
    @ObservedObject private var updater: Updater
    @ObservedObject private var audio: AudioCapture
    @ObservedObject private var formatter: LocalFormatter
    @ObservedObject private var tinkering: Tinkering
    @ObservedObject private var liveTinkering: TokenPauseAsides
    @State private var profilePresented = false

    init(model: TalkModel) {
        self.model     = model
        _tinkering     = ObservedObject(wrappedValue: model.tinkering)
        _liveTinkering = ObservedObject(wrappedValue: model.pauseAsides)
        _updater       = ObservedObject(wrappedValue: model.updater)
        _audio         = ObservedObject(wrappedValue: model.audio)
        _formatter     = ObservedObject(wrappedValue: model.localFormatter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 20) {
                if standalone {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("π Talk").font(.system(size: 25, design: .serif))
                        Text("by tinkr").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                else if model.selectedProduct == "Tokens" {
                    HStack(alignment: .center, spacing: 3) {
                        Text("π").font(.system(size: 27, design: .serif))
                        Text(appName).font(.system(size: 25, design: .serif))
                    }
                } else { ProductWordmark(product: model.selectedProduct, size: 25) }
                modeButton(.tap, title: "Tap")
                modeButton(.hold, title: "Hold")
                Spacer()
                if !standalone {
                Button { model.toggleProductDrawer() } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 16, weight: .light))
                }.buttonStyle(.plain).accessibilityLabel("Switch products")
                                .onHover { model.hoverProductDrawer($0) }
                }
            }
            .padding(.bottom, 10)

            VoiceMemoWaveform(
                samples: model.previewWaveform ?? audio.waveform,
                currentLevel: model.previewInputLevel ?? audio.inputLevel,
                active: recordingConfirmed
            )
            .frame(maxWidth: .infinity)
            .frame(height: mainWaveformHeight)
            .accessibilityLabel(recordingStatus)

            MainTranscriptStream(text: mainLiveText, phase: model.phase)
                .frame(maxWidth: .infinity)
                .frame(height: 44, alignment: .topLeading)

            if model.selectedProduct == "Talk" {
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                GridRow {
                    Toggle("Metadata", isOn: Binding(get: { model.metadataEnabled }, set: { model.selectMetadataEnabled($0) }))
                    Toggle("Markdown", isOn: Binding(get: { model.markdownEnabled }, set: { model.selectMarkdownEnabled($0) }))
                }
                GridRow {
                    Toggle("Speed of Sound", isOn: Binding(get: { model.speedOfSoundEnabled }, set: { model.selectSpeedOfSoundEnabled($0) }))
                    Toggle("Local tokens", isOn: Binding(get: { formatter.enabled }, set: { formatter.setEnabled($0) }))
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 8) {
            Text("ON-DEVICE MODEL").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker("Model", selection: Binding(get: { formatter.selectedModel }, set: { formatter.selectModel($0) })) {
                    ForEach(Array(Set(formatter.availableModels + [formatter.selectedModel])).sorted(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.phase == .capturing || model.phase == .finalizing)
                Button(action: { formatter.refreshModels() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh installed Ollama models")
            }
            }.padding(.vertical, 6)
            Button("Personal dictionary…") { dictionaryPresented = true }
                .font(.system(size: 13))
                .sheet(isPresented: $dictionaryPresented) { PersonalDictionaryEditor() }
            Text(formatter.enabled ? formatter.status : formatter.modelListStatus)
                .font(.system(size: 10, design: .serif))
                .foregroundStyle(academicPencil)
                .lineLimit(1)
                .onAppear { formatter.refreshModels() }
            }

            if model.selectedProduct == "Tokens" {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.dailyAllowanceMessage).font(.system(size: 12, design: .serif))
                    if !model.dailyDeliveryNotice.isEmpty {
                        Text(model.dailyDeliveryNotice).font(.system(size: 10, design: .serif))
                    }
                }
                .foregroundStyle(academicPencil)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Daily allowance: " + model.dailyAllowanceMessage + ". " + model.dailyDeliveryNotice)
            }

            if !model.retainedFailureText.isEmpty {
                Text(model.retainedFailureText)
                    .font(.system(size: 10.5, weight: .regular, design: .serif))
                    .foregroundStyle(academicRed.opacity(0.82))
                    .lineLimit(1)
                    .accessibilityLabel("Delivery status")
            }

            Rectangle()
                .fill(academicPencil.opacity(0.34))
                .frame(height: 0.7)

            HStack(spacing: 14) {
                academicButton("Reconnect", disabled: model.reconnectDisabled) {
                    model.reconnectMicrophone()
                }

                Text(model.effectiveInputDeviceName + (model.inputPreviewOwnsCapture ? (model.audioIsConfirmed ? " · Input live" : " · Connecting…") : (audio.captureError == nil ? "" : " · Reconnect needed")))
                    .font(.system(size: 9.5, weight: .regular, design: .serif))
                    .foregroundStyle(academicPencil.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Button { model.copyLatestTranscript() } label: {
                    CopyFeedbackLabel(title: "Copy latest", copied: model.copyFeedbackKey == "latest", revision: model.copyFeedbackRevision)
                }
                .buttonStyle(.plain)
                .disabled(model.latestTranscript.isEmpty)
                .accessibilityLabel("Copy latest")
                .accessibilityValue(model.copyFeedbackKey == "latest" ? "Copied to clipboard" : "")

                Rectangle()
                    .fill(academicPencil.opacity(0.32))
                    .frame(width: 0.7, height: 17)

                Button {
                    model.togglePromptHistory()
                } label: {
                    HStack(spacing: 5) {
                        Text(model.historyExpanded ? "▾" : "▸")
                            .font(.system(size: 11, weight: .regular, design: .serif))
                        Text("All prompts")
                            .font(.system(size: 14, weight: .regular, design: .serif))
                        Text("\(model.promptHistory.count)")
                            .font(.system(size: 10, weight: .regular, design: .serif))
                            .foregroundStyle(academicPencil.opacity(0.52))
                    }
                    .foregroundStyle(academicInk.opacity(0.86))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.historyExpanded ? "Hide all prompts" : "Show all prompts")
                .accessibilityValue("\(model.promptHistory.count) prompts")
            }

            if model.selectedProduct == "Tokens" || model.selectedProduct == "Talk" {
                HStack {
                    Text("Takeoff delay")
                    Slider(value: $model.sendDelaySeconds, in: 0...5, step: 0.5)
                        .accessibilityLabel("Takeoff delay")
                    Text(model.sendDelaySeconds == 0 ? "Instant" : String(format: "%.1f s", model.sendDelaySeconds))
                        .monospacedDigit().frame(width: 55)
                }
                .font(.system(size: 12))
                .disabled(model.phase == .finalizing)
                .help("Shared by Tokens and Talk. Zero skips the intentional wait; longer delays allow more refinement.")
            }

            if model.selectedProduct == "Tokens" {
                HStack {
                    HStack(spacing: 7) {
                        Text(model.recordingShortcut ? "Press any key…" : model.shortcutName)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.88))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(academicPencil.opacity(0.32), lineWidth: 0.8)
                                    )
                            )
                        Text(model.recordingShortcut ? "Choose the key that starts and stops dictation" : "press once to dictate · press again to paste")
                            .foregroundStyle(academicPencil.opacity(0.72))
                    }
                    Spacer()
                    Button(model.recordingShortcut ? "Cancel" : "Change") {
                        if model.recordingShortcut { model.cancelShortcutChange() }
                        else { model.changeShortcut() }
                    }
                    Button("Keyboard") { keyboardPresented = true }
                        .sheet(isPresented: $keyboardPresented) {
                            ShortcutKeyboard(selectedKeyCode: model.shortcutKeyCode) { shortcut in
                                if model.selectShortcut(shortcut) { keyboardPresented = false }
                            }
                        }
                    Button("Reset") { model.resetShortcut() }
                }
                .font(.system(size: 12))
                .disabled(model.phase == .capturing || model.phase == .finalizing)
                .help("Choose a single key, including a modifier. This key will be reserved for Talk while it is running.")
                if !model.shortcutAccessGranted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.shortcutAccessNeedsRelaunch
                             ? "Accessibility is enabled, but \(model.shortcutName) has not attached yet."
                             : "\(model.shortcutName) is blocked until macOS Accessibility is enabled for \(appName).")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(academicRed)
                        HStack(spacing: 10) {
                            Button("Open Accessibility Settings") {
                                model.openShortcutAccessibilitySettings()
                            }
                            Button("Try Again") { model.retryShortcutAccess() }
                            if model.shortcutAccessNeedsRelaunch {
                                Button("Relaunch \(appName)") { model.relaunchForShortcutAccess() }
                                    .disabled(model.reconnectDisabled)
                            }
                        }
                        .font(.system(size: 12))
                    }
                    .padding(10)
                    .background(academicRed.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(academicRed.opacity(0.22), lineWidth: 0.8)
                    )
                }
                if model.phase == .finalizing {
                    Text("Finishing your last words…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if model.thinkingExperience {
                    HStack(spacing: 10) {
                        Toggle("Show live π ttalking", isOn: $model.showLiveTinkering)
                            .toggleStyle(.checkbox)
                            .help("Shows the live AI reflection. Generation and the final generated section stay on; your words remain separate.")
                        Text(liveTinkering.status)
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(academicPencil)
                            .lineLimit(1)
                            .accessibilityLabel("π ttalking status")
                        Spacer()
                    }.font(.system(size: 12))
                }
                Button { model.copyRecommendedSkill() } label: {
                    Text(model.copyFeedbackKey == "recommended-skill" ? "Skill copied to clipboard" : "Copy recommended skill")
                        .font(.system(size: 12))
                        .foregroundStyle(model.copyFeedbackKey == "recommended-skill" ? academicRed : academicInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy recommended skill")
                .accessibilityValue(model.copyFeedbackKey == "recommended-skill" ? "Copied to clipboard" : "")
                .help("Copy agent guidance for TToken talk and spelled character tags")
            }

            if model.historyExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.promptHistory.isEmpty {
                            Text("No prompts yet")
                                .font(.system(size: 13, weight: .regular, design: .serif))
                                .foregroundStyle(academicPencil.opacity(0.54))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(model.promptHistory) { entry in
                                Button { model.copyPromptHistoryEntry(entry) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(
                                            entry.createdAt,
                                            format: .dateTime.year().month(.abbreviated).day().hour().minute()
                                        )
                                            .font(.system(size: 9.5, weight: .regular, design: .serif))
                                            .foregroundStyle(academicPencil.opacity(0.50))
                                        Text(.init(model.historyPresentation(entry)))
                                            .font(.system(size: 13.5, weight: .regular, design: .serif))
                    .italic()
                                            .foregroundStyle(academicInk.opacity(0.84))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    CopyFeedbackLabel(title: "Copy", copied: model.copyFeedbackKey == entry.id.uuidString, revision: model.copyFeedbackRevision)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Copy prompt")
                                .accessibilityValue(model.copyFeedbackKey == entry.id.uuidString ? "Copied to clipboard" : model.historyPresentation(entry))
                                Rectangle()
                                    .fill(academicPencil.opacity(0.22))
                                    .frame(height: 0.6)
                            }
                        }
                    }
                }
                .frame(height: 155, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let value = updater.progress {
                    ProgressView(value: value).frame(width: 64)
                }
                Button(updater.label) { updater.check() }
                    .buttonStyle(.plain)
                    .disabled(updater.busy)
                    .font(.system(size: 11, design: .serif))
                if updater.canCancel {
                    Button("Cancel") { updater.cancel() }.buttonStyle(.plain)
                }
                Spacer()
            }
            .foregroundStyle(academicPencil)

            if !model.historyStorageError.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.historyStorageError)
                        .font(.system(size: 10.5, weight: .regular, design: .serif))
                        .foregroundStyle(academicRed.opacity(0.82))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    academicButton("Retry", disabled: false) {
                        model.retryPromptHistoryStorage()
                    }
                    if model.historyRecoveryRequired {
                        academicButton("Preserve & reset", disabled: false) {
                            model.recoverPromptHistoryStorage()
                        }
                    }
                }
            } else if !model.historyStorageNotice.isEmpty {
                Text(model.historyStorageNotice)
                    .font(.system(size: 10.5, weight: .regular, design: .serif))
                    .foregroundStyle(academicPencil.opacity(0.66))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AcademicGraphPaper())
        .preferredColorScheme(.light)
    }

//
// :)
//
//
    private var mainLiveText: String {
        let source        = audio.transcript.isEmpty ? model.displayText : audio.transcript
        let branded       = BrandVocabulary.apply(to: source)
        let characterTalk = CharacterTalk.render(branded)
        return ParagraphFormatter.format(characterTalk.displayText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modeButton(_ mode: RightOptionMode, title: String) -> some View {
        let selected                = model.rightOptionMode == mode
        let underlineWidth: CGFloat = title == "Tap" ? 25 : 31
        return Button {
            model.selectRightOptionMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .foregroundStyle(selected ? academicRed : academicInk.opacity(0.78))
                .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? academicRed : Color.clear)
                    .frame(width: underlineWidth)
                    .frame(height: 1.5)
                    .offset(y: 4)
                }
                .frame(width: 44, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.phase == .capturing || model.phase == .finalizing)
        .accessibilityLabel("\(model.shortcutName) \(title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func academicButton(
        _ title: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .regular, design: .serif))
            .foregroundStyle(academicInk.opacity(disabled ? 0.34 : 0.84))
            .disabled(disabled)
    }

    private var recordingConfirmed: Bool {
        model.audioIsConfirmed &&
            (model.phase == .capturing || model.isLabListening || model.inputPreviewOwnsCapture || model.previewAudioConfirmed != nil)
    }

    private var recordingStatus: String {
        if recordingConfirmed { return "Recording" }
        if model.phase == .capturing { return "Arming…" }
        if model.phase == .finalizing { return "Finishing…" }
        return "Ready"
    }
}

