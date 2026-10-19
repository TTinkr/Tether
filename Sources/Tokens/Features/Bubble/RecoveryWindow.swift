
import AppKit
import SwiftUI

/// Owns immutable recovery payloads independently of the active talk's reset lifecycle.
final class RecoveryWindowController: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSPanel] = [:]
    static let defaultSize = NSSize(width: 520, height: 360)
    static let minimumSize = NSSize(width: 400, height: 280)

    /// `screenFrame` is the destination's screen (or the bubble's); nil means the screen with focus.
    @discardableResult
    func present(id: UUID, text: String, message: String, screenFrame: NSRect? = nil, show: Bool = true) -> NSPanel {
        if let existing = windows[id] {
            if show { existing.orderFrontRegardless() }
            return existing
        }
        let panel = RecoveryPanel(contentRect: NSRect(x: 0, y: 0, width: Self.defaultSize.width, height: Self.defaultSize.height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Tokens"
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(TokensUI.sheet)
        panel.identifier = NSUserInterfaceItemIdentifier("tokens.recovery.\(id.uuidString)")
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = false
        panel.appearance = NSAppearance(named: TokensUI.isDark ? .darkAqua : .aqua)
        panel.hidesOnDeactivate = false
        // Words waiting to be copied stay visible when Tokens is hidden (build 81).
        panel.canHide = false
        panel.minSize = Self.minimumSize
        panel.delegate = self
        let content = RecoveryContent(text: text, message: message)
        panel.contentView = content
        /*
        On the Space being looked at, beside a full-screen Claude, Codex or Chrome, and above
        ordinary windows like the bubble (build 81: it opened on another desktop Space while the
        bubble had already gone, so the words looked lost).
        */
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.level = .floating
        windows[id] = panel
        /*
        Centred on the screen the talk was meant for. center() alone used the panel's own starting
        screen or the main one, so with two displays the pop-up could open on the other monitor
        just as the bubble left (build 81). A pop-up the user has moved keeps its place on reshow.
        */
        if let visible = tokensTargetScreen(for: screenFrame)?.visibleFrame {
            panel.setFrameOrigin(Self.origin(size: panel.frame.size, visible: visible, cascade: windows.count - 1))
        } else {
            panel.center()
            if windows.count > 1 {
                let step = CGFloat((windows.count - 1) % 6) * 24
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX + step, y: panel.frame.minY - step))
            }
        }
        // Do not activate Tokens or take the insertion focus from the destination.
        if show { panel.orderFrontRegardless() }
        return panel
    }

    /*
    Where a new pop-up goes on a screen: centred across, a little above the middle (as center()
    does), each further open pop-up stepped down and right so none hides another, and always
    inside the visible area with its title bar on screen.
    */
    static func origin(size: NSSize, visible: NSRect, cascade: Int) -> NSPoint {
        let step = CGFloat(max(0, cascade) % 6) * 24
        let x = visible.midX - size.width / 2 + step
        let y = visible.midY - size.height / 2 + visible.height / 10 - step
        return NSPoint(x: max(min(x, visible.maxX - size.width), visible.minX),
                       y: min(max(y, visible.minY), visible.maxY - size.height))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

private final class RecoveryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Immutable payload shared by the native selectable editor and explicit copy control.
final class RecoveryContent: NSView {
    let document: RecoveryDocument
    var payload: String { document.payload }
    var copyTitle: String { document.copyTitle }
    var textView: NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(self)
    }

    init(text: String, message: String) {
        document = RecoveryDocument(payload: text)
        super.init(frame: NSRect(origin: .zero, size: RecoveryWindowController.defaultSize))
        appearance = NSAppearance(named: TokensUI.isDark ? .darkAqua : .aqua)
        // The first click on Copy or Close acts at once; it used to only focus the panel (build 81).
        let host = FirstMouseHostingView(rootView: RecoverySurface(document: document,
            presentation: RecoveryPresentation(message: message),
            close: { [weak self] in self?.window?.close() }))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult func copyAll(to pasteboard: NSPasteboard) -> Bool { document.copyAll(to: pasteboard) }
}

final class RecoveryDocument: ObservableObject {
    let payload: String
    @Published var copyTitle = "Copy to clipboard"
    init(payload: String) { self.payload = payload }
    /// The same action in fewer words, for when the full title does not fit the button.
    var compactCopyTitle: String { Self.compactTitle(for: copyTitle) }
    /*
    At the pop-up's smallest size the button is too narrow for "Copy to clipboard" (it showed
    "Copy to clip…", which hides what the button does) or for "Try copying again". These shorter
    titles still say the whole action (build 81).
    */
    static func compactTitle(for title: String) -> String {
        switch title {
        case "Copy to clipboard": return "Copy words"
        case "Try copying again": return "Copy again"
        default: return title
        }
    }
    @discardableResult func copyAll(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(payload, forType: .string) else {
            copyTitle = "Try copying again"
            return false
        }
        copyTitle = "Copied"
        return true
    }
}

/// Keep failure, uncertainty and partial delivery distinct without exposing diagnostic jargon.
/// Generic paste failures do not prove that a text field was missing.
struct RecoveryPresentation: Equatable {
    let headline: String
    let caution: String?

    init(message: String) {
        let status = message.replacingOccurrences(of: " · Copy latest", with: "")
            .replacingOccurrences(of: " · Copy captured words", with: "")
        switch status {
        /*
        The microphone or speech stopped mid-talk, or the last words never finished decoding:
        the words were kept but never pasted, and the end may be missing. "Transcript held" is
        the older name. Both used to fall through to the neutral line below (build 81).
        */
        case "Talk stopped early", "Transcript held":
            headline = "Your talk stopped before pasting."
            caution = "Some words may be missing."
        // The early π marker already went into the text box; the words after it did not (build 81).
        case "Final words unavailable":
            headline = "We couldn’t finish pasting your talk."
            caution = "Check the text box before pasting again."
        case "Paste sent · not confirmed":
            headline = "We couldn’t confirm your paste."
            caution = "Check the text box before pasting again."
        case "Not sent · paste not confirmed":
            // Auto-send or a Return pressed after Stop was held back (TalkModel.unconfirmedPasteMessage, build 81).
            headline = "Not sent. We couldn’t confirm your paste."
            caution = "Check the text box before pasting again."
        case "Partial text inserted":
            headline = "Only part of your words pasted."
            caution = "Check the text box before pasting again."
        case "Text inserted · Send unavailable":
            headline = "Your words pasted, but weren’t sent."
            caution = "Check the text box before pasting again."
        case "No text box selected", "No destination found":
            headline = "We couldn’t find a place to paste."
            caution = nil
        case "Paste unavailable":
            headline = "We couldn’t paste your words."
            caution = nil
        case "Microphone stopped":
            headline = "Your microphone stopped."
            caution = nil
        default:
            headline = "Your words are ready to copy."
            caution = nil
        }
    }
}

/// The pop-up's side margins and button gap, shared with the tests that check the buttons fit.
enum RecoveryLayout {
    static let sideMargin: CGFloat = 24
    static let buttonGap: CGFloat = 12
    /// Each of the two equal buttons gets half the row between the margins.
    static func buttonWidth(contentWidth: CGFloat) -> CGFloat {
        (contentWidth - 2 * sideMargin - buttonGap) / 2
    }
}

private struct RecoverySurface: View {
    @ObservedObject var document: RecoveryDocument
    let presentation: RecoveryPresentation
    let close: () -> Void
    private static let piLine: CGFloat = 1.6
    private static let piSize = LogoPi.size(inkHeight: NSFont.systemFont(ofSize: 17, weight: .medium).capHeight,
                                            lineWidth: piLine)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LogoPi()
                    .stroke(TokensUI.red, style: StrokeStyle(lineWidth: Self.piLine, lineCap: .round, lineJoin: .round))
                    .frame(width: Self.piSize.width, height: Self.piSize.height)
                    .padding(Self.piLine / 2)
                    .alignmentGuide(.firstTextBaseline) { $0.height }
                    .accessibilityHidden(true)
                Text(presentation.headline)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TokensUI.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier("tokens.recovery.explanation")
            }
            if let caution = presentation.caution {
                Text(caution)
                    .font(TokensType.caption)
                    .foregroundStyle(TokensUI.secondary)
                    .padding(.top, 4)
            }
            RecoveryTranscriptEditor(text: document.payload)
                .frame(minHeight: 96)
                .background(TokensUI.card, in: RoundedRectangle(cornerRadius: TokensUI.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: TokensUI.cardRadius, style: .continuous)
                        .strokeBorder(TokensUI.panelEdge, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: TokensUI.cardRadius, style: .continuous))
                .padding(.top, 16)
                .accessibilityIdentifier("tokens.recovery.text")
            // Two large buttons, nothing else (2026-10-15): copy, or close. Copy never closes it.
            HStack(spacing: RecoveryLayout.buttonGap) {
                Button {
                    _ = document.copyAll(to: .general)
                } label: {
                    /*
                    The full title whenever it fits, else the shorter one: never a cut-off label
                    (build 81). Only the shown title is in the view, so VoiceOver and Voice Control
                    hear the same words the button shows.
                    */
                    ViewThatFits(in: .horizontal) {
                        RecoveryCopyLabel(title: document.copyTitle)
                        RecoveryCopyLabel(title: document.compactCopyTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TokensPrimaryButtonStyle(size: .large))
                .keyboardShortcut(.defaultAction)
                .help(presentation.caution ?? "Copy everything you said.")
                .accessibilityHint(["Copies everything you said, including text outside the visible area.", presentation.caution]
                    .compactMap { $0 }.joined(separator: " "))
                .accessibilityIdentifier("tokens.recovery.copy")
                Button(action: close) {
                    Label("Close", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(TokensQuietButtonStyle(size: .large))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("tokens.recovery.close")
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, RecoveryLayout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TokensUI.sheet)
        .preferredColorScheme(TokensUI.isDark ? .dark : .light)
    }
}


/// The copy button's title and icon; a check once the words are copied.
struct RecoveryCopyLabel: View {
    let title: String
    var body: some View {
        Label(title, systemImage: title == "Copied" ? "checkmark" : "doc.on.doc")
    }
}

/// Recovery starts at the first readable row immediately. Unlike the general writing editor,
/// it has no extra leading caret row and requires no delayed scroll to reveal saved text.
private struct RecoveryTranscriptEditor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
                guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.lineFragmentPadding = 12
        view.layoutManager?.usesFontLeading = false
        view.textContainerInset = NSSize(width: 0, height: 10)
        view.selectedTextAttributes = [.backgroundColor: TokensInk.secondary.nsColor.withAlphaComponent(0.2)]
        view.setAccessibilityLabel("Complete recovered transcript")
        update(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        update(view)
    }

    private func update(_ view: NSTextView) {
        view.string = text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        view.textStorage?.setAttributes([.font: NSFont.systemFont(ofSize: 15),
                                         .foregroundColor: TokensInk.primary.nsColor,
                                         .paragraphStyle: paragraph],
                                        range: NSRange(location: 0, length: (text as NSString).length))
        view.sizeToFit()
    }
}
