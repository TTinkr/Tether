


//
import AVFoundation
import AppKit
import Combine
import CoreText
import Speech
import SwiftUI


// InkButtonStyle — button style that shrinks the label slightly while it is pressed


struct InkButtonStyle: ButtonStyle {
    // Pressed state: label scales to 95.5% over 0.08 seconds. Used by the lab screen (Unreached/Lab.swift).
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}


// PencilDoodle — a small line drawing for each kind of sound in the lab's Candidate list


struct PencilDoodle: View {
    /*
    Which sound to draw. Candidate is declared in Unreached/Lab.swift, and PencilDoodle is only
    used there, so this view is not part of the Tokens window itself.
    */
    let candidate: Candidate

    var body: some View {
        /*
        Every point below is written as a fraction (0 to 1) of the view's width and height, turned into
        real coordinates by p(x, y), so a drawing scales with the view. `line` is the heavy stroke and
        `light` the thin one; both grow with the view's smaller side but never go below 2 and 1.5 points.
        */
        Canvas { context, size in
            let ink = LabPalette.purple
            let line = StrokeStyle(
                lineWidth: max(2.0, min(size.width, size.height) * 0.036),
                lineCap: .round,
                lineJoin: .round
            )
            let light = StrokeStyle(
                lineWidth: max(1.5, min(size.width, size.height) * 0.026),
                lineCap: .round,
                lineJoin: .round
            )
            let p: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: size.width * x, y: size.height * y)
            }

            /*
            One drawing per sound. Each case draws its main shape with the heavier `line` stroke and its
            smaller details (air, rays, marks) with the thinner `light` stroke.
            */
            switch candidate {
            case .breath:
                var upper = Path()
                upper.move(to: p(0.10, 0.34))
                upper.addCurve(to: p(0.89, 0.28), control1: p(0.30, 0.12), control2: p(0.62, 0.52))
                context.stroke(upper, with: .color(ink), style: line)
                var middle = Path()
                middle.move(to: p(0.16, 0.52))
                middle.addCurve(to: p(0.82, 0.49), control1: p(0.38, 0.38), control2: p(0.57, 0.66))
                context.stroke(middle, with: .color(ink), style: light)
                var lower = Path()
                lower.move(to: p(0.25, 0.69))
                lower.addCurve(to: p(0.73, 0.70), control1: p(0.40, 0.59), control2: p(0.59, 0.80))
                context.stroke(lower, with: .color(ink), style: light)
            case .whisper:
                var spine = Path()
                spine.move(to: p(0.26, 0.83))
                spine.addCurve(to: p(0.74, 0.16), control1: p(0.44, 0.68), control2: p(0.53, 0.31))
                context.stroke(spine, with: .color(ink), style: line)
                var barbs = Path()
                barbs.move(to: p(0.40, 0.63)); barbs.addLine(to: p(0.20, 0.55))
                barbs.move(to: p(0.47, 0.51)); barbs.addLine(to: p(0.28, 0.40))
                barbs.move(to: p(0.53, 0.42)); barbs.addLine(to: p(0.72, 0.34))
                barbs.move(to: p(0.60, 0.31)); barbs.addLine(to: p(0.78, 0.23))
                context.stroke(barbs, with: .color(ink), style: light)
            case .voice:
                var mouth = Path()
                mouth.move(to: p(0.17, 0.49))
                mouth.addCurve(to: p(0.72, 0.47), control1: p(0.34, 0.32), control2: p(0.56, 0.31))
                mouth.addCurve(to: p(0.17, 0.49), control1: p(0.54, 0.72), control2: p(0.32, 0.70))
                context.stroke(mouth, with: .color(ink), style: line)
                var voice = Path()
                voice.move(to: p(0.79, 0.39)); voice.addCurve(to: p(0.90, 0.57), control1: p(0.87, 0.43), control2: p(0.87, 0.52))
                voice.move(to: p(0.84, 0.27)); voice.addCurve(to: p(0.97, 0.68), control1: p(0.99, 0.37), control2: p(0.98, 0.57))
                context.stroke(voice, with: .color(ink), style: light)
            case .yell:
                var mouth = Path()
                mouth.move(to: p(0.22, 0.34)); mouth.addLine(to: p(0.67, 0.28))
                mouth.addLine(to: p(0.73, 0.76)); mouth.addLine(to: p(0.20, 0.69)); mouth.addLine(to: p(0.22, 0.34))
                context.stroke(mouth, with: .color(ink), style: line)
                var rays = Path()
                rays.move(to: p(0.77, 0.34)); rays.addLine(to: p(0.94, 0.22))
                rays.move(to: p(0.80, 0.50)); rays.addLine(to: p(0.98, 0.49))
                rays.move(to: p(0.77, 0.66)); rays.addLine(to: p(0.94, 0.79))
                context.stroke(rays, with: .color(ink), style: light)
            case .laugh:
                var eyes = Path()
                eyes.move(to: p(0.18, 0.36)); eyes.addCurve(to: p(0.40, 0.36), control1: p(0.24, 0.28), control2: p(0.34, 0.28))
                eyes.move(to: p(0.58, 0.36)); eyes.addCurve(to: p(0.80, 0.36), control1: p(0.64, 0.28), control2: p(0.74, 0.28))
                context.stroke(eyes, with: .color(ink), style: light)
                var smile = Path()
                smile.move(to: p(0.20, 0.51)); smile.addCurve(to: p(0.79, 0.50), control1: p(0.34, 0.82), control2: p(0.66, 0.82))
                context.stroke(smile, with: .color(ink), style: line)
                var marks = Path()
                marks.move(to: p(0.10, 0.57)); marks.addLine(to: p(0.04, 0.65))
                marks.move(to: p(0.88, 0.57)); marks.addLine(to: p(0.95, 0.65))
                context.stroke(marks, with: .color(ink), style: light)
            case .cough:
                var profile = Path()
                profile.move(to: p(0.16, 0.20)); profile.addCurve(to: p(0.43, 0.47), control1: p(0.28, 0.20), control2: p(0.31, 0.37))
                profile.addLine(to: p(0.55, 0.50)); profile.addLine(to: p(0.43, 0.57))
                profile.addCurve(to: p(0.26, 0.82), control1: p(0.37, 0.67), control2: p(0.34, 0.76))
                context.stroke(profile, with: .color(ink), style: line)
                var bursts = Path()
                bursts.move(to: p(0.61, 0.44)); bursts.addLine(to: p(0.75, 0.35)); bursts.addLine(to: p(0.72, 0.48))
                bursts.move(to: p(0.66, 0.56)); bursts.addLine(to: p(0.88, 0.57))
                bursts.move(to: p(0.60, 0.67)); bursts.addLine(to: p(0.77, 0.78))
                context.stroke(bursts, with: .color(ink), style: light)
            case .sigh:
                var eyes = Path()
                eyes.move(to: p(0.14, 0.31)); eyes.addCurve(to: p(0.39, 0.32), control1: p(0.21, 0.40), control2: p(0.33, 0.39))
                eyes.move(to: p(0.54, 0.32)); eyes.addCurve(to: p(0.79, 0.31), control1: p(0.61, 0.40), control2: p(0.73, 0.40))
                context.stroke(eyes, with: .color(ink), style: light)
                var mouth = Path()
                mouth.move(to: p(0.28, 0.57)); mouth.addCurve(to: p(0.62, 0.57), control1: p(0.38, 0.50), control2: p(0.53, 0.50))
                context.stroke(mouth, with: .color(ink), style: line)
                var air = Path()
                air.move(to: p(0.66, 0.58)); air.addCurve(to: p(0.91, 0.78), control1: p(0.88, 0.51), control2: p(0.92, 0.65))
                air.addCurve(to: p(0.74, 0.87), control1: p(0.87, 0.86), control2: p(0.80, 0.88))
                context.stroke(air, with: .color(ink), style: light)
            case .hum:
                var lips = Path()
                lips.move(to: p(0.16, 0.59)); lips.addCurve(to: p(0.48, 0.58), control1: p(0.26, 0.51), control2: p(0.38, 0.65))
                context.stroke(lips, with: .color(ink), style: line)
                var waves = Path()
                waves.move(to: p(0.47, 0.48)); waves.addCurve(to: p(0.88, 0.42), control1: p(0.60, 0.27), control2: p(0.74, 0.65))
                waves.move(to: p(0.49, 0.62)); waves.addCurve(to: p(0.91, 0.67), control1: p(0.62, 0.45), control2: p(0.77, 0.83))
                context.stroke(waves, with: .color(ink), style: light)
            case .whistle:
                var profile = Path()
                profile.move(to: p(0.17, 0.18)); profile.addCurve(to: p(0.47, 0.43), control1: p(0.32, 0.20), control2: p(0.33, 0.34))
                profile.addCurve(to: p(0.64, 0.50), control1: p(0.53, 0.45), control2: p(0.57, 0.48))
                profile.addCurve(to: p(0.46, 0.57), control1: p(0.58, 0.53), control2: p(0.53, 0.55))
                profile.addCurve(to: p(0.29, 0.82), control1: p(0.38, 0.67), control2: p(0.34, 0.75))
                context.stroke(profile, with: .color(ink), style: line)
                var whistle = Path()
                whistle.move(to: p(0.66, 0.50)); whistle.addCurve(to: p(0.95, 0.31), control1: p(0.78, 0.48), control2: p(0.82, 0.29))
                whistle.addCurve(to: p(0.88, 0.22), control1: p(0.94, 0.25), control2: p(0.92, 0.22))
                context.stroke(whistle, with: .color(ink), style: light)
            case .snap:
                var fingers = Path()
                fingers.move(to: p(0.22, 0.78)); fingers.addCurve(to: p(0.48, 0.42), control1: p(0.28, 0.64), control2: p(0.34, 0.49))
                fingers.addCurve(to: p(0.61, 0.20), control1: p(0.52, 0.34), control2: p(0.54, 0.23))
                fingers.move(to: p(0.28, 0.82)); fingers.addCurve(to: p(0.63, 0.45), control1: p(0.48, 0.77), control2: p(0.52, 0.59))
                context.stroke(fingers, with: .color(ink), style: line)
                var snap = Path()
                snap.move(to: p(0.67, 0.36)); snap.addLine(to: p(0.82, 0.18))
                snap.move(to: p(0.72, 0.45)); snap.addLine(to: p(0.96, 0.43))
                snap.move(to: p(0.67, 0.54)); snap.addLine(to: p(0.84, 0.70))
                context.stroke(snap, with: .color(ink), style: light)
            // Quiet and texture share one flat, thin line.
            case .silence, .texture:
                var quiet = Path()
                quiet.move(to: p(0.18, 0.52)); quiet.addCurve(to: p(0.82, 0.50), control1: p(0.37, 0.47), control2: p(0.62, 0.55))
                context.stroke(quiet, with: .color(ink), style: light)
            }
        }
        .allowsHitTesting(false)
    }
}

//
// :)
//
//
// TokensPencil — Ruler-drawn pencil lines


// MARK: Pencil strokes

/// Ruler-drawn pencil lines. Each stroke is seeded, so it draws the same way every time.
enum TokensPencil {
    /*
    Turns a label into a stable number: the same text always gives the same seed (the hash has no
    randomness in it). Callers feed it to the stroke helpers, so a given control's pencil wobble is
    identical on every redraw and every launch.
    */
    static func seed(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % 1_000_003)
    }

    /*
    Not random: mixes the bits of (seed, salt) so the same inputs always give the same number.
    `salt` lets one seed produce several different values; stroke() uses salts 1, 2 and 3 for the
    two overshoots and the sideways bow.
    */
    /// A fixed value in 0..<1 for a seed.
    static func unit(_ seed: Int, _ salt: Int) -> CGFloat {
        var value = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ salt &* 40_503 &+ 977)
        value ^= value >> 33
        value = value &* 0xff51afd7ed558ccd
        value ^= value >> 33
        return CGFloat(value % 10_000) / 10_000
    }

    /*
    How one hand-ruled line is made. (ux, uy) is the unit direction from start to end. Each end is
    extended by `overshoot` times 0.6 to 1.4 (a different amount at each end), and the line is drawn
    as a very shallow curve whose middle control point is pushed sideways by `bow`, a fixed amount
    of at most 0.35 points either way. That bow is the "under half a point of drift".
    */
    /// One straight stroke, run a little past both ends, with under half a point of drift.
    static func stroke(_ path: inout Path, from start: CGPoint, to end: CGPoint, seed: Int, overshoot: CGFloat = 0) {
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        let ux     = (end.x - start.x) / length
        let uy     = (end.y - start.y) / length
        let before = overshoot * (0.6 + 0.8 * unit(seed, 1))
        let after  = overshoot * (0.6 + 0.8 * unit(seed, 2))
        let a      = CGPoint(x: start.x - ux * before, y: start.y - uy * before)
        let b      = CGPoint(x: end.x + ux * after, y: end.y + uy * after)
        let bow    = (unit(seed, 3) - 0.5) * 0.7
        path.move(to: a)
        path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2 - uy * bow, y: (a.y + b.y) / 2 + ux * bow))
    }

    /*
    Four separate strokes, clockwise from the top-left corner: top, right, bottom, left. Each gets
    the next seed number (seed, +1, +2, +3), so the sides wobble differently from each other.
    */
    static func box(_ rect: CGRect, seed: Int, overshoot: CGFloat) -> Path {
        var path = Path()
        stroke(&path, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), seed: seed, overshoot: overshoot)
        stroke(&path, from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), seed: seed + 1, overshoot: overshoot)
        stroke(&path, from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY), seed: seed + 2, overshoot: overshoot)
        stroke(&path, from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.minY), seed: seed + 3, overshoot: overshoot)
        return path
    }

    // Pencil line style: round ends and joins; `dashed` means 3 points drawn, 3 points gap.
    static func style(_ width: CGFloat = 1, dashed: Bool = false) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 3] : [])
    }
}


// TokensPencilBox — a box traced along the grid lines, corners slightly overdrawn


/// A box whose edges trace the grid lines around the view, with the corners slightly overdrawn.
struct TokensPencilBox: Shape {

//
// :)
//
//
    var seed               = 0
    var overshoot: CGFloat = 2

    /*
    The half-point shift centres the 1-point pencil line on the paper's grid line (TokensPaper draws
    each grid line as a 1-point-wide rectangle starting at a whole-number coordinate).
    */
    func path(in rect: CGRect) -> Path {
        TokensPencil.box(rect.offsetBy(dx: 0.5, dy: 0.5), seed: seed, overshoot: overshoot)
    }
}


// TokensPencilEdge — one ruled line along one edge of the view, on the grid line there


/// One ruled line along an edge of the view, on the grid line that edge sits on.
struct TokensPencilEdge: Shape {
    var edge: Edge         = .bottom
    var seed               = 0
    var overshoot: CGFloat = 0
    /// Moves the line off the edge, e.g. an underline a few points below a baseline.
    var offset: CGFloat = 0

    /*
    Top and bottom give a horizontal line, leading and trailing a vertical one. The same half-point
    shift as the box centres it on a grid line; `offset` is added to that position, so a positive
    value moves the line down (or right).
    */
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .top, .bottom:
            let y = (edge == .top ? rect.minY : rect.maxY) + 0.5 + offset
            TokensPencil.stroke(&path, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y), seed: seed, overshoot: overshoot)
        case .leading, .trailing:
            let x = (edge == .leading ? rect.minX : rect.maxX) + 0.5 + offset
            TokensPencil.stroke(&path, from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY), seed: seed, overshoot: overshoot)
        }
        return path
    }
}


// TokensPencilCheck — a pencil tick in one square, its tail overshooting the corner


/// A pencil tick, drawn in one square with the tail overshooting the corner.
struct TokensPencilCheck: Shape {
    /*
    Two strokes, the short down-stroke then the long up-stroke. Points are fixed offsets from the
    rect's top-left corner (not scaled to its size), so the tick is the same size in any rect.
    */
    func path(in rect: CGRect) -> Path {
        var path = Path()
        TokensPencil.stroke(&path, from: CGPoint(x: rect.minX + 4, y: rect.minY + 10.5),
                            to: CGPoint(x: rect.minX + 8.5, y: rect.minY + 15.5), seed: 21, overshoot: 0.5)
        TokensPencil.stroke(&path, from: CGPoint(x: rect.minX + 8.5, y: rect.minY + 15.5),
                            to: CGPoint(x: rect.minX + 18, y: rect.minY + 2), seed: 22, overshoot: 0.5)
        return path
    }
}


// TokensPencilChevron — The back mark: two short strokes meeting at a point


/// The back mark: two short strokes meeting at a point.
struct TokensPencilChevron: Shape {
    /*
    The tip is on the left; the two arms run right to the top and bottom of the mark. Fixed offsets
    from the rect's top-left corner, like the tick above.
    */
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tip  = CGPoint(x: rect.minX + 4.5, y: rect.minY + 9.5)
        TokensPencil.stroke(&path, from: CGPoint(x: rect.minX + 12.5, y: rect.minY + 1.5), to: tip, seed: 23, overshoot: 0.5)
        TokensPencil.stroke(&path, from: tip, to: CGPoint(x: rect.minX + 12.5, y: rect.minY + 17.5), seed: 24, overshoot: 0.5)
        return path
    }
}

//
// :)
//
//
// TokensStatRules — the rule three Home numbers stand on, and the two ticks between them


/// The rule the three Home numerals stand on, and the two ticks that split them.
struct TokensStatRules: Shape {
    let cell: CGFloat

    /*
    One long rule two squares below the top, plus two short vertical ticks at `cell` and 2 * `cell`
    from the left that run from one square down to the bottom. Nothing outside this file uses
    TokensStatRules at the moment.
    */
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y    = rect.minY + 2 * TokensUI.module + 0.5
        TokensPencil.stroke(&path, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y), seed: 51, overshoot: 2)
        for index in 1...2 {
            let x = rect.minX + cell * CGFloat(index) + 0.5
            TokensPencil.stroke(&path, from: CGPoint(x: x, y: rect.minY + TokensUI.module),
                                to: CGPoint(x: x, y: rect.maxY), seed: 51 + index, overshoot: 2)
        }
        return path
    }
}


// TokensKeyEdges — the pencil edges of one key in a ruled row of keys


/// One key in a ruled row of keys: top, bottom and right edges, plus the left edge for the row's first key.
struct TokensKeyEdges: Shape {
    var seed    = 0
    var leading = false

    /*
    Top, bottom and right edges always; the left edge only for the first key (`leading`), so
    neighbouring keys share one line between them instead of drawing it twice.
    */
    func path(in rect: CGRect) -> Path {
        let box  = rect.offsetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        TokensPencil.stroke(&path, from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.maxX, y: box.minY), seed: seed)
        TokensPencil.stroke(&path, from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.maxY), seed: seed + 1)
        TokensPencil.stroke(&path, from: CGPoint(x: box.maxX, y: box.minY), to: CGPoint(x: box.maxX, y: box.maxY), seed: seed + 2, overshoot: 1.5)
        if leading {
            TokensPencil.stroke(&path, from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.minX, y: box.maxY), seed: seed + 3, overshoot: 1.5)
        }
        return path
    }
}


// TokensHatch — Diagonal pencil shading inside a box


/// Diagonal pencil shading inside a box.
struct TokensHatch: Shape {
    var spacing: CGFloat = 5

    /*
    Parallel diagonal strokes rising to the right, `spacing` points apart horizontally. The loop
    starts one rect-height to the left of the box so the corners are covered, and each stroke is
    clipped to the rect's own x-range.
    */
    func path(in rect: CGRect) -> Path {
        var path  = Path()
        var start = rect.minX - rect.height
        var seed  = 0
        while start < rect.maxX {
            let x0 = max(start, rect.minX)
            let x1 = min(start + rect.height, rect.maxX)
            if x1 > x0 {
                TokensPencil.stroke(&path, from: CGPoint(x: x0, y: rect.maxY - (x0 - start)),
                                    to: CGPoint(x: x1, y: rect.maxY - (x1 - start)), seed: seed)
            }
            start += spacing
            seed += 1
        }
        return path
    }
}

