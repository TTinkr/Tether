


//
import AVFoundation
import AppKit
import Combine
import CoreText
import Speech
import SwiftUI


// Constants — the three 'academic' inks: near-black, pencil grey and a deep red


/*
Near-black for text, a softer grey for pencil lines and borders, and a deep red for the writing
caret and other red marks.
*/
var academicInk: Color { TokensUI.ink }
let academicPencil = Color(white: 0.24)
let academicRed    = Color(red: 0.72, green: 0.18, blue: 0.16)


// AcademicGraphPaper — white paper with a fine grid, and a heavier grid every fifth line


struct AcademicGraphPaper: View {
    /*
    Opacity of the white fill only. At 0 just the grid lines are drawn over whatever is behind
    (LiveNotes does this).
    */
    var paperOpacity: Double = 1
    @Environment(\.displayScale) private var displayScale

    /*
    White fill, then a light grid every 11 points and a darker grid every 55 points (every fifth
    line). allowsHitTesting(false) lets clicks pass through to whatever sits on top of the paper.
    */
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(paperOpacity)))
            drawGrid(
                context: &context,
                size: size,
                step: 11,
                color: Color.black.opacity(0.035)
            )
            drawGrid(
                context: &context,
                size: size,
                step: 55,
                color: Color.black.opacity(0.065)
            )
        }
        .allowsHitTesting(false)
    }

    /*
    All the vertical and horizontal lines are added to one path and stroked once. The line is one
    device pixel wide (1 / displayScale), so it stays a hairline on Retina screens.
    */
    private func drawGrid(
        context: inout GraphicsContext,
        size: CGSize,
        step: CGFloat,
        color: Color
    ) {
        var path       = Path()
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(color), lineWidth: 1 / max(displayScale, 1))
    }
}

//
// :)
//
//
// writingText() — text with a red caret (or a blank space) on the end


/*
Returns the text with one extra character on the end: a red "│" caret when `caret` is true,
otherwise a plain space. The transcript stream uses it for its live cursor.
*/
func writingText(_ value: String, caret: Bool) -> AttributedString {
    var result             = AttributedString(value)
    var cursor             = AttributedString(caret ? "│" : " ")
    cursor.foregroundColor = academicRed
    result.append(cursor)
    return result
}


// GraphPaper — full-window lab paper with a fine and a heavier grid


/*
Only the lab screen (Unreached/Lab.swift) uses this one. ignoresSafeArea() lets the paper run
under the title bar to the very edge of the window.
*/
struct GraphPaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(LabPalette.paper))
            drawGrid(context: &context, size: size, step: 24, opacity: 0.15, width: 0.55)
            drawGrid(context: &context, size: size, step: 120, opacity: 0.24, width: 0.75)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // Same method as AcademicGraphPaper.drawGrid, except line width and opacity come from the caller.
    private func drawGrid(
        context: inout GraphicsContext,
        size: CGSize,
        step: CGFloat,
        opacity: Double,
        width: CGFloat
    ) {
        var path       = Path()
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(LabPalette.grid.opacity(opacity)), lineWidth: width)
    }
}


// TokensPaper — The sheet: white paper with a blue-grey grid, heavier every fourth line


// MARK: Paper

/// One white sheet with large square blue-grey cells, shared by the sidebar and content.
struct TokensPaper: View {
    var body: some View {
        /*
        Large 56-point cells are independent of the compact control spacing. Minor lines are
        quiet; every gridMajorEvery-th line (4) uses the slightly stronger gridMajor alpha.
        One-point filled lines stay crisp; opaque tells SwiftUI the sheet covers its area.
        */
        Canvas(opaque: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(TokensUI.paper))
            var minor      = Path()
            var major      = Path()
            var index      = 0
            var x: CGFloat = 0
            while x <= size.width {
                let line = CGRect(x: x, y: 0, width: 1, height: size.height)
                if index % TokensUI.gridMajorEvery == 0 { major.addRect(line) } else { minor.addRect(line) }
                x += TokensUI.paperCell
                index += 1
            }
            index          = 0
            var y: CGFloat = 0
            while y <= size.height {
                let line = CGRect(x: 0, y: y, width: size.width, height: 1)
                if index % TokensUI.gridMajorEvery == 0 { major.addRect(line) } else { minor.addRect(line) }
                y += TokensUI.paperCell
                index += 1
            }
            context.fill(minor, with: .color(TokensUI.gridMinor))
            context.fill(major, with: .color(TokensUI.gridMajor))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

//
// :)
//
//
// TokensGrain — Graphite grain: paper-coloured specks laid over all ink


/// Graphite grain: paper-coloured specks laid over all ink. One fixed-seed tile, never animated.
struct TokensGrain: View {
    @Environment(\.displayScale) private var displayScale

    /*
    Built once, the first time the grain is needed, then reused. It is a 160 by 160 pixel tile of
    paper-coloured specks over transparent pixels. 0x70656E63696C is a fixed seed (its bytes spell
    "pencil") for the small shift-and-xor random generator below, so the grain looks the same on
    every launch.
    */
    private static let tile: CGImage? = {
        let side          = 160
        var state: UInt64 = 0x70656E63696C
        func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 100_000) / 100_000
        }
        /*
        Three layers of random cells, 1, 2 and 4 pixels wide, added together with weights 0.5, 0.3 and
        0.2. The coarser layers make the specks clump a little instead of looking like pure static.
        */
        var noise = [Double](repeating: 0, count: side * side)
        for (cell, weight) in [(1, 0.5), (2, 0.3), (4, 0.2)] {
            let count   = side / cell
            let lattice = (0..<(count * count)).map { _ in next() }
            for y in 0..<side {
                for x in 0..<side { noise[y * side + x] += weight * lattice[(y / cell) * count + x / cell] }
            }
        }
        /*
        Each pixel is paper-coloured with its alpha taken from the noise. The colour channels are
        multiplied by that alpha because the image is declared premultiplied (premultipliedLast).
        */
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0..<(side * side) {
            // Most of the sheet is untouched; the specks top out at 28% so ink stays 72–100% dark.
            let alpha             = min(0.28, max(0, noise[index] - 0.42) * 0.9)
            pixels[index * 4]     = UInt8(251 * alpha)
            pixels[index * 4 + 1] = UInt8(251 * alpha)
            pixels[index * 4 + 2] = UInt8(247 * alpha)
            pixels[index * 4 + 3] = UInt8(255 * alpha)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    /*
    Tiles the 160-pixel image across the view at one tile pixel per screen pixel (scale is the
    display scale) with no smoothing, so the specks stay crisp. Draws nothing if the tile failed
    to build.
    */
    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: max(displayScale, 1))
                .interpolation(.none)
                .resizable(resizingMode: .tile)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

