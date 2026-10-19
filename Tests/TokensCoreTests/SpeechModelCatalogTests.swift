import Foundation
import Testing
@testable import TokensCore

struct SpeechModelCatalogTests {
    @Test func idsAreUniqueStableAndMatchTheSavedChoices() {
        let ids = SpeechModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Existing saved choices must keep resolving after build 79.
        #expect(SpeechModelCatalog.entry(SpeechEngineChoice.apple.rawValue)?.runtime == .apple)
        #expect(SpeechModelCatalog.entry(SpeechEngineChoice.orukeet.rawValue)?.runtime == .nemoGGML)
    }

    /// A row either has a fully pinned download, or (coming soon) a planned size and nothing to fetch.
    @Test func everyDownloadIsPinned() {
        for entry in SpeechModelCatalog.all {
            if entry.runtime == .apple { #expect(entry.download == nil); continue }
            guard let download = entry.download else {
                #expect(entry.plannedDownloadBytes ?? 0 > 0, "\(entry.id): coming soon needs its published size")
                continue
            }
            #expect(download.url.scheme == "https")
            #expect(download.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
            #expect(download.bytes > 0)
        }
    }

    /// Every published number names its board and date, and is a plausible percentage / speed.
    @Test func publishedStatsAreSourced() {
        for entry in SpeechModelCatalog.all {
            guard let stats = entry.published else { #expect(entry.runtime == .apple); continue }
            #expect(stats.wer > 0 && stats.wer < 50, "\(entry.id)")
            #expect(stats.asOf.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil)
            #expect(stats.sourceURL.scheme == "https")
            if stats.macRealtime != nil { #expect(stats.macSourceURL?.scheme == "https") }
        }
        // the approved ten (build 79).
        #expect(SpeechModelCatalog.all.count == 10)
    }
}

struct SpeechModelSelectionTests {
    @Test func savedIDsRouteByRuntimeAndUnknownIDsUseTheDefault() throws {
        let suite = "SpeechModelSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SpeechEngineChoice.selectedModelID(from: defaults, orukeetBundled: true) == "orukeet")
        #expect(SpeechEngineChoice.selectedModelID(from: defaults, orukeetBundled: false) == "apple")
        defaults.set("a-model-from-the-future", forKey: SpeechEngineChoice.preferenceKey)
        #expect(SpeechEngineChoice.selectedModelID(from: defaults, orukeetBundled: true) == "orukeet")
        defaults.set("apple", forKey: SpeechEngineChoice.preferenceKey)
        #expect(SpeechEngineChoice.intended(from: defaults, orukeetBundled: true) == .apple)
        defaults.set("orukeet", forKey: SpeechEngineChoice.preferenceKey)
        #expect(SpeechEngineChoice.intended(from: defaults, orukeetBundled: true) == .orukeet)
    }
}
