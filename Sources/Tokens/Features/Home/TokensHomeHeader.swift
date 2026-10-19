


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension TokensHome {


    // Frame — the header and small shared helpers


    /*
    The page header, from the bottom of the clear title-bar strip down to rule 2 (sheet y 112), in
    the same TokensColumn as the page below it. The title's baseline sits on rule 2; detail pages
    put a quiet Back link above it on rule 1, so every title starts at the column's leading edge.
    Home keeps the same strip with an empty title (its one heading is in the hero), because
    removing the header left Release builds with a blank page. No rule under it, no trailing
    accessory.
    */
    func header() -> some View {
        let home = detail == nil && section == .home
        let backTitle: String? = switch detail {
        case .shortcut: "Settings"
        case .prompt:   "History"
        default:        nil
        }
        return TokensPageHeader(title: home ? "" : title, home: home, backTitle: backTitle,
                                titleBarInset: titleBarInset, back: back)
    }

    // Title of the page: detail pages have their own names; otherwise the section's name.
    private var title: String {
        switch detail {
        case .prompt:   return "Talk"
        case .shortcut: return "Talk key"
        case .kit:      return "Kit"
        case .firstRun: return appName
        case nil:       return Self.sectionTitle(section)
        }
    }

    /// A section's page title is its name, Home included; nothing greets by time of day.
    static func sectionTitle(_ section: Section) -> String { section.rawValue }

    // Choosing a sidebar page always closes any detail page, and opening Dictionary reloads its text.
    func select(_ next: Section) {
        section = next
        detail  = nil
        if next == .dictionary { loadDictionary() }
    }

    private func back() { detail = nil }

    // Reads the personal dictionary from its own saved settings and shows it one term per line.
    func loadDictionary() {
        // Rendered UI checks use fictional vocabulary, never the user's saved dictionary.
        if model.isSyntheticRun {
            dictionaryText = ["Avery", "Beacon Labs", "Blue pencil", "Café", "Cobalt", "Delta Nine", "Green notebook", "Harbor", "Juniper", "Kestrel", "Larkspur", "Mosaic", "Nimbus", "Orchid", "Quill", "Tinkr", "Zephyr", "3D print"].joined(separator: "\n")
            dictionaryJustAdded = "Mosaic"
            dictionarySaved = false
            return
        }
        let defaults    = UserDefaults(suiteName: PersonalDictionary.suite)!
        dictionaryText  = PersonalDictionary.load(in: defaults).joined(separator: "\n")
        dictionarySaved = false
    }

    /*
    Count structurally identified speech; older entries retain the receipt fallback.
    Typed notes and generated questions never increase new-entry spoken counts.
    */
    func refreshStats() {
        let calendar = Calendar.current
        var today    = 0, total = 0
        for entry in model.promptHistory {
            let count = TokensHistoryText.words(entry)
            total += count
            if calendar.isDateInToday(entry.createdAt) { today += count }
        }
        wordsToday = today
        wordsTotal = total
    }

//
// :)
//
//
    /*
    The word depends on the key mode: "Press" when one press starts and another stops a talk
    (.tap), "Hold" when the talk lasts while the key is held.
    */
    /// "Press" or "Hold", in a slot of whole squares so the key drawn after it starts on a grid line.
    func verb(size: CGFloat, ink: TokensInk = .primary) -> some View {
        let word = model.rightOptionMode == .tap ? "Press" : "Hold"
        return TokensLabel(word, size: size, ink: ink)
            .frame(width: TokensUI.snap(TokensUI.textWidth(word, size: size) + 6), alignment: .leading)
    }


}

/*
The header strip itself. It reads the sheet size from the environment (set by TokensHome), so it
uses exactly the page column's leading and width at every window size and zoom.
*/
struct TokensPageHeader: View {
    let title: String
    let home: Bool
    let backTitle: String?
    let titleBarInset: CGFloat
    let back: () -> Void
    @Environment(\.tokensSheetSize) private var sheet

    var body: some View {
        let column = TokensColumn.layout(sheetWidth: sheet.width)
        let rule = TokensUI.paperCell
        Color.clear
            .frame(width: column.width, height: 2 * rule - titleBarInset)
            .overlay(alignment: .bottomLeading) {
                // Baseline on the strip's bottom edge: rule 2. Descenders hang below, like handwriting.
                Text(title)
                    .font(TokensType.title)
                    .foregroundStyle(TokensUI.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .alignmentGuide(.bottom) { $0[.firstTextBaseline] }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(home)
            }
            .overlay(alignment: .topLeading) {
                if let backTitle {
                    Button(action: back) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .medium))
                            Text(backTitle).font(TokensType.caption)
                        }
                    }
                    .buttonStyle(TokensLinkButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Back")
                    .accessibilityLabel("Back")
                    /*
                    Baseline on rule 1 (sheet y 56), measured from below the title-bar strip.
                    tokensOnRule places it itself: an alignment guide inside this conditional
                    overlay content is ignored, which left the link 15 points high.
                    */
                    .tokensOnRule(cell: max(1, rule - titleBarInset))
                }
            }
            .padding(.leading, column.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

