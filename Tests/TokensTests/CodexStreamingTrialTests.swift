import Foundation
import Testing
@testable import Tokens

struct CodexStreamingTrialTests {
    @Test func trialRequiresExactReadableCodexPlanAndConsumesOnce() {
        let name = "codex-boundary-trial-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func consume(_ bundle: String? = "com.openai.codex", rich: Bool = true, exact: Bool = true) -> Bool {
            CodexStreamingTrial.consume(bundle: bundle, richComposer: rich, exactPlan: exact, in: defaults)
        }
        #expect(!consume())
        #expect(CodexStreamingTrial.status(in: defaults) == "off")
        defaults.set(1, forKey: CodexStreamingTrial.preferenceKey)
        #expect(!consume())
        #expect(CodexStreamingTrial.status(in: defaults) == "other_process")
        defaults.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: CodexStreamingTrial.processKey)
        #expect(!CodexStreamingTrial.consume(bundle: "com.openai.codex", richComposer: true, exactPlan: true,
                                             in: defaults, processID: -1))
        #expect(!consume("fictional.editor"))
        #expect(!consume(rich: false))
        #expect(!consume(exact: false))
        #expect(CodexStreamingTrial.status(in: defaults) == "armed_1")
        #expect(consume())
        #expect(!consume())
        #expect(CodexStreamingTrial.status(in: defaults) == "off")
        for _ in 0..<3 {
            PasteAckHistory.record(bundle: "com.openai.codex", acknowledged: true, in: defaults)
            #expect(!consume())
            #expect(!PasteAckHistory.allowsStaging(bundle: "com.openai.codex", richComposer: true, in: defaults))
        }
    }

    // Two physical trials missed a three-minute window and a float-rounded epoch
    // rejected a third; the lease is now a count with no clock.
    @Test func armedCountSurvivesTimeAndDecrementsPerAttempt() {
        let name = "codex-boundary-count-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(3, forKey: CodexStreamingTrial.preferenceKey)
        defaults.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: CodexStreamingTrial.processKey)
        defaults.set(Float(Date.timeIntervalSinceReferenceDate - 3600), forKey: CodexStreamingTrial.expiryKey)
        for left in [3, 2, 1] {
            #expect(CodexStreamingTrial.remaining(in: defaults) == left)
            #expect(CodexStreamingTrial.consume(bundle: "com.openai.codex", richComposer: true, exactPlan: true, in: defaults))
        }
        #expect(!CodexStreamingTrial.consume(bundle: "com.openai.codex", richComposer: true, exactPlan: true, in: defaults))
        #expect(defaults.object(forKey: CodexStreamingTrial.expiryKey) == nil)
        defaults.set(500, forKey: CodexStreamingTrial.preferenceKey)
        #expect(CodexStreamingTrial.remaining(in: defaults) == CodexStreamingTrial.maximumAttempts)
    }
}
