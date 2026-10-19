


//
import CoreGraphics
import Foundation
import TokensCore


typealias BubblePlacement = TokensCore.BubblePlacement
typealias BubbleGeometry = TokensCore.BubbleGeometry

extension BubblePlacement {
    static let preferenceKey = SettingsKey.bubblePlacement
    static let customKey     = SettingsKey.bubbleCustomPosition

    /*
    Keep the old explicit-defaults labels. Calls without defaults already resolve
    to the core API, so these adapters must not introduce competing defaults.
    */
    static func load(_ defaults: UserDefaults) -> (Self, CGPoint?) {
        load(from: defaults)
    }

    static func save(_ placement: Self, custom: CGPoint? = nil, in defaults: UserDefaults) {
        save(placement, custom: custom, to: defaults)
    }
}

extension BubbleGeometry {
    static let bottomMargin = edgeMargin

    // Older callers name the bottom-center preset as the locked origin.
    static func lockedOrigin(size: CGSize, visible: CGRect) -> CGPoint {
        origin(.bottom, custom: nil, size: size, visible: visible)
    }
}

