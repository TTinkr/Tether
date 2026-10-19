


//
import Foundation
import Testing
@testable import TokensCore


// ShortcutHoldTests — press and release edges, left versus right keys


@Suite struct ShortcutHoldTests {
    let space = TalkShortcut(keyCode: 49, displayName: "Space")

    @Test func ordinaryKeyReportsOnlyPressAndReleaseEdges() {
        var hold = ShortcutHold()
        #expect(hold.update(shortcut: space, keyCode: 49, event: .keyUp) == nil)
        #expect(hold.update(shortcut: space, keyCode: 49, event: .keyDown) == true)
        #expect(hold.update(shortcut: space, keyCode: 49, event: .keyDown, isRepeat: true) == nil)
        #expect(hold.update(shortcut: space, keyCode: 49, event: .keyDown) == nil)
        #expect(hold.update(shortcut: space, keyCode: 0, event: .keyUp) == nil)
        #expect(hold.isHeld)
        #expect(hold.update(shortcut: space, keyCode: 49, event: .keyUp) == false)
        #expect(hold.update(shortcut: space, keyCode: 49, event: .keyUp) == nil)
    }

    @Test(arguments: [(55, 0x08), (54, 0x10), (56, 0x02), (60, 0x04), (58, 0x20),
                      (61, 0x40), (59, 0x01), (62, 0x2000), (63, 0x0080_0000)])
    func modifierKeyFollowsItsOwnFlagBit(code: Int, bit: Int) {
        var hold     = ShortcutHold()
        let modifier = TalkShortcut(keyCode: UInt16(code), displayName: "Modifier")
        #expect(hold.update(shortcut: modifier, keyCode: Int64(code), event: .flagsChanged, flags: UInt64(bit)) == true)
        #expect(hold.update(shortcut: modifier, keyCode: Int64(code), event: .flagsChanged, flags: UInt64(bit)) == nil)
        #expect(hold.update(shortcut: modifier, keyCode: Int64(code), event: .flagsChanged, flags: 0) == false)
    }

    @Test func leftAndRightOptionAreIndependent() {
        // Right Option releases while Left Option stays physically down.
        var hold = ShortcutHold()
        #expect(hold.update(shortcut: .rightOption, keyCode: 61, event: .flagsChanged, flags: 0x60) == true)
        #expect(hold.update(shortcut: .rightOption, keyCode: 61, event: .flagsChanged, flags: 0x20) == false)

        // Pressing Right Option does not end a Left Option hold; releasing Left Option does.
        hold.reset()
        #expect(hold.update(shortcut: .leftOption, keyCode: 58, event: .flagsChanged, flags: 0x20) == true)
        #expect(hold.update(shortcut: .leftOption, keyCode: 61, event: .flagsChanged, flags: 0x60) == nil)
        #expect(hold.isHeld)
        #expect(hold.update(shortcut: .leftOption, keyCode: 58, event: .flagsChanged, flags: 0x40) == false)
    }

    @Test func capsLockUsesThePhysicalStateNotTheToggleFlag() {
        var hold = ShortcutHold()
        let caps = TalkShortcut(keyCode: 57, displayName: "Caps Lock")
        #expect(hold.update(shortcut: caps, keyCode: 57, event: .flagsChanged, flags: 0x10000, physicalModifierDown: true) == true)
        #expect(hold.update(shortcut: caps, keyCode: 57, event: .flagsChanged, flags: 0x10000, physicalModifierDown: false) == false)
    }
}


// TalkShortcutTests — defaults, the sibling app's key, saving and loading


@Suite struct TalkShortcutTests {
    /// A throwaway settings store, removed when the test ends.
    final class Scratch {
        let name = "TokensCoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    @Test func eachChannelDefaultsToItsOwnKeyAndReservesTheSiblings() {
        #expect(TalkShortcut.defaultShortcut(for: .production) == .rightOption)
        #expect(TalkShortcut.defaultShortcut(for: .dev) == .leftOption)
        #expect(TalkShortcut.defaultShortcut(for: nil) == .rightOption)
        #expect(TalkShortcut.reservedKeys(for: .production) == [58: "Tokens Dev"])
        #expect(TalkShortcut.reservedKeys(for: .dev) == [61: "Tokens"])
        #expect(TalkShortcut.reservedKeys(for: nil) == [:])
    }

//
// :)
//
//
    @Test(arguments: [Channel?.some(.production), .some(.dev), .none])
    func loadFallsBackWhenNothingValidIsSavedOrTheSiblingOwnsTheKey(channel: Channel?) {
        let scratch  = Scratch()
        let fallback = TalkShortcut.defaultShortcut(for: channel)
        let reserved = TalkShortcut.reservedKeys(for: channel)

        #expect(TalkShortcut.load(from: scratch.defaults, channel: channel) == fallback)
        scratch.defaults.set(Data("invalid".utf8), forKey: SettingsKey.talkShortcut)
        #expect(TalkShortcut.load(from: scratch.defaults, channel: channel) == fallback)

        let space = TalkShortcut(keyCode: 49, displayName: "Space")
        for saved in [space, .rightOption, .leftOption, .leftControl] {
            saved.save(to: scratch.defaults)
            let expected = reserved[saved.keyCode] == nil ? saved : fallback
            #expect(TalkShortcut.load(from: scratch.defaults, channel: channel) == expected)
        }
    }

    @Test func aChoiceSavedUnderTheRetiredV1KeyIsNotCarriedOver() throws {
        let scratch = Scratch()
        scratch.defaults.set(try JSONEncoder().encode(TalkShortcut.leftOption), forKey: "TTTDictationShortcut.v1")
        #expect(TalkShortcut.load(from: scratch.defaults, channel: .production) == .rightOption)
    }

    /*
    Use the literal shipped key, not SettingsKey on both sides: otherwise a
    mistaken rename in production and tests can agree while resetting users.
    */
    @Test func readsTheActualShippedV2ShortcutWithoutResettingIt() throws {
        let scratch = Scratch()
        let chosen  = TalkShortcut(keyCode: 49, displayName: "Space")
        scratch.defaults.set(try JSONEncoder().encode(chosen), forKey: "TTTDictationShortcut.v2")
        #expect(TalkShortcut.load(from: scratch.defaults, channel: .production) == chosen)
        #expect(SettingsKey.talkShortcut == "TTTDictationShortcut.v2")
    }

    @Test func channelIsRecognisedOnlyFromItsExactBundleIdentifier() {
        #expect(Channel(bundleIdentifier: "com.tinkr.tokens.community.macos") == .production)
        #expect(Channel(bundleIdentifier: "com.tinkr.tokens.community.dev.macos") == .dev)
        #expect(Channel(bundleIdentifier: "com.tinkr.tokens.community.lab.macos") == nil)
        #expect(Channel(bundleIdentifier: nil) == nil)
    }
}

