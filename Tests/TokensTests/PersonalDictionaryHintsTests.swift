import Foundation
import Testing
@testable import Tokens

@Suite struct PersonalDictionaryHintsTests {
    @Test func savedTermsReachTokensAndPreserveExistingSpellings() throws {
        let suite = "tokens.dictionary.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PersonalDictionary.save("  Riley\nRILEY\nTinkr\n  ", in: defaults)
        #expect(PersonalDictionary.hints(for: "Tokens", in: defaults) == ["Riley", "Tinkr"])
        #expect(PersonalDictionary.hints(for: "Talk", in: defaults) == ["Riley", "Tinkr"])
        #expect(PersonalDictionary.hints(for: "Other", in: defaults).isEmpty)
    }
}
