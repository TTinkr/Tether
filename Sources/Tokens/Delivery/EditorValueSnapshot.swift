import Foundation
import CoreFoundation

/// Some editable AX values expose their placeholder when the field is empty.
/// Only explicit, mutually consistent metadata can distinguish it from real draft text.
struct EditorValueSnapshot {
    var raw: String
    var placeholder: String? = nil
    var characterCount: Int? = nil
    var selection: NSRange? = nil
    var role: String? = nil
    /// A web rich-text editor (TargetDelivery.isRichComposer). Only these get the Chromium rules.
    var richComposer = false

    var isEmptyPlaceholder: Bool {
        guard let placeholder, !placeholder.isEmpty,
              selection == NSRange(location: 0, length: 0),
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") else { return false }
        if raw == placeholder && characterCount == 0 { return true }
        /*
        Chromium rich editors (Codex, ChatGPT in Chrome) report an empty field as its
        placeholder plus the empty paragraph's line break, and count those characters.
        Measured 2026-10-11: value "Ask Codex anything\n", AXNumberOfCharacters 19,
        AXPlaceholderValue "Ask Codex anything", caret 0/0.
        */
        return richComposer && raw == placeholder + "\n" && characterCount == raw.utf16.count
    }
    var text: String { isEmptyPlaceholder ? "" : raw }

    static func declaredCharacterCount(_ value: Any) -> Int? {
        guard CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID(),
              let number = value as? NSNumber, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
}
