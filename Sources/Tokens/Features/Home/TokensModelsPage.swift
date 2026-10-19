
import SwiftUI
import TokensCore

/// Where a model stands on this Mac. The engine fills this in; the page only shows it.
/// noSpace: its download stopped (or never started) because the disk is too full (build 81).
enum SpeechModelAvailability: Equatable, Sendable {
    case inUse, ready, downloadable, downloading(Double), paused, noSpace, notYet

    /// On this Mac now: the built-in recognizer, or a verified download.
    var installed: Bool {
        switch self { case .inUse, .ready: true; default: false }
    }
}

/// What a row can ask the store to do.
struct SpeechModelActions {
    var use: (SpeechModelEntry) -> Void
    var download: (SpeechModelEntry) -> Void
    var cancel: (SpeechModelEntry) -> Void
    var remove: ((SpeechModelEntry) -> Void)? = nil
}

struct TokensModelsPage: View {
    let models: [SpeechModelEntry]
    let availability: (SpeechModelEntry) -> SpeechModelAvailability
    let actions: SpeechModelActions
    /// Switching is off while a talk is running; the page says why.
    var talking = false
    var measured: (String) -> MeasuredSpeechStats? = SpeechBenchmarks.measured
    var run: SpeechBenchmarkRun? = SpeechBenchmarks.run

    @Environment(\.tokensSheetSize) private var sheet
    @State private var hovered: String?
    @State private var showsPublished = false

    private var columns: SpeechTableColumns {
        SpeechTableColumns.fitting(TokensColumn.layout(sheetWidth: sheet.width).width, models: models)
    }
    private var installed: [SpeechModelEntry] { models.filter { availability($0).installed } }
    private var more: [SpeechModelEntry] { models.filter { !availability($0).installed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(talking ? "Finish this talk to switch models." : "Models turn your talk into text. Each one runs on this Mac; your words never leave it.")
                .font(TokensType.body)
                .foregroundStyle(TokensUI.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .tokensReadingPitch()
                .tokensOnRule()
            TokensRuleSpacer(cells: 1)
            list("On this Mac", installed, id: "installed")
            if !more.isEmpty {
                TokensRuleSpacer(cells: 1)
                list("More models", more, id: "available")
            }
            Text(SpeechModelDisplay.measuredNote(run))
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .tokensReadingPitch(size: 13)
                .tokensOnRule()
                .accessibilityIdentifier("tokens.models.measured-note")
            publishedComparisons
        }
        .accessibilityIdentifier("tokens.models")
    }

    /// One list: its name in the header square (where "Model" would be), then one square per model.
    private func list(_ title: String, _ rows: [SpeechModelEntry], id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title)
            ForEach(rows) { info in
                SpeechModelRow(info: info, stats: measured(info.id), availability: availability(info), columns: columns,
                               talking: talking,
                               hovering: Binding(get: { hovered == info.id },
                                                 set: { hovered = $0 ? info.id : (hovered == info.id ? nil : hovered) }),
                               actions: actions)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tokens.models.\(id)")
    }

    private func header(_ title: String) -> some View {
        TokensHistoryCellLayout {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .font(TokensType.captionStrong)
                    .foregroundStyle(TokensUI.ink2)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if columns.accuracy { Text("Accuracy").frame(width: SpeechModelRow.accuracyWidth, alignment: .leading) }
                if columns.speed { Text("Speed").frame(width: SpeechModelRow.speedWidth, alignment: .leading) }
                Color.clear.frame(width: columns.actionWidth, height: 1)
            }
            .font(TokensType.caption)
            .foregroundStyle(TokensUI.secondary)
            .lineLimit(1)
        }
        .overlay(alignment: .bottom) { TokensHistoryDivider() }
    }

    /*
    The makers' and the Open ASR Leaderboard's numbers, kept apart from ours and named as theirs:
    one line per model on its own rule, behind a disclosure so the page leads with what we measured.
    */
    @ViewBuilder private var publishedComparisons: some View {
        Button {
            showsPublished.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(showsPublished ? 90 : 0))
                Text("Published comparisons")
            }
            .font(TokensType.caption)
            .foregroundStyle(TokensUI.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tokensOnRule()
        .accessibilityValue(showsPublished ? "Shown" : "Hidden")
        .accessibilityIdentifier("tokens.models.published")
        if showsPublished {
            ForEach(models.filter { $0.published != nil }) { info in
                Text(SpeechModelDisplay.publishedLine(info))
                    .font(TokensType.caption.monospacedDigit())
                    .foregroundStyle(TokensUI.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(SpeechModelDisplay.help(info))
                    .tokensOnRule()
            }
            Text(SpeechModelDisplay.publishedSources)
                .font(TokensType.caption)
                .foregroundStyle(TokensUI.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .tokensReadingPitch(size: 13)
                .tokensOnRule()
        }
    }
}

/// One model on one square: name and languages, our accuracy and speed, size, and what you can do.
struct SpeechModelRow: View {
    let info: SpeechModelEntry
    let stats: MeasuredSpeechStats?
    let availability: SpeechModelAvailability
    let columns: SpeechTableColumns
    var talking = false
    @Binding var hovering: Bool
    let actions: SpeechModelActions
    @Environment(\.tokensSheetZoom) private var zoom

    /// "Accuracy" and "98.0%" with room to spare; tight enough that a 336-point column keeps Accuracy.
    static let accuracyWidth: CGFloat = 76
    static let speedWidth: CGFloat = 64
    /// Wide enough for "↓ 1.05 GB", "42%  Cancel" and "Coming soon" whole: a label is never cut.
    static let actionWidth: CGFloat = 120

    /// A downloaded model this Mac can delete (Orukeet, the default, and Apple stay).
    private var removable: Bool {
        availability == .ready && info.download != nil && info.id != SpeechModelCatalog.orukeetID
    }

    private var actionable: Bool {
        switch availability {
        case .ready: !talking
        case .downloadable, .paused, .noSpace: true
        default: false
        }
    }

    var body: some View {
        TokensHistoryCellLayout {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(info.name).font(TokensType.body).foregroundStyle(TokensUI.ink)
                    if columns.tags, let tag = SpeechModelDisplay.tag(info) {
                        Text(tag).font(TokensType.caption).foregroundStyle(TokensUI.secondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if columns.accuracy {
                    Text(SpeechModelDisplay.accuracy(stats) ?? "—")
                        .font(TokensType.caption.monospacedDigit())
                        .foregroundStyle(stats == nil ? TokensUI.secondary : TokensUI.ink)
                        .frame(width: Self.accuracyWidth, alignment: .leading)
                        .accessibilityLabel(SpeechModelDisplay.spokenAccuracy(stats))
                }
                if columns.speed {
                    Text(SpeechModelDisplay.speed(stats) ?? "—")
                        .font(TokensType.caption.monospacedDigit())
                        .foregroundStyle(stats == nil ? TokensUI.secondary : TokensUI.ink)
                        .frame(width: Self.speedWidth, alignment: .leading)
                        .accessibilityLabel(SpeechModelDisplay.spokenSpeed(stats))
                }
                action.frame(width: columns.actionWidth, alignment: .trailing)
            }
        }
        // The hover fill leaves the row's top screen point clear, so the grid rule at its top edge,
        // and the divider above drawn on that rule, are never tinted.
        .background {
            Rectangle().fill(hovering && actionable ? TokensInk.primary.color.opacity(0.04) : .clear)
                .padding(.top, 1 / max(zoom, 0.01))
        }
        .overlay(alignment: .bottom) { TokensHistoryDivider() }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(SpeechModelDisplay.rowHelp(info, stats: stats))
        .contextMenu {
            if removable, let remove = actions.remove {
                Button("Remove from this Mac") { remove(info) }
            }
        }
        .accessibilityElement(children: .combine)
        // VoiceOver reaches Remove as a row action; the right-click menu is not keyboard-reachable.
        .accessibilityActions {
            if removable, let remove = actions.remove {
                Button("Remove from this Mac") { remove(info) }
            }
        }
        .accessibilityIdentifier("tokens.models.\(info.id)")
    }

    @ViewBuilder private var action: some View {
        switch availability {
        case .inUse:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                Text("In use")
            }
            .font(TokensType.caption)
            .foregroundStyle(TokensUI.ink)
        case .ready:
            Button("Use") { actions.use(info) }
                .buttonStyle(TokensQuietButtonStyle()).fixedSize().tokensControlOnBaseline()
                .disabled(talking)
                .help(talking ? "Finish this talk to switch models." : "Use \(info.name) for your next talk")
        case .downloadable:
            Button {
                actions.download(info)
            } label: {
                // The download's size is on its button: what you get and what it costs, in one place.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold))
                    Text(SpeechModelDisplay.size(info)).monospacedDigit()
                }
            }
            .buttonStyle(TokensQuietButtonStyle()).fixedSize().tokensControlOnBaseline()
            .accessibilityLabel("Download \(SpeechModelDisplay.size(info))")
        case .downloading(let fraction):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(fraction * 100))%")
                    .font(TokensType.caption.monospacedDigit())
                    .foregroundStyle(TokensUI.secondary)
                // Orukeet's download is the app's own default and starts at launch; it has no Cancel.
                if info.id != SpeechModelCatalog.orukeetID {
                    Button("Cancel") { actions.cancel(info) }
                        .buttonStyle(TokensQuietButtonStyle()).fixedSize().tokensControlOnBaseline()
                        .accessibilityLabel("Cancel download")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Downloading \(Int(fraction * 100)) percent")
        case .paused, .noSpace:
            /*
            A download that stopped (Wi-Fi, sleep, a checksum or a full disk) resumes from where it
            stopped. A full disk says so: free some space, then Retry.
            */
            Button("Retry") { actions.download(info) }
                .buttonStyle(TokensQuietButtonStyle()).fixedSize().tokensControlOnBaseline()
                .accessibilityLabel(availability == .noSpace ? "Not enough free space. Retry" : "Download stopped. Retry")
                .help(availability == .noSpace ? "Not enough free space on this Mac for this download. Free some space, then Retry."
                                               : "The download stopped. Retry picks up where it left off.")
        case .notYet:
            Text("Coming soon").font(TokensType.caption).foregroundStyle(TokensUI.secondary)
        }
    }
}

/*
Which columns the table keeps at a given page-column width. The name always stays whole: a narrow
column drops Speed, then the small tag, then Accuracy (build 81: a 336-point column left 28 points for
names, which read "A…"). The action column keeps its width: a download's size is on its button.
*/
struct SpeechTableColumns: Equatable {
    var accuracy = true, speed = true, tags = true

    var actionWidth: CGFloat { SpeechModelRow.actionWidth }

    /// The fixed columns' total; the name takes the rest.
    var fixedWidth: CGFloat {
        (accuracy ? SpeechModelRow.accuracyWidth : 0) + (speed ? SpeechModelRow.speedWidth : 0) + actionWidth
    }

    static func fitting(_ width: CGFloat, models: [SpeechModelEntry]) -> SpeechTableColumns {
        let names = models.map { TokensUI.textWidth($0.name, size: 15) }.max() ?? 0
        let tagged = models.map { info in
            TokensUI.textWidth(info.name, size: 15) + (SpeechModelDisplay.tag(info).map { 8 + TokensUI.textWidth($0, size: 13) } ?? 0)
        }.max() ?? 0
        let tiers = [
            SpeechTableColumns(),
            SpeechTableColumns(speed: false),
            SpeechTableColumns(speed: false, tags: false),
        ]
        for tier in tiers where width - tier.fixedWidth >= (tier.tags ? tagged : names) + 4 { return tier }
        return SpeechTableColumns(accuracy: false, speed: false, tags: false)
    }
}

/// How the page and the model menu word a model: languages, size, our numbers, and the published ones.
enum SpeechModelDisplay {
    /// The small word after a name: "Default" for the model Tokens starts with, else its languages.
    static func tag(_ info: SpeechModelEntry) -> String? {
        if info.id == SpeechModelCatalog.orukeetID { return "Default" }
        switch info.languages {
        case "English": return "English"
        case "Many": return "Many languages"
        case let other where other.hasPrefix("25 "): return "25 languages"
        case let other where other.contains(","): return "\(other.split(separator: ",").count) languages"
        default: return nil
        }
    }

    /// "Built in", "714.5 MB".
    static func size(_ info: SpeechModelEntry) -> String {
        info.downloadBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Built in"
    }

    /// Words right, to one decimal so close models differ ("96.8%").
    static func accuracy(_ stats: MeasuredSpeechStats?) -> String? {
        stats.map { String(format: "%.1f%%", $0.wordsRight) }
    }

    static func spokenAccuracy(_ stats: MeasuredSpeechStats?) -> String {
        stats.map { String(format: "Accuracy %.1f percent", $0.wordsRight) } ?? "Accuracy not measured"
    }

    static func spokenSpeed(_ stats: MeasuredSpeechStats?) -> String {
        stats.map { String(format: "Speed %.2f seconds", $0.talkSeconds) } ?? "Speed not measured"
    }

    /// Seconds after a 10-second talk until its text is ready ("0.12 s").
    static func speed(_ stats: MeasuredSpeechStats?) -> String? {
        stats.map { $0.talkSeconds < 1 ? String(format: "%.2f s", $0.talkSeconds) : String(format: "%.1f s", $0.talkSeconds) }
    }

    static func measuredNote(_ run: SpeechBenchmarkRun?) -> String {
        guard let run else {
            return "Accuracy and speed are Tinkr's own measurements on a Mac. — means a model has not been measured yet."
        }
        return "Measured by Tinkr on a \(run.machine), \(run.date), with build \(run.build)'s speech workers: "
            + "\(run.clipSet), read aloud from books. Accuracy is 100% minus the word error rate (words missed, "
            + "wrong or added); speed is how long a loaded model takes to turn a finished 10-second talk into "
            + "text. — means not measured yet."
    }

    /// "Parakeet v2   93.6% words right · 224× real time on a Mac".
    static func publishedLine(_ info: SpeechModelEntry) -> String {
        guard let stats = info.published else { return info.name }
        var line = String(format: "%@   %@%.1f%% words right", info.name, stats.note == nil ? "" : "≈", 100 - stats.wer)
        if let mac = stats.macRealtime { line += " · \(Int(mac.rounded()))× real time" }
        return line
    }

    static let publishedSources = "Words right: Open ASR Leaderboard, seven English test sets, 2026-05-20. Real time: "
        + "transcribe.cpp on an M4 Max (Q8). ≈ marks Orukeet, scored as its base model, Parakeet v3. These are the makers' "
        + "and the leaderboard's numbers, not Tinkr's."

    static func rowHelp(_ info: SpeechModelEntry, stats: MeasuredSpeechStats?) -> String {
        var parts: [String] = [info.languages]
        if let stats {
            parts.append(String(format: "%.1f%% words right and %@ after a 10-second talk in Tinkr's run (%d recordings)",
                                stats.wordsRight, speed(stats) ?? "", stats.clips))
            if let load = stats.loadSeconds { parts.append(String(format: "%.1f s from a cold start to its first text", load)) }
        } else {
            parts.append("Not measured yet")
        }
        parts.append(size(info))
        parts.append(info.licence)
        return parts.joined(separator: " · ")
    }

    /// The published numbers in words, for Published comparisons.
    static func help(_ info: SpeechModelEntry) -> String {
        guard let stats = info.published else { return "No published results" }
        var parts = [String(format: "%.2f%% of words wrong (%@, %@)", stats.wer, stats.sourceName, stats.asOf)]
        if let mac = stats.macRealtime, let source = stats.macSourceName { parts.append("\(Int(mac.rounded()))× real time (\(source))") }
        if let note = stats.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}
