
import SwiftUI

/// Words grouped under their first letter, A–Z first, then "#" for anything else.
enum TokensDictionaryIndex {
    struct Group { let letter: String; let words: [String] }

    static func groups(_ terms: [String]) -> [Group] {
        var buckets: [String: [String]] = [:]
        for term in terms { buckets[letter(for: term), default: []].append(term) }
        let order = buckets.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return order.map { key in
            Group(letter: key, words: buckets[key]!.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            })
        }
    }

    static func letter(for term: String) -> String {
        guard let first = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased().first, ("A"..."Z").contains(String(first)) else { return "#" }
        return String(first)
    }
}

/// Wraps words left to right; each row is one paper cell so baselines land on the rules.
struct TokensDictionaryFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: CGFloat(max(rows.count, 1)) * TokensUI.paperCell)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (row, line) in arrange(width: bounds.width, subviews: subviews).enumerated() {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(row) * TokensUI.paperCell),
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: TokensUI.paperCell))
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat)] = []
        var current: [Int] = [], used: CGFloat = 0
        for index in subviews.indices {
            let w = min(subviews[index].sizeThatFits(.unspecified).width, max(1, width))
            let needed = current.isEmpty ? w : used + spacing + w
            if needed > width, !current.isEmpty {
                rows.append((current, used)); current = [index]; used = w
            } else {
                current.append(index); used = needed
            }
        }
        if !current.isEmpty { rows.append((current, used)) }
        return rows
    }
}

/// One saved word on the rule. Hover: red pen strike and a small cross; click the cross to remove.
struct TokensDictionaryWord: View {
    let word: String
    let last: Bool
    var circled = false
    let remove: () -> Void
    @State private var hovered = false
    @FocusState private var removeFocused: Bool

    var body: some View {
        Text(word + (last ? "" : ","))
            .font(TokensUI.font(16))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(word)
            .foregroundStyle(hovered ? TokensUI.red : TokensUI.ink)
            .overlay(alignment: .center) {
                if hovered {
                    TokensPencilEdge(edge: .bottom, seed: TokensPencil.seed(word), overshoot: 3)
                        .stroke(TokensUI.red, style: TokensPencil.style(1.2))
                        .frame(height: 1).offset(y: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if circled {
                    TokensPenCircle(seed: TokensPencil.seed(word))
                        .stroke(TokensUI.red, style: TokensPencil.style(1.3))
                        .padding(.horizontal, -5).padding(.vertical, -6)
                        .allowsHitTesting(false)
                }
            }
            // The cross floats past the word's end so hidden crosses never widen the gaps.
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Text("×").font(TokensUI.font(13)).foregroundStyle(TokensUI.red)
                }
                .buttonStyle(.plain)
                .offset(x: 11, y: -9)
                .fixedSize()
                .focused($removeFocused)
                .opacity(hovered || removeFocused ? 1 : 0)
                .accessibilityLabel("Remove \(word)")
            }
        .tokensPaperLine()
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(word)
        .accessibilityAction(named: "Remove") { remove() }
    }
}

/// A quick red pen loop around a word: one stroke that overshoots where it started.
struct TokensPenCircle: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let start = -CGFloat.pi * (0.62 + 0.1 * TokensPencil.unit(seed, 1))
        let sweep = CGFloat.pi * 2 + 0.45
        let steps = 48
        for step in 0...steps {
            let t = start + sweep * CGFloat(step) / CGFloat(steps)
            // Slight wobble and a loop that ends a little outside where it began.
            let wobble = 1 + 0.03 * sin(t * 3 + TokensPencil.unit(seed, 2) * 6)
            let drift = 1 + 0.06 * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: center.x + rx * wobble * drift * cos(t),
                                y: center.y + ry * wobble * sin(t))
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}
