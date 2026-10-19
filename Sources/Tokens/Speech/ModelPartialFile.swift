import Darwin
import Foundation

/// A resumable model file must be an owned regular file, not a link to unrelated data.
/// Open with O_NOFOLLOW before inspecting it; do not reopen a validated pathname later.
enum ModelPartialFile {
    static func length(at url: URL) throws -> Int64 {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return 0 }
            throw failure()
        }
        defer { close(descriptor) }
        return try validatedInfo(descriptor).st_size
    }

    static func resume(at url: URL, maximumBytes: Int64) throws -> FileHandle {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        do {
            let info = try validatedInfo(descriptor)
            guard info.st_size < maximumBytes else { throw failure(EFBIG) }
            guard fchmod(descriptor, info.st_mode & 0o600) == 0 else { throw failure() }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func create(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure() }
        guard fchmod(descriptor, 0o600) == 0 else {
            let error = failure(); close(descriptor); throw error
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Remove only one checked regular file; never recursively erase an unexpected folder.
    static func remove(at url: URL) throws {
        let directory = try PrivateFileStore.openDirectory(url.deletingLastPathComponent(), create: false)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw failure()
        }
        try validate(info)
        guard unlinkat(directory, url.lastPathComponent, 0) == 0 else { throw failure() }
    }

    /// Replace only after all validation succeeds. A failed rename leaves the old model intact.
    static func promote(from partial: URL, to destination: URL) throws {
        guard partial.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL,
              partial.lastPathComponent != destination.lastPathComponent else { throw failure(EINVAL) }
        let directory = try PrivateFileStore.openDirectory(destination.deletingLastPathComponent(), create: false)
        defer { close(directory) }
        let descriptor = openat(directory, partial.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw failure() }
        try validate(opened)
        var current = stat()
        guard fstatat(directory, partial.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        try validate(current)
        guard current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else { throw failure(EPERM) }
        var target = stat()
        if fstatat(directory, destination.lastPathComponent, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            try validate(target)
        } else if errno != ENOENT { throw failure() }
        guard renameat(directory, partial.lastPathComponent, directory, destination.lastPathComponent) == 0 else { throw failure() }
    }

    private static func validatedInfo(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        try validate(info)
        return info
    }

    private static func validate(_ info: stat) throws {
        guard info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw failure(EPERM) }
    }

    private static func failure(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
