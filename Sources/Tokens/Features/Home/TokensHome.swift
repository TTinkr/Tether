


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TokensHome — the main window: a sidebar and one page (Home, History, Dictionary, Stats, Settings)


/// The public edition has one task on screen at a time. The private product
/// shell and legacy standalone onboarding deliberately keep their own routes.
/// The Tokens window: a solid rail on the left (never zoomed), a seam, then one working sheet of
/// 56-point graph squares holding the header and one page, all on the same page column.
struct TokensHome: View {
    let coversTitleBar: Bool


    // Setup — pages, state, init and the page switch


    // The six sidebar pages. The raw text is both the sidebar label and the page title. Models is
    // its own tab since build 82, not a page pushed from Settings; it sits
    // after Stats, beside Settings: the pages about your talk first, then the ones that set it up.
    enum Section: String, CaseIterable {
        case home = "Home", history = "History", dictionary = "Dictionary", stats = "Stats", models = "Models", settings = "Settings"
        var symbol: String {
            switch self {
            case .home:       return "house"
            case .history:    return "clock"
            case .dictionary: return "book"
            case .stats:      return "chart.bar"
            case .models:     return "waveform"
            case .settings:   return "gearshape"
            }
        }
    }

    /*
    firstRun: the set-up checklist (no sidebar or header). prompt(id): one saved talk opened full
    size. shortcut: the talk-key picker. While one of these is open, `detail` is non-nil.
    */
    /// A page shown over the selected section, with a way back.
    /// `kit` is the proof-only component specimen (--render-preview-frames --public-preview-page kit).
    enum Detail: Equatable { case firstRun, prompt(UUID), shortcut, kit }

    @ObservedObject var model: TalkModel
    @ObservedObject var audio: AudioCapture
    /// Optional Orukeet state; selected-model readiness is held by speechModels.
    @ObservedObject var orukeetDownload = OrukeetModelDownload.shared
    @ObservedObject var speechModels = SpeechModelStore.shared
    /// The chosen speech model, as Home, Settings and the Models tab show it.
    @AppStorage(SpeechEngineChoice.preferenceKey) var storedSpeechEngine = SpeechEngineChoice.defaultModelID
    @State var section: Section = .home
    @State var detail: Detail?
    /// Pages whose scrolled words fade out under the title (VIS77-02): the list pages and the
    /// Settings sub-pages; not Home, set-up or the specimen.
    var fadesUnderTitle: Bool {
        switch detail {
        case nil: section != .home
        case .prompt, .shortcut: true
        case .firstRun, .kit: false
        }
    }
    @AppStorage(PasteMarkerPreference.key) var showPasteMarker = true
    @AppStorage(PasteCursorRingPreference.key) var showCursorRing = true
    @State var historyQuery    = ""
    @State var dictionaryText  = ""
    @State var dictionarySaved = false
    @State var dictionaryEntry = ""
    @State var dictionaryJustAdded: String?
    // The saved bubble position, loaded once; Settings highlights the matching button.
    @State var bubblePlacement = BubblePlacement.loadPreset()
    // Word counts for the small stat line on Home; refreshStats() recomputes them.
    @State var wordsToday = 0
    @State var wordsTotal = 0
    // First run: which of the two set-up steps is being worked on (see TokensHomeFirstRun.swift).
    @State var firstRunStage = FirstRunStage.access
    // History: true while the "Clear history?" question is showing.
    @State var confirmingClearHistory = false
    @State var backHovered   = false
    @State var sheetZoom: CGFloat = 1
    @AppStorage(TokensTheme.defaultsKey) var themeChoice = TokensTheme.current.rawValue

    /*
    Starting page. In a public build launched with --render-preview-frames and
    --public-preview-page <name>, the window opens straight on that page (history; settings,
    controls, more or connection for Settings; shortcut; dictionary; stats; firstrun, firstrun-access,
    firstrun-done). --public-preview-bubble <edge> draws that bubble position without saving it.
    Otherwise a public build that has
    not finished setup or not accepted this Terms version opens on the first-run page.
    Everything else starts on Home.
    */
    init(model: TalkModel, initialSection: Section = .home, coversTitleBar: Bool = true) {
        self.coversTitleBar = coversTitleBar
        self.model = model
        _section = State(initialValue: initialSection)
        _audio     = ObservedObject(wrappedValue: model.audio)
        let args   = ProcessInfo.processInfo.arguments
        if publicTokens, args.contains("--render-preview-frames"),
           let flag = args.firstIndex(of: "--public-preview-page"), flag + 1 < args.count {
            if let zoomFlag = args.firstIndex(of: "--public-preview-zoom"), zoomFlag + 1 < args.count,
               let zoom = Double(args[zoomFlag + 1]), zoom.isFinite {
                _sheetZoom = State(initialValue: min(TokensSheetZoom.maximum, max(TokensSheetZoom.minimum, zoom)))
            }
            if let edge = TokensBubblePickerPreview.placement { _bubblePlacement = State(initialValue: edge) }
            switch args[flag + 1].lowercased() {
            case "history": _section = State(initialValue: .history)
            case "settings", "controls", "more", "connection": _section = State(initialValue: .settings)
            case "shortcut":
                _section = State(initialValue: .settings)
                _detail  = State(initialValue: .shortcut)
            // "speech-engine" was the Settings sub-page before build 82; both open the Models tab.
            case "models", "speech-engine": _section = State(initialValue: .models)
            case "dictionary": _section = State(initialValue: .dictionary)
            case "stats":      _section = State(initialValue: .stats)
            case "firstrun":   _detail = State(initialValue: .firstRun)
            // The two later set-up steps, for frame proofs: Accessibility waiting, and done.
            case "firstrun-access":
                _detail        = State(initialValue: .firstRun)
                _firstRunStage = State(initialValue: .access)
            case "firstrun-done":
                _detail        = State(initialValue: .firstRun)
                _firstRunStage = State(initialValue: .talk)
            // The component specimen; static, and only in proof-allowed builds.
            case "kit" where ProofRoutes.isAllowed: _detail = State(initialValue: .kit)
            default:           break
            }
        } else if TalkModel.tokensFirstRunPending {
            _detail = State(initialValue: .firstRun)
        }
    }

//
// :)
//
//
    // Compact layout spacing remains independent of the larger printed graph squares.
    var m: CGFloat { TokensUI.module }

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.size
            if detail == .firstRun {
                /*
                First run has no app rail: the whole window is the logical sheet, scaled as one,
                on the plain rail colour. The setup page draws its own rail and grid sheet.
                */
                let sheet = CGSize(width: window.width / sheetZoom, height: window.height / sheetZoom)
                firstRunPage(sheetWidth: sheet.width)
                    .frame(width: sheet.width, height: sheet.height, alignment: .topLeading)
                    .background(TokensUI.paper)
                    .environment(\.tokensSheetSize, sheet)
                    .environment(\.tokensSheetZoom, sheetZoom)
                    .coordinateSpace(name: TokensUI.paperCoordinateSpace)
                    .scaleEffect(sheetZoom, anchor: .topLeading)
                    .frame(width: window.width, height: window.height, alignment: .topLeading)
            } else {
                // 216-wide labelled rail on a window at least 900 wide, else the 72-wide icon rail.
                // The rail is outside the zoom, so its width follows the physical window.
                let railWidth = TokensRail.width(sheetWidth: window.width)
                let sheet = CGSize(width: max(1, window.width - railWidth) / sheetZoom, height: window.height / sheetZoom)
                HStack(alignment: .top, spacing: 0) {
                    sidebar(width: railWidth)
                        .frame(height: window.height, alignment: .top)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(TokensUI.seam).frame(width: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    /*
                    The working sheet: header, then the page slot. Keep the header in the tree on
                    every page: a page slot whose first child is the ScrollView rendered as an
                    alpha-zero hosting view in Release builds (2026-10-13, Home blank).
                    */
                    VStack(alignment: .leading, spacing: 0) {
                        /*
                        Home on a short sheet lifts its hero to rule 2 (TokensHomeHeroStart): the
                        empty Home strip shrinks by one rule and stays in the tree.
                        */
                        if detail == nil, section == .home, TokensHomeHeroStart.liftsHero(sheetHeight: sheet.height) {
                            header()
                                .frame(height: max(0, TokensUI.paperCell - titleBarInset), alignment: .top)
                                .clipped()
                                .zIndex(1)
                        } else {
                            header()
                                .zIndex(1)
                        }
                        Group {
                            switch detail {
                            case .firstRun:       firstRunPage(sheetWidth: sheet.width)
                            case .prompt(let id): promptPage(id)
                            case .shortcut:       shortcutPage
                            case .kit:            kitPage
                            case nil:
                                switch section {
                                case .home:       homePage(inner: sheet.width)
                                case .history:    historyPage
                                case .dictionary: dictionaryPage
                                case .stats:      statsPage
                                case .models:     modelsPage
                                case .settings:   settingsPage
                                }
                            }
                        }
                        // The slot runs to the sheet's bottom; scrolled content stops at the
                        // header's bottom edge (rule 2) and there is no line drawn there.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                        /*
                        Rule 2 is also the title's baseline, so a hard clip there sliced scrolled
                        words into slivers under the title's descenders (VIS77-02). On the list
                        pages scrolled words fade out over the half cell under the title instead;
                        their resting first line sits lower, so nothing at rest is faded. Home is
                        left out: on a short sheet its hero is lifted to that edge. Every tab but Home
                        fades, and so do the detail pages (the old Speech engine page's rows showed
                        through its title in Dev 80).
                        */
                        .mask {
                            VStack(spacing: 0) {
                                LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                                       .init(color: .black, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: fadesUnderTitle ? TokensUI.halfCell : 0)
                                Rectangle()
                            }
                        }
                    }
                    .modifier(TokensSheetSurface(top: titleBarInset))
                    // Laid out at its logical size and scaled: grid and words grow together and
                    // baselines stay on the rules.
                    .frame(width: sheet.width, height: sheet.height, alignment: .topLeading)
                    .environment(\.tokensSheetSize, sheet)
                    .environment(\.tokensSheetZoom, sheetZoom)
                    .coordinateSpace(name: TokensUI.paperCoordinateSpace)
                    .scaleEffect(sheetZoom, anchor: .topLeading)
                    .frame(width: max(1, window.width - railWidth), height: window.height, alignment: .topLeading)
                    // A fractional logical size can leave the scaled sheet a pixel short of the
                    // window's edge; the sheet colour behind it keeps that edge from showing the rail.
                    .background(TokensUI.sheet)
                    .clipped()
                }
                .frame(width: window.width, height: window.height, alignment: .topLeading)
                .background(TokensUI.paper)
            }
        }
        /*
        The rail and the sheet both run under the clear title bar. The window follows the
        theme's appearance. ⌘ or ⌃ with + / = / − / 0 reach the zoom from the keyboard monitor;
        View ▸ Zoom In / Zoom Out / Actual Size reach it through TokensZoomMenuReceiver, which
        only answers for its own window.
        */
        .background { TokensZoomShortcuts(change: changeSheetZoom).frame(width: 0, height: 0) }
        .background { TokensZoomMenuReceiver(zoom: sheetZoom, change: changeSheetZoom).frame(width: 0, height: 0) }

        .ignoresSafeArea(.container, edges: coversTitleBar ? .all : [])
        .preferredColorScheme(TokensUI.isDark ? .dark : .light)
        /*
        On opening, and whenever a talk is added to or removed from history, recompute the word counts;
        opening also loads the personal dictionary text.
        */
        .onAppear {
            refreshStats(); loadDictionary(); refreshFirstRunPresentation()
            // An offscreen fictional-history fixture, never a route through real first-run consent.
            if ProofRoutes.isAllowed, model.isSyntheticRun,
               ProcessInfo.processInfo.arguments.contains("--history-detail-preview"),
               let entry = model.promptHistory.first { detail = .prompt(entry.id) }
            // Offscreen fixture of the red Update wordmark; the offer is fictional and never installs.
            if ProofRoutes.isAllowed, model.isSyntheticRun,
               ProcessInfo.processInfo.arguments.contains("--public-preview-update-notice") {
                model.updater.hasAgreement = { true }
                model.updater.offerUpdate(version: "0.0 fixture", critical: false) { _ in }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFirstRunPresentation()
        }
        .onChange(of: model.promptHistory.count) { _, _ in refreshStats() }
        // Settings ▸ Theme writes this key; a new identity redraws every themed colour at once.
        .id(themeChoice)
    }


    /// One zoom path for ⌘ keys, the View menu and Settings' Text size control: +1, −1, or 0 (100%).
    func changeSheetZoom(_ action: Int) {
        sheetZoom = action == 0 ? 1 : TokensSheetZoom.changed(sheetZoom, by: action)
    }

    /// The proof-only component specimen in the shared page column, scrolling on whole squares.
    var kitPage: some View {
        ScrollView(.vertical) {
            TokensKitSpecimen()
                .tokensPageColumn()
        }
        .tokensRuledScroll()
    }
}

/*
The View menu lives on the app, the zoom lives in each window's TokensHome. Each TokensHome
registers a zero-size receiver; the menu asks the registry for the receiver in the key window,
so Zoom In / Zoom Out / Actual Size change only the window in front, and are disabled (or at
their limits) exactly when that window's own −/100%/+ control would be.
*/
/// Routes View ▸ Zoom In / Zoom Out / Actual Size to the TokensHome in the key window.
@MainActor
enum TokensZoomMenu {
    private static let receivers = NSHashTable<TokensZoomMenuReceiver.ReceiverView>.weakObjects()

    static func register(_ view: TokensZoomMenuReceiver.ReceiverView) { receivers.add(view) }
    static func unregister(_ view: TokensZoomMenuReceiver.ReceiverView) { receivers.remove(view) }

    /// The receiver hosted in the key window, if that window shows a TokensHome.
    static var keyReceiver: TokensZoomMenuReceiver.ReceiverView? {
        // NSApp is nil in unit tests; there is no key window then.
        guard let app = NSApp as NSApplication?, let key = app.keyWindow else { return nil }
        return receivers.allObjects.first { $0.window === key }
    }

    /// Whether the menu action `step` (+1, −1, 0) would do anything in the key window.
    static func canChange(_ step: Int) -> Bool {
        guard let receiver = keyReceiver else { return false }
        switch step {
        case 1:  return receiver.zoom < TokensSheetZoom.maximum - 0.001
        case -1: return receiver.zoom > TokensSheetZoom.minimum + 0.001
        default: return abs(receiver.zoom - 1) > 0.001
        }
    }

    static func change(_ step: Int) { keyReceiver?.change?(step) }
}

/// A zero-size view that tells TokensZoomMenu which window it lives in and its current zoom.
struct TokensZoomMenuReceiver: NSViewRepresentable {
    var zoom: CGFloat
    var change: (Int) -> Void

    func makeNSView(context: Context) -> ReceiverView {
        let view = ReceiverView()
        view.zoom = zoom
        view.change = change
        TokensZoomMenu.register(view)
        return view
    }
    func updateNSView(_ view: ReceiverView, context: Context) {
        view.zoom = zoom
        view.change = change
    }
    static func dismantleNSView(_ view: ReceiverView, coordinator: ()) { TokensZoomMenu.unregister(view) }

    final class ReceiverView: NSView {
        var zoom: CGFloat = 1
        var change: ((Int) -> Void)?
    }
}


/// The working sheet beside the rail: it runs flush to the window's top, right and bottom edges
/// (per the approved design), carries the graph squares, and pads its content below the clear
/// title-bar strip. The rail draws the seam between them.
struct TokensSheetSurface: ViewModifier {
    var active = true
    let top: CGFloat

    func body(content: Content) -> some View {
        if active {
            content
                .padding(.top, top)
                .background { TokensSheetGrid() }
        } else {
            content
        }
    }
}

/*
The working sheet's graph paper (DESIGN.md §4.1): one weight of line, grid ink at the palette's
minor alpha, at x = 56, 112, … and y = 56, 112, … from the sheet's top-left. Nothing is drawn at
0, so no line stacks on the seam or the window top. It sits inside the zoomed sheet, so lines are
1 / zoom logical points: always one screen point, while the squares grow with the words.
*/
struct TokensSheetGrid: View {
    var fill: Color = TokensUI.sheet
    @Environment(\.tokensSheetZoom) private var zoom
    init(fill: Color = TokensUI.sheet) { self.fill = fill }

    var body: some View {
        let ink = TokensUI.gridMinor
        let fill = fill
        let width = 1 / max(zoom, 0.01)
        Canvas(opaque: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(fill))
            let cell = TokensUI.paperCell
            var lines = Path()
            var x = cell
            while x < size.width {
                lines.addRect(CGRect(x: x, y: 0, width: width, height: size.height))
                x += cell
            }
            var y = cell
            while y < size.height {
                lines.addRect(CGRect(x: 0, y: y, width: size.width, height: width))
                y += cell
            }
            context.fill(lines, with: .color(ink))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
