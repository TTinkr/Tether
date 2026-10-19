import AppKit
import SwiftUI
import Testing
import TokensCore
@testable import Tokens

/// Offscreen render of the Models tab (build 82): two lists, our measured columns, no winner badge,
/// rows on the grid. Writes PNGs only when TOKENS_SPEECH_PAGE_RENDER_DIR is set.
struct ModelsPageRenderTests {
    static let actions = SpeechModelActions(use: { _ in }, download: { _ in }, cancel: { _ in })
    /// A fixture result for the render and format checks; never shipped (SpeechBenchmarks.results is the run's).
    static func fixtureStats(_ id: String) -> MeasuredSpeechStats? {
        id == "orukeet" ? MeasuredSpeechStats(wer: 3.21, talkSeconds: 0.118, loadSeconds: 1.4, clips: 200)
            : id == "whisper-large-v3-turbo" ? MeasuredSpeechStats(wer: 4.05, talkSeconds: 1.26, loadSeconds: 3.9, clips: 200) : nil
    }

    /// Our numbers only, worded plainly; nothing measured reads "—"; no model is crowned.
    @Test func measuredCellsAndTags() {
        #expect(SpeechModelDisplay.accuracy(nil) == nil && SpeechModelDisplay.speed(nil) == nil)
        #expect(SpeechModelDisplay.accuracy(Self.fixtureStats("orukeet")) == "96.8%")
        #expect(SpeechModelDisplay.speed(Self.fixtureStats("orukeet")) == "0.12 s")
        #expect(SpeechModelDisplay.speed(Self.fixtureStats("whisper-large-v3-turbo")) == "1.3 s")
        let tags = SpeechModelCatalog.all.compactMap(SpeechModelDisplay.tag)
        #expect(!tags.contains("Recommended") && !tags.contains("Smallest"), "no winner badge until a benchmark crowns one")
        #expect(SpeechModelCatalog.entry("orukeet").flatMap(SpeechModelDisplay.tag) == "Default")
        #expect(SpeechModelCatalog.entry("whisper-base.en").flatMap(SpeechModelDisplay.tag) == "English")
        #expect(SpeechModelDisplay.size(SpeechModelCatalog.entry("apple")!) == "Built in")
        // Without a run the note still says whose numbers these are and what "—" means.
        #expect(SpeechModelDisplay.measuredNote(nil).contains("Tinkr's own") && SpeechModelDisplay.measuredNote(nil).contains("—"))
        // Published numbers are named as the leaderboard's, never as ours.
        #expect(SpeechModelDisplay.publishedSources.contains("not Tinkr's"))
    }

    /// Shipping without receipts: every cell is "—" (SpeechBenchmarks holds only to_swift.py output).
    @Test func shippedResultsComeFromARun() {
        if SpeechBenchmarks.run == nil { #expect(SpeechBenchmarks.results.isEmpty) }
        for id in SpeechBenchmarks.results.keys { #expect(SpeechModelCatalog.entry(id) != nil, "\(id) is not a catalogue model") }
    }

    /*
    The numbers the app ships are the run's own. The test loads docs/benchmark-summary.json, the summary whose run_id
    is SpeechBenchmarks.run.runID (verify.py rebuilt it from the raw receipts) and checks every shipped
    field of every model, the set of models, and the run line's date, clip set and chip, so a hand edit
    of SpeechBenchmarks.swift fails here. Only `build` and the machine's marketing name are to_swift.py
    arguments with no receipt.
    */
    @Test func benchmarkNumbersMatchTheirReceipts() throws {
        guard let run = SpeechBenchmarks.run else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The public tree ships the run's summary only (raw receipts and machine details stay private).
        let data = try Data(contentsOf: root.appendingPathComponent("docs/benchmark-summary.json"))
        let summary = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try #require(summary["run_id"] as? String == run.runID, "docs/benchmark-summary.json is not run \"\(run.runID)\"")
        #expect(summary["dry_run"] as? Bool == false, "a dry run never ships")
        if let selection = summary["selection"] as? [String: Any] {
            #expect(selection["partial"] as? Bool == false, "a filtered or partial run never ships")
        }

        let models = try #require(summary["models"] as? [[String: Any]])
        let measured = models.filter { $0["status"] as? String == "ok" }
        let ids = measured.compactMap { $0["id"] as? String }
        #expect(ids.count == Set(ids).count && Set(ids) == Set(SpeechBenchmarks.results.keys),
                "shipped \(SpeechBenchmarks.results.keys.sorted()) vs measured \(ids.sorted())")
        for model in measured {
            let id = try #require(model["id"] as? String)
            let shipped = try #require(SpeechBenchmarks.results[id], "\(id) measured but not shipped")
            let combined = try #require((model["wer"] as? [String: Any])?["combined"] as? [String: Any])
            let wer = try #require(combined["wer_percent"] as? Double)
            let clips = try #require(combined["clips"] as? Int)
            let talk = try #require((model["talk_10s_latency_s"] as? [String: Any])?["median"] as? Double)
            #expect(abs(shipped.wer - wer) < 0.0006, "\(id) WER \(shipped.wer) vs receipt \(wer)")
            #expect(abs(shipped.talkSeconds - talk) < 0.00006, "\(id) speed \(shipped.talkSeconds) vs receipt \(talk)")
            #expect(shipped.clips == clips, "\(id) clips \(shipped.clips) vs receipt \(clips)")
            if let load = (model["cold_first_result_s"] as? [String: Any])?["median"] as? Double {
                let shippedLoad = try #require(shipped.loadSeconds, "\(id) has a cold-start receipt but ships none")
                #expect(abs(shippedLoad - load) < 0.0006, "\(id) cold start \(shippedLoad) vs receipt \(load)")
            } else {
                #expect(shipped.loadSeconds == nil, "\(id) ships a cold start the run did not measure")
            }
        }
        #expect(SpeechBenchmarks.results["apple"] == nil, "Apple was not measured")

        // The run line under the table: the start date in the team's zone, the clip set and the chip.
        // The public summary drops started_utc; the run ID is the same UTC start, compacted.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let started = try #require(stamp.date(from: run.runID))
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        day.dateFormat = "yyyy-MM-dd"
        #expect(run.date == day.string(from: started), "date \(run.date) vs run start \(day.string(from: started))")
        let clipCounts = try #require(summary["clips"] as? [String: Any])
        let perSet = try #require(clipCounts["per_set"] as? [String: Int])
        let total = try #require(clipCounts["total"] as? Int)
        let clipSet = "\(total) LibriSpeech recordings "
            + "(\(perSet["test-clean"] ?? 0) clear, \(perSet["test-other"] ?? 0) harder)"
        #expect(run.clipSet == clipSet, "clip set \(run.clipSet) vs receipt \(clipSet)")
        // The public summary carries no machine environment; the private receipts check the chip.
        guard let env = summary["environment"] as? [String: Any] else { return }
        let chipName = try #require(env["chip"] as? String)
        let chip = chipName.replacingOccurrences(of: "Apple ", with: "")
        let memoryBytes = try #require(env["memory_bytes"] as? Double)
        let memory = Int((memoryBytes / 1_073_741_824).rounded())
        #expect(run.machine.hasSuffix("(\(chip), \(memory) GB)"), "machine \(run.machine) vs \(chip), \(memory) GB")
    }

    /// Every page-column width leaves the longest model name whole (336 read "A…" in build 80).
    @Test func narrowColumnsKeepNamesWhole() {
        let models = SpeechModelCatalog.all
        let longest = models.map { TokensUI.textWidth($0.name, size: 15) }.max() ?? 0
        #expect(SpeechTableColumns.fitting(616, models: models) == SpeechTableColumns())
        // 336: the public window's 760-point minimum at the 150% maximum zoom.
        for width in stride(from: CGFloat(336), through: 560, by: 56) {
            let columns = SpeechTableColumns.fitting(width, models: models)
            #expect(width - columns.fixedWidth >= longest, "names cut at \(width)")
        }
        // The numbers are the page's point: the narrowest column (760 window at 150%) still shows Accuracy.
        #expect(SpeechTableColumns.fitting(336, models: models).accuracy)
    }

    /*
    Both lists sit on whole squares: with the page starting on a rule, every divider (each list's
    header and every row) is on a grid line, so the centred words sit between rules.
    */
    @Test @MainActor func tableDividersLieOnGridLines() throws {
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        let models = SpeechModelCatalog.all
        for theme in [TokensTheme.paper, .chalkboard] { for width in [CGFloat(820), 459] {
            TokensTheme.current = theme
            let size = CGSize(width: width, height: 1600)
            let page = TokensModelsPage(
                models: models, availability: { $0.id == "apple" ? .inUse : $0.id == "orukeet" ? .ready : .downloadable },
                actions: Self.actions, measured: Self.fixtureStats)
                .tokensPageColumn()
                .environment(\.tokensSheetSize, size)
                .frame(width: size.width, height: size.height, alignment: .top)
            let rep = try SpeechPagePixels.render(page, size: size)
            let column = TokensColumn.layout(sheetWidth: width)
            let lines = SpeechPagePixels.dividerLines(rep, from: column.leading + 2, to: column.leading + column.width - 2)
            let label = "\(theme.rawValue) \(Int(width))"
            #expect(lines.count == models.count + 2, "\(label): \(lines.count) dividers at \(lines)")
            for top in lines {
                let offset = top - (top / TokensUI.paperCell).rounded() * TokensUI.paperCell
                #expect(offset == -1 || offset == 0, "\(label): divider at \(top) is \(offset) from a rule")
            }
        } }
    }

    /// A hovered row tints only its own square: its top screen point (the rule, and the divider above
    /// drawn on it) stays sheet or divider, never the fill.
    @Test @MainActor func hoverFillStartsUnderTheLineAbove() throws {
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        let models = SpeechModelCatalog.all
        for theme in TokensTheme.allCases {
            TokensTheme.current = theme
            let row = { (index: Int, hovering: Bool) in
                SpeechModelRow(info: models[index], stats: nil, availability: .ready, columns: SpeechTableColumns(),
                               hovering: .constant(hovering), actions: Self.actions)
            }
            let view = VStack(spacing: 0) {
                Color.clear.frame(height: TokensUI.paperCell)
                    .overlay(alignment: .topLeading) { Rectangle().fill(TokensUI.divider).frame(width: 20, height: 8) }
                row(0, false)
                row(1, true)
                Color.clear.frame(height: TokensUI.paperCell)
            }
            .frame(width: 616)
            let rep = try SpeechPagePixels.render(view, size: CGSize(width: 616, height: 4 * TokensUI.paperCell))
            let sheet = SpeechPagePixels.pixel(rep, x: 300, y: 20)
            let divider = SpeechPagePixels.pixel(rep, x: 10, y: 4)
            let fill = SpeechPagePixels.pixel(rep, x: 300, y: 2 * TokensUI.paperCell + 6)
            #expect(!SpeechPagePixels.same(fill, sheet), "\(theme.rawValue): the hover fill is not drawn")
            for y in [2 * TokensUI.paperCell, 2 * TokensUI.paperCell + 0.5] {
                let top = SpeechPagePixels.pixel(rep, x: 300, y: y)
                #expect(SpeechPagePixels.same(top, sheet) || SpeechPagePixels.same(top, divider),
                        "\(theme.rawValue): the fill tints the line above at y \(y): \(top)")
            }
        }
    }

    /// Tags ("Default", languages) are labels: never the accent red, in any theme (DESIGN.md §2.4).
    @Test @MainActor func tagsAreNotRed() throws {
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        for theme in TokensTheme.allCases {
            TokensTheme.current = theme
            for info in SpeechModelCatalog.all where SpeechModelDisplay.tag(info) != nil {
                let row = SpeechModelRow(info: info, stats: nil, availability: .notYet, columns: SpeechTableColumns(),
                                         hovering: .constant(false), actions: Self.actions)
                    .frame(width: 616)
                let rep = try SpeechPagePixels.render(row, size: CGSize(width: 616, height: TokensUI.paperCell))
                let redness = SpeechPagePixels.maxRedness(rep, width: 616 - SpeechTableColumns().fixedWidth)
                #expect(redness < 40, "\(theme.rawValue) \(info.id): the tag is red (\(redness))")
            }
        }
    }

    @Test @MainActor func rendersThePage() throws {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["TOKENS_SPEECH_PAGE_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = TokensTheme.current
        defer { TokensTheme.current = saved }
        // 820: the wide table; 459: a 760 window at 150% (a 336 column). "-measured": fixture stats.
        for theme in [TokensTheme.paper, .chalkboard] { for width in [CGFloat(820), 459] { for withStats in [false, true] {
            TokensTheme.current = theme
            let size = NSSize(width: width, height: 1300)
            let page = TokensModelsPage(
                models: SpeechModelCatalog.all,
                availability: { $0.id == "apple" ? .ready : $0.id == "orukeet" ? .inUse
                    : $0.id == "whisper-small.en" ? .downloading(0.42) : $0.id == "whisper-base.en" ? .paused
                    : $0.id == "parakeet-tdt-0.6b-v2" ? .ready : .downloadable },
                actions: Self.actions, measured: withStats ? Self.fixtureStats : { _ in nil },
                run: withStats ? SpeechBenchmarkRun(machine: "MacBook Pro (M5, 24 GB)", date: "2026-10-17",
                                                    clipSet: "200 LibriSpeech recordings", build: "81") : nil)
                .tokensPageColumn()
                .environment(\.tokensSheetSize, CGSize(width: size.width, height: size.height))
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(TokensSheetGrid())
            let host = NSHostingView(rootView: page)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("models-\(theme.rawValue)-\(Int(width))\(withStats ? "-measured" : "").png"))
        } } }
    }
}

/// Offscreen pixels at 2x for the Models page's layout checks (points, top-left origin).
@MainActor enum SpeechPagePixels {
    private final class Window: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }

    static func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.background(TokensUI.sheet))
        let window = Window(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func rgb(_ rep: NSBitmapImageRep, px: Int, py: Int) -> [Int] {
        let data = rep.bitmapData!
        let base = py * rep.bytesPerRow + px * rep.samplesPerPixel
        return (0..<3).map { Int(data[base + $0]) }
    }

    static func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> [Int] {
        rgb(rep, px: Int(x * 2), py: Int(y * 2))
    }

    static func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }

    /// The top (points) of each line drawn in one colour, not the sheet's, across x `from` to `to`.
    static func dividerLines(_ rep: NSBitmapImageRep, from: CGFloat, to: CGFloat) -> [CGFloat] {
        let x0 = Int(from * 2), x1 = Int(to * 2)
        let data = rep.bitmapData!, stride = rep.samplesPerPixel
        var tops: [CGFloat] = []
        var previous = false
        for py in 0..<rep.pixelsHigh {
            let row = py * rep.bytesPerRow
            let first = rgb(rep, px: x0, py: py)
            // x 1 is left of the page column on every width tested, so it shows the sheet.
            var line = !same(first, rgb(rep, px: 1, py: py))
            var px = x0
            while line && px < x1 {
                let base = row + px * stride
                line = (0..<3).allSatisfy { abs(Int(data[base + $0]) - first[$0]) <= 2 }
                px += 1
            }
            if line && !previous { tops.append(CGFloat(py) / 2) }
            previous = line
        }
        return tops
    }

    /// The strongest red cast (red minus the larger of green and blue) in the leading `width` points.
    static func maxRedness(_ rep: NSBitmapImageRep, width: CGFloat) -> Int {
        var most = Int.min
        for py in 0..<rep.pixelsHigh { for px in 0..<Int(width * 2) {
            let c = rgb(rep, px: px, py: py)
            most = max(most, c[0] - max(c[1], c[2]))
        } }
        return most
    }
}
