


//
import SwiftUI
import TokensCore

/*
Today's figures, built exactly as Stats builds its "Today" range: dictations, words (Home's word
rule) and the stated talk seconds (nil when no talk today carried its timing). History is
newest-first, so only today's prefix is read; the all-time words come from refreshStats().
*/
struct TokensHomeToday: Equatable {
    var words = 0
    var dictations = 0
    var talkSeconds: Double?
    var wordsTotal = 0

    static func summary(history: [PromptHistoryEntry], wordsTotal: Int, now: Date = Date(),
                        calendar: Calendar = .current) -> TokensHomeToday {
        let start = calendar.startOfDay(for: now)
        let today = Array(history.prefix { $0.createdAt >= start })
        let totals = StatsSummary.build(TokensStatsSource.entries(today, events: [], now: now),
                                        range: .today, now: now, calendar: calendar).totals
        return TokensHomeToday(words: totals.words, dictations: totals.dictations,
                               talkSeconds: totals.talkSeconds, wordsTotal: wordsTotal)
    }

    /// The three figures as (number, label): talk time when stated, else words all time.
    var figures: [(value: String, label: String)] {
        let third: (value: String, label: String) = talkSeconds.map { (StatsSummary.talkTime($0), "talk time") }
            ?? (wordsTotal.formatted(), wordsTotal == 1 ? "word all time" : "words all time")
        return [(words.formatted(), words == 1 ? "word" : "words"),
                (dictations.formatted(), dictations == 1 ? "talk" : "talks"),
                third]
    }

    /// One spoken sentence for VoiceOver and the tooltip.
    var spoken: String {
        "Today: " + figures.map { "\($0.value) \($0.label)" }.joined(separator: ", ")
    }
}

/*
"Today   27 words · 3 talks · 4m 12s talk time  ›" on one rule, in the 15-point body size
of Recent's rows: "Today" and each label secondary, each number medium ink with tabular digits,
faint middle dots between. The whole line is one quiet button to Stats; the chevron turns ink on
hover. Hidden while nothing has been counted at all. Accessibility identifier tokens.home.stats.
*/
struct TokensHomeTodayLine: View {
    let today: TokensHomeToday
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        if today.wordsTotal > 0 {
            Button(action: open) {
                // A narrow column keeps the first two figures rather than wrapping or clipping.
                ViewThatFits(in: .horizontal) {
                    line(figures: 3)
                    line(figures: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Open Stats")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(today.spoken)
            .accessibilityHint("Opens Stats")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("tokens.home.stats")
        }
    }

    private func line(figures count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Today")
                .font(TokensType.body)
                .foregroundStyle(TokensUI.secondary)
                .padding(.trailing, 14)
            ForEach(Array(today.figures.prefix(count).enumerated()), id: \.offset) { index, figure in
                if index > 0 {
                    Text("·")
                        .font(TokensType.body)
                        .foregroundStyle(TokensUI.faint)
                        .padding(.horizontal, 10)
                }
                Text(figure.value)
                    .font(TokensType.labelLarge.monospacedDigit())
                    .foregroundStyle(TokensUI.ink)
                Text(" " + figure.label)
                    .font(TokensType.body)
                    .foregroundStyle(TokensUI.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? TokensUI.ink : TokensUI.faint)
                .padding(.leading, 10)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

