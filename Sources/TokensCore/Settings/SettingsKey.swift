


//
/// Names of saved settings.
///
/// Theorem: the string values are what is already stored on Macs that ran earlier builds.
/// They keep their old "TTT" spelling on purpose. Changing one silently resets that setting for
/// every existing user, so a rename needs a migration and explicit migration tests.
public enum SettingsKey {
    public static let talkShortcut         = "TTTDictationShortcut.v2"
    public static let bubblePlacement      = "TTTBubblePlacement.v1"
    public static let bubbleCustomPosition = "TTTBubbleCustomPosition.v1"
}

