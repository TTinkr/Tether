


//
import AppKit
import AVFoundation
import Speech
import SwiftUI
import Testing
@testable import Tokens

@Suite("Access guide", .appKitWarmup)
struct AccessGuideTests {
    @Test func loopStartsOffAndReturnsToItsStart() {
        let start = AccessGuideTimeline.pose(at: 0)
        #expect(start.on == 0 && start.pointerOpacity == 0 && start.checkOpacity == 0)
        let end = AccessGuideTimeline.pose(at: AccessGuideTimeline.cycle - 0.01)
        #expect(end.on * end.reset == 0 && end.pointerOpacity == 0 && end.checkOpacity == 0)
        func values(_ p: AccessGuidePose) -> [Double] {
            [p.travel, p.pointerOpacity, p.press, p.ripple, p.on, p.reset, p.drift, p.checkScale, p.checkOpacity]
        }
        for t in stride(from: 0.0, to: AccessGuideTimeline.cycle, by: 0.37) {
            let once = values(AccessGuideTimeline.pose(at: t))
            let later = values(AccessGuideTimeline.pose(at: t + 3 * AccessGuideTimeline.cycle))
            #expect(zip(once, later).allSatisfy { abs($0 - $1) < 1e-6 }, "t = \(t)")
        }
    }

    @Test func stillPictureHasTheSwitchOnAndTheCheckShown() {
        let still = AccessGuideTimeline.pose(at: AccessGuideTimeline.still)
        #expect(still.on == 1 && still.reset == 1 && still.checkOpacity == 1 && still.pointerOpacity == 1)
        #expect(abs(still.checkScale - 1) < 0.001)
        // The click comes after the pointer arrives, and the switch turns on during it.
        #expect(AccessGuideTimeline.pose(at: 1.6).travel == 1)
        #expect(AccessGuideTimeline.pose(at: 1.6).on == 0)
        #expect(AccessGuideTimeline.pose(at: 2.0).on == 1)
    }

    @Test func eachMissingPermissionPicksItsPicture() {
        func reading(_ trusted: Bool, _ ready: Bool, _ relaunch: Bool = false,
                     _ mic: AVAuthorizationStatus = .authorized,
                     _ speech: SFSpeechRecognizerAuthorizationStatus = .authorized) -> FirstRunAccessSnapshot {
            FirstRunAccessSnapshot(trusted: trusted, monitorReady: ready, needsRelaunch: relaunch, microphone: mic, speech: speech)
        }
        #expect(reading(false, false).guide == .accessibility)
        #expect(reading(false, true).guide == .accessibility)
        #expect(reading(true, false).guide == nil)                  // the key needs a relaunch, not a switch
        #expect(reading(false, false, true).guide == nil)
        #expect(reading(true, true, false, .notDetermined).guide == .prompt)
        #expect(reading(true, true, false, .authorized, .notDetermined).guide == .prompt)
        #expect(reading(true, true, false, .denied).guide == .microphone)
        #expect(reading(true, true, false, .authorized, .denied).guide == .speechRecognition)
        #expect(reading(true, true).guide == nil)
        // The picture never contradicts the buttons' branch.
        for trusted in [false, true] { for ready in [false, true] { for relaunch in [false, true] {
            let r = reading(trusted, ready, relaunch, .denied)
            #expect((r.guide == nil) == r.relaunchIsNext, "\(r)")
            #expect((r.guide == .accessibility) == (!r.relaunchIsNext && !r.audioIsNext), "\(r)")
        } } }
    }

    @Test func instructionsNameTheButtonOnTheStep() {
        #expect(TokensFirstRunAccessStep.instruction(.accessibility, appName: "Tokens").contains("Open Accessibility Settings"))
        #expect(TokensFirstRunAccessStep.instruction(.microphone, appName: "Tokens").contains("Open Microphone Settings"))
        #expect(TokensFirstRunAccessStep.instruction(.speechRecognition, appName: "Tokens").contains("Open Speech Settings"))
        #expect(TokensFirstRunAccessStep.instruction(.prompt, appName: "Tokens").contains("Allow microphone and speech"))
    }

    @Test func proofFlagsAreClosedInDistributionAndOutsideRenders() {
        let render = ["Tokens", "--render-preview-frames", "/tmp/x"]
        #expect(FirstRunAccessSnapshot.proofOverride(arguments: render + ["--public-preview-access", "speech"], allowed: true)?.guide == .speechRecognition)
        #expect(FirstRunAccessSnapshot.proofOverride(arguments: render + ["--public-preview-access", "speech"], allowed: false) == nil)
        #expect(FirstRunAccessSnapshot.proofOverride(arguments: ["Tokens", "--public-preview-access", "speech"], allowed: true) == nil)
        #expect(FirstRunAccessSnapshot.proofOverride(arguments: render + ["--public-preview-access", "nonsense"], allowed: true) == nil)
        #expect(AccessGuideAnimation.pinned(arguments: render + ["--access-guide-time", "1.8"], allowed: true) == 1.8)
        #expect(AccessGuideAnimation.pinned(arguments: render + ["--access-guide-time", "1.8"], allowed: false) == nil)
        #expect(AccessGuideAnimation.pinned(arguments: ["Tokens", "--access-guide-time", "1.8"], allowed: true) == nil)
        #expect(AccessGuideScene.pinnedDark(arguments: render + ["--access-guide-appearance", "light"], allowed: true) == false)
        #expect(AccessGuideScene.pinnedDark(arguments: render + ["--access-guide-appearance", "dark"], allowed: true) == true)
        #expect(AccessGuideScene.pinnedDark(arguments: render + ["--access-guide-appearance", "dark"], allowed: false) == nil)
        #expect(AccessGuideScene.pinnedDark(arguments: ["Tokens", "--access-guide-appearance", "dark"], allowed: true) == nil)
    }

    @Test @MainActor func theClickVisiblyChangesThePicture() throws {
        _ = NSApplication.shared
        func render(_ pane: AccessGuidePane, at time: Double) throws -> NSBitmapImageRep {
            let size = NSSize(width: 320, height: 210)
            let host = NSHostingView(rootView: AccessGuideScene(pane: pane, pose: AccessGuideTimeline.pose(at: time), name: "Tokens")
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let out = ProcessInfo.processInfo.environment["TOKENS_FIRSTUSE_RENDER_DIR"],
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("access-guide-\(pane.rawValue)-\(time).png"))
            }
            return bitmap
        }
        for pane in AccessGuidePane.allCases {
            let before = try render(pane, at: 0.3)
            let after  = try render(pane, at: AccessGuideTimeline.still)
            let again  = try render(pane, at: AccessGuideTimeline.still)
            #expect(before.tiffRepresentation != after.tiffRepresentation, "\(pane) did not change")
            #expect(after.tiffRepresentation == again.tiffRepresentation, "\(pane) is not deterministic")
            // Not blank: the board and window give more than one colour.
            var colours = Set<UInt32>()
            for x in stride(from: 0, to: after.pixelsWide, by: 7) {
                for y in stride(from: 0, to: after.pixelsHigh, by: 7) {
                    guard let c = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
            #expect(colours.count > 4, "\(pane) rendered \(colours.count) colours")
        }
        // The replica follows the Mac's appearance: dark and light draw different windows.
        func appearance(_ dark: Bool) throws -> Data? {
            let size = NSSize(width: 320, height: 210)
            let host = NSHostingView(rootView: AccessGuideScene(pane: .accessibility, pose: AccessGuideTimeline.pose(at: AccessGuideTimeline.still),
                                                               name: "Tokens", dark: dark).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.tiffRepresentation
        }
        #expect(try appearance(true) != appearance(false))
    }
}

