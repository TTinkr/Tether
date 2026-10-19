// swift-tools-version: 6.0


//
// Tokens: talk to your Mac, get text.
import PackageDescription

let package = Package(
    name: "Tokens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tokens", targets: ["Tokens"]),
        .library(name: "TokensCore", targets: ["TokensCore"]),
    ],
    dependencies: [
        // In-app updates. Pinned to the version the previous tree shipped with.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        /*
        The app. Lifted from the previous tree and split by area; still Swift 5 mode
        until each area is moved to strict concurrency.
        */
        .executableTarget(
            name: "Tokens",
            /*
            The app consumes the same pure rules exercised by TokensCoreTests.
            Bubble placement and shared transcript/shortcut policies use this dependency.
            */
            dependencies: ["TokensCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Inside Tokens.app the updater framework sits in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Pure logic. No AppKit, no microphone, no files on disk except through injected UserDefaults.
        .target(name: "TokensCore"),
        .testTarget(name: "TokensCoreTests", dependencies: ["TokensCore"]),
        // The app's own checks, lifted from the previous tree's stand-alone test programs.
        .testTarget(name: "TokensTests", dependencies: ["Tokens"], exclude: ["Fixtures"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ],
    swiftLanguageModes: [.v6]
)

