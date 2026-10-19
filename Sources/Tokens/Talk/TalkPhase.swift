


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// TalkPhase — where one talk is in its life, from idle to delivered


/*
The usual path is idle → capturing → finalizing → delivered → idle.
Any phase can drop to failed; the next key press clears failed and starts a new talk.
TalkModel.phase is the only stored copy. Its didSet stops TokenPauseAsides once a talk
leaves capturing and finalizing, and ends the π thinking panel once it leaves capturing.
*/
enum TalkPhase: Equatable {
    /// No talk is running. Background listening may still own the microphone
    /// between talks (see TalkModel.resumeInputPreview).
    case idle
    /// The talk key started a talk: the microphone records and the bubble shows live words.
    case capturing
    /// Stop was pressed. The target app is frozen, recognition is finishing, and the
    /// stop gate (FinishGate) counts down the send delay before delivery.
    /// Key presses are ignored in this phase (RightOptionMode.action returns .ignore).
    case finalizing
    /// The words were delivered to the target app, or there were none to deliver.
    /// TalkModel returns to idle shortly after.
    case delivered
    /// Something stopped the talk: no key access, the microphone did not start, a pause,
    /// or a delivery that could not be confirmed. Any words are held for Copy latest.
    case failed
}


// TalkStyle — named looks for the live words; Tokens always uses .terminal


/*
TalkModel sets .terminal at every launch. The other looks are drawn only by
TalkStyleView in Unreached/OldShell.swift.
*/
enum TalkStyle: String, CaseIterable, Identifiable {
    case flow
    case ribbon
    case subtitle
    case terminal
    case ink

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}


// RightOptionMode (extension) — the words shown for tap-to-talk and hold-to-talk


extension RightOptionMode {
    var title: String { self == .hold ? "Hold to talk" : "Tap to talk" }
}

