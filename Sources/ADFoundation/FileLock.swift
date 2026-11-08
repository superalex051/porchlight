import Darwin
import Foundation

public enum LockAttempt: Sendable, Equatable {
    case acquired
    /// Another holder has it, so waiting can help.
    case heldByOther
    /// The lock file can't be opened or locked, so waiting probably won't help.
    case failed
}

/// An exclusive `flock` that the OS releases if the process dies, and that also excludes other
/// `FileLock` instances in the same process. A missing directory is created at 0700, because a
/// rescue must not stall on it and a first launch must not mistake it for another instance. The
/// file stays after unlocking, because deleting it would let two processes each hold a "lock"
/// on a different file.
public final class FileLock {
    private let url: URL
    /// Open only while the lock is held. Readable so a test can check its flags.
    private(set) var held: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    deinit {
        unlock()
    }

    /// Blocks the calling thread until the lock is free. Does nothing if this instance holds it.
    public func lock() throws {
        guard held < 0 else { return }
        let file = try openLockFile()
        while flock(file, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let error = lastPOSIXError()
                close(file)
                throw error
            }
        }
        held = file
    }

    /// Returns at once: true if this instance now holds the lock, false if it couldn't be taken.
    public func tryLock() -> Bool {
        attemptLock() == .acquired
    }

    /// Returns at once, and says why if the lock wasn't taken.
    public func attemptLock() -> LockAttempt {
        guard held < 0 else { return .acquired }
        guard let file = try? openLockFile() else { return .failed }
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR else {
                let attempt: LockAttempt = errno == EWOULDBLOCK ? .heldByOther : .failed
                close(file)
                return attempt
            }
        }
        held = file
        return .acquired
    }

    /// `LOCK_UN` before closing, because `close` alone doesn't release the lock while a `posix_spawn`
    /// on another thread holds its momentary copy of the descriptor.
    public func unlock() {
        guard held >= 0 else { return }
        flock(held, LOCK_UN)
        close(held)
        held = -1
    }

    /// `O_CLOEXEC` matters: a child that inherited this descriptor would keep the lock
    /// after this process died.
    private func openLockFile() throws -> Int32 {
        var file = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if file < 0, errno == ENOENT {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            file = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        }
        guard file >= 0 else { throw lastPOSIXError() }
        return file
    }
}
