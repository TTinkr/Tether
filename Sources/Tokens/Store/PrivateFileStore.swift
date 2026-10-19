import Darwin
import Foundation

/// Owner-only storage for recognized words. The temporary file is private before any
/// bytes are written, then atomically replaces the destination inside the opened folder.
/// Final path components must be real, owned directories/files, never symbolic links.
enum PrivateFileStore {
    static func prepareDirectory(_ directory: URL) throws {
        let descriptor = try openDirectory(directory, create: true)
        close(descriptor)
    }

    static func read(from url: URL) throws -> Data {
        let directory = try openDirectory(url.deletingLastPathComponent(), create: false)
        defer { close(directory) }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        let permissions = try validateFile(descriptor)
        // Tighten files written by older builds before returning their recognized words.
        guard fchmod(descriptor, permissions & 0o600) == 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = try openDirectory(url.deletingLastPathComponent(), create: true, fileManager: fileManager)
        defer { close(directory) }
        try validateDestination(url.lastPathComponent, in: directory)
        let temporary = ".tokens-private-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR { continue }
                else { throw posixError(written == 0 ? EIO : errno) }
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        try validateDestination(url.lastPathComponent, in: directory)
        guard renameat(directory, temporary, directory, url.lastPathComponent) == 0 else { throw posixError() }
    }

    /// Returns an owned directory descriptor; callers must close it.
    static func openDirectory(_ url: URL, create: Bool, fileManager: FileManager = .default) throws -> Int32 {
        if create {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = posixError(); close(descriptor); throw error
        }
        guard info.st_uid == getuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            close(descriptor); throw posixError(EPERM)
        }
        guard fchmod(descriptor, info.st_mode & 0o700) == 0 else {
            let error = posixError(); close(descriptor); throw error
        }
        return descriptor
    }

    private static func validateFile(_ descriptor: Int32) throws -> mode_t {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw posixError(EPERM) }
        return info.st_mode
    }

    private static func validateDestination(_ name: String, in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        guard info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw posixError(EPERM) }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
