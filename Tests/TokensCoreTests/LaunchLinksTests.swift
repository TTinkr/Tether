


//
import Foundation
import Testing
@testable import TokensCore


// LaunchLinks — the project pages the app opens


@Suite struct LaunchLinksTests {
    @Test func linksPointAtTheProjectRepositoryOverHTTPS() {
        for url in [LaunchLinks.tutorial, LaunchLinks.privacy] {
            #expect(url.scheme == "https")
            #expect(url.host == "github.com")
            #expect(url.path.hasPrefix("/TTinkr/Tether"))
        }
    }
}

