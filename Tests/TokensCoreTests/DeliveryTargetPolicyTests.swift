


//
/*
DeliveryTargetPolicyTests.swift
Owns: preventing capture apps from becoming each other's paste destination.
Never: launch apps or access the real clipboard or Accessibility tree.
See: App/DeliveryTargetPolicy.swift; Tokens/Delivery/TargetTracker.swift.
*/


import Testing
@testable import TokensCore


struct DeliveryTargetPolicyTests {
    @Test func bothChannelsAndLegacyCompanionsAreExcluded() {
        let identities = Channel.allCases.map(\.bundleIdentifier)
            + ["com.tinkr.tokens.community.lab.macos", "com.tinkr.tokens.community.talk.macos"]
        for identity in identities {
            #expect(DeliveryTargetPolicy.isOwnApplication(
                processID: 20, bundleIdentifier: identity, currentProcessID: 10))
        }
    }

    @Test func processIdentityProtectsUnbundledPreviews() {
        #expect(DeliveryTargetPolicy.isOwnApplication(
            processID: 10, bundleIdentifier: nil, currentProcessID: 10))
        #expect(!DeliveryTargetPolicy.isOwnApplication(
            processID: 20, bundleIdentifier: nil, currentProcessID: 10))
    }

    @Test func externalEditorsAndSimilarNamesAreNotOurApps() {
        for identity in ["com.todesktop.230313mzl4w4u92", "com.example.tokens", "com.tinkr.tokens.community.dev.macos.fake"] {
            #expect(!DeliveryTargetPolicy.isOwnApplication(
                processID: 20, bundleIdentifier: identity, currentProcessID: 10))
        }
    }
}

