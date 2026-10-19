


//
import AppKit
import CoreText
import SwiftUI


// TokensSidebarItem — one sidebar row: icon, label, red dot when this page is selected


struct TokensSidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var labelCapHeight: CGFloat { NSFont.systemFont(ofSize: 15).capHeight }

    /*
    A sidebar row. The red dot sits in the left margin rail, the label gets a hover underline only
    when the row is not already selected, and VoiceOver hears the title plus a "selected" trait.
    */
    var body: some View {
        Button(action: action) {
            HStack(alignment: .bottom, spacing: 0) {
                TokensIcon(symbol: symbol, size: 14, ink: selected ? .red : .secondary)
                    // Text is drawn above the cell's bottom baseline, not at its centre.
                    // Align the symbol centre with the label's capital-letter centre; keep
                    // the original grid slot and click target unchanged.
                    .offset(y: (TokensUI.module - labelCapHeight) / 2)
                    .frame(width: 2 * TokensUI.module)
                TokensLabel(title, ink: selected ? .red : .secondary)
                    .tokensHoverUnderline(hovered && !selected, reduceMotion: reduceMotion)
                Spacer(minLength: 0)
            }
            // Each row is two squares; the label is written on the line between them.
            .padding(.bottom, TokensUI.module)
            .contentShape(Rectangle())
        }
        .buttonStyle(TokensBareButtonStyle())
        .tokensFocus()
        .onHover { hovered = $0 }
        .overlay(alignment: .topLeading) {
            // Center the selected mark on the same capital-letter center as the icon.
            Circle().fill(TokensUI.red).frame(width: 6, height: 6)
                .offset(x: -2.5, y: TokensUI.module - labelCapHeight / 2 - 3)
                .opacity(selected ? 1 : 0)
                .animation(TokensUI.fade(reduceMotion), value: selected)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}


// TokensSectionHeader — a label written on a grid line, with a ruled line running on after it


/// A section label written on a grid line, with a ruled line carrying on along it.
struct TokensSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    /*
    Bottom-aligned row: the label, then a clear bar that stretches to fill the width and is one
    square tall, with a ruled pencil line drawn along its bottom edge, then any trailing content.
    The line's wobble is seeded from the title, so each header always draws the same line.
    */
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TokensLabel(title, size: 13, ink: .secondary)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: TokensUI.module)
                .overlay {
                    TokensPencilEdge(edge: .bottom, seed: TokensPencil.seed(title))
                        .stroke(TokensUI.rule, style: TokensPencil.style())
                }
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

//
// :)
//
//
// TokensGroup — A titled group of rows


/// A titled group of rows. The paper's own lines separate the rows; only the heading is ruled.
struct TokensGroup<Content: View>: View {
    @Environment(\.tokensPaperText) private var paperText
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: paperText ? TokensUI.paperCell : TokensUI.module) {
            TokensSectionHeader(title: title) { EmptyView() }
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}


// TokensRow — one settings row: a label on the left, a control on the right, optional caption


struct TokensRow<Trailing: View>: View {
    @Environment(\.tokensPaperText) private var paperText
    let title: String
    var caption = ""
    /// Marks the caption with the red pencil: something here needs fixing.
    var flagged = false
    @ViewBuilder let trailing: Trailing

    /*
    Row layout: the title and the trailing control share one line (title pushed left by the
    Spacer); the optional caption is written on the line below, red-flagged when `flagged` is set.
    */
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if paperText {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: TokensUI.module) {
                        TokensLabel(title).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        HStack(alignment: .bottom, spacing: TokensUI.module) { trailing }
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        TokensParagraph(title)
                        TokensPaperControlFlow { trailing }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: TokensUI.module) {
                    TokensLabel(title)
                    Spacer(minLength: 0)
                    trailing
                }
            }
            if !caption.isEmpty {
                TokensParagraph(caption, size: 13, ink: flagged ? .primary : .secondary)
                    .tokensFlagged(flagged)
            }
        }
    }
}


// TokensDivider — The gap between two rows: one empty grid line


/// The gap between two rows: one empty grid line.
struct TokensDivider: View {
    @Environment(\.tokensPaperText) private var paperText
    var body: some View { Color.clear.frame(height: paperText ? TokensUI.paperCell : TokensUI.module).accessibilityHidden(true) }
}


// TokensGridScroll — scrolling settles on whole squares, so writing rests on the lines


/// Scrolling settles on whole squares, so writing comes to rest back on the lines.
struct TokensGridScroll: ScrollTargetBehavior {
    var step: CGFloat = TokensUI.module
    /*
    Where a scroll or flick is about to stop, snap the top edge to the nearest whole module.
    Without this, a scroll could stop with the text sitting between grid lines.
    */
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.y = (target.rect.origin.y / step).rounded() * step
    }
}

