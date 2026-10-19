


//
import Foundation


// ProofRoutes — test launch commands stay out of the public download



/// Mutating QA routes require an explicit developer build. Missing metadata fails closed.
enum ProofRoutes {
    static func allowed(distributionMode: String?) -> Bool { distributionMode == "dev" }

    
    static func nativeBubblePreviewAllowed(arguments: [String], distributionMode: String?) -> Bool {
        ["preview", "dev"].contains(distributionMode ?? "") && arguments.contains("--native-bubble-preview")
    }
    static let nativeBubblePreview = nativeBubblePreviewAllowed(arguments: ProcessInfo.processInfo.arguments,
        distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String)

    static let isAllowed = allowed(
        distributionMode: Bundle.main.object(forInfoDictionaryKey: "TokensDistributionMode") as? String)
}

