


//
import AppKit
import SwiftUI
import TokensCore

enum VoiceLedgerSource {
    /// Spoken part only when the entry is structured, so typed notes never inflate word counts.
    static func records(_ entries: [PromptHistoryEntry], events: [(date: Date, bundle: String)]) -> [VoiceRecord] {
        entries.compactMap { entry in
            VoiceRecord.parse(text: entry.authored?.transcript ?? entry.text, date: entry.createdAt,
                              app: VoiceAppAttribution.app(at: entry.createdAt, events: events))
        }
    }

    /// Bundle ids and times from Diagnostics' word-free events.log, read backwards in chunks until
    /// the first line older than `since` (or the file start, or `hardCap` bytes); empty if absent.
    /// A fixed tail missed a third of 14 days on a 7 MB production log, so the read follows the window.
    static func deliveryEvents(url: URL = Diagnostics.url, since: Date,
                               chunk: UInt64 = 1 << 20, hardCap: UInt64 = 64 << 20) -> [(date: Date, bundle: String)] {
        let (newest, covered) = readBackwards(url, since: since, chunk: chunk, hardCap: hardCap)
        var data = newest
        // After a size rotation the older lines are in events.1.log: read on into it (build 81).
        if !covered, UInt64(data.count) < hardCap {
            var older = readBackwards(Diagnostics.previousURL(for: url), since: since, chunk: chunk,
                                      hardCap: hardCap - UInt64(data.count)).data
            if let last = older.last, last != 0x0A { older.append(0x0A) }
            data = older + data
        }
        return VoiceAppAttribution.events(fromLog: String(decoding: data, as: UTF8.self))
    }

    /// One file's tail back to the first line older than `since`; `covered` is false when the
    /// read reached the file's start (or found no file) without getting that far back.
    private static func readBackwards(_ url: URL, since: Date, chunk: UInt64,
                                      hardCap: UInt64) -> (data: Data, covered: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = size
        var data = Data()
        while offset > 0, size - offset < hardCap {
            let step = min(chunk, offset, hardCap - (size - offset))
            offset -= step
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let piece = try? handle.read(upToCount: Int(step)) else { break }
            data = piece + data
            if let first = firstFullLineDate(data, atFileStart: offset == 0), first < since { return (data, true) }
        }
        return (data, offset > 0)
    }

    /// Timestamp of the first complete line in `data` (skipping a partial leading line mid-file).
    static func firstFullLineDate(_ data: Data, atFileStart: Bool) -> Date? {
        var start = data.startIndex
        if !atFileStart {
            guard let newline = data.firstIndex(of: 0x0A) else { return nil }
            start = data.index(after: newline)
        }
        guard let space = data[start...].prefix(40).firstIndex(of: 0x20) else { return nil }
        return ISO8601DateFormatter().date(from: String(decoding: data[start..<space], as: UTF8.self))
    }

    /// Start of the ledger's 14 days, padded a day so the attribution window at the edge still finds events.
    static func windowStart(now: Date, calendar: Calendar = .current, dayCount: Int = 14) -> Date {
        calendar.date(byAdding: .day, value: -dayCount, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-Double(dayCount + 1) * 86_400)
    }
}

/// One reusable window; each open rebuilds the numbers from what is in memory right then.
@MainActor
final class VoiceLedgerWindowController {
    static let shared = VoiceLedgerWindowController()
    private var window: NSWindow?

    func show(history: [PromptHistoryEntry]) {
        let now = Date()
        let events = VoiceLedgerSource.deliveryEvents(since: VoiceLedgerSource.windowStart(now: now))
        let ledger = VoiceLedger.build(VoiceLedgerSource.records(history, events: events), now: now)
        let view = VoiceLedgerView(ledger: ledger)
        let window = self.window ?? {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            made.title = "Your voice"
            made.isReleasedWhenClosed = false
            made.minSize = NSSize(width: 640, height: 420)
            made.center()
            self.window = made
            return made
        }()
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

//
// :)
//
//
/*
--render-voice-ledger <dir> --voice-ledger-fixture: synthetic π envelopes of the placeholder
word "talk" go through the real parse → ledger → view path, then render offscreen (never ordered
front) at the default 760×760, the 640×420 minimum, and 1040×720. Prints counts only.
*/
@MainActor
enum VoiceLedgerProof {
    static let sizes = [NSSize(width: 760, height: 760), NSSize(width: 640, height: 420), NSSize(width: 1040, height: 720)]

    static func fixture(now: Date) -> [PromptHistoryEntry] {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var entries: [PromptHistoryEntry] = []
        for day in 0..<14 where day != 9 {
            for talk in 0..<(2 + next(6)) {
                let words = 20 + next(160), wpm = 150 + next(150) + (day < 5 ? 30 : 0)
                let seconds = Double(words) * 60 / Double(wpm)
                let pause = Double(5 + next(40)) / 10
                let body = Array(repeating: "talk", count: words / 2).joined(separator: " ")
                    + " *[pause \(String(format: "%.4f", pause))]* "
                    + Array(repeating: "talk", count: words - words / 2).joined(separator: " ")
                let stats = String(format: "> *%.4fs · %d words · %d wpm · 1x thinking (%.4fs)*", seconds, words, wpm, pause)
                let text = "# π\n" + body + "\n\n---\n\n" + AuthoredPrompt.metadataHeading + "\n\n" + stats
                let date = now.addingTimeInterval(-Double(day) * 86_400 - Double(talk * 1_800))
                entries.append(PromptHistoryEntry(id: UUID(), createdAt: date, text: text))
            }
        }
        return entries
    }

    static func render(to directoryPath: String) -> Int32 {
        let now = Date()
        let entries = fixture(now: now)
        let events = entries.enumerated().map { (date: $0.element.createdAt.addingTimeInterval(2), bundle: ["com.openai.codex", "com.openai.codex", "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.apple.Safari"][$0.offset % 6]) }
        let ledger = VoiceLedger.build(VoiceLedgerSource.records(entries, events: events), now: now)
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        for size in sizes {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            let view = NSHostingView(rootView: VoiceLedgerView(ledger: ledger))
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            for _ in 0..<3 {
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = "voice-ledger-\(Int(size.width))x\(Int(size.height))-\(TokensTheme.current.rawValue).png"
            if let data = bitmap.representation(using: .png, properties: [:]),
               (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil {
                written += 1
            }
        }
        print("VOICE_LEDGER_RENDER talks=\(ledger.total.talks) apps=\(ledger.apps.count) streak=\(ledger.streak) written=\(written)")
        return written == sizes.count ? 0 : 1
    }
}

