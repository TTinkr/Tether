


//
import SwiftUI
import TokensCore

struct VoiceLedgerView: View {
    let ledger: VoiceLedger

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                header
                totals
                if ledger.total.talks == 0 {
                    TokensCard {
                        Text("No talks in the last 14 days yet.")
                            .font(TokensType.body).foregroundStyle(TokensUI.secondary)
                    }
                } else {
                    TokensCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                TokensEyebrow("Median words per minute, by day")
                                Spacer()
                                Text("dashed line · \(VoiceLedger.fastWPM) wpm")
                                    .font(TokensType.micro).foregroundStyle(TokensUI.secondary)
                            }
                            VoiceLedgerSparkline(values: ledger.days.map { $0.medianWPM.map(Double.init) },
                                                 threshold: Double(VoiceLedger.fastWPM))
                                .frame(height: 72)
                            HStack {
                                Text(ledger.days.first?.label ?? "")
                                Spacer()
                                Text("Today")
                            }
                            .font(TokensType.micro).foregroundStyle(TokensUI.secondary)
                        }
                    }
                    TokensCard { VoiceLedgerTable(title: "By app", firstColumn: "App", rows: ledger.apps + [ledger.total]) }
                    TokensCard {
                        VoiceLedgerTable(title: "By day", firstColumn: "Day",
                                         rows: ledger.days.reversed().filter { $0.talks > 0 })
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(TokensUI.sheet)
        .accessibilityIdentifier("tokens.voiceLedger")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your voice, last 14 days")
                .font(TokensType.title).foregroundStyle(TokensUI.ink)
            Text("Numbers only, never words · nothing saved")
                .font(TokensType.caption).foregroundStyle(TokensUI.secondary)
        }
    }

    private var totals: some View {
        HStack(spacing: 12) {
            tile(VoiceLedgerFormat.count(ledger.total.talks), "talks")
            tile(VoiceLedgerFormat.count(ledger.total.words), "words")
            tile(VoiceLedgerFormat.optional(ledger.total.medianWPM), "median wpm")
            tile(VoiceLedgerFormat.percent(ledger.total.fastShare), "> \(VoiceLedger.fastWPM) wpm")
            tile("\(ledger.streak)", "day streak")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        TokensCard(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(TokensType.headline.monospacedDigit()).foregroundStyle(TokensUI.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(TokensType.caption).foregroundStyle(TokensUI.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

//
// :)
//
//
/// Seven columns; numbers right-aligned in tabular digits; the "All apps" row reads medium.
struct VoiceLedgerTable: View {
    let title: String
    let firstColumn: String
    let rows: [VoiceLedgerRow]

    private static let headings = ["Talks", "Words", "Median wpm", ">220", "Pauses /100w", "Longest pause"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TokensEyebrow(title)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    Text(firstColumn).frame(minWidth: 110, alignment: .leading).gridColumnAlignment(.leading)
                    ForEach(Self.headings, id: \.self) { Text($0) }
                }
                .font(TokensType.micro).foregroundStyle(TokensUI.secondary)
                TokensHairline().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label).font(row.id == "total" ? TokensType.captionStrong : TokensType.caption)
                            .foregroundStyle(TokensUI.ink)
                        cell(VoiceLedgerFormat.count(row.talks))
                        cell(VoiceLedgerFormat.count(row.words))
                        cell(VoiceLedgerFormat.optional(row.medianWPM))
                        cell(VoiceLedgerFormat.percent(row.fastShare))
                        cell(row.pausesPer100Words.map { String(format: "%.1f", $0) } ?? VoiceLedgerFormat.none)
                        cell(row.longestPause.map { String(format: "%.1fs", $0) } ?? VoiceLedgerFormat.none)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text).font(TokensType.stat)
            .foregroundStyle(text == VoiceLedgerFormat.none ? TokensUI.faint : TokensUI.ink2)
    }
}

/*
Daily medians as a thin ink line with dots; days with no timed talk leave a gap rather than
a fake zero. The threshold is a dashed hairline. A Shape gets its rect from layout, so no
GeometryReader is needed inside the ScrollView.
*/
struct VoiceLedgerSparkline: View {
    let values: [Double?]
    let threshold: Double

    var body: some View {
        let present = values.compactMap { $0 }
        let top = max((present.max() ?? threshold), threshold) * 1.08
        let bottom = min((present.min() ?? threshold), threshold) * 0.85
        ZStack {
            SparkPath(values: [threshold, threshold].map(Optional.some), low: bottom, high: top, dots: false)
                .stroke(TokensUI.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            SparkPath(values: values, low: bottom, high: top, dots: false)
                .stroke(TokensUI.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            SparkPath(values: values, low: bottom, high: top, dots: true).fill(TokensUI.ink)
        }
        .accessibilityLabel("Median words per minute over 14 days")
    }
}

struct SparkPath: Shape {
    let values: [Double?]
    let low: Double
    let high: Double
    let dots: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, high > low else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        var drawing = false
        for (index, value) in values.enumerated() {
            guard let value else { drawing = false; continue }
            let point = CGPoint(x: rect.minX + CGFloat(index) * step,
                                y: rect.maxY - CGFloat((value - low) / (high - low)) * rect.height)
            if dots {
                path.addEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
            } else if drawing {
                path.addLine(to: point)
            } else {
                path.move(to: point); drawing = true
            }
        }
        return path
    }
}

enum VoiceLedgerFormat {
    static let none = "–"
    static func count(_ value: Int) -> String { value.formatted() }
    static func optional(_ value: Int?) -> String { value.map { $0.formatted() } ?? none }
    static func percent(_ share: Double?) -> String { share.map { "\(Int(($0 * 100).rounded()))%" } ?? none }
}

