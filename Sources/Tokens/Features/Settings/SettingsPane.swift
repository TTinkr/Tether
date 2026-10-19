


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// OllamaStatusLine — whether the optional local model is reachable, checked on appearance


/// Whether the optional local model is reachable, probed each time Settings appears.
struct OllamaStatusLine: View {
    @ObservedObject var asides: TokenPauseAsides

    var body: some View {
        /*
        One selectable line of text from the pause-aside helper. It asks that helper to check again
        whether the local model is present every time the line appears.
        */
        VStack(alignment: .leading, spacing: 1) {
            Text(asides.ollamaStatusLine)
                .textSelection(.enabled)
        }
        .font(TokensType.caption)
        .foregroundStyle(TokensUI.secondary)
        .onAppear { asides.refreshOllamaPresence() }
        .accessibilityElement(children: .combine)
    }
}


// SettingsPane — Cmd-, window: launch at login, Live notes, local-model status, version


/// Cmd-, in the public app: the launch-at-login off switch, background-listening consent and the version.
struct SettingsPane: View {
    @ObservedObject var model: TalkModel

    /*
    Rows: the launch-at-login switch, the keep-mic-on switch (enabling locked while a talk is running),
    the local-model status, the version and build, "No account needed." and Quit. The switch
    uses the fresh-consent binding, the same setting the Settings page calls "Keep the mic
    on between talks".
    */
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TokensCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    TokensLoginSwitchRow()
                    TokensHairline()
                    // The launch exposes no typing/questions panel toggle. Empty label: see TokensHomeSettings.
                    TokensSettingsRow(title: "Keep the mic on between talks", caption: model.ambientStatus) {
                        Toggle(isOn: model.backgroundListeningBinding) { EmptyView() }
                            .toggleStyle(TokensSwitchStyle())
                            .disabled((model.phase == .capturing || model.phase == .finalizing) && !model.ambientEnabled)
                            .accessibilityLabel("Keep the mic on between talks")
                            .accessibilityValue(model.ambientEnabled ? "On" : "Off")
                    }
                    TokensHairline()
                    TokensSettingsRow(title: TokensHome.versionLine, caption: "No account needed.") {
                        Button("Quit \(appName)") { NSApp.terminate(nil) }
                            .buttonStyle(TokensQuietButtonStyle())
                    }
                }
            }
            OllamaStatusLine(asides: model.pauseAsides)
                .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 440)
        .background(TokensUI.paper)
        .preferredColorScheme(TokensUI.isDark ? .dark : .light)
    }
}

