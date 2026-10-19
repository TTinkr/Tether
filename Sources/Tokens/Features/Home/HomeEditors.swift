


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TinkeringProfileEditor — review, calibrate and save the profile note for the local model


/*
No other file creates a TinkeringProfileEditor at the moment, so this sheet is not reachable
from the app as it stands.
*/
/// Review-before-use profile editor. Calibration runs only from its button.
struct TinkeringProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TalkModel
    @ObservedObject var tinkering: Tinkering
    /*
    Top to bottom: what the profile is, the Calibrate button (builds a draft from saved talks;
    disabled while it runs), the status line, the editable draft, a line saying whether the draft
    equals the saved profile in use, a disclosure that prints the exact prompts, then Clear,
    Revert, Close (Escape) and Save (Return). Nothing is used until Save is pressed.
    */
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tinkering profile").font(.system(size: 20, weight: .semibold))
            Text("A short note about you that is added to the local model’s prompt. This is prompt personalization only: it does not train the model or change its weights. It stays on this Mac; nothing is sent anywhere and no audio is stored.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(tinkering.calibrating ? "Calibrating…" : "Calibrate from saved prompts") {
                    tinkering.calibrate(entries: model.promptHistory)
                }
                .disabled(tinkering.calibrating)
                .help("Uses up to \(TinkeringPrompts.maximumEntries) of your \(model.promptHistory.count) saved prompts, newest first, without any generated sections. Runs on the local Ollama model only.")
                if tinkering.calibrating { ProgressView().controlSize(.small) }
            }
            Text(tinkering.calibrationStatus)
                .font(.system(size: 11, design: .serif)).foregroundStyle(academicPencil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Calibration status")
            TextEditor(text: $tinkering.draft)
                .font(.system(size: 13))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.25)))
                .accessibilityLabel("Profile text")
            Text(tinkering.draft == (tinkering.profile?.text ?? "")
                 ? "This is the saved profile in use."
                 : "Unsaved draft · not used until you press Save.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            DisclosureGroup("Show the exact prompts") {
                ScrollView {
                    Text("TINKERING SYSTEM PROMPT\n\(TinkeringPrompts.system(profile: tinkering.profile?.text))\n\nCALIBRATION PROMPT\n\(TinkeringPrompts.calibration)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 120)
            }.font(.system(size: 12))
            HStack {
                Button("Clear profile") { tinkering.clearProfile() }
                    .help("Deletes the saved profile from this Mac")
                Button("Revert") { tinkering.revertDraft() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { tinkering.saveDraft() }.keyboardShortcut(.defaultAction)
            }.font(.system(size: 13))
        }.padding(24).frame(width: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(TokensUI.isDark ? .dark : .light)
    }
}


// PersonalDictionaryEditor — small sheet to edit the personal dictionary, one term per line


/*
Used by the old shell (Unreached/OldShell.swift) and the proof window in App/AppDelegate.swift.
The Home window's Dictionary page edits the same list inline.
*/
struct PersonalDictionaryEditor: View {

//
// :)
//
//
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var defaults: UserDefaults { UserDefaults(suiteName: PersonalDictionary.suite)! }
    /*
    The text is loaded when the sheet appears. Save writes it through PersonalDictionary and closes;
    Cancel (Escape) closes without saving. The count shown is the number of terms after normalising.
    */
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personal dictionary").font(.system(size: 20, weight: .semibold))
            Text("Names and terms you use. One per line, spelled as you want them.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 15))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.25)))
                .accessibilityLabel("Personal dictionary words")
            Text("For example: a teammate’s name, a friend’s name, or a company product. These are recognition hints, not guaranteed corrections. Saved changes apply to your next talk.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Text("\(PersonalDictionary.normalize(text).count) terms").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    PersonalDictionary.save(text, in: defaults)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.font(.system(size: 13))
        }.padding(24).frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(TokensUI.isDark ? .dark : .light)
            .onAppear { text = PersonalDictionary.load(in: defaults).joined(separator: "\n") }
    }
}

//
// :)
//
//
/*
The Dictionary's Edit as text editor: a real AppKit text view drawing 15 pt system text in ink
with no background, so the inset panel behind it shows through. Lines run at a 28 pt pitch
(half a graph square): the paragraph's line spacing is 28 minus the font's own line height
(ascender − descender + leading as the text system lays it out), computed from the font, never
typed. The insertion point and
the selection are ink, not red. Same editing rules as the pencil editor it replaced (plain text,
undo on, no smart quotes/dashes, no text replacement, no auto-correction) so the saved list is
exactly what was typed, and pasted text is re-styled so it cannot bring in another font or
colour. It scrolls inside its panel. `onEdit` fires only for user edits, never when the binding
pushes new text in.
*/
struct TokensPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll                   = NSTextView.scrollableTextView()
        scroll.drawsBackground       = false
        scroll.borderType            = .noBorder
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers    = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.insertionPointColor = TokensInk.primary.nsColor
        view.selectedTextAttributes = [.backgroundColor: TokensInk.primary.nsColor.withAlphaComponent(0.18)]
        // With the panel's 12-point top padding this puts the first baseline on rule 4 and
        // every later line on a rule or half-rule, the page's own rhythm.
        view.textContainerInset = NSSize(width: 0, height: 1)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.defaultParagraphStyle = Self.paragraph
        view.typingAttributes      = Self.attributes
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label)
        view.string = text
        Self.style(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEdit = onEdit
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        Self.style(view)
    }

    private static var font: NSFont { NSFont.systemFont(ofSize: 15) }

    /*
    28-point lines: the pitch minus the font's line height. The text system rounds ascender −
    descender + leading up to whole points (17.67 → 18 for 15 pt, measured 2026-10-13), so the
    raw sum left a 28.33-point pitch that drifted off the half-squares; defaultLineHeight is
    that same sum as the layout manager uses it.
    */
    static var lineSpacing: CGFloat {
        let height = NSLayoutManager().defaultLineHeight(for: font)
        return max(0, TokensUI.halfCell - height)
    }

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }()

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: TokensInk.primary.nsColor, .paragraphStyle: paragraph]
    }

    /// Pasted text cannot bring in another font or colour.
    fileprivate static func style(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        view.typingAttributes = attributes
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEdit: () -> Void

        init(text: Binding<String>, onEdit: @escaping () -> Void) {
            self.text = text
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if !view.hasMarkedText() { TokensPlainTextEditor.style(view) }
            if text.wrappedValue != view.string {
                text.wrappedValue = view.string
                onEdit()
            }
        }
    }
}

