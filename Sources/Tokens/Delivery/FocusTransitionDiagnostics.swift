import AppKit
import ApplicationServices

/// Structural evidence only. Never logs editor text, identifiers, labels or coordinates,
/// and never authorizes a replacement target or Return.
struct FocusTransitionDiagnostics {
    let parent: AXUIElement?
    let identifier: String?
    let role: String?

    init(_ element: AXUIElement) {
        parent = TargetDelivery.copyElement(kAXParentAttribute as String, from: element)
        identifier = TargetDelivery.stringAttribute(kAXIdentifierAttribute as String, from: element)
        role = TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: element)
    }

    static func record(target: CapturedTarget, before: Self?, inserted: String) {
        guard target.application.bundleIdentifier == "com.openai.codex",
              TargetDelivery.exactWindow(target), let old = target.element,
              let current = TargetDelivery.focusedElement(in: TargetDelivery.applicationElement(target.pid)),
              !TargetDelivery.isSecure(current) else { return }
        let next = Self(current)
        let oldRoleNow = TargetDelivery.stringAttribute(kAXRoleAttribute as String, from: old)
        let editor = TargetDelivery.editorValueSnapshot(in: current)
        let caret = TargetDelivery.selectedRange(in: current)
        let sameParent = before?.parent.flatMap { a in next.parent.map { CFEqual(a, $0) } } ?? false
        let sameIdentifier = before?.identifier.map { !$0.isEmpty && $0 == next.identifier } ?? false
        let oldParentIsCurrent = before?.parent.map { CFEqual($0, current) } ?? false
        let newParentIsOld = next.parent.map { CFEqual($0, old) } ?? false
        let exact = target.valueBefore.flatMap { source in
            target.selection.map { range in
                PasteAcknowledgement.evaluate(before: source,
                    selection: NSRange(location: range.location, length: range.length),
                    inserted: inserted, after: editor?.text,
                    caret: caret.map { NSRange(location: $0.location, length: $0.length) }) == .verified
            }
        } ?? false
        // A changed window during these read-only probes invalidates the diagnostic comparison.
        guard TargetDelivery.exactWindow(target) else { return }
        Diagnostics.event("focus_transition same_element=\(CFEqual(old, current)) old_readable=\(oldRoleNow != nil) old_textarea=\(before?.role == "AXTextArea") new_textarea=\(next.role == "AXTextArea") same_parent=\(sameParent) same_nonempty_identifier=\(sameIdentifier) old_parent_is_current=\(oldParentIsCurrent) new_parent_is_old=\(newParentIsOld) new_rich=\(editor?.richComposer ?? false) new_exact_text_caret=\(exact)")
    }
}
