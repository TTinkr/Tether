


//
import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI


// LoginItem — Registers or removes the app from macOS Login Items, once-only default included


// MARK: - Login item eligibility and system status

/// SMAppService pins Login Items to the bundle path, so only a real /Applications install
/// registers; translocated, Downloads-folder and proof-run copies stay out of Login Items.
enum LoginItem {


    // Status and eligibility — what macOS says, and whether this copy may register


    /*
    Saved setting: true once the person has been offered the choice, or has chosen either way.
    It is a name on people's Macs, so it stays as it is. See set(), registerIfEligible() and declineDefault().
    */
    private static let offeredKey = "TTTLoginItemOffered.v1"

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var requiresApproval: Bool { status == .requiresApproval }

    /*
    Only a copy running from /Applications, not a translocated one (a path containing
    /AppTranslocation/), and not a preview or proof run (--render-preview-frames or any
    argument ending in "-proof").
    */
    static var canRegister: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/"), !path.contains("/AppTranslocation/") else { return false }
        return !ProcessInfo.processInfo.arguments.contains { $0 == "--render-preview-frames" || $0.hasSuffix("-proof") }
    }


    // Choosing and launching — set(), the first-run default, launchedAsLoginItem


    /// Returns a user-facing error, or nil on success. Always logs one TTT_EVENT line.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        var failure: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error.localizedDescription
        }
        /*
        Any explicit choice, including off, ends the one-time default.
        This runs even when registering failed, so a failure does not leave the default pending.
        */
        UserDefaults.standard.set(true, forKey: offeredKey)
        let line = "login_item on=\(on) status=\(SMAppService.mainApp.status.rawValue)" + (failure.map { " error=\($0)" } ?? "")
        print("TTT_EVENT \(line)")
        Diagnostics.event(line)
        return failure
    }

    /// First-run default: register once per install, never again after the user has been offered it.
    static func registerIfEligible() {
        guard canRegister, !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)
        set(true)
    }

    /// True once the default was applied or the person chose on/off themselves.
    static var choiceMade: Bool { UserDefaults.standard.bool(forKey: offeredKey) }

//
// :)
//
//
    /// The first-run switch was turned off: never register by default afterwards.
    static func declineDefault() {
        UserDefaults.standard.set(true, forKey: offeredKey)
        Diagnostics.event("login_item declined=first_run")
    }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Only meaningful while the launch Apple event is current (app delegate launch callbacks).
    /// True when macOS opened the app because it is a login item (the launch event's reason is
    /// "launched as login item"); AppDelegate then keeps the main window closed.
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication,
              let reason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue else { return false }
        return reason == keyAELaunchedAsLogInItem
    }


}


// LoginItemRow — The Settings row with the start-at-login switch, in two looks


struct LoginItemRow: View {


    // State and wiring — what the row remembers, and when it refreshes


    // Read on appear and activation, not on every parent render (each read is an XPC call).
    @State private var enabled          = false
    @State private var requiresApproval = false
    @State private var errorText        = ""

    static let label = "Open Tokens when your Mac starts"

    /// Draws the row in pencil for the Tokens window; the system Settings pane keeps the standard look.
    var pencil = false

    var body: some View {
        Group {
            if pencil { pencilRow } else { standardRow }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /*
    The switch is bound to the real system state (`enabled`); turning it calls LoginItem.set and
    then re-reads the state, so the switch shows what macOS actually did. On failure the row
    shows fixed words and the raw error goes to the log.
    */
    private var isOn: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { on in
                // The raw error is logged by set(); the row shows fixed words.
                errorText = LoginItem.set(on) == nil ? "" : "That didn't work. Try Login Items."
                refresh()
            })
    }


    // The two looks — pencilRow (Tokens window) and standardRow (system Settings)


    /*
    Both looks show the same three things: the switch (disabled when this copy cannot register),
    a "drag into Applications" note when it cannot, and, when approval is needed or an error
    occurred, a note with a button that opens Login Items.
    */
    private var pencilRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: TokensUI.module) {
                TokensLabel(Self.label)
                Spacer(minLength: 0)
                Toggle(Self.label, isOn: isOn)
                    .toggleStyle(TokensToggleStyle())
                    .disabled(!LoginItem.canRegister)
            }
            if !LoginItem.canRegister {
                TokensParagraph("Drag Tokens into Applications to use this.", size: 13, ink: .secondary)
            } else if requiresApproval || !errorText.isEmpty {
                HStack(alignment: .bottom, spacing: TokensUI.module) {
                    TokensParagraph(requiresApproval ? "Almost: allow Tokens in Login Items." : errorText,
                                    size: 13, ink: .secondary)
                    Spacer(minLength: 0)
                    TokensButton("Open Login Items", kind: .quiet) { LoginItem.openLoginItems() }
                }
            }
        }
    }

//
// :)
//
//
    private var standardRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Self.label).font(.system(size: 13))
                Spacer()
                Toggle(Self.label, isOn: isOn)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(Color(white: 0.11))
                    .disabled(!LoginItem.canRegister)
            }
            if !LoginItem.canRegister {
                note("Drag Tokens into Applications to use this.")
            } else if requiresApproval || !errorText.isEmpty {
                HStack(spacing: 6) {
                    note(requiresApproval ? "Almost: allow Tokens in Login Items." : errorText)
                    Button("Open Login Items") { LoginItem.openLoginItems() }
                        .font(.system(size: 10)).buttonStyle(.link)
                }
            }
        }
    }

    // Re-reads the state from macOS. Clears an old error once the switch is actually on.
    private func refresh() {
        enabled          = LoginItem.isEnabled
        requiresApproval = LoginItem.requiresApproval
        if enabled { errorText = "" }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }


}

