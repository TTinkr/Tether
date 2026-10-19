import AppKit
import SwiftUI
import Testing
@testable import Tokens

/// Build 82: the menu bar and the compact rail show the logo's π, never "Tk".
/// Writes PNGs only when TOKENS_LOGO_PI_RENDER_DIR is set.
@MainActor
struct LogoPiMarkTests {
    @Test func menuBarMarkIsTheLogoPiAsATemplate() throws {
        let image = LogoPi.templateImage()
        #expect(image.isTemplate, "macOS tints it for light and dark menu bars")
        #expect(image.size == NSSize(width: 22, height: 18))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 88, pixelsHigh: 72, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // Ink inside the canvas, clear around it: the π is drawn and never clipped at an edge.
        var inked = 0, edge = 0
        for y in 0..<72 { for x in 0..<88 {
            let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            if alpha > 0.2 { inked += 1; if x == 0 || y == 0 || x == 87 || y == 71 { edge += 1 } }
        } }
        #expect(inked > 200 && edge == 0, "inked \(inked), at the edge \(edge)")
        if let directory = ProcessInfo.processInfo.environment["TOKENS_LOGO_PI_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu-bar-pi@4x.png"))
        }
    }

    @Test func noTkMarkIsLeft() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Tokens/App/AppDelegateMenu.swift", "Sources/Tokens/Features/Home/TokensHomeSidebar.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("\"tokens-mark\"") && !source.contains("Text(\"Tk\")"), "\(file) still draws Tk")
        }
    }
}
