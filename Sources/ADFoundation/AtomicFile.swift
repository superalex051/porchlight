import Darwin
import Foundation

/// Replaces a file so that a process crash at any point leaves either the old contents or the new
/// ones. That is the whole promise: `fsync` doesn't flush the drive's cache, so power loss isn't covered.
public enum AtomicFile {
    /// Writes a temp file in the same directory, fsyncs it, renames it over `url`, then fsyncs
    /// the directory. `mode` is exact: the umask doesn't apply, and it replaces the old file's mode.
    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent().path
        var tempPath = Array("\(directory)/.\(url.lastPathComponent).XXXXXX".utf8CString)

        let file = mkostemp(&tempPath, O_CLOEXEC)
        guard file >= 0 else { throw lastPOSIXError() }

        do {
            defer { close(file) }
            guard fchmod(file, mode) == 0 else { throw lastPOSIXError() }
            try writeAll(data, to: file)
            guard fsync(file) == 0 else { throw lastPOSIXError() }
            guard rename(tempPath, url.path) == 0 else { throw lastPOSIXError() }
        } catch {
            unlink(tempPath)
            throw error
        }

        // From here the new contents are in place, and a failure means only that syncing the
        // directory failed. It still throws, so the caller knows something is wrong with the disk.
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw lastPOSIXError() }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw lastPOSIXError() }
    }
}

/// The current `errno` as a thrown error. Call it before anything else can change `errno`.
func lastPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

/// Writes all of `data`, carrying on after partial writes and interrupted calls. `writer` stands in
/// for `write(2)` in tests.
func writeAll(
    _ data: Data,
    to file: Int32,
    using writer: (Int32, UnsafeRawPointer, Int) -> Int = { write($0, $1, $2) }
) throws {
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < buffer.count, let base = buffer.baseAddress {
            let written = writer(file, base + offset, buffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw lastPOSIXError()
            }
            // Writing nothing sets no errno, and retrying could loop forever.
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}
