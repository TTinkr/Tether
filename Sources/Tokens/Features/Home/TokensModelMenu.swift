
import SwiftUI
import TokensCore

struct TokensModelMenu: View {
    enum Look { case home, settings }

    let look: Look
    @ObservedObject var store: SpeechModelStore
    /// A talk is capturing or finishing: switching waits.
    var talking = false
    /// The model the running talk uses (its engine was fixed when it started); nil when idle.
    var talkingWith: String? = nil
    /// Switches the model; the parent checks the talk phase again at the moment of the click,
    /// since a menu can be opened before a talk starts and clicked after.
    let choose: (String) -> Void
    /// Opens the Models tab.
    let manage: () -> Void
    /// Render fixtures only: what the line shows instead of the store's answer.
    var shown: TokensHomeEngine? = nil

    @AppStorage(SpeechEngineChoice.preferenceKey)
    private var storedChoice = SpeechEngineChoice.defaultModelID
    @State private var hovered = false

    /// The models this Mac can use right now, in catalogue order.
    static func offered(_ store: SpeechModelStore) -> [SpeechModelEntry] {
        SpeechModelCatalog.all.filter { entry in
            switch store.state(for: entry.id) { case .builtIn, .ready: true; default: false }
        }
    }

    /// Keep the person's selection while its model is downloading or unavailable.
    static func inUse(_ store: SpeechModelStore) -> String {
        SpeechEngineChoice.selectedModelID()
    }

    var body: some View {
        _ = storedChoice  // redraw when the choice changes
        // During a talk the line and the check name the engine that talk started with, even if a
        // download finishes meanwhile (review, 2026-10-17).
        let session = talkingWith.flatMap(SpeechModelCatalog.entry)
        let engine = shown ?? session.map { TokensHomeEngine(name: $0.name, pill: nil) } ?? TokensHomeEngine.current(store: store)
        let current = talkingWith ?? Self.inUse(store)
        return Menu {
            if talking {
                Text("Finish this talk to switch")
            }
            Picker("Speech model", selection: Binding(get: { current }, set: { id in
                // Clicking the checked model changes nothing: it used to save Apple over a chosen
                // model still downloading (review, 2026-10-17).
                guard !talking, id != current else { return }
                choose(id)
            })) {
                ForEach(Self.offered(store)) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(talking)
            Divider()
            Button("Manage models…", action: manage)
        } label: {
            label(engine)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .modifier(MenuLook(look: look))
        .fixedSize()
        .onHover { hovered = $0 }
        .help(talking ? "Finish this talk to switch models" : "Choose the speech model")
        .accessibilityLabel("Speech model")
        .accessibilityValue(engine.name + (engine.pill.map { ", " + $0 } ?? ""))
        .accessibilityHint(talking ? "Finish this talk to switch" : "Opens the list of models on this Mac")
        .accessibilityIdentifier(look == .home ? "tokens.home.speech-model" : "tokens.settings.speech-engine")
    }

    @ViewBuilder private func label(_ engine: TokensHomeEngine) -> some View {
        switch look {
        case .home:
            // A menu's label keeps only text and a symbol, so the download pill sits beside the menu
            // (TokensHomeEngineLine), not in it.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(engine.name)
                    .font(TokensType.labelLarge)
                    .foregroundStyle(TokensUI.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hovered ? TokensUI.ink : TokensUI.secondary)
                    .padding(.leading, 8)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        case .settings:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(engine.name)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TokensUI.secondary)
            }
        }
    }

    private struct MenuLook: ViewModifier {
        let look: Look
        func body(content: Content) -> some View {
            switch look {
            case .home: content.buttonStyle(.plain)
            case .settings: content.buttonStyle(TokensQuietButtonStyle())
            }
        }
    }
}
