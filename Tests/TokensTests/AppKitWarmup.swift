// Warms AppKit on the main thread before any test runs.
//
// Full parallel runs can deadlock: a background suite's
// first NSFont use ran +[NSFont initialize], which posts a notification and waits for main, while
// main was blocked in +[NSApplication sharedApplication] on the Objective-C class-init lock.
// Swift Testing builds every suite's traits while planning, before the first test starts, so the
// `.appKitWarmup` trait on any one suite initialises these AppKit and TextKit classes on main
// exactly once, first. A later class-init deadlock in another AppKit class: add it to `warmed`.
import AppKit
import Testing

struct AppKitWarmup: SuiteTrait {
    private static let warmed: Void = {
        let work = {
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                _ = NSFont.systemFont(ofSize: 13)
                _ = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                // TextKit: NSLayoutManager's first layout initialises NSParagraphArbitrator, whose
                // +initialize registers defaults and waits on main.
                let storage = NSTextStorage(string: "Warm up TextKit.\nSecond line.",
                                            attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                         .paragraphStyle: NSParagraphStyle.default])
                let layout = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: 200, height: 200))
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                layout.ensureLayout(for: container)
                _ = NSAttributedString(string: "Warm", attributes: [.font: NSFont.systemFont(ofSize: 13)])
                    .boundingRect(with: NSSize(width: 200, height: 200), options: [.usesLineFragmentOrigin])
                _ = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
                _ = NSTextField(labelWithString: "Warm")
                _ = NSColor.labelColor.cgColor
                _ = NSImage(size: NSSize(width: 1, height: 1))
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }()

    static func warm() { _ = warmed }
}

extension Trait where Self == AppKitWarmup {
    /// Initialises NSApplication and NSFont on main while the test plan is built.
    static var appKitWarmup: Self {
        AppKitWarmup.warm()
        return AppKitWarmup()
    }
}
