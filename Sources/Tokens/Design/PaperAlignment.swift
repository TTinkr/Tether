


import AppKit
import SwiftUI

private struct TokensPaperTextKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Opt in at a paper form; compact legacy views keep their existing control rhythm.
    var tokensPaperText: Bool {
        get { self[TokensPaperTextKey.self] }
        set { self[TokensPaperTextKey.self] = newValue }
    }
}

enum TokensPaperGeometry {
    /// Move forward to a rule, tolerating subpixel layout noise at an existing rule.
    static func leadingSpace(origin: CGFloat, pitch: CGFloat = TokensUI.paperCell) -> CGFloat {
        let remainder = origin.truncatingRemainder(dividingBy: pitch)
        let phase = remainder < 0 ? remainder + pitch : remainder
        return phase < 0.01 || pitch - phase < 0.01 ? 0 : pitch - phase
    }
}

extension View {
    /// Reserves one complete cell for phase correction before aligning a whole group to the
    /// continuous sheet. Measuring the unshifted wrapper avoids geometry feedback loops.
    func tokensPaperAligned() -> some View { modifier(TokensPaperAligned()) }

    /// Place native text by its actual SwiftUI baseline inside a full paper cell.
    func tokensPaperLine() -> some View { TokensPaperLineLayout { self } }
}

private struct TokensPaperAligned: ViewModifier {
    @State private var origin: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: TokensPaperGeometry.leadingSpace(origin: origin))
            .padding(.bottom, TokensUI.paperCell)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { origin = proxy.frame(in: .named(TokensUI.paperCoordinateSpace)).minY }
                        .onChange(of: proxy.frame(in: .named(TokensUI.paperCoordinateSpace)).minY) { _, value in
                            origin = value
                        }
                }
            }
    }
}

private struct TokensPaperLineLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let dimensions = view.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: dimensions.width, height: TokensUI.paperCell)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let offered = ProposedViewSize(width: bounds.width, height: nil)
        let dimensions = view.dimensions(in: offered)
        view.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - dimensions[.firstTextBaseline]), proposal: offered)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .firstTextBaseline || guide == .lastTextBaseline ? bounds.height : nil
    }
}

/// A session-only, proportionate sheet zoom. No production preferences are read or written.
enum TokensSheetZoom {
    static let minimum: CGFloat = 0.75
    static let maximum: CGFloat = 1.5
    static func changed(_ current: CGFloat, by steps: Int) -> CGFloat {
        let levels: [CGFloat] = [0.75, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5]
        if steps > 0 { return levels.first(where: { $0 > current + 0.001 }) ?? maximum }
        if steps < 0 { return levels.last(where: { $0 < current - 0.001 }) ?? minimum }
        return current
    }

    static func action(characters: String, modifiers: NSEvent.ModifierFlags) -> Int? {
        let flags = modifiers.intersection([.command, .control, .option])
        // ⌘ is the Mac zoom chord; Control +/− is also accepted, so Control is an alias.
        guard flags == .command || flags == .control else { return nil }
        switch characters {
        case "+", "=": return 1
        case "-": return -1
        case "0": return 0
        default: return nil
        }
    }
}

/// Local event monitor is scoped to this hosting window, including when a text editor is first
/// responder. Removing the view removes the monitor; other windows keep their own shortcuts.
struct TokensZoomShortcuts: NSViewRepresentable {
    var change: (Int) -> Void

    func makeNSView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.change = change
        return view
    }
    func updateNSView(_ view: ZoomView, context: Context) { view.change = change }
    static func dismantleNSView(_ view: ZoomView, coordinator: ()) { view.stop() }

    final class ZoomView: NSView {
        var change: ((Int) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window,
                      let action = TokensSheetZoom.action(characters: event.charactersIgnoringModifiers ?? "",
                                                         modifiers: event.modifierFlags) else { return event }
                self.change?(action)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stop() }
    }
}

/// Settings controls wrap onto whole paper rows when zoom leaves less horizontal space.
/// Each row aligns the controls' measured bottoms, matching their label baseline slots.
struct TokensPaperControlFlow: Layout {
    private func placements(width: CGFloat, subviews: Subviews) -> ([(CGPoint, CGSize)], CGSize) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var used: CGFloat = 0
        var result: [(CGPoint, CGSize)] = []
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(natural.width, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += TokensUI.paperCell
            }
            result.append((CGPoint(x: x, y: y + TokensUI.paperCell - size.height), size))
            used = max(used, x + size.width)
            x += size.width + TokensUI.module
        }
        return (result, CGSize(width: used, height: result.isEmpty ? 0 : y + TokensUI.paperCell))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placements(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).1
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = placements(width: bounds.width, subviews: subviews).0
        for (view, placement) in zip(subviews, rows) {
            view.place(at: CGPoint(x: bounds.minX + placement.0.x, y: bounds.minY + placement.0.y),
                       proposal: ProposedViewSize(placement.1))
        }
    }
}

/// Keep the viewport itself on whole paper cells. A fractional last viewport otherwise
/// clamps end-of-document scrolling between rules, even when every row has the right pitch.
struct TokensPaperScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { proxy in
            ScrollView { content }
                .scrollTargetBehavior(TokensGridScroll(step: TokensUI.paperCell))
                .frame(height: max(TokensUI.paperCell,
                                   floor(proxy.size.height / TokensUI.paperCell) * TokensUI.paperCell), alignment: .top)
        }
    }
}

//
// :)
//
//
/*
The V3 rhythm (DESIGN.md §4.2-§4.4). Sheet coordinates are logical points with the origin at the
sheet's top-left; rule n is y = 56n. A page builds its content as a spacing-0 VStack of
.tokensOnRule() rows and TokensRuleSpacers, so every single line's baseline lands on a rule and
every block occupies whole squares.
*/

private struct TokensSheetSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 824, height: 720)
}

private struct TokensSheetZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The working sheet's logical size (window minus rail, divided by zoom). TokensHome sets it.
    var tokensSheetSize: CGSize {
        get { self[TokensSheetSizeKey.self] }
        set { self[TokensSheetSizeKey.self] = newValue }
    }
    /// The working sheet's zoom; the grid draws 1 / zoom lines so they stay 1 screen point.
    var tokensSheetZoom: CGFloat {
        get { self[TokensSheetZoomKey.self] }
        set { self[TokensSheetZoomKey.self] = newValue }
    }
}

/*
The one page column. Both edges sit on vertical rules; the header uses the same column. The
leading edge always comes from the 616 page column, so a wider maxWidth (the set-up Access step's
712) keeps that edge and grows only to the right, stopping half a square short of the sheet's edge.
Centring the wider width instead put Access one square left of Terms and Done in the default
window (sheet 824: x 56 against x 112), so the step jumped sideways (DESIGN.md §4.4, §6.7).
*/
enum TokensColumn {
    static func layout(sheetWidth W: CGFloat, maxWidth: CGFloat = 616) -> (leading: CGFloat, width: CGFloat) {
        let cell = TokensUI.paperCell
        let fit = max(4 * cell, floor((W - 2 * cell) / cell) * cell)
        let page = min(maxWidth, TokensUI.pageMaxWidth, fit)
        var leading = max(cell, (((W - page) / 2) / cell).rounded() * cell)
        if leading + page > W - TokensUI.halfCell { leading = cell }
        let wide = min(maxWidth, fit)
        guard wide > page else { return (leading, page) }
        let room = floor((W - TokensUI.halfCell - leading) / cell) * cell
        return (leading, max(page, min(wide, room)))
    }

    /// Scroll content's bottom padding: one square plus the page slot's remainder, so the last
    /// scroll position also rests on a rule (the slot starts at rule 2).
    static func bottomPadding(sheetHeight: CGFloat) -> CGFloat {
        let cell = TokensUI.paperCell
        let slot = max(0, sheetHeight - 2 * cell)
        return cell + (slot - floor(slot / cell) * cell)
    }
}

/// Places a child so its first text baseline lands on the bottom edge of a cell; the height
/// rounds up to whole cells so its last baseline is no lower than the bottom.
struct TokensOnRuleLayout: Layout {
    var cell: CGFloat = TokensUI.paperCell
    /// Sub-point layout noise never pushes the first line onto the next rule.
    static let tolerance: CGFloat = 0.5
    /*
    A single-line row whose last-baseline guide sits a few points below its first (a label
    mixing sizes, such as "See all ›") stays one square. Real second lines are at least 14
    points lower (11-point text), so this never hides a wrapped line.
    */
    static let lastLineTolerance: CGFloat = 4

    /// Offset of the child's top and the layout's height for measured baselines.
    static func placement(firstBaseline: CGFloat, lastBaseline: CGFloat, cell: CGFloat) -> (offset: CGFloat, height: CGFloat) {
        let rule = max(1, ceil((firstBaseline - tolerance) / cell)) * cell
        let offset = rule - firstBaseline
        let last = offset + max(firstBaseline, lastBaseline)
        return (offset, max(cell, ceil((last - lastLineTolerance) / cell) * cell))
    }

    private func measure(_ view: LayoutSubview, width: CGFloat?) -> (ViewDimensions, (offset: CGFloat, height: CGFloat)) {
        let dimensions = view.dimensions(in: ProposedViewSize(width: width, height: nil))
        return (dimensions, Self.placement(firstBaseline: dimensions[.firstTextBaseline],
                                           lastBaseline: dimensions[.lastTextBaseline], cell: cell))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let (dimensions, placement) = measure(view, width: proposal.width)
        return CGSize(width: dimensions.width, height: placement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let (_, placement) = measure(view, width: bounds.width)
        view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + placement.offset),
                   proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard let view = subviews.first, guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let (dimensions, placement) = measure(view, width: bounds.width)
        return placement.offset + dimensions[guide == .firstTextBaseline ? .firstTextBaseline : .lastTextBaseline]
    }
}

/// A blank run of whole squares between rows or blocks.
struct TokensRuleSpacer: View {
    let cells: CGFloat
    init(cells: CGFloat = 1) { self.cells = cells }
    var body: some View {
        Color.clear.frame(height: cells * TokensUI.paperCell).accessibilityHidden(true)
    }
}

extension View {
    /// Puts this view's first text baseline on a rule and rounds its height up to whole squares.
    func tokensOnRule(cell: CGFloat = TokensUI.paperCell) -> some View { TokensOnRuleLayout(cell: cell) { self } }

    /// A non-text control (switch, chip, button, field) centres `capCentre` above the row's
    /// baseline inside HStack(alignment: .firstTextBaseline), level with the label's capitals.
    func tokensControlOnBaseline(_ capCentre: CGFloat = 5) -> some View {
        alignmentGuide(.firstTextBaseline) { $0.height / 2 + capCentre }
            .alignmentGuide(.lastTextBaseline) { $0.height / 2 + capCentre }
    }

    /// Wrapped reading text on the 28-point pitch: every line lands on a rule or half-way.
    func tokensReadingPitch(size: CGFloat = 15) -> some View { lineSpacing(TokensType.lineSpacing(size: size)) }

    /// Scrolling comes to rest on whole squares.
    func tokensRuledScroll() -> some View { scrollTargetBehavior(TokensGridScroll(step: TokensUI.paperCell)) }
}

