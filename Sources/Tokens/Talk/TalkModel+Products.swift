


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Products


extension TalkModel {

    /// Talk keeps its settings in its own suite (the Telepathy preferences); every other
    /// product uses the standard defaults.
    var preferences: UserDefaults {
        selectedProduct == "Talk" ? UserDefaults(suiteName: "com.tinkr.tokens.community.preferences")! : .standard
    }

    /// One-time copy of a few settings from the standard defaults into the Talk (Telepathy)
    /// suite, marked done with ClonedTokens.v1. Skipped in Tokens and Tokens Dev.
    func seedTelepathyPreferences() {
        // Tokens is an isolated clone; opening it must not seed another app.
        guard !["com.tinkr.tokens.community.macos", "com.tinkr.tokens.community.dev.macos", "com.tinkr.tokens.community.preview", FreshStart.bundleIdentifier].contains(Bundle.main.bundleIdentifier ?? "") else { return }
        let target = UserDefaults(suiteName: "com.tinkr.tokens.community.preferences")!
        guard !target.bool(forKey: "ClonedTokens.v1") else { return }
        for key in ["TTTRightOptionMode.v1", "TTTMetadataFooterEnabled.v1", TranscriptRenderMode.preferenceKey,
                    SpeedOfSoundPreference.key, LocalFormatter.preferenceKey, "TTTLocalModel.v1"] {
            if let value = UserDefaults.standard.object(forKey: key) { target.set(value, forKey: key) }
        }
        target.set(true, forKey: "ClonedTokens.v1")
    }

    /// What one product was showing when the user switched away; restored on return.
    struct SuspendedProduct {
        var history: [PromptHistoryEntry]
        var error: String
        var notice: String
        var recoveryRequired: Bool
        var payload: String
        var message: String
        var latest: String
    }

    /// No product switch mid-talk or while the lab is listening.
    var productSwitchAllowed: Bool {
        phase != .capturing && phase != .finalizing && !isLabListening
    }

    /// Switches the whole model to another product. Refused for the standalone build,
    /// mid-talk, for unknown names, for the current product, and for anything but Tokens
    /// in public Tokens.
    func selectProduct(_ product: String) {
        guard !standalone, productSwitchAllowed, ["Tokens", "Talk", "Telescope", "Tincture"].contains(product),
              !(publicTokens && product != "Tokens"), product != selectedProduct else { return }
        // Save this product's state first: resetSession() below clears the held failure words.
        suspendedProducts[selectedProduct] = SuspendedProduct(history: promptHistory, error: historyStorageError,
            notice: historyStorageNotice, recoveryRequired: historyRecoveryRequired,
            payload: retainedFailurePayload, message: retainedFailureText, latest: lastTranscriptForCopy)
        // Close every microphone owner and floating window before the product changes.
        audio.keepMicrophoneOpenWhileIdle(false)
        stopInputPreview()
        ambientChip?.orderOut(nil)
        asidePanel?.orderOut(nil)
        stopRecoveryCommandCapture()
        hideSurface()
        resetSession()
        selectedProduct = product
        // Telescope has no talk key, so the key monitor is stopped there.
        if product == "Telescope" {
            input.stop()
            shortcutAccessGranted = false
        } else if !isSyntheticRun {
            startMonitoring()
        }
        // Load the new product's history and dataset rows (Talk's history lives in "Telepathy").
        PromptHistoryStore.productFolder = product == "Talk" ? "Telepathy" : nil
        lastTranscriptForCopy = ""
        rows = []
        displayText = ""
        copyFeedbackKey = nil
        historyStorageError = ""
        historyStorageNotice = ""
        historyRecoveryRequired = false
        setPromptHistoryExpanded(false)
        do { promptHistory = isSyntheticRun ? [] : try PromptHistoryStore.load() }
        catch { promptHistory = []; historyRecoveryRequired = true; historyStorageError = "History could not be loaded. Original preserved." }
        // Coming back to a product restores what it showed, including held failure words.
        if let saved = suspendedProducts[product] {
            promptHistory           = saved.history
            historyStorageError     = saved.error
            historyStorageNotice    = saved.notice
            historyRecoveryRequired = saved.recoveryRequired
            retainedFailurePayload  = saved.payload
            retainedFailureText     = saved.message
            lastTranscriptForCopy   = saved.latest
            if !saved.payload.isEmpty { phase = .failed }
        }
        /*
        The new product's settings. Receipt and Markdown are Talk-only; Speed of Sound is
        always on outside Talk; only Talk lets the local formatter use a model; only Tokens
        runs the thinking formatter.
        */
        rightOptionMode = RightOptionMode(rawValue: preferences.string(forKey: "TTTRightOptionMode.v1") ?? "") ?? .tap
        metadataEnabled = preferences.bool(forKey: product == "Tokens" ? TokensOutputOptions.metadataKey : "TTTMetadataFooterEnabled.v1")
        characterTagsEnabled = product == "Tokens" && TokensOutputOptions.characterTags(in: preferences)
        numberTagsEnabled = product == "Tokens" && TokensOutputOptions.numberTags(in: preferences)
        markdownEnabled = product == "Talk" && TranscriptRenderMode.current(in: preferences) == .markdown
        speedOfSoundEnabled = product != "Talk" || SpeedOfSoundPreference.isEnabled(in: preferences)
        localFormatter.switchPreferences(to: preferences, allowModel: product == "Talk")
        thinkingFormatter.setActive(thinkingMetadataEnabled && !isSyntheticRun)
        thinkingFormatter.probe()
        onProductChange?()
        setInputPreviewVisible(true)
    }

//
// :)
//
//
    /// Launch-argument proof (synthetic run only): held failure words and a storage error
    /// survive a product round trip, and switching is refused mid-talk. Prints PASS.
    func runProductSwitchProof() {
        guard isSyntheticRun else { return }
        phase                  = .failed
        retainedFailurePayload = "preserve failed paste"
        retainedFailureText    = "Paste not confirmed"
        lastTranscriptForCopy  = retainedFailurePayload
        historyStorageError    = "fixture storage error"
        selectProduct("Talk")
        precondition(selectedProduct == "Talk" && retainedFailurePayload.isEmpty)
        selectProduct("Telescope")
        precondition(selectedProduct == "Telescope")
        selectProduct("Tokens")
        precondition(retainedFailurePayload == "preserve failed paste" && historyStorageError == "fixture storage error")
        phase = .capturing
        selectProduct("Talk")
        precondition(selectedProduct == "Tokens")
        phase = .finalizing
        selectProduct("Talk")
        precondition(selectedProduct == "Tokens")
        phase                  = .idle
        retainedFailurePayload = ""
        retainedFailureText    = ""
        historyStorageError    = ""
        print("PASS failed paste/storage recovery survives product roundtrip; active capture/finalization blocked")
    }

    func setProductDrawerExpanded(_ expanded: Bool) {
        productDrawerDismissal?.cancel()
        productDrawerDismissal = nil
        guard expanded != productDrawerExpanded else { return }
        productDrawerExpanded = expanded
        onProductDrawerChange?(expanded)
    }

    func toggleProductDrawer() { setProductDrawerExpanded(true) }

    /// Pointer enters: open now. Pointer leaves: close after 0.25 s unless it comes back.
    func hoverProductDrawer(_ inside: Bool) {
        productDrawerDismissal?.cancel()
        if inside { setProductDrawerExpanded(true); return }
        let dismissal          = DispatchWorkItem { [weak self] in self?.setProductDrawerExpanded(false) }
        productDrawerDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: dismissal)
    }

    /// A click on a product: switch, and close the drawer if the switch happened.
    func chooseProduct(_ product: String) {
        selectProduct(product)
        if selectedProduct == product { setProductDrawerExpanded(false) }
    }

}

