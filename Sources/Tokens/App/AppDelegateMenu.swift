


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


extension AppDelegate {


    // Menu-bar item and showing windows — status item, bubble, main window


    /// Menu bar presence: the app keeps working with its window closed, so it needs a way back.
    /// The icon is the logo's π (LogoPi, the app icon's own drawing; build 82; not "Tk"), a
    /// template image macOS tints for light or dark menu bars. Dev builds add the word "Dev".
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = LogoPi.templateImage()
        item.button?.setAccessibilityLabel(appName)
        if DevChannel.isActive {
            item.button?.title = "Dev"
            item.button?.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open \(appName)", action: #selector(statusOpen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Last Talk", action: #selector(statusCopyLatest), keyEquivalent: "").target = self
        menu.addItem(withTitle: "How to Use \(appName)", action: #selector(statusHowTo), keyEquivalent: "").target = self
        // Default off and quiet: one checkmark item, no sheet or alert (ScreenReferenceSampler).
        let reference = NSMenuItem(title: "Note On-Screen File When Mentioned",
                                   action: #selector(statusToggleScreenReference(_:)), keyEquivalent: "")
        reference.target = self
        reference.state  = ScreenReferenceSampler.isEnabled ? .on : .off
        menu.addItem(reference)
        // Default off: agent names are corrected only after the person asks (AgentNameFixes).
        let agentNames = NSMenuItem(title: "Fix Agent Names (Claude Code, Codex)",
                                    action: #selector(statusToggleAgentNameFixes(_:)), keyEquivalent: "")
        agentNames.target = self
        agentNames.state  = AgentNameFixes.isEnabled ? .on : .off
        menu.addItem(agentNames)
        // Read-only numbers window (Features/VoiceLedger): built from in-memory history on open.
        menu.addItem(withTitle: "Your voice…", action: #selector(statusVoiceLedger), keyEquivalent: "").target = self
        if model.updater.isConfigured {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(statusCheckUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu  = menu
        statusItem = item
        // Called once at launch on the main thread, like the rest of installStatusItem.
        MainActor.assumeIsolated { ScreenReferenceSampler.shared.attach(to: model) }
    }

    /*
    View ▸ Zoom In (⌘+, also ⌘=), Zoom Out (⌘−), Actual Size (⌘0) in the app's main menu. They
    drive the same changeSheetZoom as Settings' Text size control, in the key window only.
    SwiftUI owns the main menu and may rebuild it, so this is idempotent and is re-run whenever
    the window is made or shown. In a Tokens window the window's own key monitor answers the
    keys first; the menu items are what a click (or another window) reaches.
    */
    func installViewMenu() {
        guard publicTokens else { return }
        DispatchQueue.main.async { TokensViewMenu.install() }
    }

    @objc private func statusOpen() { showStyleChooser() }
    @objc private func statusCopyLatest() { model.copyLatestTranscript() }
    // The one web page the menu opens: the one-page tutorial.
    @objc private func statusHowTo() { NSWorkspace.shared.open(LaunchLinks.tutorial) }
    /*
    Checks, then answers in a small card under the menu-bar icon (build 81: the answer only
    changed Settings → About, so with Home closed the click showed nothing at all). The card has
    the same choices as Settings → About; a found update still needs its explicit Install.
    */
    @objc private func statusCheckUpdates() {
        model.updater.check()
        MainActor.assumeIsolated { UpdateCheckPopover.shared.show(updater: model.updater, below: statusItem?.button) }
    }
    // Flips the opt-in key; titles are sampled only while it is on.
    @objc private func statusToggleScreenReference(_ sender: NSMenuItem) {
        ScreenReferenceSampler.isEnabled.toggle()
        sender.state = ScreenReferenceSampler.isEnabled ? .on : .off
    }
    // Flips the opt-in agent-name corrections; the raw path is faithful while it is off.
    @objc private func statusToggleAgentNameFixes(_ sender: NSMenuItem) {
        AgentNameFixes.isEnabled.toggle()
        sender.state = AgentNameFixes.isEnabled ? .on : .off
    }

    @objc private func statusVoiceLedger() {
        MainActor.assumeIsolated { VoiceLedgerWindowController.shared.show(history: model.promptHistory) }
    }

    // Brings the bubble to the front without making it the key window.
    func showCompactWindow(reason: String) {
        guard let window = surfaceWindow else { return }
        window.presentRequested()
        print("TTT_EVENT compact_shown reason=\(reason) frame=\(NSStringFromRect(window.frame))")
    }

    /*
    Shows the main window: makes it, activates the app, restores it if minimized, and turns the
    input preview on unless the first-run card is pending.
    */
    func showStyleChooser() {
        let window  = styleWindow ?? makeStyleWindow()
        styleWindow = window
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        installViewMenu()
        if !tokensFirstRunPending { model.setInputPreviewVisible(true) }
        print("TTT_EVENT style_chooser_shown style=\(model.dictationStyle.rawValue)")
    }


}


// UpdateCheckPopover — the answer to the menu bar's Check for Updates… (build 81)


/*
A small card under the menu-bar icon showing the updater's one line: "Checking…", "You're up
to date", an error to retry, or the update with Later and Install. It follows the updater
live and closes when the person clicks anywhere else. Nothing installs from opening it.
*/
@MainActor
final class UpdateCheckPopover {
    static let shared = UpdateCheckPopover()
    private var popover: NSPopover?

    func show(updater: Updater, below button: NSStatusBarButton?) {
        guard let button else { return }
        popover?.close()
        let hosting = NSHostingController(rootView: UpdateCheckCard(updater: updater))
        hosting.sizingOptions = .preferredContentSize
        let card = NSPopover()
        card.behavior = .transient
        card.appearance = NSAppearance(named: TokensUI.isDark ? .darkAqua : .aqua)
        card.contentViewController = hosting
        popover = card
        // Tokens has no Dock icon; make it active so the card's buttons take the first click.
        NSApp.activate(ignoringOtherApps: true)
        card.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

/*
The card: the π mark and the updater's one line, then the same choices as Settings → About's
update row (Later and Install for a found update, Restart, Cancel, or Check). Laid out for a
small card rather than the ruled Settings page, on the window's sheet colour.
*/
struct UpdateCheckCard: View {
    @ObservedObject var updater: Updater
    static let width: CGFloat = 360
    private static let piLine: CGFloat = 1.5
    private static let piSize = LogoPi.size(inkHeight: NSFont.systemFont(ofSize: 15, weight: .medium).capHeight,
                                            lineWidth: piLine)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LogoPi()
                    .stroke(TokensUI.red, style: StrokeStyle(lineWidth: Self.piLine, lineCap: .round, lineJoin: .round))
                    .frame(width: Self.piSize.width, height: Self.piSize.height)
                    .padding(Self.piLine / 2)
                    .alignmentGuide(.firstTextBaseline) { $0.height }
                    .accessibilityHidden(true)
                Text(updater.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TokensUI.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tokens.update.card.status")
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if updater.available {
                    Button("Later") { updater.dismissAvailable() }.buttonStyle(TokensQuietButtonStyle())
                    Button("Install") { updater.installAvailable() }.buttonStyle(TokensPrimaryButtonStyle())
                } else if updater.canRetryRestart {
                    Button("Restart \(appName)") { updater.retryRestart() }.buttonStyle(TokensPrimaryButtonStyle())
                } else if updater.canCancel {
                    Button("Cancel") { updater.cancel() }.buttonStyle(TokensQuietButtonStyle())
                } else {
                    Button("Check") { updater.check() }
                        .buttonStyle(TokensQuietButtonStyle())
                        .disabled(updater.busy)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: Self.width, alignment: .leading)
        .background(TokensUI.sheet)
        .preferredColorScheme(TokensUI.isDark ? .dark : .light)
    }
}

//
// :)
//
//
/// Main-menu View ▸ Zoom In / Zoom Out / Actual Size for the Tokens window's sheet zoom.
@MainActor
final class TokensViewMenu: NSObject, NSMenuItemValidation {
    static let shared = TokensViewMenu()
    static let zoomInID     = NSUserInterfaceItemIdentifier("tokens.view.zoomIn")
    static let zoomInAltID  = NSUserInterfaceItemIdentifier("tokens.view.zoomIn.equals")
    static let zoomOutID    = NSUserInterfaceItemIdentifier("tokens.view.zoomOut")
    static let actualSizeID = NSUserInterfaceItemIdentifier("tokens.view.actualSize")
    private static var keyObserver: NSObjectProtocol?

    /// Adds the items to the main menu's View menu (creating it before Window if SwiftUI has
    /// none). Safe to call repeatedly; also re-checks whenever a window becomes key, because
    /// SwiftUI may rebuild the main menu.
    static func install() {
        if keyObserver == nil {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { _ = TokensViewMenu.addItems() } }
        }
        addItems()
    }

    /// Builds the three zoom items into `mainMenu`'s View menu. Returns the View menu.
    @discardableResult
    static func addItems(to menu: NSMenu? = nil) -> NSMenu? {
        guard let mainMenu = menu ?? (NSApp as NSApplication?)?.mainMenu else { return nil }
        let view: NSMenu
        if let existing = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu {
            view = existing
        } else {
            view = NSMenu(title: "View")
            let holder = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            holder.submenu = view
            let window = mainMenu.items.firstIndex { $0.submenu?.title == "Window" }
            mainMenu.insertItem(holder, at: window ?? min(3, mainMenu.items.count))
        }
        guard !view.items.contains(where: { $0.identifier == zoomInID }) else { return view }
        let items = [
            item("Actual Size", "0", actualSizeID, #selector(actualSize(_:))),
            item("Zoom In", "+", zoomInID, #selector(zoomIn(_:))),
            item("Zoom In", "=", zoomInAltID, #selector(zoomIn(_:)), hidden: true),
            item("Zoom Out", "-", zoomOutID, #selector(zoomOut(_:))),
        ]
        for (offset, menuItem) in items.enumerated() { view.insertItem(menuItem, at: offset) }
        if view.items.count > items.count { view.insertItem(.separator(), at: items.count) }
        return view
    }

    private static func item(_ title: String, _ key: String, _ id: NSUserInterfaceItemIdentifier,
                             _ action: Selector, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.identifier = id
        item.target = shared
        // ⌘= is the unshifted ⌘+ on most keyboards: it works without a second visible row.
        if hidden { item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true }
        return item
    }

    @objc func zoomIn(_ sender: Any?) { TokensZoomMenu.change(1) }
    @objc func zoomOut(_ sender: Any?) { TokensZoomMenu.change(-1) }
    @objc func actualSize(_ sender: Any?) { TokensZoomMenu.change(0) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)):     return TokensZoomMenu.canChange(1)
        case #selector(zoomOut(_:)):    return TokensZoomMenu.canChange(-1)
        case #selector(actualSize(_:)): return TokensZoomMenu.canChange(0)
        default:                        return true
        }
    }
}

