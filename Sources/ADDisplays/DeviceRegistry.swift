import ADFoundation
import ADModel
import Foundation
import Synchronization

public enum DeviceRegistryError: Error, Equatable {
    case unknownDisplay(String)
    /// The file exists but couldn't be read, so nothing was written. The change is in memory only.
    case fileUnreadable
}

/// `devices.json`: every display ever seen, by UUID. This is how something can still find a display
/// that macOS will no longer look up by UUID, because it's off.
///
/// Entries are never removed, so tag IDs and refresh pins survive a reboot. Only entries seen in the
/// current boot are returned, because a display ID means nothing in another boot. The exception is
/// `pin`, which isn't tied to an ID.
///
/// `update` writes what this instance loaded at `init`, plus what it has recorded since, and doesn't
/// see another process's writes. So build a fresh instance when a restore runs, and don't keep a
/// stale one.
public final class DeviceRegistry: Sendable {
    private static let schemaVersion = 1
    private static let log = ADLog.logger("registry")

    private struct Document: Codable, Sendable {
        var schemaVersion = DeviceRegistry.schemaVersion
        var nextTagID = 1
        var entries: [RegistryEntry] = []

        func index(ofUUID uuid: String) -> Int? {
            let wanted = uuid.uppercased()
            return entries.firstIndex { $0.identity.uuid?.uppercased() == wanted }
        }

        mutating func record(_ display: DisplaySnapshot, bootSession: String) {
            guard display.kind != .emptyPipe else { return }

            guard let uuid = display.identity.uuid else {
                // A disconnected display reads with no UUID or name, so this row can't improve the
                // entry, and must not replace it. If the row's ID, vendor, model and serial all match
                // an entry, that monitor is here right now under that ID, whichever boot wrote it.
                let match = entries.firstIndex {
                    $0.lastID == display.id
                        && $0.identity.vendor == display.identity.vendor
                        && $0.identity.model == display.identity.model
                        && $0.identity.serial == display.identity.serial
                }
                if let match { entries[match].bootSessionID = bootSession }
                return
            }

            if let existing = index(ofUUID: uuid) {
                entries[existing].identity = Self.merging(display.identity, over: entries[existing].identity)
                entries[existing].lastID = display.id
                entries[existing].bootSessionID = bootSession
                entries[existing].kind = display.kind
            } else {
                entries.append(
                    RegistryEntry(
                        identity: display.identity,
                        lastID: display.id,
                        bootSessionID: bootSession,
                        tagID: nextTagID,
                        kind: display.kind
                    )
                )
                nextTagID += 1
            }
        }

        /// The new read wins, but a field it doesn't have keeps the value on file.
        private static func merging(_ new: DisplayIdentity, over old: DisplayIdentity) -> DisplayIdentity {
            var merged = new
            merged.alphanumericSerial = new.alphanumericSerial ?? old.alphanumericSerial
            merged.productName = new.productName ?? old.productName
            merged.registryLocation = new.registryLocation ?? old.registryLocation
            merged.weekOfManufacture = new.weekOfManufacture ?? old.weekOfManufacture
            merged.yearOfManufacture = new.yearOfManufacture ?? old.yearOfManufacture
            return merged
        }
    }

    private struct Loaded: Sendable {
        var document: Document
        /// The file is there but a read failed, so it may be perfectly good. Any write would replace
        /// it, so `document` stays in memory only until a read succeeds.
        var fileIsUnread = false

        mutating func retryRead(from url: URL) {
            guard fileIsUnread else { return }
            let retried = DeviceRegistry.load(from: url)
            if !retried.fileIsUnread { self = retried }
        }
    }

    private let url: URL
    private let bootSession: String
    private let loaded: Mutex<Loaded>

    /// Reads the file now. A missing file starts empty. A file that isn't a valid registry is renamed
    /// to `devices.json.corrupt-<UUID>`, and also starts empty. The file's folder has to exist already.
    ///
    /// If the read itself fails, the file may be fine, so it stays where it is and is never overwritten.
    /// Every call tries the read again. Until one succeeds, `update` and `pin` work in memory and throw
    /// `fileUnreadable`, which also refuses a plain disconnect. Once one does, the file replaces what
    /// was in memory, including any tag ID given out meanwhile, which was never saved.
    public init(url: URL, bootSession: String) {
        self.url = url
        self.bootSession = bootSession
        loaded = Mutex(Self.load(from: url))
    }

    /// Records what the topology shows and writes the file. It writes every time, even if nothing
    /// changed, because a plain disconnect is only allowed after a write that just succeeded.
    /// On a failed write it throws and keeps the previous state, so memory never gets ahead of the disk.
    public func update(from topology: Topology) throws {
        try loaded.withLock { loaded in
            loaded.retryRead(from: url)
            var updated = loaded.document
            for display in topology.displays {
                updated.record(display, bootSession: bootSession)
            }
            try Self.store(updated, in: &loaded, at: url)
        }
    }

    public func entry(uuid: String) -> RegistryEntry? {
        let document = currentDocument()
        return document.index(ofUUID: uuid).map { document.entries[$0] }.flatMap(currentBootOnly)
    }

    public func entry(tagID: Int) -> RegistryEntry? {
        currentDocument().entries.first { $0.tagID == tagID }.flatMap(currentBootOnly)
    }

    /// An empty current boot means the boot is unknown, never another boot, so that returns every
    /// entry. A no-ledger rescue depends on this, and a stale ID only makes its enable fail.
    public func currentBootEntries() -> [RegistryEntry] {
        let entries = currentDocument().entries
        return bootSession.isEmpty ? entries : entries.filter { $0.bootSessionID == bootSession }
    }

    /// Sets or clears a refresh pin, and writes the file. Throws if the UUID was never seen.
    public func pin(uuid: String, hz: Int?) throws {
        try loaded.withLock { loaded in
            loaded.retryRead(from: url)
            guard let index = loaded.document.index(ofUUID: uuid) else {
                throw DeviceRegistryError.unknownDisplay(uuid)
            }
            var updated = loaded.document
            updated.entries[index].pinnedRefreshHz = hz
            try Self.store(updated, in: &loaded, at: url)
        }
    }

    private func currentDocument() -> Document {
        loaded.withLock { loaded in
            loaded.retryRead(from: url)
            return loaded.document
        }
    }

    private func currentBootOnly(_ entry: RegistryEntry) -> RegistryEntry? {
        entry.bootSessionID == bootSession ? entry : nil
    }

    private static func store(_ document: Document, in loaded: inout Loaded, at url: URL) throws {
        guard !loaded.fileIsUnread else {
            loaded.document = document
            throw DeviceRegistryError.fileUnreadable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(document), to: url)
        loaded.document = document
    }

    private static func load(from url: URL) -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Loaded(document: Document())
        } catch {
            log.error("Couldn't read the display registry, so the file stays and this works from memory: \(error.localizedDescription, privacy: .public)")
            return Loaded(document: Document(), fileIsUnread: true)
        }

        if let document = try? JSONDecoder().decode(Document.self, from: data), document.schemaVersion == schemaVersion {
            return Loaded(document: document)
        }

        let kept = url.deletingLastPathComponent()
            .appending(component: "\(url.lastPathComponent).corrupt-\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try FileManager.default.moveItem(at: url, to: kept)
            log.error("The display registry isn't valid, so it starts empty. The old file is at \(kept.path, privacy: .public)")
        } catch {
            // The next write replaces it, so the only thing lost is the copy to look at later.
            log.error("The display registry isn't valid and couldn't be renamed: \(error.localizedDescription, privacy: .public)")
        }
        return Loaded(document: Document())
    }
}
