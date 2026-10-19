
import Testing
@testable import Tokens

struct TalkShortcutConflictTests {
    @Test func explicitFnSettingsMapToTheirOwnAction() {
        #expect(TalkShortcut.systemConflict(keyCode: 63, usage: 0) == nil)
        for (usage, action) in [(1, "input source"), (2, "Emoji & Symbols"), (3, "Apple Dictation")] {
            let warning = TalkShortcut.systemConflict(keyCode: 63, usage: usage)
            #expect(warning?.contains(action) == true)
            #expect(warning?.contains("Do Nothing") == true)
        }
    }

    @Test func absentAndUnknownPreferencesNeverClaimEmojiIsTheActualAction() {
        for usage in [nil, -1, 4, 42] as [Int?] {
            let warning = TalkShortcut.systemConflict(keyCode: 63, usage: usage)
            #expect(warning?.contains("may") == true)
            #expect(warning?.contains("Check") == true)
            #expect(warning?.contains("opens Emoji") == false)
            #expect(warning?.contains("starts Apple Dictation") == false)
        }
    }

    @Test func otherSelectedKeysDoNotInheritTheFnWarning() {
        for key in [55, 54, 58, 61, 0, 36] as [UInt16] {
            for usage in [nil, 0, 1, 2, 3, 42] as [Int?] {
                #expect(TalkShortcut.systemConflict(keyCode: key, usage: usage) == nil)
            }
        }
    }
}
