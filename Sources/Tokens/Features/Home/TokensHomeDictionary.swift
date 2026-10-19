


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension TokensHome {

    // MARK: Dictionary

    /*
    The page itself lives in TokensDictionaryPage, which keeps the list / text switch and the
    edited flag; TokensHome keeps the words, the add field's text and the just-added mark.
    */
    var dictionaryPage: some View {
        TokensDictionaryPage(appName: appName,
                             text: $dictionaryText,
                             entry: $dictionaryEntry,
                             justAdded: dictionaryJustAdded,
                             add: addDictionaryEntry,
                             remove: removeDictionaryTerm,
                             save: { saveDictionaryTerms(PersonalDictionary.normalize(dictionaryText)) })
            .help("Saved words stay on this Mac.")
    }

    /// One word per add; a pasted list split by commas or new lines adds each. Repeats are ignored.
    func addDictionaryEntry() {
        let typed = dictionaryEntry.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        let next  = PersonalDictionary.normalize((PersonalDictionary.normalize(dictionaryText) + typed).joined(separator: "\n"))
        dictionaryEntry = ""
        saveDictionaryTerms(next)
        // Mark the newest word for a moment so it is easy to find.
        if let newest = typed.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { !$0.isEmpty }),
           let saved = next.first(where: { $0.caseInsensitiveCompare(newest) == .orderedSame }) {
            dictionaryJustAdded = saved
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if dictionaryJustAdded == saved { dictionaryJustAdded = nil }
            }
        }
    }

    func removeDictionaryTerm(_ word: String) {
        saveDictionaryTerms(PersonalDictionary.normalize(dictionaryText).filter { $0 != word })
    }

    /// Writes the normalized list through PersonalDictionary. Synthetic runs never write.
    func saveDictionaryTerms(_ terms: [String]) {
        dictionaryText = terms.joined(separator: "\n")
        if !model.isSyntheticRun {
            PersonalDictionary.save(dictionaryText, in: UserDefaults(suiteName: PersonalDictionary.suite)!)
        }
        dictionarySaved = true
    }
}

//
// :)
//
//
/*
Sheet coordinates at 1040 × 720: the title is on rule 2 (lane 0's header) and this page starts
at y = 112, so its first row's baseline lands on rule 3 (y = 168). Every line is one
.tokensOnRule() row in a spacing-0 VStack; nothing else adds vertical space.

List mode: rule 3 intro + count + Edit as text; rule 4 the add field; a blank square
(TokensFieldClearance), then one term per square, each centred in it; the next rule the hints
footnote (or, with no words, an empty line then the footnote).
Text mode keeps the intro line and replaces everything below it with one inset panel whose
top sits on the half-rule y = 196 and whose height is whole squares, so its bottom is on a
half-rule too (DESIGN.md §4.2 R3). `editingText` and `edited` live here, so leaving the page
(which reloads the saved words) always comes back to a clean list.
*/
struct TokensDictionaryPage: View {
    let appName: String
    @Binding var text: String
    @Binding var entry: String
    let justAdded: String?
    let add: () -> Void
    let remove: (String) -> Void
    let save: () -> Void

    @Environment(\.tokensSheetSize) private var sheet
    @State private var editingText = false
    @State private var edited = false
    @FocusState private var entryFocused: Bool

    /// Proof renders have no pointer, so they show the remove button on the first row only.
    private static var proofRender: Bool { ProcessInfo.processInfo.arguments.contains("--render-preview-frames") }
    /// Render-only: --dictionary-preview-hover draws the first term as if the pointer were over it
    /// (same gate as History's fixtures: --render-preview-frames in a proof-allowed build).
    static let previewHover = TokensHistoryPreview.flag("--dictionary-preview-hover")
    /// The 36-point add field is centred 5 points above its rule, so it ends 13 points below it;
    /// a term in the square right under it starts its wash 1 point lower than that.
    static let fieldOverhang: CGFloat = 36 / 2 - 5 + 1

    private var trimmedEntry: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let terms = PersonalDictionary.normalize(text)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                introRow(count: terms.count)
                if editingText {
                    TokensRuleSpacer(cells: 0.5)
                    textPanel(count: terms.count)
                } else {
                    // Above the rows: the field hangs a little below its rule, over the first
                    // term's cell, and must stay on top of that row's hover wash.
                    addRow.zIndex(1)
                    if terms.isEmpty {
                        Text("No words yet. Add names you say often.")
                            .font(TokensType.body)
                            .foregroundStyle(TokensUI.secondary)
                            .tokensOnRule()
                    } else {
                        /*
                        The terms are centred in their own squares; a blank square keeps the first
                        one (and its wash) clear of the field hanging below its rule. A sheet too
                        short for it (760 × 520 at 150%) leaves it out so a term shows, and that
                        first term's wash starts just under the field (TokensFieldClearance).
                        */
                        let clearance = TokensFieldClearance.shows(sheetHeight: sheet.height)
                        TokensFieldClearance()
                        ForEach(Array(terms.enumerated()), id: \.element) { index, term in
                            TokensDictionaryTermRow(term: term,
                                                    marked: term == justAdded,
                                                    alwaysShowsRemove: Self.proofRender && index == 0,
                                                    proofHover: Self.previewHover && index == 0,
                                                    washTop: index == 0 && !clearance ? Self.fieldOverhang : 0,
                                                    remove: { remove(term) })
                        }
                    }
                    Text("Hints for speech recognition, saved on this Mac.")
                        .font(TokensType.caption)
                        .foregroundStyle(TokensUI.secondary)
                        .tokensOnRule()
                }
            }
            .tokensPageColumn()
        }
        .tokensRuledScroll()
        .tokensRestingEdge()
    }

    // MARK: Rule 3

    /*
    One line when it fits: the intro on the left, "18 terms · Edit as text" on the right. In a
    narrow column (the 1.5x zoom) the intro wraps from rule 3 at the 28-point pitch and the count
    and link sit on the very next half-rule under it (TokensPitchStack), so the block ends on a
    whole square with no blank square before the add field. Text mode shows the intro alone; the
    panel's footer carries the count.
    */
    private func introRow(count: Int) -> some View {
        let intro = Text("Names and terms \(appName) should spell your way.")
            .font(TokensType.body)
            .foregroundStyle(TokensUI.secondary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                intro.lineLimit(1)
                if !editingText {
                    Spacer(minLength: 16)
                    introTrailing(count: count)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
            TokensPitchStack {
                intro
                    .tokensReadingPitch()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !editingText { introTrailing(count: count) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tokensOnRule()
        }
    }

    private func introTrailing(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            countLabel(count)
            Text("·").foregroundStyle(TokensUI.secondary).accessibilityHidden(true)
            Button("Edit as text") { edited = false; editingText = true }
                .buttonStyle(TokensLinkButtonStyle())
                .help("Type the whole list, one word per line")
                .accessibilityIdentifier("tokens.dictionary.edit-as-text")
        }
        .font(TokensType.caption)
        .fixedSize()
    }

    private func countLabel(_ count: Int) -> some View {
        Text("\(count) \(count == 1 ? "term" : "terms")")
            .font(TokensType.caption.monospacedDigit())
            .foregroundStyle(TokensUI.secondary)
            .accessibilityIdentifier("tokens.dictionary.count")
    }

    // MARK: Rule 4

    /*
    The add field: the kit's field surface, column width minus 76, so the quiet Add button ends
    on the column's right rule. The typed text's baseline sits on rule 4 and the button's label
    shares it. Tokens draws the placeholder itself, in secondary, because macOS draws a
    TextField's own prompt nearly as bright as typed text (as tokensFieldPlaceholder does). It is
    aligned by baseline rather than centred, so it sits exactly where typed text does: the
    centred overlay measured about half a point high (2026-10-13 Release render).
    */
    private var addRow: some View {
        let column = TokensColumn.layout(sheetWidth: sheet.width).width
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            TextField("", text: $entry)
                .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                    if entry.isEmpty {
                        Text("Add a word or name")
                            .font(TokensType.body)
                            .foregroundStyle(TokensUI.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($entryFocused)
                .onSubmit(submit)
                .tokensFieldSurface(focused: entryFocused)
                .focusEffectDisabled()
                .frame(width: max(0, column - 76))
                .help("Return adds it. Commas or new lines add several; repeats are ignored.")
                .accessibilityLabel("Add a word or name")
                .accessibilityIdentifier("tokens.dictionary.add")
            Spacer(minLength: 12)
            // 64 wide: with the 12-point gap it fills the 76 points the field leaves free.
            Button(action: submit) { Text("Add").frame(maxWidth: .infinity) }
                .buttonStyle(TokensQuietButtonStyle())
                .frame(width: 64)
                .disabled(trimmedEntry.isEmpty)
                .accessibilityIdentifier("tokens.dictionary.add-button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tokensOnRule()
    }

    /// Return or Add. An empty field adds nothing (and so writes nothing).
    private func submit() {
        guard !trimmedEntry.isEmpty else { return }
        add()
    }

    // MARK: Edit as text

    /*
    The inset panel (TokensCard, padding 0): the plain-text editor with 16 points either side and
    12 above, a hairline, then a 52-point footer. The panel is whole squares tall, from y = 196
    down to at least one square above the sheet's bottom: floor((H − 196 − 56) / 56) × 56, never
    under three squares. The editor scrolls inside it. Done keeps typed changes (it saves them)
    so the list never shows words that were not saved.
    */
    private func textPanel(count: Int) -> some View {
        let cell = TokensUI.paperCell
        let height = max(3 * cell, floor((sheet.height - 196 - cell) / cell) * cell)
        return TokensCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TokensPlainTextEditor(text: $text, label: "Personal dictionary words") { edited = true }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("tokens.dictionary.entry")
                TokensHairline()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    countLabel(count)
                    Spacer(minLength: 0)
                    if edited {
                        Button("Save") { save(); edited = false }
                            .buttonStyle(TokensQuietButtonStyle())
                            .keyboardShortcut("s", modifiers: .command)
                            .accessibilityIdentifier("tokens.dictionary.save")
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("Saved")
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        }
                        .font(TokensType.caption)
                        .foregroundStyle(TokensUI.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Saved")
                        .accessibilityIdentifier("tokens.dictionary.save")
                    }
                    Button("Done") {
                        if edited { save(); edited = false }
                        editingText = false
                    }
                    .buttonStyle(TokensLinkButtonStyle())
                    .font(TokensType.caption)
                    .help("Back to the list")
                    .accessibilityIdentifier("tokens.dictionary.done")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
            }
        }
        .frame(height: height)
    }
}

/*
Lines stacked at the reading pitch: each child's first baseline sits `pitch` (28) below the
previous child's last baseline, whatever their fonts. It reports the first and last baselines,
so .tokensOnRule() puts the whole block's first line on a rule and rounds it to whole squares.
*/
struct TokensPitchStack: Layout {
    var pitch: CGFloat = TokensUI.halfCell

    /// Each child's top, from its first and last baselines (measured from its own top).
    static func tops(firstBaselines: [CGFloat], lastBaselines: [CGFloat], pitch: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = []
        var previousLast: CGFloat?
        for (first, last) in zip(firstBaselines, lastBaselines) {
            let top = previousLast.map { $0 + pitch - first } ?? 0
            tops.append(top)
            previousLast = top + max(first, last)
        }
        return tops
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> ([ViewDimensions], [CGFloat]) {
        let dimensions = subviews.map { $0.dimensions(in: ProposedViewSize(width: width, height: nil)) }
        let tops = Self.tops(firstBaselines: dimensions.map { $0[.firstTextBaseline] },
                             lastBaselines: dimensions.map { $0[.lastTextBaseline] }, pitch: pitch)
        return (dimensions, tops)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (dimensions, tops) = measure(subviews, width: proposal.width)
        let width = dimensions.map(\.width).max() ?? 0
        let height = zip(tops, dimensions).map { $0 + $1.height }.max() ?? 0
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: offered ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, tops) = measure(subviews, width: bounds.width)
        for (view, top) in zip(subviews, tops) {
            view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top),
                       proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        let (dimensions, tops) = measure(subviews, width: bounds.width)
        guard let first = dimensions.first, let last = dimensions.last, let lastTop = tops.last else { return nil }
        if guide == .firstTextBaseline { return first[.firstTextBaseline] }
        if guide == .lastTextBaseline { return lastTop + last[.lastTextBaseline] }
        return nil
    }
}

/*
One term in its own grid square: body 15 ink, with a hover-only × (12 secondary, ink on hover)
at the column's right edge, the line centred in the square like History's rows
(TokensHistoryCellLayout). The wash fills exactly that square, on the same grid lines as the
column: ink 4% while the pointer is over it, ink 6% (static) for the word just added (build 77: the old wash ran 12 points past the column with the word pressed against its bottom).
*/
struct TokensDictionaryTermRow: View {
    let term: String
    let marked: Bool
    let alwaysShowsRemove: Bool
    /// Render-only hover fixture (--dictionary-preview-hover) for the first term.
    var proofHover = false
    /// Points at the top of the square the wash leaves clear: the first term's, when it sits
    /// right under the add field (TokensFieldClearance left out on a short sheet).
    var washTop: CGFloat = 0
    let remove: () -> Void
    @State private var hovering = false

    private var wash: Color {
        if marked { return TokensInk.primary.color.opacity(0.06) }
        return hovering || proofHover ? TokensInk.primary.color.opacity(0.04) : .clear
    }

    var body: some View {
        let showsRemove = hovering || alwaysShowsRemove
        TokensHistoryCellLayout {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(term)
                    .font(TokensType.body)
                    .foregroundStyle(TokensUI.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("tokens.dictionary.term.\(term)")
                Spacer(minLength: 0)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TokensLinkButtonStyle())
                .opacity(showsRemove ? 1 : 0)
                .allowsHitTesting(showsRemove)
                .help("Remove")
                .accessibilityLabel("Remove \(term)")
                .accessibilityIdentifier("tokens.dictionary.remove.\(term)")
                .tokensControlOnBaseline()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { Rectangle().fill(wash).padding(.top, washTop) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Under the bottom edge: no hidden ×, and no strip of the just-added wash (build 81).
        .tokensQuietUnderRestingEdge()
    }
}

