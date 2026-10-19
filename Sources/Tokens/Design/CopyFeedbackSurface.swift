


import SwiftUI

/// Feedback observes a successful clipboard write; it never performs one.
private struct CopyFeedbackSurface: ViewModifier {
    let active: Bool
    let revision: UUID
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        let reduced = reduceMotionOverride ?? reduceMotion
        /*
        A neutral ink wash, matching a sheet row's hover wash (radius 6, 12 points past the text
        on each side). DESIGN.md §2.4 never allows red in a wash behind text (2026-10-13).
        */
        return content.overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(TokensInk.primary.color.opacity((reduced ? active : pulse) ? 0.06 : 0))
                .padding(.horizontal, -12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task(id: revision) {
            pulse = false
            guard active, !reduced else { return }
            /*
            The task identity restarts feedback on a second successful copy, even of the
            same entry. SwiftUI cancels the previous task on replacement/removal; its old
            fade must never erase a newer pulse. No clipboard data enters this modifier.
            */
            withAnimation(.easeOut(duration: 0.08)) { pulse = true }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { pulse = false }
        }
        .onChange(of: active) { _, value in if !value { pulse = false } }
    }
}

extension View {
    func tokensCopyFeedback(active: Bool, revision: UUID, reduceMotionOverride: Bool? = nil) -> some View {
        modifier(CopyFeedbackSurface(active: active, revision: revision, reduceMotionOverride: reduceMotionOverride))
    }
}

