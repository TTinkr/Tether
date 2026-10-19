


//
import Foundation
import Testing
import TokensCore
@testable import Tokens

@Suite struct PromptTargetAppTests {
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func oldEntriesDecodeWithoutAnAppAndResaveWithoutTheKey() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "entries": [["id": UUID().uuidString, "createdAt": "2026-10-03T18:00:00Z", "text": "hello there"]]
        ])
        let old = try #require(decoder.decode(PromptHistoryDocument.self, from: raw).entries.first)
        #expect(old.targetApp == nil)
        let resaved = try String(decoding: encoder.encode(old), as: UTF8.self)
        #expect(!resaved.contains("targetApp"))
    }

    @Test func appRoundTripsAndSurvivesSpokenCorrection() throws {
        let app = PromptTargetApp(bundleID: "com.openai.codex", name: "Codex")
        let authored = AuthoredPrompt(transcript: "open tinker now", spokenText: "open tinker now")
        let entry = PromptHistoryEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000),
                                       authored: authored, targetApp: app)
        let document = PromptHistoryDocument(version: 1, entries: [entry])
        let restored = try decoder.decode(PromptHistoryDocument.self, from: encoder.encode(document))
        #expect(restored.entries.first?.targetApp == app)
        #expect(entry.correctingSpoken(BrandVocabulary.apply(to:)).targetApp == app)
    }

    @Test func unknownTargetsAreNilAndNamesFallBack() {
        #expect(PromptTargetApp(bundleID: nil, name: "Ghost") == nil)
        #expect(PromptTargetApp(bundleID: Optional("  "), name: "Ghost") == nil)
        let unnamed = PromptTargetApp(bundleID: "com.apple.Terminal", name: " ")
        #expect(unnamed.name == nil)
        #expect(unnamed.displayName == "Terminal")
        #expect(PromptTargetApp(bundleID: "com.openai.codex", name: "Codex").displayName == "Codex")
    }
}

