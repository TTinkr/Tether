import Foundation
import Testing
import TokensCore
@testable import Tokens

/// Build 81: model downloads, engine names, the update-restart key, F-key advice.
struct SettingsReliabilityTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Tokens/" + path), encoding: .utf8)
    }

    @Test func functionKeysExplainFnWhenTheyControlMedia() {
        let f8 = Tokens.TalkShortcut(keyCode: 100, displayName: "F8")
        let media = TalkKeyAdvice.confirmation(for: f8, standardFunctionKeys: false)
        #expect(media.contains("fn") && media.contains("standard function keys"))
        #expect(!TalkKeyAdvice.confirmation(for: f8, standardFunctionKeys: true).contains("fn held"))
        let letter = Tokens.TalkShortcut(keyCode: 0, displayName: "A")
        #expect(TalkKeyAdvice.confirmation(for: letter, standardFunctionKeys: false).contains("ordinary typing"))
        #expect(TalkKeyAdvice.standardFunctionKeys(["com.apple.keyboard.fnState": true]))
        #expect(!TalkKeyAdvice.standardFunctionKeys([:]))
        #expect(!TalkKeyAdvice.standardFunctionKeys(nil))
    }

    @Test func downloadsNeverRefetchWhatIsOnThisMac() throws {
        let store = try source("Speech/SpeechModelStore.swift")
        #expect(store.contains("case .ready, .builtIn, .downloading, .comingSoon: return"))
        #expect(store.contains("func downloadIfMissing(_ id: String, selectWhenReady: Bool = false)"))
        let settings = try source("Features/Home/TokensHomeSettings.swift")
        // Build 82: the Models tab's Download and Retry both go through downloadIfMissing.
        #expect(settings.contains("download: { speechModels.downloadIfMissing($0.id, selectWhenReady: true) }"))
        #expect(try source("Features/Home/TokensModelsPage.swift").contains("Button(\"Retry\") { actions.download(info) }"))
    }

    @Test func statusLinesNameTheChosenModel() throws {
        let recognition = try source("Speech/AudioCapture+Recognition.swift")
        #expect(!recognition.contains("\"Orukeet · ready on this Mac\""))
        #expect(!recognition.contains("\"Loading Orukeet on this Mac…\""))
        #expect(recognition.contains("LocalSpeechModelName.current"))
        let settings = try source("Features/Home/TokensHomeSettings.swift")
        #expect(settings.contains("if orukeetChosen, let line = orukeetDownload.statusLine { return line }"))
    }

    @Test func aRestartingUpdateExplainsInsteadOfIgnoringTheKey() throws {
        let capture = try source("Talk/TalkModel+Capture.swift")
        #expect(capture.contains("capture_refused reason=update_restarting"))
        #expect(!capture.contains("guard !updater.restarting,"))
    }
}
