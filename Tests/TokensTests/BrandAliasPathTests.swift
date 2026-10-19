


//
import Testing
@testable import Tokens

@Suite struct BrandAliasPathTests {
    static let kept = [
        "open ~/Documents/Tinkr in the terminal",
        "cd /tmp/example-user/Documents/Tinkr/source",
        "the folder Tinkr/ has it",
        "quit Tinkr.app first",
        #"C:\Tinker\bin"#,
    ]

    @Test(arguments: kept)
    func pathAndFileNamesKeepTheirSpelling(_ text: String) {
        #expect(TalkVocabulary.normalizeRecognizedText(text) == text)
    }

    @Test func proseWordIsStillBranded() {
        #expect(TalkVocabulary.normalizeRecognizedText("open the tinker app") == "open the tinkr app")
        #expect(TalkVocabulary.normalizeRecognizedText("I use Tinker.") == "I use tinkr.")
        #expect(TalkVocabulary.normalizeRecognizedText("Tinkr, stop") == "tinkr, stop")
    }
}

