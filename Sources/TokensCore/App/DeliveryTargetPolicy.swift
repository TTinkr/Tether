


//
/*
DeliveryTargetPolicy.swift
Owns: recognizing our app family before selecting a paste destination.
Never: inspect windows, change focus, or authorize a paste by itself.
See: Channel.swift; Tokens/Delivery/TargetTracker.swift.
*/


/// Both channels are control surfaces, not destinations for their own output.
/// Keep identity separate from the visible product name: renaming the app must
/// not make a sibling build look like a safe external editor.
public enum DeliveryTargetPolicy {
    public static func isOwnApplication(processID: Int32, bundleIdentifier: String?,
                                        currentProcessID: Int32) -> Bool {
        if processID == currentProcessID { return true }
        if Channel(bundleIdentifier: bundleIdentifier) != nil { return true }

        /*
        Retained companions can still run while people migrate. Do not send
        their captured words back into those microphone-owning apps either.
        */
        return bundleIdentifier == "com.tinkr.tokens.community.lab.macos"
            || bundleIdentifier == "com.tinkr.tokens.community.talk.macos"
    }

    /*
    The lock screen, the screen saver and macOS password prompts are never a place for words
    (build 81: a talk stopped while the Mac was locked chose loginwindow as its target).
    */
    public static let protectedSystemSurfaces: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.SecurityAgent",
    ]

    public static func isProtectedSystemSurface(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(protectedSystemSurfaces.contains) ?? false
    }
}

