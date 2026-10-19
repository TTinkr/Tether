


//
import CoreGraphics
import Foundation
import Testing
@testable import TokensCore


// BubbleGeometryTests — where the bubble lands on a screen


@Suite struct BubbleGeometryTests {
    let size    = CGSize(width: 300, height: 54)
    let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)

    @Test func presetsPinToTheirEdgeWithTheMargin() {
        #expect(BubbleGeometry.origin(.bottom, custom: nil, size: size, visible: visible) == CGPoint(x: 570, y: 92))
        #expect(BubbleGeometry.origin(.top, custom: nil, size: size, visible: visible) == CGPoint(x: 570, y: 814))
        #expect(BubbleGeometry.origin(.left, custom: nil, size: size, visible: visible) == CGPoint(x: 12, y: 453))
        #expect(BubbleGeometry.origin(.right, custom: nil, size: size, visible: visible) == CGPoint(x: 1128, y: 453))
    }

    @Test func aDraggedPositionSurvivesAScreenChange() {
        let dragged  = CGPoint(x: 855, y: 453)
        let fraction = BubbleGeometry.fraction(of: dragged, size: size, visible: visible)
        #expect(BubbleGeometry.origin(.custom, custom: fraction, size: size, visible: visible) == dragged)

        // Same fraction on a smaller screen stays fully on that screen.
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        let moved = BubbleGeometry.origin(.custom, custom: fraction, size: size, visible: small)
        #expect(small.contains(CGRect(origin: moved, size: size)))
    }

    @Test func customFractionsOutsideZeroToOneAreClamped() {
        let far = BubbleGeometry.origin(.custom, custom: CGPoint(x: 9, y: -3), size: size, visible: visible)
        #expect(far == CGPoint(x: 1140, y: 80))
    }

    @Test func aScreenSmallerThanTheBubbleDoesNotProduceANegativeMargin() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 40)
        #expect(BubbleGeometry.origin(.left, custom: nil, size: size, visible: tiny).x == 0)
        #expect(BubbleGeometry.fraction(of: .zero, size: size, visible: tiny) == CGPoint(x: 0.5, y: 0))
    }

    @Test func onlyTheMiddleOfSideEdgesStandsTheBubbleVertically() {
        #expect(BubbleGeometry.isVertical(at: CGPoint(x: 0.08, y: 0.5), wasVertical: false))
        #expect(BubbleGeometry.isVertical(at: CGPoint(x: 0.92, y: 0.5), wasVertical: false))
        for fraction in [CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.92, y: 0.92),
                         CGPoint(x: 0.5, y: 0.02), CGPoint(x: 0.5, y: 0.98),
                         CGPoint(x: 0.5, y: 0.5)] {
            #expect(!BubbleGeometry.isVertical(at: fraction, wasVertical: false))
        }
    }

    @Test func exactEntryAndExitBoundariesKeepCornersHorizontal() {
        // Entry includes its boundary; an upright bubble exits at the wider boundary.
        for x in [0.22, 0.78] {
            for y in [0.24, 0.76] {
                #expect(BubbleGeometry.isVertical(at: CGPoint(x: x, y: y), wasVertical: false))
            }
        }
        for x in [0.30, 0.70] {
            #expect(!BubbleGeometry.isVertical(at: CGPoint(x: x, y: 0.5), wasVertical: true))
        }
        for y in [0.18, 0.82] {
            for x in [0.08, 0.92] {
                #expect(!BubbleGeometry.isVertical(at: CGPoint(x: x, y: y), wasVertical: true))
            }
        }
        for x in [0.0, 1.0] {
            for y in [0.0, 1.0] {
                #expect(!BubbleGeometry.isVertical(at: CGPoint(x: x, y: y), wasVertical: false))
                #expect(!BubbleGeometry.isVertical(at: CGPoint(x: x, y: y), wasVertical: true))
            }
        }
    }

    @Test func screenOffsetsAndRoundedPointsPreserveCustomPlacement() {
        let secondScreen = CGRect(x: -1440, y: -200, width: 1440, height: 800)
        let fraction     = CGPoint(x: 0.25, y: 0.75)
        let moved        = BubbleGeometry.origin(.custom, custom: fraction, size: size, visible: secondScreen)
        #expect(moved == CGPoint(x: -1155, y: 360))
        #expect(BubbleGeometry.origin(.custom, custom: nil, size: size, visible: secondScreen)
                == CGPoint(x: -870, y: -200))
        #expect(BubbleGeometry.fraction(of: CGPoint(x: -2000, y: 1000), size: size, visible: secondScreen)
                == CGPoint(x: 0, y: 1))
    }

//
// :)
//
//
    @Test func sideOrientationUsesHysteresisAndLeavesTheTopAndBottomBands() {
        #expect(!BubbleGeometry.isVertical(at: CGPoint(x: 0.27, y: 0.5), wasVertical: false))
        #expect(BubbleGeometry.isVertical(at: CGPoint(x: 0.27, y: 0.5), wasVertical: true))
        #expect(!BubbleGeometry.isVertical(at: CGPoint(x: 0.31, y: 0.5), wasVertical: true))
        #expect(!BubbleGeometry.isVertical(at: CGPoint(x: 0.08, y: 0.84), wasVertical: true))
    }
}


// BubblePlacementTests — the saved placement choice


@Suite struct BubblePlacementTests {
    @Test func savedPlacementRoundTripsAndCustomNeedsAPosition() {
        let name     = "TokensCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(BubblePlacement.load(from: defaults).0 == .bottom)

        BubblePlacement.save(.custom, to: defaults)
        #expect(BubblePlacement.load(from: defaults).0 == .bottom, "custom without a position falls back")

        BubblePlacement.save(.custom, custom: CGPoint(x: 0.25, y: 0.75), to: defaults)
        let (placement, position) = BubblePlacement.load(from: defaults)
        #expect(placement == .custom)
        #expect(position == CGPoint(x: 0.25, y: 0.75))

        BubblePlacement.save(.right, to: defaults)
        #expect(BubblePlacement.load(from: defaults).0 == .right)
    }
}

