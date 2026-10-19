


//
import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Darwin
import Speech
import SwiftUI


// Constants — Build and launch flags, read once from Info.plist and the command line


/*
Product identity is fixed in this source: standalone is false and publicTokens is true.
AppDelegate uses those constants to select TokensHome, add the menu item and prepare speech.
Historical Info.plist flags are mentioned below only to explain the former missing-key failure.
 - bubbleInteractivePreview: launch argument --bubble-interactive-preview. A preview of the
   bubble with synthetic audio; the microphone, clipboard, history and preferences are not used.
 - bubblePreviewProduction: only with the preview flag, plus --bubble-preview-production.
Trap: these two used to come from Info.plist (TTTStandaloneTokens, TTTPublicTokens). A bundle
packaged without the key silently became a different, older product. This tree builds one
product, so they are constants now; the branches they guard are deleted with Unreached/.
*/
let standalone   = false
let publicTokens = true
var appName: String {
    ProductIdentity.displayName
}
let bubbleInteractivePreview = ProcessInfo.processInfo.arguments.contains("--bubble-interactive-preview")
let bubblePreviewProduction = bubbleInteractivePreview && ProcessInfo.processInfo.arguments.contains("--bubble-preview-production")


// TokensApp — The @main entry point: a Settings scene and one menu command


/*
@NSApplicationDelegateAdaptor makes AppDelegate the app delegate, so the app and its windows
are built there. `appDelegate.model` is the same TalkModel every window uses.
*/
@main
struct TokensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /*
    The only SwiftUI scene is Settings (the windows themselves are made in AppDelegate). The
    menu command's shortcut is Control+Option+Space; both are inert in the bubble preview.
    */
    var body: some Scene {
        Settings {
            if bubbleInteractivePreview {
                Text("Interactive preview · microphone and clipboard disabled").padding(24)
            } else if publicTokens {
                TokensHome(model: appDelegate.model, initialSection: .settings, coversTitleBar: false)
                    .frame(minWidth: 660, idealWidth: 1040, minHeight: 464, idealHeight: 720)
            } else {
                SettingsPane(model: appDelegate.model)
            }
        }
            .commands {
                CommandMenu("Talk") {
                    Button("Start / Finish Talk") {
                        appDelegate.model.toggle()
                    }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                    .disabled(bubbleInteractivePreview)
                }
            }
    }
}

