


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI
import TokensCore


// PromptHistoryEntry — One saved prompt: an id, when it was made, and its text


struct PromptHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    /*
    Missing on older v1 entries. Never guess the boundary from a heading:
    legacy text remains byte-for-byte intact when decoded or saved again.
    */
    let authored: AuthoredPrompt?
    /*
    The app in front at the stop (bundle id + localized name), build 77+. Local only: it is
    saved in this file and read by Stats and History, never sent or logged. Nil on older
    entries and when no target was captured; an absent key decodes as nil and a nil value
    is not written, so older files re-save unchanged.
    */
    let targetApp: PromptTargetApp?

    init(id: UUID, createdAt: Date, text: String, authored: AuthoredPrompt? = nil,
         targetApp: PromptTargetApp? = nil) {
        self.id        = id
        self.createdAt = createdAt
        self.text      = text
        self.authored  = authored
        self.targetApp = targetApp
    }

    init(id: UUID, createdAt: Date, authored: AuthoredPrompt, targetApp: PromptTargetApp? = nil) {
        self.init(id: id, createdAt: createdAt, text: authored.text, authored: authored, targetApp: targetApp)
    }

    /// Unstructured legacy text could already contain literal typed content.
    /// Preserve it rather than applying a guessed correction or migration.
    func correctingSpoken(_ correct: (String) -> String) -> Self {
        guard let authored else { return self }
        return Self(id: id, createdAt: createdAt, authored: authored.correctingSpoken(correct), targetApp: targetApp)
    }
}


// PromptHistoryDocument — The file as stored: a version number and the list of entries


struct PromptHistoryDocument: Codable {
    // Only version 1 is understood; load() treats any other number as a corrupt file.
    let version: Int
    let entries: [PromptHistoryEntry]
}


// PromptHistoryStore — Reads and writes prompt-history.json, and recovers it if it is damaged


enum PromptHistoryStore {


    // Load and save — the happy path


    private static let filename = "prompt-history.json"
    /*
    Optional subfolder under the app's folder. TalkModel sets it each time a product is selected
    (selectProduct): the Talk product uses a "Telepathy" subfolder, any other product uses none.
    */
    static var productFolder: String?
    /*
    Tests only: a throwaway folder used in place of Application Support/<bundle id>, so a test
    can make a History save fail or succeed without touching anyone's real History (build 81).
    */
    nonisolated(unsafe) static var directoryOverride: URL?

    /*
    No file yet is not an error: it gives an empty list. A file that exists but cannot be read,
    decoded, or has a version other than 1 throws, so the caller can start recovery.
    */
    static func load() throws -> [PromptHistoryEntry] {
        // Until this read succeeds, no History row counts as saved (the journal keeps every talk).
        HistoryRowsOnDisk.replace(with: [])
        let url = try historyURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try PrivateFileStore.read(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(PromptHistoryDocument.self, from: data)
        guard document.version == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        HistoryRowsOnDisk.replace(with: document.entries.map(\.id))
        return document.entries
    }

//
// :)
//
//
    /*
    Replaces the whole file in one atomic write. Pretty-printed with sorted keys so the file is
    readable and a re-save of the same entries gives identical text. Only after the write lands
    are these rows confirmed for the recovery journal (HistoryRowsOnDisk, build 81); a failed
    write leaves the old file, and the old confirmation, in place.
    */
    static func save(_ entries: [PromptHistoryEntry]) throws {
        let url = try historyURL(createDirectory: true)
        let document = PromptHistoryDocument(version: 1, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFileStore.write(encoder.encode(document), to: url)
        HistoryRowsOnDisk.replace(with: entries.map(\.id))
    }


    // Recovery and location — recoverPreservingSource(), historyURL()


    /// Copies the existing source byte-for-byte before replacing it with a fresh document.
    /// A corrupt source is never moved or deleted as part of recovery.
    /// The copy is named prompt-history.preserved-<unix time>-<8 random characters>.json, in
    /// the same folder, and its URL is returned (nil if there was nothing to copy).
    static func recoverPreservingSource(
        with entries: [PromptHistoryEntry]
    ) throws -> URL? {
        let sourceURL = try historyURL(createDirectory: true)
        var preservedURL: URL?
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            let timestamp = Int(Date().timeIntervalSince1970)
            let nonce     = UUID().uuidString.prefix(8)
            let backup = sourceURL.deletingLastPathComponent().appendingPathComponent(
                "prompt-history.preserved-\(timestamp)-\(nonce).json"
            )
            try PrivateFileStore.write(PrivateFileStore.read(from: sourceURL), to: backup)
            preservedURL = backup
        }
        try save(entries)
        return preservedURL
    }

    /*
    Application Support/<bundle id>/[productFolder]/prompt-history.json. The folders are created
    only when asked (`createDirectory`), so merely reading history never makes folders.
    */
    private static func historyURL(createDirectory: Bool) throws -> URL {
        let base: URL
        if let directoryOverride {
            base = directoryOverride
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: createDirectory
            )
            let identity = Bundle.main.bundleIdentifier ?? "com.tinkr.tokens.community.lab.macos"
            base = support.appendingPathComponent(identity, isDirectory: true)
        }
        let directory = productFolder.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
        if createDirectory {
            try PrivateFileStore.prepareDirectory(directory)
        }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }


}

