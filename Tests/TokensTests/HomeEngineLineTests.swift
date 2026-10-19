import Testing
@testable import Tokens
import TokensCore

/// Home names the selected model even while its local download is unavailable.
@Suite struct HomeEngineLineTests {
    @Test func appleIsAlwaysApple() {
        #expect(TokensHomeEngine.describe(chosenID: "apple", state: .builtIn) == TokensHomeEngine(name: "Apple", pill: nil))
        #expect(TokensHomeEngine.describe(chosenID: "no-such-model", state: .notDownloaded).name == "Apple")
    }

    @Test func readyLocalModelIsNamed() {
        #expect(TokensHomeEngine.describe(chosenID: "orukeet", state: .ready) == TokensHomeEngine(name: "Orukeet", pill: nil))
        #expect(TokensHomeEngine.describe(chosenID: "orukeet", state: .builtIn).name == "Orukeet")
        #expect(TokensHomeEngine.describe(chosenID: "parakeet-tdt-0.6b-v3", state: .ready)
                == TokensHomeEngine(name: "Parakeet v3", pill: nil))
    }

    @Test func missingOrUnavailableLocalModelKeepsItsNameAndExplainsTheState() {
        for (id, name) in [("orukeet", "Orukeet"), ("parakeet-tdt-0.6b-v3", "Parakeet v3")] {
            #expect(TokensHomeEngine.describe(chosenID: id, state: .notDownloaded)
                    == TokensHomeEngine(name: name, pill: "Not downloaded"))
            #expect(TokensHomeEngine.describe(chosenID: id, state: .failed("synthetic failure"))
                    == TokensHomeEngine(name: name, pill: "Download paused"))
            #expect(TokensHomeEngine.describe(chosenID: id, state: .comingSoon)
                    == TokensHomeEngine(name: name, pill: "Unavailable in this build"))
        }
    }

    @Test func downloadingLocalModelKeepsItsNameAndReportsProgress() {
        for (id, name) in [("orukeet", "Orukeet"), ("parakeet-tdt-0.6b-v3", "Parakeet v3")] {
            let downloading = TokensHomeEngine.describe(chosenID: id, state: .downloading(0.42))
            #expect(downloading == TokensHomeEngine(name: name, pill: "42%"))
            #expect(downloading.spoken == "Speech model: \(name), 42%")
        }
    }
}
