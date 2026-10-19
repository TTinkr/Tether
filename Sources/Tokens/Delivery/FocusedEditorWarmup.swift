

/// Pure orchestration; production supplies AX reads and tests supply synthetic focus.
enum FocusedEditorWarmup {
    struct Evidence {
        var role: String?
        var subrole: String? = nil
        var hasSelection: Bool

        var secure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
        var editor: Bool {
            !secure && (hasSelection || ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? ""))
        }
    }

    struct Resolution<Element> {
        var element: Element?
        var enabled: Bool
        var attempts: Int
        var valid: Bool
    }

    static func needsWarmup(_ evidence: Evidence?) -> Bool {
        guard let evidence else { return true }
        guard !evidence.secure && !evidence.editor else { return false }
        // Known controls (buttons/links) are a real destination, not a hidden editor.
        // Never wait for a later editor to replace one at the stop edge.
        return evidence.role == nil || ["AXWebArea", "AXGroup", "AXWindow", "AXApplication", "AXUnknown"].contains(evidence.role ?? "")
    }

    static func resolve<Element>(initial: Element?, evidence: (Element) -> Evidence,
                                  enable: () -> Bool, stillCurrent: () -> Bool,
                                  read: () -> Element?, wait: () -> Void) -> Resolution<Element> {
        var result = Resolution(element: initial, enabled: false, attempts: 0, valid: true)
        let initialEvidence = initial.map(evidence)
        if initialEvidence?.secure == true { result.valid = false; return result }
        guard needsWarmup(initialEvidence) else { return result }
        guard stillCurrent() else { result.valid = false; return result }
        guard enable() else { return result }
        result.enabled = true
        for _ in 0..<6 {
            guard stillCurrent() else { result.valid = false; return result }
            wait()
            guard stillCurrent() else { result.valid = false; return result }
            result.attempts += 1
            let candidate = read()
            guard stillCurrent() else { result.valid = false; return result }
            if let candidate {
                result.element = candidate
                let facts = evidence(candidate)
                if facts.secure { result.valid = false; return result }
                if facts.editor || !needsWarmup(facts) { return result }
            }
        }
        return result
    }
}
