import Testing
@testable import Tokens

@Suite struct SpeechAssetPolicyTests {
    @Test func missingAssetsCannotReachInstallerInInstalledOnlyMode() async {
        var requests = 0
        do {
            try await SpeechAssetPolicy.ensure(installed: false, allowDownload: false) { requests += 1 }
            Issue.record("missing installed assets accepted")
        } catch StreamingSpeechError.assetsNotInstalled {} catch { Issue.record("wrong failure: \(error)") }
        #expect(requests == 0)
    }
    @Test func installedAssetsNeverRequestInstallation() async throws {
        for allowed in [true, false] {
            var requests = 0
            try await SpeechAssetPolicy.ensure(installed: true, allowDownload: allowed) { requests += 1 }
            #expect(requests == 0)
        }
    }
    @Test func normalPolicyRetainsInstallation() async throws {
        var requests = 0
        try await SpeechAssetPolicy.ensure(installed: false, allowDownload: true) { requests += 1 }
        #expect(requests == 1)
    }
}
