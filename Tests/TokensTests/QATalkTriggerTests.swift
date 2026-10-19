import Foundation
import Testing
@testable import Tokens

/// The Dev-only --qa-talk switch (build 81): closed in public builds,
/// addressed to one PID, and routed through the key monitor's own edge path.
struct QATalkTriggerTests {
    @Test func closedUnlessDevChannelWithProofRoutes() {
        #expect(QATalkTrigger.allowed(devChannel: true, proofRoutes: true))
        #expect(!QATalkTrigger.allowed(devChannel: false, proofRoutes: true))
        #expect(!QATalkTrigger.allowed(devChannel: true, proofRoutes: false))
        #expect(!QATalkTrigger.allowed(devChannel: false, proofRoutes: false))
        // A public build is never the Dev channel and closes proof routes.
        #expect(!ProofRoutes.allowed(distributionMode: "distribution"))
    }

    @Test func onlyThreeEdgeWords() {
        #expect(QATalkTrigger.Edge.allCases.map(\.rawValue) == ["press", "release", "tap"])
        #expect(QATalkTrigger.Edge(rawValue: "bogus") == nil)
        #expect(QATalkTrigger.Edge(rawValue: "") == nil)
    }

    @Test func addressesExactlyOneRunningCopy() throws {
        typealias T = QATalkTrigger
        #expect(try T.target(requested: nil, running: [42]).get() == 42)
        #expect(try T.target(requested: 7, running: [7, 9]).get() == 7)
        #expect(throws: T.Exit.noReceiver) { try T.target(requested: nil, running: []).get() }
        #expect(throws: T.Exit.usage) { try T.target(requested: nil, running: [7, 9]).get() }
        #expect(throws: T.Exit.noReceiver) { try T.target(requested: 5, running: [7]).get() }
    }

    /// The injected edge reaches onPress/onRelease on main once per real change of state, and is
    /// refused when the key is already in that state (it never doubles or cuts a press).
    @Test @MainActor func injectedEdgesUseTheKeyMonitorPath() async {
        let monitor = GlobalKeyMonitor()
        var presses = 0, releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }
        #expect(monitor.injectQAEdge(down: true))
        #expect(!monitor.injectQAEdge(down: true))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(presses == 1)
        #expect(monitor.injectQAEdge(down: false))
        #expect(!monitor.injectQAEdge(down: false))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(releases == 1)
        monitor.finishReturnReservation()
    }

    /// Source guards: the launch reads the switch only behind the Dev gate, that launch is a
    /// synthetic run, and the physical tap and the QA edge share one edge function.
    @Test func sourceKeepsTheGates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
        }
        let delegate = try source("App/AppDelegate.swift").components(separatedBy: "\n")
        let reads = delegate.filter { $0.contains("\"--qa-talk\"") }
        #expect(reads.count == 1)
        #expect(reads.allSatisfy { $0.contains("QATalkTrigger.isAvailable") })
        #expect(try source("Talk/TalkModel.swift").contains("(QATalkTrigger.isAvailable && arguments.contains(\"--qa-talk\"))"))
        let monitor = try source("Keyboard/GlobalKeyMonitor.swift")
        #expect(monitor.contains("talkEdge(down: down, keyCode: keyCode, source: nil)"))
        #expect(monitor.contains("talkEdge(down: down, keyCode: Int64(shortcut.keyCode), source: \"qa\")"))
        // Nothing else in the app calls the injector except the QA handler.
        let trigger = try source("App/QATalkTrigger.swift")
        #expect(trigger.contains("input.injectQAEdge("))
        #expect(!trigger.contains("routeRightOption"))
    }
}
