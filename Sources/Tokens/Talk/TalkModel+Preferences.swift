


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkModel — Preferences


extension TalkModel {

    /*
    Three-step paste is a saved delivery preference; this file declares no
    paired quality-log writer.
    */
    /// Three-step paste (title and metadata, then the opening words, then the rest). On in Tokens Dev
    /// and the promoted daily app; the saved preference can disable it. Exact editor acknowledgement
    /// and focus/caret guards still decide whether any delivery can stage.
    static let threeStepPasteKey = "TokensThreeStepPaste.v1"

    static var threeStepPasteEnabled: Bool {
        UserDefaults.standard.object(forKey: threeStepPasteKey) as? Bool ?? true
    }

    /// Both outcomes set the same message; the ledger's status value is not used.
    func refreshDailyAllowance() {
        guard !isSyntheticRun else { return }
        do {
            _ = try dailyAllowance.status()
            dailyAllowanceMessage = "Clean transcription · optional metadata and character tags"
        } catch {
            dailyAllowanceMessage = "Clean transcription · optional metadata and character tags"
        }
    }

    /// Whether to add Tokens formatting: true for every real Tokens talk, false otherwise.
    func shouldDecorateDelivery(session: UUID) -> Bool {
        guard selectedProduct == "Tokens", !isSyntheticRun else { return false }
        refreshDailyAllowance()
        /*
        Base readability is mandatory for Tokens. The allowance ledger is
        retained for a future paid customization tier and never gates it.
        */
        _ = session
        return true
    }

    /// Counts one verified delivery; a save failure only sets a notice.
    func recordVerifiedAllowance(session: UUID, wasClean: Bool) {
        guard selectedProduct == "Tokens", !isSyntheticRun else { return }
        do {
            _ = try dailyAllowance.recordDelivery(sessionID: session, outcome: .verifiedSuccess, wasClean: wasClean)
            dailyDeliveryNotice = ""
        } catch { dailyDeliveryNotice = "Delivery completed; allowance could not be saved." }
        refreshDailyAllowance()
    }

    // Settings — choices saved in the current product's preferences

    /// Saves a TalkStyle for the current product. Tokens resets it to .terminal at launch.
    func selectDictationStyle(_ style: TalkStyle) {
        dictationStyle = style
        preferences.set(style.rawValue, forKey: "TTTDictationStyle.v1")
        print("TTT_EVENT dictation_style_selected style=\(style.rawValue)")
    }

    /// Tap or hold. Refused mid-talk, so a talk always ends with the mode it began with.
    func selectRightOptionMode(_ mode: RightOptionMode) {
        guard phase != .capturing, phase != .finalizing else { return }
        rightOptionMode = mode
        preferences.set(mode.rawValue, forKey: "TTTRightOptionMode.v1")
        print("TTT_EVENT right_option_mode_selected mode=\(mode.rawValue)")
        Diagnostics.event("right_option_mode mode=\(mode.rawValue)")
    }

//
// :)
//
//
    /// Receipt on/off. Saved to the current product's preferences (not in synthetic runs);
    /// re-renders the live words.
    func selectMetadataEnabled(_ enabled: Bool) {
        metadataEnabled = enabled
        if !isSyntheticRun {
            preferences.set(enabled, forKey: selectedProduct == "Tokens" ? TokensOutputOptions.metadataKey : "TTTMetadataFooterEnabled.v1")
        }
        if selectedProduct == "Tokens" { thinkingFormatter.setActive(thinkingMetadataEnabled && !isSyntheticRun) }
        Diagnostics.event("metadata_footer enabled=\(enabled)")
        rerenderActiveTranscript()
    }

    /// Spelled letters stay usable as text; their machine-readable tags can be switched off.
    func selectCharacterTagsEnabled(_ enabled: Bool) {
        characterTagsEnabled = enabled
        if !isSyntheticRun { TokensOutputOptions.setCharacterTags(enabled, in: preferences) }
        rerenderActiveTranscript()
    }

    /// Spoken number runs stay digits either way; only their <num> tags switch.
    func selectNumberTagsEnabled(_ enabled: Bool) {
        numberTagsEnabled = enabled
        if !isSyntheticRun { preferences.set(enabled, forKey: TokensOutputOptions.numberTagsKey) }
        rerenderActiveTranscript()
    }

    /// Plain or Markdown. Saved like the receipt setting; re-renders the live words.
    func selectMarkdownEnabled(_ enabled: Bool) {
        markdownEnabled                = enabled
        let mode: TranscriptRenderMode = enabled ? .markdown : .plain
        if !isSyntheticRun {
            preferences.set(mode.rawValue, forKey: TranscriptRenderMode.preferenceKey)
        }
        Diagnostics.event("transcript_render_mode mode=\(mode.rawValue)")
        rerenderActiveTranscript()
    }

    /// Speed of Sound on/off. Saved like the receipt setting.
    func selectSpeedOfSoundEnabled(_ enabled: Bool) {
        speedOfSoundEnabled = enabled
        if !isSyntheticRun {
            preferences.set(enabled, forKey: SpeedOfSoundPreference.key)
        }
        Diagnostics.event("speed_of_sound enabled=\(enabled)")
    }

}

