


//
import Foundation
import Testing
import TokensCore
@testable import Tokens


@Suite struct TypedHistoryParityTests {
    private let typed      = " \tTinker  Token Maxxing\r\n\n## Typed\n café e\u{301} 👩🏽‍💻 日本語\t \n\n"
    private let transcript = "## Transcript\n\nShip this today"

    @Test func copiedPayloadAndHistoryPreserveTypedBytes() throws {
        let authored = AuthoredPrompt(transcript: transcript, spokenText: "Ship this today", typed: typed)
        let entry = PromptHistoryEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: 1000), authored: authored)
        let document = PromptHistoryDocument(version: 1, entries: [entry])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PromptHistoryDocument.self, from: encoder.encode(document))
        let saved = try #require(restored.entries.first)
        let provenance = try #require(saved.authored)

        #expect(restored.version == 1)
        #expect(Array(provenance.typed.utf8) == Array(typed.utf8))
        #expect(Array(saved.text.utf8) == Array((transcript + "\n\n## Typed\n\n" + typed).utf8))
        #expect(Array(saved.text.utf8) == Array(authored.presented(over: transcript).utf8))
        #expect(provenance.spokenText == "Ship this today")
        #expect(provenance.spokenWordCount == 3)
    }

    @Test func literalHeadingsNeverDecideAuthorship() throws {
        let spoken = "say this\n## Typed\nand continue"
        let authored = AuthoredPrompt(transcript: "## Transcript\n\n" + spoken,
                                      spokenText: spoken, typed: typed)
        let restored = try JSONDecoder().decode(AuthoredPrompt.self, from: JSONEncoder().encode(authored))
        #expect(restored.spokenText == spoken)
        #expect(restored.spokenText.hasSuffix("and continue"))
        #expect(restored.spokenWordCount == 6)
        #expect(Array(restored.typed.utf8) == Array(typed.utf8))
    }

    @Test func brandCorrectionNeverRespellsTypedText() throws {
        let authored = AuthoredPrompt(transcript: "## Transcript\n\nopen tinker now",
                                      spokenText: "open tinker now", typed: typed)
        let entry      = PromptHistoryEntry(id: UUID(), createdAt: Date(), authored: authored)
        let corrected  = entry.correctingSpoken(BrandVocabulary.apply(to:))
        let provenance = try #require(corrected.authored)
        #expect(provenance.spokenText == BrandVocabulary.apply(to: "open tinker now"))
        #expect(provenance.spokenText != "open tinker now")
        #expect(Array(provenance.typed.utf8) == Array(typed.utf8))
        #expect(corrected.text.hasSuffix(typed))
        #expect(corrected.id == entry.id && corrected.createdAt == entry.createdAt)
    }

    @Test func generatedPresentationNeverEntersHistoryOrSpokenInput() {
        let authored  = AuthoredPrompt(transcript: transcript, spokenText: "Ship this today", typed: typed)
        let decorated = "> *AI question:* Who owns the rollout?\n\n" + transcript
        let copied    = authored.presented(over: decorated) + "\n\n## Questions\n\nWhen should we ship?"
        let entry     = PromptHistoryEntry(id: UUID(), createdAt: Date(), authored: authored)
        #expect(copied.contains("Who owns the rollout?"))
        #expect(!entry.text.contains("Who owns the rollout?"))
        #expect(!entry.text.contains("When should we ship?"))
        #expect(entry.authored?.spokenText == "Ship this today")
        #expect(entry.authored?.spokenWordCount == 3)
        #expect(!authored.spokenText.contains("Tinker"))
    }

    @Test func oldVersionOneHistoryDecodesWithoutGuessingTypedBoundaries() throws {
        let oldText = "  tinker\n## Typed\nTinker stays literal\r\n \t"
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "entries": [["id": UUID().uuidString, "createdAt": "2026-10-03T18:00:00Z", "text": oldText]]
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try #require(decoder.decode(PromptHistoryDocument.self, from: raw).entries.first)
        #expect(old.authored == nil)
        #expect(Array(old.text.utf8) == Array(oldText.utf8))
        #expect(old.correctingSpoken(BrandVocabulary.apply(to:)) == old)
        let encoder                  = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let resaved                  = try decoder.decode(PromptHistoryEntry.self, from: encoder.encode(old))
        #expect(Array(resaved.text.utf8) == Array(oldText.utf8))
        #expect(resaved.authored == nil)
    }

//
// :)
//
//
    @Test func compatibilityAppendPreservesWhitespaceAndEmptyNotesAddNothing() {
        #expect(ThinkingNotes.appending("", to: transcript) == transcript)
        for note in [typed, " \n\t ", "\n\n", "## Typed", "typed without speech"] {
            #expect(Array(ThinkingNotes.appending(note, to: transcript).utf8)
                    == Array((transcript + "\n\n## Typed\n\n" + note).utf8))
        }
        let typedOnly = AuthoredPrompt(transcript: "", spokenText: "", typed: typed)
        #expect(typedOnly.text == "## Transcript\n\n## Typed\n\n" + typed)
        #expect(typedOnly.spokenWordCount == 0)
        #expect(!typedOnly.isEmpty)
    }

    @Test @MainActor func notesEnteredBetweenTalksSurviveStartAndConsumeOnce() {
        let state   = ThinkingPanelState()
        state.notes = typed
        state.beginSession()
        #expect(Array(state.notes.utf8) == Array(typed.utf8))
        #expect(Array(state.consumeNotesForDelivery().utf8) == Array(typed.utf8))
        #expect(state.notes.isEmpty)
        #expect(state.consumeNotesForDelivery().isEmpty)
        state.notes = " next talk \n"
        state.beginSession()
        #expect(state.notes == " next talk \n")
        #expect(state.batches.isEmpty)
    }
}

