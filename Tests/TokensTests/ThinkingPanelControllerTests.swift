


//
import AppKit
import Testing
@testable import Tokens

@Suite(.serialized) @MainActor struct ThinkingPanelControllerTests {
    private func isolatedDefaults() throws -> (String, UserDefaults) {
        let name = "TokensPanelControllerTests-" + UUID().uuidString
        return (name, try #require(UserDefaults(suiteName: name)))
    }

    @Test func hideRemainsOffAcrossSessionsAndControllerRecreation() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = ThinkingPanelController(state: ThinkingPanelState(), defaults: defaults)
        #expect(!controller.isEnabled)
        controller.hideForGood()
        #expect(!controller.isEnabled)
        controller.beginSession()
        // Disabled show exits before creating any NSPanel; this test never orders a window forward.
        controller.show()
        #expect(controller.panel == nil)
        let relaunched = ThinkingPanelController(state: ThinkingPanelState(), defaults: defaults)
        relaunched.beginSession()
        #expect(!relaunched.isEnabled)
        #expect(relaunched.panel == nil)
        #expect(Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? [])
                == Set([TokensThinkingTemple.enabledKey]))
    }

    @Test func savedTrueCannotReopenLaunchPanel() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = ThinkingPanelController(state: ThinkingPanelState(), defaults: defaults)
        controller.hide()
        #expect(!controller.isEnabled)
        controller.hideForGood()
        #expect(!controller.isEnabled)
        // Historical opt-in must not reopen the panel in the bubble-only launch.
        defaults.set(true, forKey: TokensThinkingTemple.enabledKey)
        #expect(!controller.isEnabled)
        controller.show()
        #expect(controller.panel == nil)
        #expect(defaults.bool(forKey: TokensThinkingTemple.enabledKey)) // Do not erase the preference.
    }

    @Test func movedAndCollapsedFrameRetainsExpandedSizeAcrossLaunches() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let placement = ThinkingPanelPlacement(defaults: defaults)
        let expanded  = NSSize(width: 640, height: 420)
        placement.save(NSRect(x: 150, y: 230, width: 640, height: 420), expanded: expanded)
        let collapsed = NSRect(x: 150, y: 594, width: 88, height: 56)
        placement.save(collapsed, expanded: expanded)
        let restored = ThinkingPanelPlacement(defaults: defaults)
        #expect(restored.frame == collapsed)
        #expect(restored.expandedSize == expanded)
        #expect(defaults.object(forKey: TokensThinkingTemple.enabledKey) == nil)
    }

    @Test func malformedFramesFallBackInsteadOfCreatingUnreachableWindows() throws {
        let (name, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let placement = ThinkingPanelPlacement(defaults: defaults)
        defaults.set("not a rectangle", forKey: ThinkingPanelPlacement.frameKey)
        #expect(placement.frame == nil)
        defaults.set(NSStringFromRect(NSRect(x: 0, y: 0, width: 50_000, height: 100)),
                     forKey: ThinkingPanelPlacement.frameKey)
        #expect(placement.frame == nil)
        defaults.set(NSStringFromSize(NSSize(width: 88, height: 56)),
                     forKey: ThinkingPanelPlacement.expandedKey)
        #expect(placement.expandedSize == nil)
        defaults.removeObject(forKey: ThinkingPanelPlacement.frameKey)
        placement.save(NSRect(x: CGFloat.infinity, y: 0, width: 560, height: 300),
                       expanded: NSSize(width: 560, height: 300))
        #expect(placement.frame == nil)
    }

//
// :)
//
//
    @Test func disconnectedDisplayFrameReturnsInsideAvailableScreen() {
        let area     = NSRect(x: -1280, y: 20, width: 1280, height: 800)
        let frame    = NSRect(x: 2400, y: 1300, width: 560, height: 364)
        let restored = ThinkingPanelPlacement.fitting(frame, in: area)
        #expect(area.contains(restored))
        #expect(restored.size == frame.size)
        let smallArea = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(ThinkingPanelPlacement.fitting(frame, in: smallArea) == smallArea)
        #expect(ThinkingPanelPlacement.fitting(frame, in: nil) == frame)
    }
}

