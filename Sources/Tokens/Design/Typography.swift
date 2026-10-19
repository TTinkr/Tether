


//
import AppKit
import CoreText
import SwiftUI


// View (extension) — modifiers: tokensLine, tokensFlagged, tokensFocus, tokensHoverUnderline


// MARK: Grid-aligned text

extension View {
    /*
    Read top to bottom: the view's bottom edge is moved up to its last text baseline, it is placed
    in a slot `slot` tall with its bottom at the slot's bottom, and then the slot declares its own
    first and last text baselines to be its bottom edge. Stacks and rows of these slots therefore
    line up on the baseline.
    */
    /// Puts one line of writing in a slot whose bottom edge is its baseline, so stacked slots write on grid lines.
    func tokensLine(_ slot: CGFloat = TokensUI.module) -> some View {
        alignmentGuide(.bottom) { $0[.lastTextBaseline] }
            .frame(height: slot, alignment: .bottom)
            .alignmentGuide(.firstTextBaseline) { $0.height }
            .alignmentGuide(.lastTextBaseline) { $0.height }
    }

    /// The red pencil's correction mark: an underline under writing that needs fixing.
    func tokensFlagged(_ on: Bool = true) -> some View {
        overlay {
            if on {
                TokensPencilEdge(edge: .bottom, seed: 3, offset: 3)
                    .stroke(TokensUI.red, style: TokensPencil.style(1.5))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Keyboard focus: a dashed pencil outline in place of the system ring.
    func tokensFocus(below: CGFloat = 0) -> some View { modifier(TokensFocusOutline(below: below)) }

    /// A graphite underline that fades in under the pointer.
    func tokensHoverUnderline(_ hovered: Bool, reduceMotion: Bool) -> some View {
        overlay {
            TokensPencilEdge(edge: .bottom, seed: 5, offset: 4)
                .stroke(TokensUI.rule, style: TokensPencil.style())
                .opacity(hovered ? 1 : 0)
                .animation(TokensUI.fade(reduceMotion), value: hovered)
                .allowsHitTesting(false)
        }
    }
}


// TokensFocusOutline — dashed pencil outline drawn while a control has keyboard focus


struct TokensFocusOutline: ViewModifier {
    /// How far the control's drawing runs below its layout slot.
    let below: CGFloat
    @FocusState private var focused: Bool

    /*
    focusEffectDisabled() switches off the system focus ring; while focused, a dashed rectangle is
    drawn instead, 4 points outside the control on every side plus `below` more at the bottom.
    It ignores clicks so it never blocks the control underneath.
    */
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                if focused {
                    Rectangle()
                        .stroke(TokensUI.rule, style: TokensPencil.style(dashed: true))
                        .padding(.init(top: -4, leading: -4, bottom: -4 - below, trailing: -4))
                        .allowsHitTesting(false)
                }
            }
    }
}

//
// :)
//
//
// TokensLabel — One line of system text sitting on a grid line


/// One line of system text sitting on a grid line. Too long for its space, it ends in an ellipsis.
struct TokensLabel: View {
    let text: String
    var size: CGFloat = 15
    var ink           = TokensInk.primary

    init(_ text: String, size: CGFloat = 15, ink: TokensInk = .primary) {
        self.text = text
        self.size = size
        self.ink  = ink
    }

    var body: some View { TokensParagraph(text, size: size, ink: ink, lineLimit: 1) }
}


// TokensIcon — An SF Symbol drawn light in graphite inside one square


/// An SF Symbol drawn light in graphite inside one square.
struct TokensIcon: View {
    let symbol: String
    var size: CGFloat = 13
    var ink           = TokensInk.secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(ink.color)
            .frame(width: TokensUI.module, height: TokensUI.module)
    }
}


// TokensTypesetter — breaks text into lines with Core Text, one line per grid row


/// Breaks text into lines with Core Text, so wrapped writing keeps one line per grid row.
enum TokensTypesetter {
    /*
    Core Text does the line breaking. Each pass asks the typesetter how many characters fit in
    `width` (at least 1, so the loop always moves forward). With a `limit` above 0, once the last
    allowed line is reached and text is still left, the remainder is built as one line and cut
    short with an ellipsis at the end. A limit of 0 means no limit.
    */
    static func lines(_ text: String, size: CGFloat, ink: TokensInk, width: CGFloat, limit: Int, pencil: Bool = false) -> [CTLine] {
        guard !text.isEmpty else { return [] }
        let attributes      = attributes(size: size, ink: ink, pencil: pencil)
        let string          = NSAttributedString(string: text, attributes: attributes)
        let typesetter      = CTTypesetterCreateWithAttributedString(string)
        let length          = string.length
        var lines: [CTLine] = []
        var start           = 0
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(width, 1))))
            if limit > 0, lines.count == limit - 1, start + count < length {
                let rest     = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                lines.append(CTLineCreateTruncatedLine(rest, Double(max(width, 1)), .end, ellipsis) ?? rest)
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    /*
    strokeWidth is negative on purpose: AppKit then strokes and fills the letters (a positive
    value would outline them). The extra weight is -2.6 for sizes up to 13, -1.7 for sizes up to
    16, and none above that.
    */
    /// One pencil has one line width, but a light face thins as it shrinks. Small writing gets a
    /// hairline of extra stroke so body text and captions carry the same graphite as the titles.
    static func attributes(size: CGFloat, ink: TokensInk, pencil: Bool = false) -> [NSAttributedString.Key: Any] {
        let extra = pencil ? (size <= 13 ? -2.6 : size <= 16 ? -1.7 : 0.0) : 0.0
        return [.font: TokensUI.nsFont(size, pencil: pencil), .foregroundColor: ink.nsColor,
                .strokeWidth: extra, .strokeColor: ink.nsColor]
    }

//
// :)
//
//
    // Width of the line's ink, not counting any spaces at its end.
    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }
}


// TokensParagraph — pencil writing drawn with Core Text, every baseline on a grid line


/// System text (or explicit live pencil) drawn with Core Text so every baseline lands exactly on a grid line.
/// Each line takes one grid row (two for title sizes); the view's bottom edge is the last baseline.
struct TokensParagraph: View {
    let text: String
    var size: CGFloat = 15
    var ink           = TokensInk.primary
    var lineLimit     = 0
    var pencil        = false
    @Environment(\.tokensPaperText) private var paperText

    init(_ text: String, size: CGFloat = 15, ink: TokensInk = .primary, lineLimit: Int = 0, pencil: Bool = false) {
        self.text      = text
        self.size      = size
        self.ink       = ink
        self.lineLimit = lineLimit
        self.pencil = pencil
    }

    /*
    Where it all happens: the layout (below) reserves the space and the Canvas draws the lines
    with Core Text. Core Text draws upward but a Canvas is flipped, so the text matrix is flipped.
    Line n has its baseline at `rise + (n + 1) * pitch`, which is the (n + 1)th grid row of the
    view once the layout has shifted the canvas up by `rise`.
    The Canvas is invisible to VoiceOver, so the element is given the text as its label.
    */
    var body: some View {
        TokensParagraphLayout(text: text, size: size, lineLimit: lineLimit, pencil: pencil, paperText: paperText) {
            Canvas { context, canvas in
                let lines = TokensTypesetter.lines(text, size: size, ink: ink,
                                                   width: canvas.width - TokensParagraphLayout.bleed, limit: lineLimit, pencil: pencil)
                let pitch = TokensParagraphLayout.pitch(size, paperText: paperText)
                context.withCGContext { cg in
                    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    for (index, line) in lines.enumerated() {
                        cg.textPosition = CGPoint(x: 0, y: TokensParagraphLayout.rise + CGFloat(index + 1) * pitch)
                        CTLineDraw(line, cg)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
    }
}


// TokensParagraphLayout — measures wrapped writing and gives the canvas room to draw


struct TokensParagraphLayout: Layout {
    /// Room past the layout bounds so descenders and the last glyph's edge are not cut.
    static let bleed: CGFloat = 8
    /// Room above the first row for tall letters.
    static let rise: CGFloat = 12
    /// Title sizes take two squares per line; everything else takes one.
    static func pitch(_ size: CGFloat, paperText: Bool = false) -> CGFloat {
        paperText ? TokensUI.paperCell : (size > 20 ? 2 * TokensUI.module : TokensUI.module)
    }
    let text: String
    let size: CGFloat
    let lineLimit: Int
    var pencil = false
    var paperText = false

    /*
    Wraps the text at the offered width (or does not wrap at all when the width is unbounded, and
    never narrower than one square). Returns the widest line's width and one pitch of height per
    line, at least one line tall. Ink colour does not change sizes, so .primary is used here.
    */
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width = CGFloat.greatestFiniteMagnitude
        if let proposed = proposal.width, proposed.isFinite { width = max(proposed, TokensUI.module) }
        let lines = TokensTypesetter.lines(text, size: size, ink: .primary, width: width, limit: lineLimit, pencil: pencil)
        let used  = lines.map(TokensTypesetter.width).max() ?? 0
        return CGSize(width: ceil(min(used, width)), height: CGFloat(max(lines.count, 1)) * Self.pitch(size, paperText: paperText))
    }

//
// :)
//
//
    /*
    The canvas is put `rise` above the top of the layout bounds and made `bleed` wider and
    `rise + bleed` taller, so tall letters and descenders drawn outside the bounds are not cut off.
    */
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.minY - Self.rise),
                              proposal: ProposedViewSize(width: bounds.width + Self.bleed,
                                                         height: bounds.height + Self.rise + Self.bleed))
    }
}

