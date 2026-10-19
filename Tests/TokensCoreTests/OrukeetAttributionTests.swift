import Foundation
import Testing
@testable import TokensCore

/// The CC BY-SA 4.0 credit must name Oruk, the license and the model page wherever Orukeet is named.
@Suite struct OrukeetAttributionTests {
    @Test func lineCreditsOrukAndLicense() {
        #expect(OrukeetAttribution.line == "Orukeet by Oruk, CC BY-SA 4.0")
        #expect(OrukeetAttribution.line.contains(OrukeetAttribution.license))
    }

    @Test func engineCaptionCarriesTheCredit() {
        #expect(OrukeetAttribution.engineCaption.hasPrefix(OrukeetAttribution.line))
        #expect(OrukeetAttribution.engineCaption.contains("local model on this Mac"))
    }

    @Test func linksPointAtTheModelAndLicense() {
        #expect(OrukeetAttribution.modelPage.absoluteString == "https://huggingface.co/oruk/orukeet")
        #expect(OrukeetAttribution.licensePage.host == "creativecommons.org")
    }
}
