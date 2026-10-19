


//
import SwiftUI
import TokensCore

/*
Five squares tall. Square 1 holds the hover card. The plot is squares 2-4: its zero line is the
fourth rule and its three ticks are the rules above it, so the sheet's grid is the chart paper.
Day labels sit half a square under the zero line. Tick labels sit on their rules at the left.
*/
struct TokensStatsChart: View {
    let points: [StatsPoint]
    let unit: StatsBucketUnit
    let width: CGFloat
    /// 0 → 1 once: the plot is revealed left to right.
    let arrival: Double
    @Binding var hovered: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cell = TokensUI.paperCell
    static let height = 5 * cell
    static let plotTop = cell
    static let zero = 4 * cell
    static let ticks = 3
    /*
    The hover card's top inside square 1. The range control on the rule above hangs 8 points into
    this square, so the card starts 4 points under it (QA, build 77: at 4 the card overlapped the
    control) and, with 4-point padding, still ends above the plot's top rule.
    */
    static let cardTop: CGFloat = 12
    static let cardPadding: CGFloat = 4

    private var maxWords: Int { points.map(\.words).max() ?? 0 }
    private var step: Int { StatsBoard.tickStep(max: maxWords, ticks: Self.ticks) }
    private var tickLabels: [String] { (0...Self.ticks).map { ($0 * step).formatted() } }
    private var gutter: CGFloat {
        (tickLabels.map { TokensUI.textWidth($0, size: 13) }.max() ?? 0) + 12
    }
    private var left: CGFloat { gutter + 16 }
    private var right: CGFloat { width - 16 }

    private func x(_ index: Int) -> CGFloat {
        guard points.count > 1 else { return (left + right) / 2 }
        return left + CGFloat(index) * (right - left) / CGFloat(points.count - 1)
    }

    private func y(_ words: Int) -> CGFloat {
        let top = CGFloat(step * Self.ticks)
        return Self.zero - (Self.zero - Self.plotTop) * CGFloat(words) / max(1, top)
    }

    private var locations: [CGPoint] { points.indices.map { CGPoint(x: x($0), y: y(points[$0].words)) } }

    var body: some View {
        let spots = locations
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: Self.height)
            ticksLayer
            Rectangle().fill(TokensUI.divider)
                .frame(width: max(0, width - gutter), height: 1)
                .offset(x: gutter, y: Self.zero - 0.5)
            plot(spots)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, width * arrival), height: Self.height)
                }
            axisLabels(spots)
            if let hovered, points.indices.contains(hovered) {
                hoverLayer(index: hovered, at: spots[hovered])
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): set(nearest(location.x))
            case .ended: set(nil)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { scrub(-1); return .handled }
        .onKeyPress(.rightArrow) { scrub(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words over time")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            scrub(direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("tokens.stats.graph")
    }

    private func set(_ index: Int?) {
        guard index != hovered else { return }
        withAnimation(TokensUI.fade(reduceMotion)) { hovered = index }
    }

    private func nearest(_ locationX: CGFloat) -> Int? {
        guard !points.isEmpty, locationX >= gutter else { return nil }
        return points.indices.min { abs(x($0) - locationX) < abs(x($1) - locationX) }
    }

    /// Arrow keys move the card one point; starting from the newest point.
    private func scrub(_ delta: Int) {
        guard !points.isEmpty else { return }
        let start = hovered ?? (delta < 0 ? points.count : -1)
        set(min(points.count - 1, max(0, start + delta)))
    }

    private var accessibilityValue: String {
        if let hovered, points.indices.contains(hovered) { return TokensStatsChartCopy.card(points[hovered], unit: unit).joined(separator: ", ") }
        let total = points.reduce(0) { $0 + $1.words }
        return "\(total.formatted()) words over \(points.count) \(TokensStatsChartCopy.unitName(unit, count: points.count))"
    }

    // MARK: Layers

    /// Tick values on their rules, right-aligned in the gutter; the grid line is the tick.
    private var ticksLayer: some View {
        ForEach(Array(tickLabels.enumerated()), id: \.offset) { index, label in
            if maxWords > 0 || index == 0 {
                Text(label)
                    .font(TokensType.caption.monospacedDigit())
                    .foregroundStyle(TokensUI.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: gutter - 12, alignment: .trailing)
                    .statsBaseline(Self.zero - CGFloat(index) * Self.cell)
            }
        }
        .accessibilityHidden(true)
    }

    /// The pen: soft fill, the line, the dots and the point values.
    private func plot(_ spots: [CGPoint]) -> some View {
        let showDots = points.count <= 31
        let labelled = valueLabelIndices
        return ZStack(alignment: .topLeading) {
            StatsArea(points: spots, baseline: Self.zero)
                .fill(TokensUI.red.opacity(TokensUI.isDark ? 0.10 : 0.08))
            StatsLine(points: spots)
                .stroke(TokensUI.red, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if showDots {
                ForEach(points.indices, id: \.self) { index in
                    let on = index == hovered
                    Circle()
                        .fill(TokensUI.red)
                        .overlay { if on { Circle().strokeBorder(TokensUI.sheet, lineWidth: 2) } }
                        .frame(width: on ? 12 : 7, height: on ? 12 : 7)
                        .position(spots[index])
                }
            }
            ForEach(labelled, id: \.self) { index in
                let below = labelGoesBelow(index, spots: spots)
                Text(points[index].words.formatted())
                    .font(index == hovered ? TokensType.captionStrong.monospacedDigit() : TokensType.caption.monospacedDigit())
                    .foregroundStyle(index == hovered ? TokensUI.ink : TokensUI.ink2)
                    .lineLimit(1)
                    .fixedSize()
                    // A thin halo in the sheet's colour, so a line passing close to the digits
                    // goes behind them, never through them (build 78).
                    .shadow(color: below ? .clear : TokensUI.sheet, radius: 1)
                    .shadow(color: below ? .clear : TokensUI.sheet, radius: 1)
                    .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - spots[index].x }
                    .statsBaseline(below ? spots[index].y + 19 : spots[index].y - 11)
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// Every value when a week or less is shown; otherwise the highest, the newest and the hovered one.
    /*
    At a dip both neighbours are higher, so the two lines rise away from the point and a value
    centred above it sits between them, touching one (the "270" in the sample week). There the
    value goes under the point instead, where nothing is drawn, as long as it clears the zero line.
    */
    private func labelGoesBelow(_ index: Int, spots: [CGPoint]) -> Bool {
        guard index > 0, index < points.count - 1 else { return false }
        let dip = points[index - 1].words > points[index].words && points[index + 1].words > points[index].words
        return dip && spots[index].y + 24 <= Self.zero
    }

    private var valueLabelIndices: [Int] {
        guard maxWords > 0 else { return [] }
        if points.count <= 7 { return points.indices.filter { points[$0].talks > 0 } }
        var set = Set<Int>()
        if let top = points.indices.max(by: { points[$0].words < points[$1].words }) { set.insert(top) }
        if let last = points.indices.last, points[last].talks > 0 { set.insert(last) }
        if let hovered { set.insert(hovered) }
        return set.sorted()
    }

    /// Day labels half a square under the zero line, thinned from the newest so they never touch.
    private func axisLabels(_ spots: [CGPoint]) -> some View {
        let labels = points.map { TokensStatsLabels.axis($0, unit: unit, count: points.count) }
        let widest = (labels.map { TokensUI.textWidth($0, size: 13) }.max() ?? 0) + 14
        let spacing = points.count > 1 ? (right - left) / CGFloat(points.count - 1) : widest
        let every = max(1, Int((widest / max(1, spacing)).rounded(.up)))
        return ForEach(points.indices, id: \.self) { index in
            if (points.count - 1 - index) % every == 0 || index == hovered {
                Text(labels[index])
                    .font(index == hovered ? TokensType.captionStrong : TokensType.caption)
                    .foregroundStyle(index == hovered ? TokensUI.ink : TokensUI.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - spots[index].x }
                    .statsBaseline(Self.zero + TokensUI.halfCell)
            }
        }
        .accessibilityHidden(true)
    }

    /// A chalk guide from the card to the zero line, and the card in the top square.
    private func hoverLayer(index: Int, at spot: CGPoint) -> some View {
        let lines = TokensStatsChartCopy.card(points[index], unit: unit)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: spot.x, y: 50))
                path.addLine(to: CGPoint(x: spot.x, y: Self.zero))
            }
            .stroke(TokensUI.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            VStack(alignment: .leading, spacing: 2) {
                (Text(lines[0]).foregroundStyle(TokensUI.ink)
                    + Text(" · ").foregroundStyle(TokensUI.secondary)
                    + Text(lines[1]).fontWeight(.medium).foregroundStyle(TokensUI.ink))
                Text(lines.dropFirst(2).joined(separator: " · ")).foregroundStyle(TokensUI.secondary)
            }
            .font(TokensType.caption.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, Self.cardPadding)
            .background(TokensUI.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(TokensUI.controlEdge, lineWidth: 1) }
            .alignmentGuide(.leading) { d in
                -min(max(gutter, spot.x - d.width / 2), width - d.width)
            }
            .alignmentGuide(.top) { _ in -Self.cardTop }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}

/// The hover card's words: "Thu 9 Oct", "1,240 words", "9 talks", "212 wpm" (speed only when stated).
enum TokensStatsChartCopy {
    static func card(_ point: StatsPoint, unit: StatsBucketUnit) -> [String] {
        var lines = [TokensStatsLabels.long(point, unit: unit),
                     "\(point.words.formatted()) \(point.words == 1 ? "word" : "words")",
                     "\(point.talks.formatted()) \(point.talks == 1 ? "talk" : "talks")"]
        if let wpm = point.medianWPM { lines.append("\(wpm.formatted()) wpm") }
        return lines
    }

    static func unitName(_ unit: StatsBucketUnit, count: Int) -> String {
        switch unit {
        case .hour: count == 1 ? "hour" : "hours"
        case .day: count == 1 ? "day" : "days"
        case .week: count == 1 ? "week" : "weeks"
        }
    }
}

struct StatsLine: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

struct StatsArea: Shape {
    var points: [CGPoint]
    var baseline: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last, points.count > 1 else { return path }
        path.move(to: CGPoint(x: first.x, y: baseline))
        for point in points { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.closeSubpath()
        return path
    }
}

//
// :)
//
//
/// Slice and dot colours: the lead app in the pen's coral, then chalk tints; Other is faintest.
enum TokensStatsSlices {
    static func color(_ index: Int, _ row: StatsAppRow) -> Color {
        if row.isOther { return TokensUI.ink.opacity(TokensUI.isDark ? 0.16 : 0.14) }
        if index == 0 { return TokensUI.red }
        let tints: [Double] = [0.70, 0.48, 0.34, 0.24]
        return TokensUI.ink.opacity(tints[min(tints.count - 1, index - 1)])
    }
}

/*
The donut: one ring, slices by words, the total in the middle. Hovering a slice raises it,
fades the rest and shows its words and share in the middle; clicking filters the graph.
*/
struct TokensStatsDonut: View {
    let rows: [StatsAppRow]
    let total: Int
    let size: CGFloat
    let arrival: Double
    @Binding var hovered: String?
    let selected: String?
    let toggle: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ring: CGFloat { (size * 0.2).rounded() }

    private var spans: [(start: Double, end: Double)] {
        let sum = Double(max(1, rows.reduce(0) { $0 + $1.words }))
        var start = 0.0
        return rows.map { row in
            defer { start += Double(row.words) / sum }
            return (start, start + Double(row.words) / sum)
        }
    }

    var body: some View {
        let spans = self.spans
        let focus = hovered ?? selected
        ZStack {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let span = spans[index]
                let gap = rows.count > 1 ? 0.004 : 0
                let lifted = row.id == focus
                Circle()
                    .trim(from: span.start * arrival + gap, to: max(span.start * arrival + gap, span.end * arrival - gap))
                    .stroke(TokensStatsSlices.color(index, row), style: StrokeStyle(lineWidth: lifted ? ring + 8 : ring, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    // The resting ring sits 4 inside the frame; a lifted slice grows 4 out and 4 in.
                    .padding(lifted ? (ring + 8) / 2 : ring / 2 + 4)
                    .opacity(focus == nil || lifted ? 1 : 0.45)
            }
            centre(focus)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onContinuousHover { phase in
            let next: String?
            switch phase {
            case .active(let location): next = slice(at: location)
            case .ended: next = nil
            }
            guard next != hovered else { return }
            withAnimation(TokensUI.fade(reduceMotion)) { hovered = next }
        }
        .onTapGesture { if let hovered { toggle(hovered) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words by app")
        .accessibilityValue(rows.map { "\($0.name) \($0.words.formatted()) words" }.joined(separator: ", "))
        .accessibilityIdentifier("tokens.stats.donut")
    }

    @ViewBuilder
    private func centre(_ focus: String?) -> some View {
        let row = focus.flatMap { id in rows.first { $0.id == id } }
        let value = (row?.words ?? total).formatted()
        let caption: String = row.map { row in
            let share = total > 0 ? Int((Double(row.words) * 100 / Double(total)).rounded()) : 0
            return "\(row.name) · \(share)%"
        } ?? (total == 1 ? "word" : "words")
        VStack(spacing: 2) {
            Text(value).font(.system(size: size >= 140 ? 20 : 17, weight: .medium).monospacedDigit())
                .foregroundStyle(TokensUI.ink)
            Text(caption).font(TokensType.caption).foregroundStyle(TokensUI.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: size - 2 * ring - 12)
    }

    private func slice(at location: CGPoint) -> String? {
        let dx = location.x - size / 2, dy = location.y - size / 2
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= size / 2 - ring - 10, radius <= size / 2 + 2 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let fraction = Double(angle / (2 * .pi))
        return spans.firstIndex { fraction >= $0.start && fraction < $0.end }.map { rows[$0].id }
    }
}

/// App · Words · Talks · WPM, one row per rule; hovering a row lights its slice, clicking filters.
struct TokensStatsAppTable: View {
    let rows: [StatsAppRow]
    @Binding var hovered: String?
    let selected: String?
    let toggle: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let numberWidth: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(name: Text("App"), words: "Words", talks: "Talks", wpm: "WPM", header: true)
                .tokensOnRule()
                .accessibilityHidden(true)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { toggle(row.id) } label: {
                    line(name: Text(row.name), words: row.words.formatted(), talks: row.talks.formatted(),
                         wpm: row.medianWPM.map { $0.formatted() } ?? TokensStatsCopy.none, header: false,
                         dot: TokensStatsSlices.color(index, row), strong: row.id == selected)
                        .tokensOnRule()
                        .background(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(TokensUI.hover.opacity(row.id == hovered || row.id == selected ? 1 : 0))
                                .frame(height: 34)
                                .padding(.horizontal, -10)
                                .offset(y: 12)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { on in
                    let next = on ? row.id : (hovered == row.id ? nil : hovered)
                    guard next != hovered else { return }
                    withAnimation(TokensUI.fade(reduceMotion)) { hovered = next }
                }
                .help(row.isOther ? "Apps after the top five, and talks with no app saved." : "Click to show only \(row.name) on the graph.")
                .accessibilityLabel("\(row.name), \(row.words.formatted()) words, \(row.talks.formatted()) talks"
                    + (row.medianWPM.map { ", \($0) words per minute" } ?? ""))
                .accessibilityAddTraits(row.id == selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tokens.stats.app.\(row.id)")
            }
        }
    }

    private func line(name: Text, words: String, talks: String, wpm: String, header: Bool,
                      dot: Color? = nil, strong: Bool = false) -> some View {
        let font = header ? TokensType.caption : TokensType.body
        let tone = header ? TokensUI.secondary : TokensUI.ink
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The slice's dot; the header keeps the same indent so the names line up.
            Circle().fill(dot ?? .clear).frame(width: 8, height: 8)
                .tokensControlOnBaseline()
                .padding(.trailing, 10)
            name.font(strong ? TokensType.labelLarge : font).foregroundStyle(tone)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            Group {
                Text(words).frame(width: Self.numberWidth, alignment: .trailing)
                Text(talks).frame(width: Self.numberWidth - 8, alignment: .trailing)
                Text(wpm).frame(width: Self.numberWidth - 8, alignment: .trailing)
            }
            .font(font.monospacedDigit())
            .foregroundStyle(header ? TokensUI.secondary : TokensUI.ink2)
            .lineLimit(1)
        }
    }
}

