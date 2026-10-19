


//
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct TalkShortcutTests {
    @Test static func run() throws {
        var hold   = ShortcutHold()
        let custom = TalkShortcut(keyCode: 49, displayName: "Space")
        precondition(hold.update(shortcut: custom, keyCode: 49, event: .keyUp) == nil)
        precondition(hold.update(shortcut: custom, keyCode: 49, event: .keyDown) == true)
        precondition(hold.update(shortcut: custom, keyCode: 49, event: .keyDown, isRepeat: true) == nil)
        precondition(hold.update(shortcut: custom, keyCode: 49, event: .keyDown) == nil)
        precondition(hold.update(shortcut: custom, keyCode: 0, event: .keyUp) == nil && hold.held)
        precondition(hold.update(shortcut: custom, keyCode: 49, event: .keyUp) == false)
        precondition(hold.update(shortcut: custom, keyCode: 49, event: .keyUp) == nil)
        for (code, bit) in [(55, 0x08), (54, 0x10), (56, 0x02), (60, 0x04), (58, 0x20), (61, 0x40), (59, 0x01), (62, 0x2000), (63, 0x00800000)] {
            hold.reset()
            let modifier = TalkShortcut(keyCode: UInt16(code), displayName: "Modifier")
            precondition(hold.update(shortcut: modifier, keyCode: Int64(code), event: .flagsChanged, flags: UInt64(bit)) == true)
            precondition(hold.update(shortcut: modifier, keyCode: Int64(code), event: .flagsChanged, flags: UInt64(bit)) == nil)
            precondition(hold.update(shortcut: modifier, keyCode: Int64(code), event: .flagsChanged, flags: 0) == false)
        }
        // Left Option remains held while physical right Option is released.
        hold.reset()
        precondition(hold.update(shortcut: .rightOption, keyCode: 61, event: .flagsChanged, flags: 0x60) == true)
        precondition(hold.update(shortcut: .rightOption, keyCode: 61, event: .flagsChanged, flags: 0x20) == false)
        /*
        Physical right Option does not release Left Option; releasing the selected
        Left Option still ends the hold while Right Option remains down.
        */
        hold.reset()
        let leftOption = TalkShortcut(keyCode: 58, displayName: "Left Option")
        precondition(hold.update(shortcut: leftOption, keyCode: 58, event: .flagsChanged, flags: 0x20) == true)
        precondition(hold.update(shortcut: leftOption, keyCode: 61, event: .flagsChanged, flags: 0x60) == nil && hold.held)
        precondition(hold.update(shortcut: leftOption, keyCode: 58, event: .flagsChanged, flags: 0x40) == false)
        let caps = TalkShortcut(keyCode: 57, displayName: "Caps Lock")
        precondition(hold.update(shortcut: caps, keyCode: 57, event: .flagsChanged, flags: 0x10000, physicalModifierDown: true) == true)
        precondition(hold.update(shortcut: caps, keyCode: 57, event: .flagsChanged, flags: 0x10000, physicalModifierDown: false) == false)
        let domain   = "TTTShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let tokens = TalkShortcut.tokensBundleIdentifier
        let dev    = TalkShortcut.tokensDevBundleIdentifier
        let cases: [(String, TalkShortcut, [UInt16: String])] = [
            (tokens, .rightOption, [58: "Tokens Dev"]), (dev, .leftOption, [61: "Tokens"]),
            // prod_tokens defaults to Fn (a9c92a7): a Mac may remap Caps Lock to Right Command, and Caps + Space is a common launcher shortcut.
            (FreshStart.bundleIdentifier, .globe, [61: "Tokens", 58: "Tokens Dev"]),
            ("com.tinkr.tokens.community.lab.macos", .rightOption, [:])]
        for (identity, fallback, reserved) in cases {
            precondition(TalkShortcut.siblingReservedKeys(bundleIdentifier: identity) == reserved)
            defaults.removeObject(forKey: TalkShortcut.preferenceKey)
            precondition(TalkShortcut.load(in: defaults, bundleIdentifier: identity) == fallback)
            defaults.set(Data("invalid".utf8), forKey: TalkShortcut.preferenceKey)
            precondition(TalkShortcut.load(in: defaults, bundleIdentifier: identity) == fallback)
            for saved in [custom, .rightOption, .leftOption, .leftControl, .rightCommand] {
                saved.save(in: defaults)
                // A key the sibling owns falls back, so one press never dictates in both apps.
                let expected = reserved[saved.keyCode] == nil ? saved : fallback
                precondition(TalkShortcut.load(in: defaults, bundleIdentifier: identity) == expected)
            }
        }
        // A choice saved under the old key does not survive the move.
        defaults.removeObject(forKey: TalkShortcut.preferenceKey)
        defaults.set(try! JSONEncoder().encode(TalkShortcut.leftOption), forKey: "TTTDictationShortcut.v1")
        precondition(TalkShortcut.load(in: defaults, bundleIdentifier: tokens) == .rightOption)
        print("PASS configurable physical key press/release, repeat suppression, left/right modifier identity, physical Caps Lock override, persistence, Tokens Right Option and Tokens Dev Left Option with sibling reservation, old saved key not carried over")
    }
}

