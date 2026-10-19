


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// CopyPi — the π mark as three open strokes; the bubble draws it dotted behind its copy label


struct CopyPi: Shape {
    /*
    Three strokes, all in fractions of the rect: a curved top bar left to right, then the left leg
    and the right leg, each a short curve running down from the bar.
    */
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.22))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height * 0.15), control: CGPoint(x: rect.width * 0.4, y: 0))
        path.move(to: CGPoint(x: rect.width * 0.32, y: rect.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.18, y: rect.height), control: CGPoint(x: rect.width * 0.34, y: rect.height * 0.75))
        path.move(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.84, y: rect.height), control: CGPoint(x: rect.width * 0.60, y: rect.height))
        return path
    }
}


// PencilPi — a heavy-stroked π whose strokes thicken a little with energy (lab screen only)


struct PencilPi: View {
    let energy: Double

    /*
    Only the lab screen (Unreached/Lab.swift) draws this one. `energy` adds to each line width:
    the top bar starts at 3.2 points (plus energy * 0.5), each leg at 10 (plus energy * 1.2).
    */
    var body: some View {
        Canvas { context, size in
            let ink = LabPalette.purple
            var cap = Path()
            cap.move(to: CGPoint(x: size.width * 0.10, y: size.height * 0.24))
            cap.addCurve(
                to: CGPoint(x: size.width * 0.90, y: size.height * 0.22),
                control1: CGPoint(x: size.width * 0.30, y: size.height * 0.14),
                control2: CGPoint(x: size.width * 0.66, y: size.height * 0.31)
            )
            context.stroke(
                cap,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 3.2 + energy * 0.5, lineCap: .round, lineJoin: .round)
            )

            var leftStem = Path()
            leftStem.move(to: CGPoint(x: size.width * 0.39, y: size.height * 0.29))
            leftStem.addCurve(
                to: CGPoint(x: size.width * 0.36, y: size.height * 0.83),
                control1: CGPoint(x: size.width * 0.38, y: size.height * 0.47),
                control2: CGPoint(x: size.width * 0.39, y: size.height * 0.68)
            )
            context.stroke(
                leftStem,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 10.0 + energy * 1.2, lineCap: .round, lineJoin: .round)
            )

            var rightStem = Path()
            rightStem.move(to: CGPoint(x: size.width * 0.61, y: size.height * 0.28))
            rightStem.addCurve(
                to: CGPoint(x: size.width * 0.66, y: size.height * 0.83),
                control1: CGPoint(x: size.width * 0.60, y: size.height * 0.47),
                control2: CGPoint(x: size.width * 0.61, y: size.height * 0.69)
            )
            context.stroke(
                rightStem,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 10.0 + energy * 1.2, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }
}

//
// :)
//
//
// ProductWordmark — the product's name as a mark; used only by the old shell (Unreached)


struct ProductWordmark: View {
    let product: String
    let size: CGFloat

    /*
    "Tokens" gets its brand image. Any other name is drawn as a π (standing in for the first letter,
    which is dropped) followed by the rest of the name in lower-case serif type.
    */
    var body: some View {
        if product == "Tokens" {
            TokensBrandWordmark(width: size * 3)
        } else {
        HStack(alignment: .center, spacing: 1) {
            HeaderPi()
                .stroke(style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.85, height: size * 0.9)
            Text(String(product.dropFirst()).lowercased())
                .font(.system(size: size, design: .serif))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(product)
        }
    }
}


// TokensBrandAssets — loads brand PNGs from the app bundle's WaveIdentity folder


enum TokensBrandAssets {
    /*
    Looks for `name`.png in the WaveIdentity folder of the running app's bundle and returns nil if
    it is not there, so callers need a fallback (the wordmark falls back to text).
    */
    /// Tests point this at Resources/Release/WaveIdentity to render the real artwork; nil in the app.
    static var overrideDirectory: URL?

    static func image(named name: String) -> NSImage? {
        if let directory = overrideDirectory {
            return NSImage(contentsOf: directory.appendingPathComponent(name + ".png"))
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "WaveIdentity") else { return nil }
        return NSImage(contentsOf: url)
    }
}


// TokensBrandWordmark — the Tokens wordmark image, or plain pencil text if it is missing


struct TokensBrandWordmark: View {
    let width: CGFloat

    var body: some View {
        // The master's alpha is the shape; the theme's ink fills it, so the handwriting reads
        // as graphite on Paper and as chalk on the dark themes.
        wordmark.hidden().overlay { TokensUI.ink.mask { wordmark } }
    }

    @ViewBuilder private var wordmark: some View {
        Group {
            if let image = TokensBrandAssets.image(named: "tokens-wordmark") {
                // Tighten the wide T–o span while leaving k/e/n/s and the handwriting's
                // vertical proportions unchanged. Transform only the rendered view: the
                // approved transparent master and its original ink are kept intact.
                Canvas { context, _ in
                    let scale = width / 1348
                    let split: CGFloat = 576
                    let compression: CGFloat = 0.82
                    let artwork = Image(nsImage: image)
                    let master = CGRect(x: -264.5, y: -142.5, width: 1877, height: 838)
                    context.scaleBy(x: scale, y: scale)
                    context.drawLayer { left in
                        left.scaleBy(x: compression, y: 1)
                        left.clip(to: Path(CGRect(x: 0, y: 0, width: split, height: 553)))
                        left.draw(artwork, in: master)
                    }
                    context.drawLayer { right in
                        right.translateBy(x: -split * (1 - compression), y: 0)
                        right.clip(to: Path(CGRect(x: split, y: 0, width: 1348 - split, height: 553)))
                        right.draw(artwork, in: master)
                    }
                }
                .frame(width: width, height: width * 553 / 1348)
            } else {
                /*
                The image is not in the app bundle: plain pencil-font text, sized from `width`,
                stands in.
                */
                Text("Tokens").font(TokensUI.font(width / 6, pencil: true))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens")
    }
}

//
// :)
//
//
// LogoPi — the Tokens logo's π, for small marks that must be the logo, never a font glyph

/*
The π from the Tokens app icon (Resources/Release/WaveIdentity/tokens-icon-1024.png), traced
along its pencil strokes: the wavy bar (two cubics) and two slightly leaning legs. Coordinates
are the icon's 1024 space; the rect is the strokes' centre-line bounds, so stroke it and pad by
half the line width. The website's rehearsal label draws the same path (src/feelItFirst.ts
PI_MARK), so the two marks match (a pie symbol that differs from the logo's would read as a different mark).
*/
struct LogoPi: Shape {
    static let bounds = CGRect(x: 257, y: 291, width: 529, height: 401)
    /// The centre-line size for a mark whose ink, stroked at `lineWidth`, is `inkHeight` tall.
    static func size(inkHeight: CGFloat, lineWidth: CGFloat) -> CGSize {
        let height = max(1, inkHeight - lineWidth)
        return CGSize(width: height * bounds.width / bounds.height, height: height)
    }

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - Self.bounds.minX) / Self.bounds.width * rect.width,
                    y: rect.minY + (y - Self.bounds.minY) / Self.bounds.height * rect.height)
        }
        var path = Path()
        path.move(to: p(257, 398))
        path.addCurve(to: p(500, 374), control1: p(318, 316), control2: p(425, 340))
        path.addCurve(to: p(786, 291), control1: p(599, 418), control2: p(724, 392))
        path.move(to: p(425, 352)); path.addLine(to: p(422, 692))
        path.move(to: p(609, 395)); path.addLine(to: p(607, 692))
        return path
    }
}


extension LogoPi {
    /*
    The menu-bar mark (it used to show "Tk"; it is the π used as the
    logo). A template image, so macOS draws it in the menu bar's own colour, light or dark, and
    vector, so it is crisp on every display. `inkHeight` is the π's drawn height in points.
    */
    static func templateImage(inkHeight: CGFloat = 13, lineWidth: CGFloat = 1.7, canvas: NSSize = NSSize(width: 22, height: 18)) -> NSImage {
        let size = Self.size(inkHeight: inkHeight, lineWidth: lineWidth)
        let image = NSImage(size: canvas, flipped: true) { bounds in
            let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(LogoPi().path(in: rect).cgPath)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tokens"
        return image
    }
}

// HeaderPi — the π mark as one top bar and two straight legs (used by ProductWordmark)


struct HeaderPi: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        p.move(to: point(0.04, 0.23))
        p.addCurve(to: point(0.50, 0.20), control1: point(0.19, 0.10), control2: point(0.34, 0.16))
        p.addCurve(to: point(0.96, 0.20), control1: point(0.69, 0.25), control2: point(0.81, 0.29))
        p.move(to: point(0.34, 0.18))
        p.addLine(to: point(0.28, 0.91))
        p.move(to: point(0.72, 0.22))
        p.addLine(to: point(0.70, 0.88))
        return p
    }
}


// WavePi — a π whose top bar bends more as the voice level (amplitude 0 to 1) rises


struct WavePi: Shape {
    let amplitude: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        /*
        amplitude is clamped to 0...1, then scaled to at most 8% of the height. The top bar's two
        curve controls are pushed in opposite directions by that amount, so the bar bends further as
        the amplitude goes up. The two legs do not move.
        */
        let lift = CGFloat(min(1, max(0, amplitude))) * rect.height * 0.08
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.30))
        path.addCurve(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.30), control1: CGPoint(x: rect.minX + rect.width * 0.33, y: rect.minY + rect.height * 0.30 - lift), control2: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.15 + lift))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.30))
        path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.29, y: rect.maxY - rect.height * 0.12), control1: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.54), control2: CGPoint(x: rect.minX + rect.width * 0.31, y: rect.maxY - rect.height * 0.16))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.67, y: rect.minY + rect.height * 0.30))
        path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.73, y: rect.maxY - rect.height * 0.12), control1: CGPoint(x: rect.minX + rect.width * 0.67, y: rect.minY + rect.height * 0.54), control2: CGPoint(x: rect.minX + rect.width * 0.69, y: rect.maxY - rect.height * 0.16))
        return path
    }
}


// TokensHappyFace — A small pencil face that gets happier as your words get ready to send


/// A small pencil face that gets happier as your words get ready to send. Drawn here: no image
/// asset, emoji or font glyph. `joy` 0…1 widens the smile and lifts the eyes into happy arcs.
struct TokensHappyFace: View {
    let joy: Double
    var ink = Color(red: 54 / 255, green: 56 / 255, blue: 51 / 255)
    var red = Color(red: 214 / 255, green: 69 / 255, blue: 65 / 255)

    var body: some View {
        /*
        Everything is placed with p(x, y), a fraction (0 to 1) of `side`, the shorter edge of the
        view, so the face is a centred square. `joy` is clamped to 0...1 and called `happy` below.
        Smile half-width grows from 0.14 to 0.26 of the side and its depth from 0.06 to 0.22.
        */
        Canvas { context, size in
            let side   = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * side, y: origin.y + y * side) }
            let happy  = CGFloat(min(1, max(0, joy)))
            let line   = max(1, side * 0.07)
            let pencil = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)

            // Head: one pencil circle, left a little open like a quick sketch.
            var head = Path()
            head.addArc(center: p(0.5, 0.5), radius: side * 0.44, startAngle: .degrees(-78), endAngle: .degrees(268), clockwise: false)
            context.stroke(head, with: .color(ink.opacity(0.9)), style: pencil)

            // Eyes: dots that lift into small arcs as the smile grows.
            for x in [0.34, 0.66] as [CGFloat] {
                var eye  = Path()
                let lift = 0.07 * happy
                eye.move(to: p(x - 0.06, 0.42))
                eye.addQuadCurve(to: p(x + 0.06, 0.42), control: p(x, 0.42 - lift * 2))
                context.stroke(eye, with: .color(ink), style: StrokeStyle(lineWidth: line * (1.5 - 0.5 * happy), lineCap: .round))
            }

            // Smile: red pencil, from a small curve to a wide grin.
            var smile = Path()
            let half  = 0.14 + 0.12 * happy
            let depth = 0.06 + 0.16 * happy
            smile.move(to: p(0.5 - half, 0.60))
            smile.addQuadCurve(to: p(0.5 + half, 0.60), control: p(0.5, 0.60 + depth * 1.6))
            context.stroke(smile, with: .color(red), style: StrokeStyle(lineWidth: line * 1.15, lineCap: .round))

            /*
            Cheeks appear at full joy.
            The cheeks fade in only for the top 40% of joy: opacity is (happy - 0.6) * 0.6.
            */
            if happy > 0.6 {
                let blush = red.opacity(Double(happy - 0.6) * 0.6)
                for x in [0.24, 0.76] as [CGFloat] {
                    context.fill(Path(ellipseIn: CGRect(x: p(x, 0).x - side * 0.045, y: p(0, 0.56).y, width: side * 0.09, height: side * 0.05)),
                                 with: .color(blush))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

