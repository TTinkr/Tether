


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


extension AppDelegate {


    // Launch helpers — second-launch hand-over, argument lookup, proof frames


    /*
    If another copy of this app (same bundle identifier, different process, still alive) is
    running: end this duplicate launch. Request setup/Home and activate the existing copy
    only while setup is pending or for retained products; accepted public Tokens stays quiet.
    */
    func redirectToExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID && !$0.isTerminated }) else { return false }
        print("TTT_EVENT duplicate_launch_redirect existing_pid=\(existing.processIdentifier)")
        if shouldPresentHomeOnReopen {
            DistributedNotificationCenter.default().postNotificationName(
                Self.reopenNotification,
                object: bundleIdentifier,
                userInfo: ["target_pid": NSNumber(value: existing.processIdentifier)],
                deliverImmediately: true
            )
            _ = existing.activate(options: [])
        }
        NSApp.terminate(nil)
        return true
    }

    // The command-line word right after `flag`, or nil if the flag is missing or is the last word.
    func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /*
    Writes numbered PNG files of the window (frame-00000.png and so on) at `framesPerSecond`
    for `duration` seconds into `directoryPath`, then quits the app. Used by the preview and
    proof launches above; the timer is kept in `proofTimer` so it is not released early.
    */
    func renderProofFrames(
        window: NSWindow,
        to directoryPath: String,
        framesPerSecond: Double,
        duration: Double
    ) {
        guard let view = window.contentView else { return }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frameCount = Int(duration * framesPerSecond)
        var frame      = 0
        let timer      = DispatchSource.makeTimerSource(queue: .main)
        proofTimer     = timer
        timer.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
        timer.setEventHandler { [weak self, weak view] in
            guard let self, let view else { return }
            view.layoutSubtreeIfNeeded()
            // This opt-in offscreen proof exposes Settings' real footer without touching
            // a running app, requesting permissions, or changing saved scroll positions.
            // Two layout passes cover SwiftUI's deferred scroll-document sizing.
            // --preview-scroll-rows <n> stops n whole paper rows from the top instead, so a
            // middle row (the bubble picker) can be inspected with its words still on rules.
            let scrollRows = self.argumentValue(after: "--preview-scroll-rows").flatMap(Double.init)
            if (frame == 6 || frame == 12),
               ProcessInfo.processInfo.arguments.contains("--settings-footer-preview") || scrollRows != nil {
                func scrollViews(in root: NSView) -> [NSScrollView] {
                    (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap { scrollViews(in: $0) }
                }
                if let scroll = scrollViews(in: view).max(by: {
                    ($0.documentView?.bounds.height ?? 0) - $0.contentView.bounds.height <
                    ($1.documentView?.bounds.height ?? 0) - $1.contentView.bounds.height
                }), let document = scroll.documentView {
                    let range = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    let fromTop = scrollRows.map { min(range, CGFloat(max(0, $0)) * TokensUI.paperCell) } ?? range
                    let bottom = document.isFlipped
                        ? document.bounds.minY + fromTop
                        : document.bounds.maxY - scroll.contentView.bounds.height - fromTop
                    scroll.contentView.scroll(to: NSPoint(x: document.bounds.minX, y: bottom))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    view.layoutSubtreeIfNeeded()
                    if frame == 12 { print("PREVIEW scrolled \(fromTop) pt; offscreen layout proof only") }
                }
            }
            let bounds = view.bounds
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width),
                pixelsHigh: Int(bounds.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return }
            bitmap.size = bounds.size
            view.cacheDisplay(in: bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let name = String(format: "frame-%05d.png", frame)
                try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
            frame += 1
            if frame >= frameCount {
                timer.cancel()
                self.proofTimer = nil
                NSApp.terminate(nil)
            }
        }
        timer.resume()
    }


}

