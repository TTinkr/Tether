


//
/*
ProductIdentity.swift
Owns: the human-facing name of the Tokens app.
Never: rename saved settings, bundle IDs, permissions or transcript history.
See: TokensApp.swift; TokensCore/App/Channel.swift; scripts/package_app.py.
*/


import Foundation


/*
The bundle may add a visible Dev or Preview suffix. SwiftPM tests and
unbundled launches still get the actual product name instead of an old brand.
*/
enum ProductIdentity {
    static let name = "Tokens"

    static var displayName: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : name
    }
}

