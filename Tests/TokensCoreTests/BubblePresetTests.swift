


//
import Foundation
import Testing
@testable import TokensCore

struct BubblePresetTests {
    @Test func completeCycleHasOnlyFourStops() {
        var value = BubblePlacement.bottom
        var seen: [BubblePlacement] = []
        for _ in 0..<8 { seen.append(value); value = value.nextPreset }
        #expect(seen == [.bottom, .left, .top, .right, .bottom, .left, .top, .right])
    }
    @Test func legacyCustomMigratesAndPersistsWithDeterministicTies() throws {
        let defaults = try #require(UserDefaults(suiteName: "preset-tests-\(UUID())"))
        // Use a disposable domain; clear only the exact keys created by this fixture.
        defer { defaults.removeObject(forKey: SettingsKey.bubblePlacement); defaults.removeObject(forKey: SettingsKey.bubbleCustomPosition) }
        for (point, expected) in [(CGPoint(x: 0.04, y: 0.6), BubblePlacement.left),
                                  (CGPoint(x: 0.7, y: 0.98), .top), (CGPoint(x: 0.95, y: 0.5), .right),
                                  (CGPoint(x: 0.5, y: 0.5), .bottom), (CGPoint(x: .nan, y: 0.5), .bottom)] {
            BubblePlacement.save(.custom, custom: point, to: defaults)
            #expect(BubblePlacement.loadPreset(from: defaults) == expected)
            #expect(BubblePlacement.loadPreset(from: defaults) == expected)
            #expect(defaults.string(forKey: SettingsKey.bubblePlacement) == expected.rawValue)
            #expect(defaults.array(forKey: SettingsKey.bubbleCustomPosition) != nil)
        }
    }
    @Test func publicDefaultIsEstablishedOnceWithoutReplacingAStoredEdge() throws {
        let name = "preset-default-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(BubblePlacement.loadPreset(defaultingTo: .right, from: defaults) == .right)
        #expect(defaults.string(forKey: SettingsKey.bubblePlacement) == "right")
        #expect(BubblePlacement.loadPreset(from: defaults) == .right)
        BubblePlacement.save(.left, to: defaults)
        #expect(BubblePlacement.loadPreset(defaultingTo: .right, from: defaults) == .left)
    }
    @Test func presetsFitOffsetDisplayWithExpectedOrientation() {
        let visible = CGRect(x: -1600, y: 80, width: 1440, height: 850)
        for preset in BubblePlacement.presets {
            let size = preset.isVerticalPreset ? CGSize(width: 104, height: 148) : CGSize(width: 272, height: 44)
            let origin = BubbleGeometry.origin(preset, custom: nil, size: size, visible: visible)
            #expect(visible.contains(CGRect(origin: origin, size: size)))
        }
    }
}

