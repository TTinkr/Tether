


//
import CoreGraphics
import Foundation

/// Where the bubble sits. Presets pin it to a screen edge; `custom` is wherever it was dragged.
public enum BubblePlacement: String, CaseIterable, Sendable {
    case bottom, left, right, top, custom

    /// Clockwise around the screen; persisted raw values remain compatible with old builds.
    public static let presets: [Self] = [.bottom, .left, .top, .right]
    public var nextPreset: Self {
        guard let index = Self.presets.firstIndex(of: self) else { return .bottom }
        return Self.presets[(index + 1) % Self.presets.count]
    }
    public var isVerticalPreset: Bool { self == .left || self == .right }

    /// Old free-drag positions migrate to their nearest edge. Ties use cycle order;
    /// missing/nonfinite coordinates go bottom. Keep the legacy coordinates for rollback.
    public static func loadPreset(from defaults: UserDefaults = .standard) -> Self {
        let (saved, point) = load(from: defaults)
        guard saved == .custom else {
            if defaults.string(forKey: SettingsKey.bubblePlacement) == "custom" { save(.bottom, to: defaults) }
            return saved
        }
        let migrated: Self
        if let point, point.x.isFinite, point.y.isFinite {
            let x = min(1, max(0, point.x)), y = min(1, max(0, point.y))
            let distances: [CGFloat] = [y, x, 1 - y, 1 - x]
            let index = distances.indices.min { distances[$0] < distances[$1] } ?? 0
            migrated = presets[index]
        } else { migrated = .bottom }
        save(migrated, to: defaults)
        return migrated
    }

    /// Establishes a product default once, without replacing any valid saved edge.
    /// Public Tokens uses `.right`; callers that do not opt in retain the historical bottom default.
    public static func loadPreset(defaultingTo defaultPlacement: Self,
                                  from defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: SettingsKey.bubblePlacement) == nil else {
            return loadPreset(from: defaults)
        }
        let preset = presets.contains(defaultPlacement) ? defaultPlacement : .bottom
        save(preset, to: defaults)
        return preset
    }

    /// The saved placement, plus the dragged position when the placement is `custom`.
    ///
    /// The dragged position is a fraction (0…1) of the room the bubble can move in, so it
    /// survives a change of screen. `custom` with no saved position falls back to `bottom`.
    public static func load(from defaults: UserDefaults = .standard) -> (BubblePlacement, CGPoint?) {
        let placement = Self(rawValue: defaults.string(forKey: SettingsKey.bubblePlacement) ?? "") ?? .bottom
        let values    = defaults.array(forKey: SettingsKey.bubbleCustomPosition) as? [Double]
        let custom    = values.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        return placement == .custom && custom == nil ? (.bottom, nil) : (placement, custom)
    }

    public static func save(_ placement: BubblePlacement, custom: CGPoint? = nil,
                            to defaults: UserDefaults = .standard) {
        defaults.set(placement.rawValue, forKey: SettingsKey.bubblePlacement)
        if let custom { defaults.set([Double(custom.x), Double(custom.y)], forKey: SettingsKey.bubbleCustomPosition) }
    }
}

