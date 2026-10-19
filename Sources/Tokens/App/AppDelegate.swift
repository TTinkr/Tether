


//
import TokensCore
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// AppDelegate — Launch, windows, menu-bar item and proof/preview modes for the whole app


final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    /*
    prod_tokens only: wipe its memory before `model` below loads anything. Stored properties
    initialise top to bottom, so this must stay the first one in the class.
    */
    private let freshStart = FreshStart.resetIfFreshApp()


    // What the delegate holds, and the first-run rule


    /*
    Name of the distributed notification a second launch sends to the copy that is already
    running (see redirectToExistingInstanceIfNeeded).
    */
    static let reopenNotification = Notification.Name("com.tinkr.tokens.community.lab.macos.reopen")
    /// Public first launch: nothing that prompts macOS runs until the card's button is pressed.
    var tokensFirstRunPending: Bool { TalkModel.tokensFirstRunPending }
    /// Explicit relaunch shows Home without requesting permissions or bypassing consent.
    var shouldPresentHomeOnReopen: Bool {
        LaunchPresentation.needsHome(publicTokens: publicTokens, firstRunPending: tokensFirstRunPending,
                                     background: false, loginItem: false)
    }
    /*
    Existing Accessibility grants stay intact, but never stand in for explicit acceptance.
    A working installation must still show setup when its current Terms record is absent.
    The one TalkModel for the whole app. TokensApp reads it as appDelegate.model for the Settings
    scene and the menu command, so every window talks to the same model.
    */
    let model = TalkModel()
    /*
    surfaceWindow: the bubble. styleWindow: the main Tokens window (identifier "TTTStyleChooser").
    labWindow: the lab (identifier "TTTVoiceLab"). bubblePreviewStage: the preview-only stage.
    proofTimer: the timer that writes proof frames. statusItem: the menu-bar item.
    */
    var surfaceWindow: CaptureBubblePanel?
    var bubblePreviewStage: NSWindow?
    var labWindow: NSWindow?
    var styleWindow: NSWindow?
    var proofTimer: DispatchSourceTimer?
    var statusItem: NSStatusItem?


    // Launch — applicationDidFinishLaunching(): proof runs first, then the normal start


    /*
    Order of work at launch:
     1. Special proof runs (below) do one job and quit; they never reach the normal start.
     2. A second copy of the app hands over to the running one and quits.
     3. The bubble window is built and wired to the model.
     4. One branch of the chain at the bottom runs: interactive bubble preview, rendered proof
        frames (controls, main stream, lab, idle, glass/headless), or the normal start.
    The `bubbleInteractivePreview` flag (--bubble-interactive-preview) turns off everything that
    would start real services, so each proof guard below also checks it.
    */
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        // Dev-only live QA: send one talk-key edge to the running copy, print its receipt, stop.
        if QATalkTrigger.isAvailable, let edge = argumentValue(after: "--qa-talk") {
            NSApp.setActivationPolicy(.prohibited)  // no Dock icon, never takes focus
            exit(QATalkTrigger.post(edge, pid: argumentValue(after: "--qa-pid").flatMap { Int32($0) }))
        }
        // Readiness is separate from selection: missing local weights never select Apple.
        SpeechEngineChoice.localModelReady = { SpeechModelStore.isReady($0) }
        TalkModel.migrateSetupFinished()
        if DevChannel.isActive,
           let output = argumentValue(after: "--claude-caret-fixture-proof"),
           let fixtureID = argumentValue(after: "--fixture-id") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await ClaudeCaretFixtureProof.run(fixtureID: fixtureID, output: output)
                NSApp.terminate(nil)
            }
            return
        }
        if DevChannel.isActive,
           let output = argumentValue(after: "--local-speech-fixture-proof"),
           let input = argumentValue(after: "--fixture-audio") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                let engineRaw = self.argumentValue(after: "--fixture-engine") ?? "apple"
                guard let engine = SpeechEngineChoice(rawValue: engineRaw) else {
                    NSApp.terminate(nil); return
                }
                // Build 79: which local model to run, for this process only (saved settings untouched).
                SpeechEngineChoice.processModelOverride = self.argumentValue(after: "--fixture-model")
                // --fixture-download: fetch the model through SpeechModelStore first (real pinned download).
                if arguments.contains("--fixture-download"), let model = SpeechEngineChoice.processModelOverride,
                   await !SpeechModelStore.downloadForProof(model, receipt: output + ".download.json") {
                    NSApp.terminate(nil); return
                }
                await LocalSpeechFixtureProof.run(input: input, output: output, engine: engine)
                NSApp.terminate(nil)
            }
            return
        }
        if ProofRoutes.isAllowed, let output = argumentValue(after: "--recovery-ui-proof"),
           NativeRecoveryUIProof.allowed(arguments: arguments,
               distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String) {
            runRecoveryUIProof(directoryPath: output,
                minimum: argumentValue(after: "--recovery-ui-size") == "minimum")
            return
        }
        if ProofRoutes.isAllowed, let output = argumentValue(after: "--single-paste-fixture-proof"),
           SinglePasteFixtureProof.allowed(distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String,
               proofRoutesAllowed: ProofRoutes.isAllowed, continuousReveal: arguments.contains("--continuous-reveal"),
               devChannel: DevChannel.isActive),
           let fixtureID = argumentValue(after: "--fixture-id"),
           let targetBundle = argumentValue(after: "--target-bundle") {
            NSApp.setActivationPolicy(.accessory)
            SinglePasteFixtureProof.schedule(output: output, fixtureID: fixtureID, targetBundle: targetBundle) {
                NSApp.terminate(nil)
            }
            return
        }
        /*
        Dev builds only: --staged-scratch-proof runs TargetDelivery.runStagedScratchProof one
        second after launch, then quits. `.accessory` means no Dock icon for this run.
        */
        if DevChannel.isActive, let output = argumentValue(after: "--native-editor-fixture-proof"),
           let fixtureID = argumentValue(after: "--fixture-id"),
           let targetBundle = argumentValue(after: "--target-bundle") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                NativeEditorFixtureProof.run(output: output, id: fixtureID, bundle: targetBundle,
                    prepareOwnedTestpad: arguments.contains("--prepare-owned-testpad"),
                    fixtureDocument: self.argumentValue(after: "--fixture-doc")) {
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if DevChannel.isActive, let output = argumentValue(after: "--staged-scratch-proof"),
           let documentID = argumentValue(after: "--scratch-doc") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task { @MainActor in
                    await TargetDelivery.runStagedScratchProof(output: output, documentID: documentID)
                    NSApp.terminate(nil)
                }
            }
            return
        }
        /*
        Proof runs. Each takes its place only when its flag is given, does its one job, then
        quits. The two microphone proofs can also be requested through a saved setting, which is
        deleted as soon as it is read so the proof runs once. None of them exist in the public
        download (ProofRoutes): there a flag or saved setting is ignored and the normal start runs.
        */
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let output = argumentValue(after: "--ambient-microphone-proof") ?? UserDefaults.standard.string(forKey: "TTTAmbientMicrophoneProofOutput.v1") {
            UserDefaults.standard.removeObject(forKey: "TTTAmbientMicrophoneProofOutput.v1")
            // The explicit hardware check has no interactive surface. Keep it
            // from taking focus while the user or another agent owns the screen.
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                if arguments.contains("--hardware-signal-only") {
                    await AudioHardwareSmokeProof.run(audio: model.audio, output: output)
                } else {
                    await model.audio.runAmbientLifecycleProof(output: output)
                }
                NSApp.terminate(nil)
            }
            return
        }
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, arguments.contains("--takeoff-now-proof") {
            model.runTakeOffNowProof()
            NSApp.terminate(nil)
            return
        }
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let output = argumentValue(after: "--microphone-pause-proof") ?? UserDefaults.standard.string(forKey: "TTTMicrophonePauseProofOutput.v1") {
            UserDefaults.standard.removeObject(forKey: "TTTMicrophonePauseProofOutput.v1")
            NSApp.setActivationPolicy(.accessory)
            Task { await MicrophonePauseProof.run(output: output); NSApp.terminate(nil) }
            return
        }
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let input = argumentValue(after: "--legacy-dictation-file-proof"),
           let output = argumentValue(after: "--dictation-proof-output") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                await LegacyTalkFileProof.run(input: input, output: output)
                NSApp.terminate(nil)
            }
            return
        }
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let input = argumentValue(after: "--dictation-file-proof"),
           let output = argumentValue(after: "--dictation-proof-output") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                await TalkFileProof.run(input: input, output: output)
                NSApp.terminate(nil)
            }
            return
        }
        // Offscreen π envelope check and TTH arm render: files in, files out, exit before any window.
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let input = argumentValue(after: "--envelope-check"),
           let output = argumentValue(after: "--envelope-check-output") {
            NSApp.setActivationPolicy(.accessory)
            exit(EnvelopeCheckProof.check(inputPath: input, outputPath: output))
        }
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let input = argumentValue(after: "--tth-arms"),
           let output = argumentValue(after: "--tth-arms-output") {
            NSApp.setActivationPolicy(.accessory)
            exit(EnvelopeCheckProof.renderArms(historyPath: input, outputDirectory: output))
        }
        // Offscreen "Your voice" render: synthetic fixture only, PNGs out, exit before any window.
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, let output = argumentValue(after: "--render-voice-ledger"),
           arguments.contains("--voice-ledger-fixture") {
            NSApp.setActivationPolicy(.accessory)
            exit(MainActor.assumeIsolated { VoiceLedgerProof.render(to: output) })
        }
        // Paste ledger: read the events log (counts and codes only), write ledger.json + ledger.md, exit.
        // A bare --paste-ledger prints usage and exits instead of falling through to a full launch.
        if ProofRoutes.isAllowed, !bubbleInteractivePreview, arguments.contains("--paste-ledger") {
            NSApp.setActivationPolicy(.accessory)
            guard let output = argumentValue(after: "--paste-ledger"), !output.hasPrefix("--") else {
                FileHandle.standardError.write(Data("usage: Tokens --paste-ledger <out-dir> [--paste-ledger-input <events.log>]\n".utf8))
                exit(64)
            }
            exit(PasteLedgerReport.run(outputDirectory: output, inputPath: argumentValue(after: "--paste-ledger-input")))
        }
        /*
        Preview flags for the rendered-frame proofs further down. `isHeadlessProof` is true when
        --render-preview-frames was given with a folder to write into.
        */
        let isDemo            = arguments.contains("--demo")
        let proofDirectory    = argumentValue(after: "--render-preview-frames")
        let isHeadlessProof   = proofDirectory != nil
        let isControlsProof   = arguments.contains("--controls-preview")
        let isMainStreamProof = arguments.contains("--main-stream-preview")
        let isLabProof        = arguments.contains("--lab-preview")
        let isIdleProof       = arguments.contains("--idle-preview")
        // Listen for a second launch asking this copy to show its window (not in preview modes).
        if !bubbleInteractivePreview { DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleReopenNotification(_:)),
            name: Self.reopenNotification,
            object: Bundle.main.bundleIdentifier
        ) }
        // A preview of the held-words capsule with given text; never in the public download (ProofRoutes).
        let heldWordsPreview = ProofRoutes.isAllowed ? argumentValue(after: "--held-words-preview") : nil
        /*
        A normal launch while the app is already running hands over to that copy and stops here.
        Preview, demo and proof launches are allowed to run beside it.
        */
        if !ProofRoutes.nativeBubblePreview, !bubbleInteractivePreview, !isHeadlessProof, !isDemo, heldWordsPreview == nil, redirectToExistingInstanceIfNeeded() { return }

        // Headless proof runs get no Dock icon; everything else is a regular app.
        NSApp.setActivationPolicy(isHeadlessProof ? .accessory : .regular)
        if let heldWordsPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.model.previewHeldWords(heldWordsPreview)
            }
        }
        let isGlassPreview = arguments.contains("--spiral-preview") || arguments.contains("--magic-preview")
        /*
        The bubble: a borderless panel that never takes keyboard focus (NonactivatingPanel), at
        its fixed size. Its identifier "TTTCompactPanel" is how compactWindow() finds it later.
        */
        let window = CaptureBubblePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: panelDefaultSize.width,
                height: panelDefaultSize.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title       = appName
        window.identifier  = NSUserInterfaceItemIdentifier("TTTCompactPanel")
        window.contentView = hostingView(TalkBubbleSheet(model: model), size: panelDefaultSize)
        surfaceWindow      = window
        configureCompactWindow(window)
        /*
        Hooks the model calls back into: show or hide the lab, apply a spoken window command,
        and resize the main window when the history list opens or closes.
        */
        model.onLabVisibilityChange = { [weak self] visible in
            if visible { self?.showLabWindow() } else { self?.hideLabWindow() }
        }
        model.onVoiceCommand = { [weak self] command in self?.handleVoiceCommand(command) }
        model.onHistoryExpansionChange = { [weak self] expanded in
            DispatchQueue.main.async { [weak self] in
                self?.resizeStyleWindow(expanded: expanded)
            }
        }

        // Which window to show. Exactly one branch below runs; the first that matches wins.
        if ProofRoutes.nativeBubblePreview {
            // Local synthetic signals in the real panel, never the stage window or microphone.
            model.runInteractiveBubblePreview()
            window.title = "Tokens Native Bubble Proof · Synthetic audio"
            model.showSurface()
        } else if bubbleInteractivePreview {
            model.runInteractiveBubblePreview()
            window.title = "Tokens Bubble Preview · Synthetic audio"
            let stage = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            stage.title                = "Tokens Bubble Preview — no microphone"
            stage.appearance           = NSAppearance(named: .aqua)
            stage.identifier           = NSUserInterfaceItemIdentifier("TTTBubblePreviewStage")
            stage.isReleasedWhenClosed = false
            stage.delegate             = self
            let canvas                 = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
            let backdrop               = hostingView(BubblePreviewStage(), size: NSSize(width: 800, height: 480))
            backdrop.frame             = canvas.bounds
            canvas.addSubview(backdrop)
            stage.contentView = canvas
            stage.center()
            bubblePreviewStage = stage
            stage.makeKeyAndOrderFront(nil)
            /*
            The same native bubble view, hosted inside a disposable recording stage.
            A single window makes scripted capture and event targeting unambiguous.
            */
            let bubble        = hostingView(TalkBubbleSheet(model: model), size: panelDefaultSize)
            bubble.identifier = NSUserInterfaceItemIdentifier("TTTPreviewBubbleHost")
            bubble.frame      = NSRect(origin: NSPoint(x: (800 - panelDefaultSize.width) / 2, y: 64), size: panelDefaultSize)
            stage.contentView?.addSubview(bubble)
            window.dismissRequested()
        } else if (isControlsProof || isMainStreamProof), let proofDirectory {
            // Proof run: build the main window off-screen and write PNG frames of it.
            let proofWindow = makeStyleWindow()
            styleWindow     = proofWindow
            surfaceWindow?.dismissRequested()
            if isMainStreamProof {
                model.runMainStreamPreview()
            } else {
                model.runControlsPreview()
                if arguments.contains("--products-preview") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.model.toggleProductDrawer()
                        if (arguments.contains("--telepathy-preview") || arguments.contains("--talk-preview")) { self.model.selectProduct("Talk") }
                        if arguments.contains("--telescope-preview") { self.model.selectProduct("Telescope") }
                        if arguments.contains("--tincture-preview") { self.model.selectProduct("Tincture") }
                    }
                }
            }
            // The local UI fixture can stay visible for a bounded Copy/zoom test. It retains
            // fictional history and skips capture/monitoring; distribution ignores this flag.
            let interactiveUIProof = ProofRoutes.isAllowed && arguments.contains("--interactive-ui-proof")
            if interactiveUIProof {
                NSApp.setActivationPolicy(.regular)
                proofWindow.title = "Tokens UI Proof — fictional history"
                proofWindow.makeKeyAndOrderFront(nil)
            } else {
                proofWindow.orderOut(nil)
            }
            if arguments.contains("--dictionary-preview") {
                proofWindow.setContentSize(NSSize(width: 488, height: 390))
                proofWindow.contentView = NSHostingView(rootView: PersonalDictionaryEditor())
            }
            if arguments.contains("--switch-window-proof") {
                model.runProductSwitchProof()
                precondition(proofWindow.styleMask.contains(.resizable))
                precondition(proofWindow.collectionBehavior.contains(.fullScreenPrimary))
                proofWindow.setContentSize(NSSize(width: 960, height: 640))
                precondition(proofWindow.contentRect(forFrameRect: proofWindow.frame).width == 960)
                print("PASS native resizable/fullscreen configuration and 960x640 content resize")
            }
            if arguments.contains("--tincture-preview") {
                proofWindow.setContentSize(NSSize(width: 1440, height: 900))
            }
            renderProofFrames(window: proofWindow, to: proofDirectory,
                              framesPerSecond: interactiveUIProof ? 1 : arguments.contains("--tincture-preview") ? 4 : 12,
                              duration: interactiveUIProof ? 120 : arguments.contains("--tincture-train-preview") ? 24 : 2.4)
        } else if isLabProof {
            let proofWindow = makeLabWindow(size: NSSize(width: 1100, height: 700), restoreFrame: false)
            labWindow       = proofWindow
            surfaceWindow?.dismissRequested()
            if isDemo { model.runLabPreview() }
            if let proofDirectory {
                proofWindow.orderOut(nil)
                renderProofFrames(window: proofWindow, to: proofDirectory, framesPerSecond: 24, duration: 18.0)
            }
        } else if isIdleProof {
            if let proofDirectory {
                window.dismissRequested()
                renderProofFrames(window: window, to: proofDirectory, framesPerSecond: 12, duration: 0.5)
            } else {
                showCompactWindow(reason: "idle_preview")
            }
        } else if isGlassPreview || isHeadlessProof {
            model.runGlassPreview()
            if let proofDirectory {
                window.dismissRequested()
                renderProofFrames(window: window, to: proofDirectory, framesPerSecond: 24, duration: 6.8)
            } else {
                showCompactWindow(reason: "preview")
            }
        } else {
            /*
            The normal start. The first line is the older multi-product shell, used only when
            neither the public nor the standalone flag is set.
            */
            if !publicTokens && !standalone { model.selectProduct("Telescope") }
            // The local model needs no permission: warm it now, before (and during) first run.
            if LaunchPresentation.prewarmsLocalSpeech(engine: SpeechEngineChoice.load(),
                                                      orukeetBundled: SpeechEngineChoice.orukeetBundled,
                                                      localModelReady: SpeechEngineChoice.orukeetModelReady()) {
                model.audio.prewarmRecognition()
            }
            // Verify/download only the selected local model. An explicit Apple or other saved
            // selection is never overwritten by the packaged Parakeet default.
            let localModelReady: (String) -> Void = { [weak self] id in
                guard let self, SpeechEngineChoice.selectedModelID() == id else { return }
                self.model.audio.refreshSpeechEngineStatus()
                if LaunchPresentation.prewarmsLocalSpeech(engine: SpeechEngineChoice.load(),
                                                          orukeetBundled: SpeechEngineChoice.orukeetBundled,
                                                          localModelReady: SpeechEngineChoice.orukeetModelReady()) {
                    self.model.audio.prewarmRecognition()
                }
            }
            SpeechModelStore.shared.onReady = localModelReady
            OrukeetModelDownload.shared.onReady = { localModelReady(SpeechModelCatalog.orukeetID) }
            SpeechModelStore.shared.prepareSelectedModel()
            /*
            Listening and speech preparation both wait for `!tokensFirstRunPending`: on a first
            public launch nothing that makes macOS ask for a permission runs until the person
            presses the card's button.
            */
            if (!standalone || UserDefaults.standard.bool(forKey: "tinkr.onboarding.complete")) && !tokensFirstRunPending { model.startMonitoring() }
            // Working installs get any undecided prompts and the speech model before the first dictation.
            if publicTokens && !tokensFirstRunPending { model.prepareSpeech() }
            /*
            Returning Tokens launches stay quiet. First-run consent still opens its setup card;
            the menu bar can explicitly open Home later. Retained products keep their old policy.
            */
            let updateRelaunch = LaunchPresentation.consumeUpdateRelaunch()
            if updateRelaunch { Diagnostics.event("launch_after_update quiet=\(!tokensFirstRunPending)") }
            if LaunchPresentation.needsHome(publicTokens: publicTokens, firstRunPending: tokensFirstRunPending,
                                          background: arguments.contains("--background"), loginItem: LoginItem.launchedAsLoginItem,
                                          updateRelaunch: updateRelaunch) {
                showStyleChooser()
            }
            if publicTokens { installStatusItem() }
        }
    }


}

