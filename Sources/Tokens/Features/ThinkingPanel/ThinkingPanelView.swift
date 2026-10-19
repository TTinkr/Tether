


//
/*
ThinkingPanelView.swift
Owns: two quiet sheets of graph paper over native background material.
Never: generate text, decorate the transcript, or focus another application.
See: ThinkingPanelGridEditor.swift, ThinkingPanelState.swift.
*/


import AppKit
import SwiftUI

struct ThinkingPanelView: View {
    @ObservedObject var state: ThinkingPanelState
    var collapse: () -> Void
    var expand: () -> Void
    var dismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let tiny = geometry.size.width <= 180 || geometry.size.height <= 110
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                    else { ThinkingDesktopGlass() }
                }
                if tiny {
                    GraphPaperPage()
                    Button(action: expand) {
                        Text("π").font(.system(size: 25, design: .serif))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand notes and questions")
                } else {
                    pages
                }
                ThinkingResizeGrip()
                    .frame(width: 28, height: 28)
                    .padding(3)
                    .accessibilityLabel("Resize notes and questions")
                    .help("Drag to resize. Shrink to a tiny π.")
            }
            .foregroundStyle(.primary.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contextMenu {
                Button(tiny ? "Expand" : "Make tiny", action: tiny ? expand : collapse)
                Button("Hide", action: dismiss)
                Divider()
                Text("Questions are generated locally")
            }
            .transaction { $0.animation = nil }
        }
        .ignoresSafeArea()
    }

    private var pages: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Each native document draws its own paper in text coordinates: grid and ink scroll together.
                ThinkingPanelGridEditor(text: $state.notes, editable: true, label: "Your notes",
                    spacing: state.repairSpacing, spacingEpoch: state.spacingEpoch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(ThinkingGridPaper.side / 2)
                    .accessibilityHint("Typed notes are delivered separately after the transcript.")
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.5)
                    .accessibilityHidden(true)
                ThinkingPanelGridEditor(text: .constant(state.question), editable: false,
                                        label: "Questions, generated locally")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(ThinkingGridPaper.side / 2)
            }
            HStack {
                Button(action: collapse) {
                    Text("π").font(.system(size: 17, design: .serif))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Make notes and questions tiny")
                .help("Make tiny. Drag the paper margin to move.")
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 30)
        }
    }
}

//
// :)
//
//
private struct GraphPaperPage: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: 0.0, through: size.width, by: ThinkingGridPaper.side) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, through: size.height, by: ThinkingGridPaper.side) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.16)), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ThinkingDesktopGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view          = NSVisualEffectView()
        view.material     = .popover
        view.blendingMode = .behindWindow
        view.state        = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

