


//
import AppKit
import ApplicationServices
import Darwin


// Diagnostics — Appends timestamped event lines to a local log file


/// Local diagnostic sink. Callers must omit transcript, audio and secrets; this function does not inspect or redact its input.
enum Diagnostics {
    /*
    ~/Library/Logs/<folder>/events.log. The folder is the bundle identifier in the public
    Tokens build (TTTPublicTokens Info.plist key) and "TTT" otherwise; both are names on
    people's Macs, so they stay as they are. Lines are only ever appended; see rotationBytes.
    */
    static var url: URL {
        let isPublicTokens = publicTokens
        let identity       = Bundle.main.bundleIdentifier ?? "com.tinkr.tokens.community.talk.macos"
        let directory      = isPublicTokens ? identity : "TTT"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(directory)/events.log")
    }

    /// The one older log kept beside events.log after a rotation: events.1.log (build 81).
    static var previousURL: URL { previousURL(for: url) }
    static func previousURL(for log: URL) -> URL {
        let name = log.deletingPathExtension().lastPathComponent + ".1"
        return log.deletingLastPathComponent()
            .appendingPathComponent(log.pathExtension.isEmpty ? name : name + "." + log.pathExtension)
    }

    /*
    Once a line would take events.log past this size it is renamed events.1.log, replacing the
    older one, and a new events.log begins (build 81: the log grew forever, 8.7 MB in three weeks
    on the heaviest Mac). 16 MB keeps well over the 15 days "Your voice" and Stats read, and
    they read events.1.log too when events.log starts later than that.
    */
    static let rotationBytes: UInt64 = 16 << 20

    private static let lock = NSLock()
    // One formatter for every line (it was rebuilt per line); only used under `lock`.
    private static let stamp = ISO8601DateFormatter()

    /*
    One line per call: ISO-8601 time, app bundle id, process id, then `name`. The lock keeps
    lines from two threads from interleaving. The function cannot throw: a full disk or a
    missing folder just means no line is written.
    */
    static func event(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let pid    = ProcessInfo.processInfo.processIdentifier
        append(Data("\(stamp.string(from: Date())) app=\(bundle) pid=\(pid) \(name)\n".utf8),
               to: url, rotatingAt: rotationBytes)
    }

    /*
    Append through one checked descriptor in an owner-only directory. Refuse linked or
    non-regular files before writing or rotating; a bad log path silently disables logging.
    Rotation remains a rename of events.log onto its one older sibling in the same folder.
    */
    static func append(_ line: Data, to log: URL, rotatingAt cap: UInt64) {
        guard let directory = try? PrivateFileStore.openDirectory(log.deletingLastPathComponent(), create: true) else { return }
        defer { close(directory) }
        let name = log.lastPathComponent
        func openLog() -> Int32 {
            let descriptor = openat(directory, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return -1 }
            var info = stat()
            guard fstat(descriptor, &info) == 0, ownedRegularFile(info), fchmod(descriptor, info.st_mode & 0o600) == 0 else {
                close(descriptor)
                return -1
            }
            return descriptor
        }
        var descriptor = openLog()
        guard descriptor >= 0 else { return }
        defer { if descriptor >= 0 { close(descriptor) } }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { return }
        if opened.st_size > 0, UInt64(opened.st_size) + UInt64(line.count) > cap {
            var current = stat()
            guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  ownedRegularFile(current), current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else { return }
            let previous = previousURL(for: log).lastPathComponent
            var older = stat()
            if fstatat(directory, previous, &older, AT_SYMLINK_NOFOLLOW) == 0 {
                guard ownedRegularFile(older) else { return }
            } else if errno != ENOENT { return }
            guard renameat(directory, name, directory, previous) == 0 else { return }
            close(descriptor)
            descriptor = openLog()
            guard descriptor >= 0 else { return }
        }
        line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR { continue }
                else { return }
            }
        }
    }

    private static func ownedRegularFile(_ info: stat) -> Bool {
        info.st_uid == getuid() && info.st_nlink == 1 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

}

