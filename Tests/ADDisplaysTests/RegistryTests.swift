import ADDisplays
import ADModel
import Foundation
import Testing

private let lgUUID = "40A936A8-FEB4-4F0F-ADA4-F81E1BC66A25"
private let m34UUID = "0A4FA257-A531-4885-BA5E-76B9D0C0EF8D"

private let lgIdentity = DisplayIdentity(
    uuid: lgUUID,
    vendor: 7789,
    model: 23423,
    serial: 198499,
    productName: "27GL850",
    registryLocation: "dispext0"
)

private let m34Identity = DisplayIdentity(
    uuid: m34UUID,
    vendor: 7252,
    model: 13314,
    serial: 332,
    productName: "M34WQ",
    registryLocation: "dispext3"
)

private func snapshot(_ id: DisplayID, _ identity: DisplayIdentity, kind: DisplayKind = .physical) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        identity: identity,
        kind: kind,
        isOnline: identity.uuid != nil,
        isActive: identity.uuid != nil,
        isMain: false,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0)
    )
}

/// How a display reads while it's off.
private func disconnected(_ id: DisplayID, _ identity: DisplayIdentity) -> DisplaySnapshot {
    var offIdentity = identity
    offIdentity.uuid = nil
    offIdentity.productName = nil
    return snapshot(id, offIdentity)
}

private func desk() -> Topology {
    Topology(displays: [snapshot(2, lgIdentity), snapshot(4, m34Identity)])
}

/// A folder for one test, removed when the closure ends.
private func withStateDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "ADRegistryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appending(component: "devices.json", directoryHint: .notDirectory))
}

@Test func recordsIDPerUUID() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())

        let lg = try #require(registry.entry(uuid: lgUUID))
        #expect(lg.lastID == 2)
        #expect(lg.bootSessionID == "boot-a")
        #expect(lg.kind == .physical)
        #expect(lg.identity == lgIdentity)
        #expect(registry.entry(uuid: m34UUID)?.lastID == 4)
        #expect(registry.entry(uuid: "00000000-0000-0000-0000-000000000000") == nil)
    }
}

@Test func uuidLookupIgnoresCase() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())
        #expect(registry.entry(uuid: lgUUID.lowercased())?.lastID == 2)

        // The same display reported in another case is still one entry.
        var lower = lgIdentity
        lower.uuid = lgUUID.lowercased()
        try registry.update(from: Topology(displays: [snapshot(2, lower)]))
        #expect(registry.currentBootEntries().count == 2)
        try registry.pin(uuid: lgUUID.lowercased(), hz: 120)
        #expect(registry.entry(uuid: lgUUID)?.pinnedRefreshHz == 120)
    }
}

@Test func newIDForTheSameUUIDKeepsTheEntry() throws {
    // A virtual screen comes back under a new ID with the same UUID.
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        var screen = lgIdentity
        screen.uuid = "63C872E8-4E48-4D23-9889-F8EE8F82BEEE"
        try registry.update(from: Topology(displays: [snapshot(15, screen, kind: .ownVirtual)]))
        let tag = try #require(registry.entry(uuid: screen.uuid!)).tagID

        try registry.update(from: Topology(displays: [snapshot(16, screen, kind: .ownVirtual)]))

        let entry = try #require(registry.entry(uuid: screen.uuid!))
        #expect(entry.lastID == 16)
        #expect(entry.tagID == tag)
        #expect(entry.kind == .ownVirtual)
        #expect(registry.currentBootEntries().count == 1)
    }
}

@Test func emptyPipesAndUnknownNilUUIDRowsAreNotRecorded() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        let pipe = DisplayIdentity(vendor: 0, model: 0, serial: 0)
        let stranger = DisplayIdentity(vendor: 9, model: 9, serial: 9)
        try registry.update(from: Topology(displays: [snapshot(1, pipe, kind: .emptyPipe), snapshot(8, stranger)]))
        #expect(registry.currentBootEntries().isEmpty)
    }
}

@Test func keepsEntryAfterDisconnect() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())
        try registry.pin(uuid: m34UUID, hz: 144)
        let before = try #require(registry.entry(uuid: m34UUID))

        // Off with another display up: listed, with no UUID and no name.
        try registry.update(from: Topology(displays: [snapshot(2, lgIdentity), disconnected(4, m34Identity)]))
        #expect(registry.entry(uuid: m34UUID) == before, "UUID, name, ID, tag and pin all survive")

        // Fallback: both are gone from every list.
        let fallback = DisplayIdentity(
            uuid: "A8AD2690-9F4D-4D59-8538-A5FE7CFE0F02",
            vendor: 0x756E_6B6E,
            model: 0x7669_7274,
            serial: 0
        )
        try registry.update(from: Topology(displays: [snapshot(6, fallback, kind: .osFallback)]))
        #expect(registry.entry(uuid: m34UUID) == before)
        #expect(registry.entry(uuid: lgUUID)?.lastID == 2)

        // And all of it survives a restart, which is what a no-ledger rescue depends on.
        let reopened = DeviceRegistry(url: url, bootSession: "boot-a")
        #expect(reopened.entry(uuid: m34UUID) == before)
    }
}

@Test func disconnectedRowRenewsAnOlderEntryOnlyOnFullMatch() throws {
    try withStateDirectory { url in
        let earlier = DeviceRegistry(url: url, bootSession: "boot-a")
        try earlier.update(from: desk())

        // The ID was read just now and vendor, model and serial agree, so it's this monitor.
        let registry = DeviceRegistry(url: url, bootSession: "boot-b")
        try registry.update(from: Topology(displays: [disconnected(2, lgIdentity)]))
        let renewed = try #require(registry.entry(uuid: lgUUID))
        #expect(renewed.lastID == 2)
        #expect(renewed.identity.productName == "27GL850", "A row with no name doesn't wipe the one on file")

        // Another monitor under M34WQ's old ID, and M34WQ's own identity under another ID.
        var stranger = m34Identity
        stranger.vendor = 1234
        try registry.update(from: Topology(displays: [disconnected(4, stranger), disconnected(5, m34Identity)]))
        #expect(registry.entry(uuid: m34UUID) == nil)
    }
}

/// `BootSession.current()` returns an empty ID if its sysctl fails. Unknown isn't another boot, and a
/// no-ledger rescue has nothing else to go on.
@Test func unknownBootReturnsEveryEntry() throws {
    try withStateDirectory { url in
        try DeviceRegistry(url: url, bootSession: "boot-a").update(from: desk())

        let registry = DeviceRegistry(url: url, bootSession: "")

        #expect(registry.currentBootEntries().map(\.identity.uuid) == [lgUUID, m34UUID])
    }
}

@Test func staleBootEntriesNotReturned() throws {
    try withStateDirectory { url in
        let earlier = DeviceRegistry(url: url, bootSession: "boot-a")
        try earlier.update(from: desk())
        let tag = try #require(earlier.entry(uuid: lgUUID)).tagID

        let registry = DeviceRegistry(url: url, bootSession: "boot-b")
        #expect(registry.currentBootEntries().isEmpty)
        #expect(registry.entry(uuid: lgUUID) == nil)
        #expect(registry.entry(tagID: tag) == nil)

        // Seen again in this boot, under a new ID. On Nov 5 the LG was 1, and on Nov 6 it was 2.
        try registry.update(from: Topology(displays: [snapshot(1, lgIdentity)]))
        let seen = try #require(registry.entry(uuid: lgUUID))
        #expect(seen.lastID == 1)
        #expect(seen.bootSessionID == "boot-b")
        #expect(seen.tagID == tag)
        #expect(registry.currentBootEntries().map(\.identity.uuid) == [lgUUID], "M34WQ wasn't seen yet")
    }
}

@Test func tagIDsMonotonicAndStable() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())
        #expect(registry.entry(uuid: lgUUID)?.tagID == 1)
        #expect(registry.entry(uuid: m34UUID)?.tagID == 2)
        #expect(registry.entry(tagID: 2)?.identity.uuid == m34UUID)
        #expect(registry.entry(tagID: 3) == nil)

        try registry.update(from: desk())
        #expect(registry.entry(uuid: m34UUID)?.tagID == 2, "Stable across updates")

        // The counter is on disk, so a new instance in a new boot carries on from it.
        let reopened = DeviceRegistry(url: url, bootSession: "boot-b")
        var screen = lgIdentity
        screen.uuid = "63C872E8-4E48-4D23-9889-F8EE8F82BEEE"
        try reopened.update(from: Topology(displays: [snapshot(7, screen, kind: .ownVirtual)]))
        #expect(reopened.entry(uuid: screen.uuid!)?.tagID == 3, "Stale entries still hold their tags")

        try reopened.update(from: desk())
        #expect(reopened.entry(uuid: lgUUID)?.tagID == 1)
        #expect(reopened.entry(uuid: m34UUID)?.tagID == 2)
    }
}

@Test func pinPersists() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())

        try registry.pin(uuid: lgUUID, hz: 120)
        #expect(registry.entry(uuid: lgUUID)?.pinnedRefreshHz == 120)

        try registry.update(from: desk())
        #expect(registry.entry(uuid: lgUUID)?.pinnedRefreshHz == 120, "An update doesn't drop it")

        let reopened = DeviceRegistry(url: url, bootSession: "boot-a")
        #expect(reopened.entry(uuid: lgUUID)?.pinnedRefreshHz == 120)

        let nextBoot = DeviceRegistry(url: url, bootSession: "boot-b")
        try nextBoot.update(from: desk())
        #expect(nextBoot.entry(uuid: lgUUID)?.pinnedRefreshHz == 120, "A pin isn't tied to one boot")

        try nextBoot.pin(uuid: lgUUID, hz: nil)
        #expect(nextBoot.entry(uuid: lgUUID)?.pinnedRefreshHz == nil)
        #expect(DeviceRegistry(url: url, bootSession: "boot-b").entry(uuid: lgUUID)?.pinnedRefreshHz == nil)
    }
}

@Test func pinOfUnknownDisplayThrows() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        #expect(throws: DeviceRegistryError.unknownDisplay(lgUUID)) {
            try registry.pin(uuid: lgUUID, hz: 120)
        }
    }
}

@Test func corruptFileStartsEmpty() throws {
    try withStateDirectory { url in
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)

        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        #expect(registry.currentBootEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path), "Renamed, not left in place")

        let folder = url.deletingLastPathComponent()
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("devices.json.corrupt-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: folder.appending(component: kept[0])) == garbage, "Kept to look at later")

        try registry.update(from: desk())
        #expect(DeviceRegistry(url: url, bootSession: "boot-a").entry(uuid: lgUUID)?.tagID == 1)
    }
}

@Test func readErrorKeepsTheFileAndWorksFromMemory() throws {
    try withStateDirectory { url in
        let earlier = DeviceRegistry(url: url, bootSession: "boot-a")
        try earlier.update(from: desk())
        try earlier.pin(uuid: lgUUID, hz: 120)
        let good = try Data(contentsOf: url)
        let folder = url.deletingLastPathComponent()
        func fileMode() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }

        // A read fails, but a write would still work: the atomic rename only needs the folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        #expect(registry.currentBootEntries().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["devices.json"], "Not moved aside")

        // It works from memory, says nothing was saved, and leaves the file alone. A write would have
        // reset the mode to 0600, so the mode proves there wasn't one.
        #expect(throws: DeviceRegistryError.fileUnreadable) { try registry.update(from: desk()) }
        #expect(registry.entry(uuid: lgUUID)?.lastID == 2)
        #expect(registry.entry(uuid: lgUUID)?.pinnedRefreshHz == nil)
        #expect(throws: DeviceRegistryError.fileUnreadable) { try registry.pin(uuid: m34UUID, hz: 144) }
        #expect(try fileMode() == 0o000)

        // Once a read works, the file wins, and its pin and tags are all still there.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == good)
        try registry.update(from: desk())
        #expect(registry.entry(uuid: lgUUID)?.pinnedRefreshHz == 120)
        #expect(registry.entry(uuid: lgUUID)?.tagID == 1)
        #expect(registry.entry(uuid: m34UUID)?.tagID == 2)
        #expect(registry.entry(uuid: m34UUID)?.pinnedRefreshHz == nil, "The pin made in memory wasn't saved")
        #expect(DeviceRegistry(url: url, bootSession: "boot-a").entry(uuid: lgUUID)?.pinnedRefreshHz == 120)
    }
}

@Test func laterReadKeepsIdentityValuesItDoesNotHave() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        var full = lgIdentity
        full.alphanumericSerial = "SERIAL"
        full.weekOfManufacture = 11
        full.yearOfManufacture = 2020
        try registry.update(from: Topology(displays: [snapshot(2, full)]))

        // Online with a UUID, but the info dictionary came back empty.
        let sparse = DisplayIdentity(uuid: lgUUID, vendor: full.vendor, model: full.model, serial: full.serial)
        try registry.update(from: Topology(displays: [snapshot(3, sparse)]))
        let entry = try #require(registry.entry(uuid: lgUUID))
        #expect(entry.identity == full)
        #expect(entry.lastID == 3)

        // A value the new read does have still replaces the old one.
        var renamed = full
        renamed.productName = "New Name"
        try registry.update(from: Topology(displays: [snapshot(3, renamed)]))
        #expect(registry.entry(uuid: lgUUID)?.identity.productName == "New Name")
    }
}

@Test func unknownSchemaVersionCountsAsCorrupt() throws {
    try withStateDirectory { url in
        try Data(#"{"schemaVersion":99,"nextTagID":5,"entries":[]}"#.utf8).write(to: url)
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try registry.update(from: desk())
        #expect(registry.entry(uuid: lgUUID)?.tagID == 1)
    }
}

@Test func writesAFileOnlyItsOwnerCanRead() throws {
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}

@Test func failedWriteThrowsAndLeavesNothingBehind() throws {
    // The spec refuses a plain disconnect unless the registry write just before it succeeded.
    try withStateDirectory { url in
        let missingFolder = url.deletingLastPathComponent()
            .appending(component: "missing", directoryHint: .isDirectory)
        let unwritable = missingFolder.appending(component: "devices.json", directoryHint: .notDirectory)
        let registry = DeviceRegistry(url: unwritable, bootSession: "boot-a")

        #expect(throws: (any Error).self) { try registry.update(from: desk()) }
        #expect(registry.entry(uuid: lgUUID) == nil, "Memory doesn't get ahead of the disk")

        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try registry.update(from: desk())
        #expect(registry.entry(uuid: lgUUID)?.tagID == 1, "The failed attempt didn't use up a tag")
    }
}

@Test func everyUpdateWritesEvenWhenNothingChanged() throws {
    // Otherwise an unwritable disk would go unnoticed by the check before a disconnect.
    try withStateDirectory { url in
        let registry = DeviceRegistry(url: url, bootSession: "boot-a")
        try registry.update(from: desk())
        try FileManager.default.removeItem(at: url)
        try registry.update(from: desk())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
