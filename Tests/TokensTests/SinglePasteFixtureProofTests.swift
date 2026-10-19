import Foundation
import Testing
@testable import Tokens

struct SinglePasteFixtureProofTests {
    @Test func browserFixturePreservesLeadingByteOrderMark() {
        let bytes = Data([0xEF, 0xBB, 0xBF, 0x41, 0x0A])
        #expect(SinglePasteFixtureProof.fixtureText(bytes).map { Data($0.utf8) } == bytes)
    }
    @Test func continuousBrowserProofRequiresExplicitDevelopmentIdentityAndMode() {
        #expect(SinglePasteFixtureProof.allowed(distributionMode: "dev", proofRoutesAllowed: true,
            continuousReveal: true, devChannel: true))
        for mode in ["distribution", "local-production", "fresh", "unknown"] {
            #expect(!SinglePasteFixtureProof.allowed(distributionMode: mode, proofRoutesAllowed: true,
                continuousReveal: true, devChannel: true))
        }
        #expect(!SinglePasteFixtureProof.allowed(distributionMode: "dev", proofRoutesAllowed: true,
            continuousReveal: false, devChannel: true))
        #expect(!SinglePasteFixtureProof.allowed(distributionMode: "dev", proofRoutesAllowed: true,
            continuousReveal: true, devChannel: false))
        #expect(!SinglePasteFixtureProof.allowed(distributionMode: "dev", proofRoutesAllowed: false,
            continuousReveal: true, devChannel: true))
    }
    private let id = "tokens-fictional-123456"

    @Test func rawFixtureRequiresBoundedValidUTF8AndPreservesExactBytes() {
        let raw = "é e\u{301} 👩🏽‍💻\nsecond line"
        #expect(SinglePasteFixtureProof.fixtureText(Data(raw.utf8))?.utf8.elementsEqual(raw.utf8) == true)
        #expect(SinglePasteFixtureProof.fixtureText(Data(repeating: 65, count: 65_536)) != nil)
        #expect(SinglePasteFixtureProof.fixtureText(Data(repeating: 65, count: 65_537)) == nil)
        #expect(SinglePasteFixtureProof.fixtureText(Data([0xff, 0xfe])) == nil)
    }

    @Test func requiresExplicitPreviewAndProofPermission() {
        for mode in [nil, "", "distribution", "development", "local", "Preview"] as [String?] {
            #expect(!SinglePasteFixtureProof.allowed(distributionMode: mode, proofRoutesAllowed: true))
        }
        #expect(!SinglePasteFixtureProof.allowed(distributionMode: "preview", proofRoutesAllowed: false))
        #expect(SinglePasteFixtureProof.allowed(distributionMode: "preview", proofRoutesAllowed: true))
    }

    @Test func ownedFixtureAllowsOnlyExactSentinelAndKnownEndCaret() {
        let text = SinglePasteFixtureProof.sentinel(fixtureID: id)
        func check(value: String?, selection: NSRange?) -> String? {
            SinglePasteFixtureProof.ownershipFailure(fixtureID: id, targetBundle: "com.apple.Safari",
                title: "Owned \(id)", value: value, role: "AXTextArea", secure: false, selection: selection)
        }
        #expect(check(value: text, selection: NSRange(location: text.utf16.count, length: 0)) == nil)
        #expect(check(value: text, selection: nil) == nil)
        #expect(check(value: nil, selection: nil) == "fixture_value_mismatch")
        #expect(check(value: text + "private words", selection: nil) == "fixture_value_mismatch")
        #expect(check(value: text, selection: NSRange(location: 0, length: 0)) == "fixture_caret_mismatch")
        #expect(check(value: text, selection: NSRange(location: text.utf16.count, length: 1)) == "fixture_caret_mismatch")
    }

    @Test func rejectsUnownedWindowsSecureFieldsAndUnlistedApps() {
        let text = SinglePasteFixtureProof.sentinel(fixtureID: id)
        func check(bundle: String = "com.apple.Safari", title: String? = nil,
                   role: String? = "AXTextArea", secure: Bool = false) -> String? {
            SinglePasteFixtureProof.ownershipFailure(fixtureID: id, targetBundle: bundle,
                title: title, value: text, role: role, secure: secure, selection: nil)
        }
        #expect(check() == "owned_window_not_focused")
        #expect(check(title: "An unrelated editor") == "owned_window_not_focused")
        #expect(check(bundle: "com.example.arbitrary", title: id) == "target_bundle_not_allowed")
        #expect(check(title: id, role: "AXWebArea") == "requires_unprotected_text_field")
        #expect(check(title: id, role: nil) == "requires_unprotected_text_field")
        #expect(check(title: id, secure: true) == "requires_unprotected_text_field")
        for bundle in SinglePasteFixtureProof.allowedBundles { #expect(check(bundle: bundle, title: id) == nil) }
    }

    @Test func invalidNoncesCannotMatchBroadWindowTitles() {
        for invalid in ["", "a", "title with spaces", "fixture/../../secret", id + "\n", String(repeating: "a", count: 81)] {
            #expect(!SinglePasteFixtureProof.validFixtureID(invalid))
        }
        #expect(SinglePasteFixtureProof.validFixtureID(id))
    }

    @Test func receiptContainsHashesAndCountsWithoutFixtureText() throws {
        let payload = SinglePasteFixtureProof.payload(fixtureID: id)
        var receipt = SinglePasteFixtureProof.Receipt(fixtureID: id, targetBundle: "com.apple.Safari")
        receipt.afterCharacters = payload.utf16.count
        receipt.afterSHA256 = SinglePasteFixtureProof.digest(payload)
        let data = try JSONEncoder().encode(receipt)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("fictional blue notebook"))
        #expect(!receipt.physicalInput && !receipt.microphoneUsed)
        #expect(receipt.insertInvocations == 0 && receipt.returnInvocations == 0 && receipt.retryInvocations == 0)
        #expect(receipt.afterSHA256?.count == 64)
        #expect(SinglePasteFixtureProof.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(payload.hasSuffix("  Exact fictional ending.  \n"))
        #expect(payload.contains("👩🏽‍💻") && payload.utf16.count > 8000)
    }
}
