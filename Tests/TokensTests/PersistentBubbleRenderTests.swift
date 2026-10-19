import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// Model-free, offscreen fixtures for the persistent standby and fallback status surfaces.
@Suite(.serialized) @MainActor struct PersistentBubbleRenderTests {
    private static func luminance(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> Double {
        let data = try #require(rep.bitmapData)
        let pixel = data + y * rep.bytesPerRow + x * rep.samplesPerPixel
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 * linear(pixel[2])
    }

    private static func standbyContrast(_ rep: NSBitmapImageRep, size: CGSize,
                                        scale: CGFloat) throws -> Double {
        let centerX = Int(size.width * scale / 2), centerY = Int(size.height * scale / 2)
        let radius = Int(5 * scale)
        var brightest = 0.0
        for y in (centerY - radius)...(centerY + radius) {
            for x in (centerX - radius)...(centerX + radius) {
                brightest = max(brightest, try luminance(rep, x: x, y: y))
            }
        }
        let interior = try luminance(rep, x: Int(size.width * scale / 5), y: centerY)
        return (brightest + 0.05) / (interior + 0.05)
    }

    @Test func standbyAndFallbackStatesRenderInBothThemes() throws {
        let output = ProcessInfo.processInfo.environment["TOKENS_FEEDBACK_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }

        let fixtures: [(String, CGSize, AnyView)] = [
            ("standby-wide", panelDefaultSize,
             AnyView(BubbleStandbySurface(vertical: false, shortcutName: "Right Option"))),
            ("standby-side", BubbleLayout.compactVerticalSize,
             AnyView(BubbleStandbySurface(vertical: true, shortcutName: "Right Option"))),
            ("finishing", panelDefaultSize, AnyView(TinyStatusSurface(text: "Finishing…"))),
            ("recovery", BubbleLayout.recoveryHorizontalSize,
             AnyView(TinyStatusSurface(text: "Ready to retry"))),
        ]

        for dark in [false, true] {
            for (name, size, fixture) in fixtures {
                let themed = fixture.preferredColorScheme(dark ? .dark : .light)
                let rep = try PasteMarkerPNG.render(themed, size: size, scale: 2, dark: dark)
                #expect(rep.pixelsWide == Int(size.width * 2))
                #expect(rep.pixelsHigh == Int(size.height * 2))
                if name.hasPrefix("standby") {
                    let contrast = try Self.standbyContrast(rep, size: size, scale: 2)
                    #expect(contrast >= 3, "\(name) ring contrast was \(contrast):1")
                }
                let data = try PasteMarkerPNG.png(rep)
                #expect(data.count > 500)
                if let output {
                    try data.write(to: output.appendingPathComponent(
                        "bubble-\(name)-\(dark ? "dark" : "light")@2x.png"))
                }
            }
        }
    }
}
