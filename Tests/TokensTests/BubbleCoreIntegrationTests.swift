


//
import CoreGraphics
import Foundation
import Testing
import TokensCore
@testable import Tokens


@Suite struct BubbleCoreIntegrationTests {
    private typealias Placement = Tokens.BubblePlacement
    private typealias Geometry = Tokens.BubbleGeometry

    @Test func legacySavedCustomPlacementLoadsThroughBothAPIs() {
        withDefaults { defaults in
            /*
            Literal old keys are intentional: changing both the app and core key
            together must not silently make this migration regression test pass.
            */
            defaults.set("custom", forKey: "TTTBubblePlacement.v1")
            defaults.set([0.25, 0.75], forKey: "TTTBubbleCustomPosition.v1")

            let (placement, custom) = Placement.load(defaults)
            let corePlacement: TokensCore.BubblePlacement = placement
            #expect(corePlacement == .custom)
            #expect(custom == CGPoint(x: 0.25, y: 0.75))
            #expect(TokensCore.BubblePlacement.load(from: defaults).1 == custom)
            #expect(Placement.preferenceKey == "TTTBubblePlacement.v1")
            #expect(Placement.customKey == "TTTBubbleCustomPosition.v1")
        }
    }

    @Test func appSaveKeepsLegacyKeysAndLastDraggedPosition() {
        withDefaults { defaults in
            let fraction = CGPoint(x: 0.25, y: 0.75)
            Placement.save(.custom, custom: fraction, in: defaults)
            #expect(defaults.string(forKey: "TTTBubblePlacement.v1") == "custom")
            #expect(defaults.array(forKey: "TTTBubbleCustomPosition.v1") as? [Double] == [0.25, 0.75])

            Placement.save(.right, in: defaults)
            #expect(Placement.load(defaults).0 == .right)
            #expect(Placement.load(defaults).1 == fraction)
            #expect(TokensCore.BubblePlacement.load(from: defaults).1 == fraction)

            // Returning to custom without a new drag restores the stored fraction.
            TokensCore.BubblePlacement.save(.custom, to: defaults)
            #expect(Placement.load(defaults).0 == .custom)
            #expect(Placement.load(defaults).1 == fraction)
        }
    }

    @Test func missingUnknownAndMalformedLegacyValuesKeepTheirFallback() {
        withDefaults { defaults in
            #expect(Placement.load(defaults).0 == .bottom)
            #expect(Placement.load(defaults).1 == nil)
            defaults.set("future-placement", forKey: "TTTBubblePlacement.v1")
            #expect(Placement.load(defaults).0 == .bottom)

            defaults.set("custom", forKey: "TTTBubblePlacement.v1")
            #expect(Placement.load(defaults).0 == .bottom)
            let malformedValues: [[Any]] = [[], [0.5], [0.1, 0.2, 0.3], ["left", "top"]]
            for malformed in malformedValues {
                defaults.set(malformed, forKey: "TTTBubbleCustomPosition.v1")
                #expect(Placement.load(defaults).0 == .bottom)
                #expect(Placement.load(defaults).1 == nil)
            }
        }
    }

    @Test func savedOutOfRangeFractionsRemainStoredAndClampOnlyAtPlacement() {
        withDefaults { defaults in
            Placement.save(.custom, custom: CGPoint(x: -2, y: 3), in: defaults)
            let (placement, custom) = Placement.load(defaults)
            #expect(placement == .custom)
            #expect(custom == CGPoint(x: -2, y: 3))
            #expect(Geometry.origin(placement, custom: custom, size: CGSize(width: 300, height: 54),
                                    visible: CGRect(x: -1440, y: 80, width: 1440, height: 800))
                    == CGPoint(x: -1440, y: 826))
        }
    }

//
// :)
//
//
    @Test func legacyGeometryNamesAndOrientationUseTheSharedModel() {
        let size   = CGSize(width: 246, height: 36)
        let screen = CGRect(x: 1440, y: 91, width: 1920, height: 964)
        #expect(Geometry.bottomMargin == 12)
        #expect(Geometry.bottomMargin == TokensCore.BubbleGeometry.edgeMargin)
        #expect(Geometry.lockedOrigin(size: size, visible: screen) == CGPoint(x: 2277, y: 103))
        #expect(Geometry.origin(.right, custom: nil, size: size, visible: screen) == CGPoint(x: 3102, y: 555))
        #expect(!Geometry.isVertical(at: CGPoint(x: 0.27, y: 0.5), wasVertical: false))
        #expect(Geometry.isVertical(at: CGPoint(x: 0.27, y: 0.5), wasVertical: true))
        #expect(!Geometry.isVertical(at: CGPoint(x: 0.08, y: 0.08), wasVertical: true))
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name     = "BubbleCoreIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}

