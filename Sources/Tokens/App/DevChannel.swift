


//
import Combine
import SwiftUI


// DevChannel — Dev build only: runs the script that merges this build into Tokens


/// Tokens Dev only: one Merge word on the rail's Dev line moves this build into the installed Tokens.
/// The script builds first and swaps only after Tokens has been quiet, so a dictation is never cut off.
enum DevChannel {


    // Build facts and status file — what this build is, and what the script reports


    /*
    Info.plist keys: TTTDevChannel (true only in the Dev build), TTTDevSourceCommit (the git
    commit the build was made from) and TTTDevSourceRoot (the source folder holding Scripts/).
    */
    static let isActive = Bundle.main.object(forInfoDictionaryKey: "TTTDevChannel") as? Bool == true
    static let commit   = Bundle.main.object(forInfoDictionaryKey: "TTTDevSourceCommit") as? String ?? ""
    /*
    A build can be merged only if its commit is a full 40-character hex id. Anything else (empty,
    short, or not hex) is shown as "<first 7> · edited" and the Dev line offers no Merge.
    */
    static var canPromote: Bool { commit.count == 40 && commit.allSatisfy { $0.isHexDigit } }
    static var displayCommit: String { String(commit.prefix(7)) + (canPromote ? "" : " · edited") }
    /*
    The rail's Dev line names the build: "Dev · <displayCommit>" when a merge commit was stamped.
    The dev packager leaves that key empty, so the line then shows the commit the package was built
    from (TokensSourceCommit), or just "Dev". Display only: canPromote still reads `commit`.
    */
    static var lineLabel: String {
        if !commit.isEmpty { return "Dev · " + displayCommit }
        let built = Bundle.main.object(forInfoDictionaryKey: "TokensSourceCommit") as? String ?? ""
        return built.isEmpty ? "Dev" : "Dev · " + String(built.prefix(7))
    }
    private static let sourceRoot = Bundle.main.object(forInfoDictionaryKey: "TTTDevSourceRoot") as? String

    /*
    The promote script writes its progress, one line, to this file; the row reads it every second.
    Lines seen by the code below: "Starting…", "Step 1" to "Step 4", "Merged", "FAILED…", "Dry run…".
    */
    static var statusURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/com.tinkr.tokens.community.dev.macos/promote.status")
    }

    static func readStatus() -> String {
        ((try? String(contentsOf: statusURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which of the four merge steps the status line reports (0 before step 1, 4 when merged).
    /// `current` is the step in progress, nil when finished. Returns nil for any other text
    /// (for example FAILED), which hides the step boxes.
    static func stepsDone(_ status: String) -> (done: Int, current: Int?)? {
        if status.hasPrefix("Merged") { return (4, nil) }
        if status.hasPrefix("Starting") { return (0, 1) }
        guard status.hasPrefix("Step "), let step = Int(status.dropFirst(5).prefix(1)), (1...4).contains(step) else { return nil }
        return (step - 1, step)
    }

    // The script has stopped for good: nothing written yet, merged, failed, or a dry run.
    static func isFinished(_ status: String) -> Bool {
        status.isEmpty || status.hasPrefix("Merged") || status.hasPrefix("FAILED") || status.hasPrefix("Dry run")
    }

    /// True while a promote_dev.sh run holds its lock, even one started before Tokens Dev was reopened.
    /*
    The script keeps its process id in promote.lock/pid. kill(pid, 0) sends no signal; it only
    reports whether that process still exists, so a lock left behind by a dead run counts as not running.
    */
    static var mergeIsRunning: Bool {
        let pidURL = statusURL.deletingLastPathComponent().appendingPathComponent("promote.lock/pid")
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }


    // Starting a merge — startMerge()


    /// Starts the promotion detached, so it finishes even if Tokens Dev is closed.
    /*
    Returns true if a merge is now running (including one that was already running), false if
    this build cannot be merged, the source folder or script is missing, or the process will
    not start. Runs: /usr/bin/nohup /bin/zsh <TTTDevSourceRoot>/Scripts/promote_dev.sh --commit <commit>
    with no input or output attached.
    */
    @discardableResult
    static func startMerge() -> Bool {
        guard canPromote, let sourceRoot else { return false }
        if mergeIsRunning { return true }
        let script = sourceRoot + "/Scripts/promote_dev.sh"
        guard FileManager.default.isExecutableFile(atPath: script) else { return false }
        let process            = Process()
        process.executableURL  = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments      = ["/bin/zsh", script, "--commit", commit]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        process.standardInput  = FileHandle.nullDevice
        // Clear the last result so the row does not read a stale "Merged".
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("Starting…".utf8).write(to: statusURL)
        do { try process.run() } catch { return false }
        Diagnostics.event("dev_merge_started commit=\(commit)")
        return true
    }


}

//
// :)
//
//
// DevMergeRow — The rail's one Dev line: build label, Merge word, progress bars and status


struct DevMergeRow: View {
    // A merge keeps running if Tokens Dev is closed; reopening picks its progress back up.
    @State private var status  = DevChannel.mergeIsRunning ? DevChannel.readStatus() : ""
    @State private var running = DevChannel.mergeIsRunning
    private let timer          = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Set only by the offscreen test fixture below; nil in the app.
    private var fixturePromotable: Bool?

    init() {}

    /*
    Offscreen test fixture only (LogoUpdateRenderTests): draws a fictional status, running state
    and promotability. It never reads the status file, never polls, and never starts a merge
    unless its Merge word is clicked, which an offscreen render cannot do.
    */
    init(fixtureStatus: String, running: Bool, promotable: Bool) {
        _status = State(initialValue: fixtureStatus)
        _running = State(initialValue: running)
        fixturePromotable = promotable
    }

    private var promotable: Bool { fixturePromotable ?? DevChannel.canPromote }

    /// What the old button's caption explained; now the tooltip and the Merge word's hint.
    private var explanation: String {
        promotable ? "Checks this version, then restarts Tokens once you finish talking."
                   : "Merge unlocks after changes are saved and rebuilt."
    }

    var body: some View {
        /*
        V3 (DESIGN.md §5.1): one 13-point line. Idle: "Dev · <commit>" in secondary, plus "· Merge"
        (13 medium ink) only when this build can be merged. Running: "Merging… n of 4" over four
        24 × 3 bars. FAILED: a red dot and "Merge failed". The status logic is unchanged.
        */
        let steps  = DevChannel.stepsDone(status)
        let failed = status.hasPrefix("FAILED")
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if running {
                    Text(steps.map { "Merging… \($0.current ?? $0.done) of 4" } ?? "Merging…")
                } else if failed {
                    TokensStatusDot(color: TokensUI.red)
                        .padding(.trailing, 8)
                    Text("Merge failed")
                        .foregroundStyle(TokensUI.ink2)
                    if promotable { mergeAction("Retry") }
                } else {
                    Text(DevChannel.lineLabel)
                    if status.hasPrefix("Merged") {
                        Text(" · Merged")
                    } else if promotable {
                        mergeAction("Merge")
                    }
                }
            }
            .font(TokensType.caption)
            .foregroundStyle(TokensUI.secondary)
            .lineLimit(1)
            if running, let steps {
                TokensMergeSteps(done: steps.done, current: steps.current)
                    .animation(.easeOut(duration: 0.3), value: steps.done)
            }
        }
        .help(status.isEmpty ? explanation : status + "\n" + explanation)
        /*
        Once a second while a merge runs: copy the script's latest status line into the row. The
        row stops "running" when the status says finished or the lock's process has gone away.
        */
        .onReceive(timer) { _ in
            guard running, fixturePromotable == nil else { return }
            let latest = DevChannel.readStatus()
            if !latest.isEmpty { status = latest }
            guard DevChannel.isFinished(latest) || !DevChannel.mergeIsRunning else { return }
            running = false
            // One soft chime when Tokens has been updated, so nobody has to watch the bar.
            if latest.hasPrefix("Merged") { NSSound(named: "Glass")?.play() }
        }
    }

    /// " · Merge": a 13-point medium ink word that starts the promotion. Offered only when it can run.
    private func mergeAction(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(" · ")
            Button(title, action: start)
                .buttonStyle(.plain)
                .font(TokensType.captionStrong)
                .foregroundStyle(TokensUI.ink)
                .accessibilityLabel(title == "Merge" ? "Merge this build into Tokens" : "Retry the merge")
                .accessibilityHint(explanation)
        }
    }

    // The same start action the old "Ready to merge" button ran.
    private func start() {
        if DevChannel.startMerge() {
            running = true
            status  = DevChannel.readStatus()
        } else {
            status = "FAILED: the Tokens Dev source folder is missing."
        }
    }
}


// TokensMergeSteps — Four small bars, one per merge step


/// Four 24 × 3 bars 4 apart, one per merge step: done ink 80%, current ink 40%, to do ink 15%.
struct TokensMergeSteps: View {
    let done: Int
    let current: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...4, id: \.self) { step in
                Capsule()
                    .fill(TokensUI.ink.opacity(step <= done ? 0.8 : step == current ? 0.4 : 0.15))
                    .frame(width: 24, height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Merge progress")
        .accessibilityValue(done == 4 ? "Merged" : "Step \(current ?? done) of 4")
    }
}

