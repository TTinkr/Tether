


//
import AppKit

@MainActor final class ThinkingPadSpacing {
    typealias Repair = @MainActor (String) async -> String?
    private var task: Task<Void, Never>?
    private var generation    = 0
    private(set) var applying = false
    var delay: UInt64         = 900_000_000

    deinit { task?.cancel() }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func changed(_ view: NSTextView, repair: Repair?, publish: @escaping (String) -> Void) {
        guard !applying else { return }
        cancel()
        guard let repair, view.isEditable, !view.hasMarkedText(),
              view.undoManager?.isUndoing != true, view.undoManager?.isRedoing != true else { return }
        let raw = view.string, selection = view.selectedRange(), token = generation
        guard !raw.isEmpty else { return }
        // Ask only about the current line. A long notebook never becomes a model prompt.
        let line  = (raw as NSString).lineRange(for: selection)
        let input = (raw as NSString).substring(with: line)
        guard !input.isEmpty, input.utf8.count <= 800 else { return }
        task = Task { @MainActor [weak self, weak view] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.delay) } catch { return }
            guard !Task.isCancelled, let view, self.matches(view, raw, selection, token) else { return }
            guard let repaired = await repair(input), !Task.isCancelled,
                  self.matches(view, raw, selection, token),
                  TypedSpacing.accepts(raw: input, proposal: repaired) else { return }
            let proposal  = (raw as NSString).replacingCharacters(in: line, with: repaired)
            self.applying = true
            defer { self.applying = false }
            let target = TypedSpacing.selection(selection, from: raw, to: proposal)
            // Native insertion participates in TextKit's undo stack; assigning .string would not.
            view.breakUndoCoalescing()
            view.insertText(proposal, replacementRange: NSRange(location: 0, length: (raw as NSString).length))
            view.breakUndoCoalescing()
            view.undoManager?.setActionName("Automatic spacing")
            view.setSelectedRange(target)
            publish(view.string)
        }
    }

    private func matches(_ view: NSTextView, _ raw: String, _ selection: NSRange, _ token: Int) -> Bool {
        generation == token && view.isEditable && !view.hasMarkedText()
            && Array(view.string.utf8) == Array(raw.utf8) && view.selectedRange() == selection
    }
}

