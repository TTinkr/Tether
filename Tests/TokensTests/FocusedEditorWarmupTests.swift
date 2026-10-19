
import Testing
@testable import Tokens

struct FocusedEditorWarmupTests {
    private func facts(_ role: String) -> FocusedEditorWarmup.Evidence {
        .init(role: role, hasSelection: role == "customEditor")
    }

    @Test func containersNeedWarmupButEditorsAndSecureFieldsDoNot() {
        #expect(FocusedEditorWarmup.needsWarmup(nil))
        for role in ["AXWebArea", "AXGroup", "AXWindow", "AXApplication", "AXUnknown"] {
            #expect(FocusedEditorWarmup.needsWarmup(facts(role)))
        }
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "customEditor", "AXSecureTextField", "AXButton", "AXLink", "unknown"] {
            #expect(!FocusedEditorWarmup.needsWarmup(facts(role)))
        }
        let maskedSecure = FocusedEditorWarmup.Evidence(role: "AXTextField", subrole: "AXSecureTextField", hasSelection: true)
        let maskedNeedsWarmup = FocusedEditorWarmup.needsWarmup(maskedSecure)
        #expect(!maskedNeedsWarmup)
    }

    @Test func nonnilContainerRetriesUntilTheEditorArrives() {
        var asks = 0, sleeps = 0, reads = 0
        let result = FocusedEditorWarmup.resolve(initial: "AXWebArea", evidence: facts,
            enable: { asks += 1; return true }, stillCurrent: { true }, read: {
                reads += 1
                return reads == 1 ? "AXGroup" : "AXTextArea"
            }, wait: { sleeps += 1 })
        #expect(result.valid && result.enabled)
        #expect(result.element == "AXTextArea")
        #expect(asks == 1 && reads == 2 && sleeps == 2 && result.attempts == 2)
    }

    @Test func nilFocusAndPersistentContainerHaveABoundedRetryBudget() {
        for initial in [nil, "AXWebArea"] as [String?] {
            var asks = 0, reads = 0, sleeps = 0
            let result = FocusedEditorWarmup.resolve(initial: initial, evidence: facts,
                enable: { asks += 1; return true }, stillCurrent: { true },
                read: { reads += 1; return initial }, wait: { sleeps += 1 })
            #expect(result.valid && result.element == initial)
            #expect(asks == 1 && reads == 6 && sleeps == 6 && result.attempts == 6)
        }
    }

    @Test func deniedAskDoesNotRetryOrInventAnEditor() {
        let result = FocusedEditorWarmup.resolve(initial: "AXWebArea", evidence: facts,
            enable: { false }, stillCurrent: { true },
            read: { Issue.record("A denied tree request must not read again"); return "AXTextArea" },
            wait: { Issue.record("A denied tree request must not wait") })
        #expect(result.valid && !result.enabled && result.attempts == 0)
        #expect(result.element == "AXWebArea")
    }

    @Test func ordinaryEditorKeepsItsExactOriginalElement() {
        let result = FocusedEditorWarmup.resolve(initial: "customEditor", evidence: facts,
            enable: { Issue.record("Existing editor must not enable a tree"); return true },
            stillCurrent: { true }, read: { Issue.record("Existing editor must not retarget"); return "AXTextArea" },
            wait: { Issue.record("Existing editor must not wait") })
        #expect(result.valid && !result.enabled && result.element == "customEditor")
    }

    @Test func realNonEditorControlNeverWaitsForALaterEditor() {
        var reads = 0
        let result = FocusedEditorWarmup.resolve(initial: "AXWebArea", evidence: facts,
            enable: { true }, stillCurrent: { true }, read: {
                reads += 1
                return reads == 1 ? "AXButton" : "AXTextArea"
            }, wait: {})
        #expect(result.valid && result.element == "AXButton" && reads == 1)
        #expect(!facts(result.element ?? "").editor)
    }

    @Test func secureFocusIsRejectedInitiallyAndAfterWarmup() {
        let initial = FocusedEditorWarmup.resolve(initial: "AXSecureTextField", evidence: facts,
            enable: { Issue.record("Secure focus must not enable a tree"); return true },
            stillCurrent: { true }, read: { nil }, wait: {})
        #expect(!initial.valid && !initial.enabled && initial.attempts == 0)
        let discovered = FocusedEditorWarmup.resolve(initial: "AXWebArea", evidence: facts,
            enable: { true }, stillCurrent: { true }, read: { "AXSecureTextField" }, wait: {})
        #expect(!discovered.valid && discovered.attempts == 1)
    }

    @Test func changedAppOrWindowInvalidatesCaptureAtEveryRetryBoundary() {
        // Production's predicate checks both the frontmost PID and original window.
        // Fail before enable, after enable, after wait, or after the focus AX read.
        for failureBoundary in 1...4 {
            var checks = 0, reads = 0, asks = 0
            let result = FocusedEditorWarmup.resolve(initial: "AXWebArea", evidence: facts,
                enable: { asks += 1; return true }, stillCurrent: {
                    checks += 1
                    return checks < failureBoundary
                }, read: { reads += 1; return "AXTextArea" }, wait: {})
            #expect(!result.valid)
            #expect(asks == (failureBoundary == 1 ? 0 : 1))
            #expect(reads == (failureBoundary == 4 ? 1 : 0))
        }
    }
}
