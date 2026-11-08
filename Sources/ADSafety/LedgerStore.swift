import ADFoundation
import Darwin
import Foundation
import Synchronization
import os

public protocol LedgerStoring: Sendable {
    /// The ledger, or nil if there is none. Throws only if reading failed, which says nothing about
    /// the contents, so the caller must not take it to mean there's no session.
    func load() throws -> SafetyLedger?
    func save(_ ledger: SafetyLedger) throws
    /// Clearing a ledger that isn't there succeeds.
    func clear() throws
    /// True once if a `load` since the last call met an unreadable file, whether or not it could be
    /// moved aside, or if another process has set one aside since. A nil from `load` after either is
    /// not a cleared ledger, and this is what tells them apart.
    func takeSetAsideEvent() -> Bool
}

extension LedgerStoring {
    public func takeSetAsideEvent() -> Bool { false }
}

/// `safety.json`, replaced atomically and at mode 0600.
public final class FileLedgerStore: LedgerStoring {
    /// Tells one `.corrupt` file from another.
    private struct FileStamp: Equatable {
        var inode: UInt64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
    }

    private struct SetAsideState {
        var raised = false
        var corruptFile: FileStamp?
    }

    private let url: URL
    private let corruptURL: URL
    private let log: @Sendable (String) -> Void
    private let setAsideState: Mutex<SetAsideState>

    public init(
        url: URL,
        log: @escaping @Sendable (String) -> Void = { ADLog.logger("ledger").error("\($0, privacy: .public)") }
    ) {
        self.url = url
        self.log = log
        let corruptURL = url.appendingPathExtension("corrupt")
        self.corruptURL = corruptURL
        // A file already there is from before this store, so it isn't news.
        setAsideState = Mutex(SetAsideState(corruptFile: Self.stamp(of: corruptURL)))
    }

    public func load() throws -> SafetyLedger? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileReadNoPermission {
            // It will never read as it is, so it's handled like damaged contents.
            setAside("it can't be read")
            return nil
        }
        // Any other read error propagates: it may pass, and renaming a good ledger would lose a
        // live session's records.

        do {
            let ledger = try JSONDecoder().decode(SafetyLedger.self, from: data)
            guard ledger.schemaVersion == SafetyLedger.currentSchemaVersion else {
                setAside("it has schema version \(ledger.schemaVersion)")
                return nil
            }
            return ledger
        } catch {
            setAside("it can't be decoded")
            return nil
        }
    }

    public func save(_ ledger: SafetyLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates stay in the default encoding, a plain number. It's the only one that returns the
        // exact value, and the guardian watches `updatedAt` move.
        let data = try encoder.encode(ledger)

        do {
            try AtomicFile.write(data, to: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try AtomicFile.write(data, to: url)
        }
    }

    public func clear() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Also looks at the `.corrupt` file: if another process got to a bad file first, this store only
    /// ever finds it missing. A set-aside by this store changes that file too, and still counts once.
    public func takeSetAsideEvent() -> Bool {
        let corruptFile = Self.stamp(of: corruptURL)
        return setAsideState.withLock {
            defer {
                $0.raised = false
                $0.corruptFile = corruptFile
            }
            return $0.raised || (corruptFile != nil && corruptFile != $0.corruptFile)
        }
    }

    private static func stamp(of url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileStamp(
            inode: info.st_ino,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    /// Moves the file aside, replacing any earlier one, so that recovery falls back to the display
    /// registry. A failed rename is only logged: there's still no usable ledger to return. Either way
    /// the event is raised, so the caller can tell this from a ledger that was cleared.
    private func setAside(_ why: String) {
        setAsideState.withLock { $0.raised = true }
        if rename(url.path, corruptURL.path) == 0 {
            log("\(url.lastPathComponent): \(why), renamed to \(corruptURL.lastPathComponent)")
        } else if errno != ENOENT {
            // ENOENT is another process setting the same file aside first.
            log("\(url.lastPathComponent): \(why), and renaming it failed with errno \(errno)")
        }
    }
}

/// A test double. Set `failOnSave` to make writes fail, as a full or read-only disk would. Call
/// `setAsideOnNextLoad` or set `unreadableAndStuck` to act out an unreadable file.
public final class InMemoryLedgerStore: LedgerStoring {
    private struct State {
        var ledger: SafetyLedger?
        var failOnSave = false
        var setAsidePending = false
        var unreadableAndStuck = false
        var setAsideEvent = false
    }

    private let state: Mutex<State>

    public init(ledger: SafetyLedger? = nil) {
        state = Mutex(State(ledger: ledger))
    }

    public var failOnSave: Bool {
        get { state.withLock { $0.failOnSave } }
        set { state.withLock { $0.failOnSave = newValue } }
    }

    /// The next load finds the file unreadable and moves it aside: the contents are gone, and the
    /// event is raised once.
    public func setAsideOnNextLoad() {
        state.withLock { $0.setAsidePending = true }
    }

    /// While true, every load finds the file unreadable and can't move it, so the event is raised each
    /// time. A save ends it, because replacing a file doesn't need to read it.
    public var unreadableAndStuck: Bool {
        get { state.withLock { $0.unreadableAndStuck } }
        set { state.withLock { $0.unreadableAndStuck = newValue } }
    }

    public func load() throws -> SafetyLedger? {
        state.withLock {
            guard $0.setAsidePending || $0.unreadableAndStuck else { return $0.ledger }
            $0.setAsidePending = false
            $0.setAsideEvent = true
            $0.ledger = nil
            return nil
        }
    }

    public func save(_ ledger: SafetyLedger) throws {
        try state.withLock {
            if $0.failOnSave { throw POSIXError(.EIO) }
            $0.ledger = ledger
            $0.unreadableAndStuck = false
        }
    }

    public func clear() throws {
        state.withLock { $0.ledger = nil }
    }

    public func takeSetAsideEvent() -> Bool {
        state.withLock {
            defer { $0.setAsideEvent = false }
            return $0.setAsideEvent
        }
    }
}
