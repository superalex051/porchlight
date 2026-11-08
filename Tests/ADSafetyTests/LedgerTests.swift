import ADFoundation
import ADModel
import ADSafety
import Darwin
import Foundation
import Synchronization
import Testing

// MARK: - Fixtures shared by this test target

let testBoot = "11111111-2222-3333-4444-555555555555"
let otherBoot = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
let sessionStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
let appRef = ProcessRef(pid: 100, startTime: 5000.5)
let ownerRef = ProcessRef(pid: 200, startTime: 6000.25)

func makeLedger(
    state: LedgerState = .active,
    owners: [ProcessRef] = [ownerRef],
    app: ProcessRef? = appRef,
    boot: String = testBoot,
    startedAt: Date = sessionStart,
    updatedAt: Date = sessionStart
) -> SafetyLedger {
    SafetyLedger(
        state: state,
        client: "parsec",
        looksLike: ScreenSize(w: 1728, h: 1080),
        hiDPI: true,
        hz: 60,
        keepOn: [],
        physical: [],
        owners: owners,
        app: app,
        bootSessionID: boot,
        startedAt: startedAt,
        updatedAt: updatedAt
    )
}

// MARK: - Helpers

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(component: "ADSafetyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileStatus(_ url: URL) -> stat {
    var info = stat()
    #expect(stat(url.path, &info) == 0)
    return info
}

private func permissions(of url: URL) -> mode_t {
    fileStatus(url).st_mode & 0o777
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] {
        lines.withLock { $0 }
    }
}

// MARK: - The ledger file

@Test func roundTripPreservesEveryField() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileLedgerStore(url: root.appending(component: "safety.json"))

    let ledger = SafetyLedger(
        state: .ending,
        client: "remote-app",
        looksLike: ScreenSize(w: 1180, h: 820),
        hiDPI: false,
        hz: 120,
        keepOn: ["40A936A8-FEB4-4F0F-ADA4-F81E1BC66A25"],
        physical: [
            PhysicalRecord(
                id: 4,
                identity: DisplayIdentity(
                    uuid: "0A4FA257-A531-4885-BA5E-76B9D0C0EF8D",
                    vendor: 7_249,
                    model: 13_154,
                    serial: 16_843_009,
                    alphanumericSerial: "SN123",
                    productName: "M34WQ",
                    registryLocation: "dcp-ext@2",
                    weekOfManufacture: 12,
                    yearOfManufacture: 2023
                ),
                origin: DisplayOrigin(x: -446, y: 1440),
                mode: DisplayMode(pointsWide: 3440, pointsHigh: 1440, pixelsWide: 3440, pixelsHigh: 1440, refreshHz: 143.97),
                wasMain: false
            ),
        ],
        owners: [ownerRef, ProcessRef(pid: 300, startTime: 7000.125)],
        app: appRef,
        bootSessionID: testBoot,
        // Fractions on purpose: the guardian compares `updatedAt` exactly to see progress.
        startedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123456),
        updatedAt: Date(timeIntervalSinceReferenceDate: 812_345_699.654321)
    )

    try store.save(ledger)
    #expect(try store.load() == ledger)

    // Other processes read this file, so the keys are part of the format.
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(component: "safety.json")))
    let keys = try #require(json as? [String: Any]).keys
    #expect(
        Set(keys) == [
            "schemaVersion", "state", "client", "looksLike", "hiDPI", "hz", "keepOn",
            "physical", "owners", "app", "bootSessionID", "startedAt", "updatedAt",
        ]
    )
}

@Test func newLedgerIsSchemaVersion1() {
    #expect(makeLedger().schemaVersion == 1)
}

@Test func roundTripKeepsAMissingApp() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileLedgerStore(url: root.appending(component: "safety.json"))

    let ledger = makeLedger(app: nil)
    try store.save(ledger)
    #expect(try store.load() == ledger)
}

@Test func saveIsAtomicAnd0600() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)

    // An older file with a looser mode, held open like a reader caught mid-read.
    let old = Data("old contents".utf8)
    try old.write(to: url)
    #expect(chmod(url.path, 0o644) == 0)
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    let oldInode = fileStatus(url).st_ino

    try store.save(makeLedger())

    #expect(permissions(of: url) == 0o600)
    // A new inode, and the old one still whole: the file was replaced, never written in place.
    #expect(fileStatus(url).st_ino != oldInode)
    #expect(try reader.readToEnd() == old)
    // No temp file left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["safety.json"])
    #expect(try store.load() == makeLedger())
}

@Test func saveCreatesAMissingParentAt0700() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appending(path: "nested/state", directoryHint: .isDirectory)
    let store = FileLedgerStore(url: state.appending(component: "safety.json"))

    try store.save(makeLedger())

    #expect(permissions(of: state) == 0o700)
    #expect(permissions(of: state.appending(component: "safety.json")) == 0o600)
    #expect(try store.load() == makeLedger())
}

@Test func saveLeavesAnExistingParentsModeAlone() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(chmod(root.path, 0o755) == 0)

    try FileLedgerStore(url: root.appending(component: "safety.json")).save(makeLedger())

    #expect(permissions(of: root) == 0o755)
}

@Test func saveThrowsWhenTheFileCannotBeWritten() throws {
    let root = try makeTempDirectory()
    defer {
        chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)
    try store.save(makeLedger(state: .starting))

    #expect(chmod(root.path, 0o500) == 0)
    #expect(throws: (any Error).self) { try store.save(makeLedger(state: .active)) }

    // The session rule depends on this: a failed write changes nothing.
    #expect(try store.load()?.state == .starting)
}

@Test func loadMissingIsNil() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try FileLedgerStore(url: root.appending(component: "safety.json")).load() == nil)
    #expect(try FileLedgerStore(url: root.appending(path: "no/such/dir/safety.json")).load() == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test(arguments: [
    "not json at all",
    "",
    "{\"schemaVersion\":1,\"state\":\"active\"",
    "{\"schemaVersion\":1,\"state\":\"active\"}",
    "[1,2,3]",
])
func corruptLedgerIsRenamedAndTreatedAsAbsent(contents: String) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let corrupt = root.appending(component: "safety.json.corrupt")
    let lines = LogLines()
    let store = FileLedgerStore(url: url, log: { lines.append($0) })
    try Data(contents.utf8).write(to: url)

    #expect(try store.load() == nil)

    #expect(!exists(url))
    #expect(try Data(contentsOf: corrupt) == Data(contents.utf8))
    #expect(lines.all.contains { $0.contains("safety.json.corrupt") })

    // Stays absent, and a new session can write over it.
    #expect(try store.load() == nil)
    try store.save(makeLedger())
    #expect(try store.load() == makeLedger())
}

@Test func unknownLedgerStateIsCorrupt() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)
    try store.save(makeLedger())

    let good = try String(contentsOf: url, encoding: .utf8)
    try good.replacingOccurrences(of: "\"active\"", with: "\"sideways\"").write(to: url, atomically: true, encoding: .utf8)

    #expect(try store.load() == nil)
    #expect(exists(root.appending(component: "safety.json.corrupt")))
}

@Test func anotherSchemaVersionIsUnreadable() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)

    var future = makeLedger()
    future.schemaVersion = 2
    try store.save(future)

    #expect(try store.load() == nil)
    #expect(!exists(url))
    #expect(exists(root.appending(component: "safety.json.corrupt")))
}

@Test func fileWithoutReadPermissionIsRenamedAndTreatedAsAbsent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)
    try store.save(makeLedger())
    #expect(chmod(url.path, 0) == 0)

    #expect(try store.load() == nil)

    #expect(!exists(url))
    #expect(exists(root.appending(component: "safety.json.corrupt")))
}

/// A failed read says nothing about the contents. Renaming a good ledger here would lose a live
/// session's records, so the error goes to the caller and the file stays.
@Test func readErrorThrowsAndRenamesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // A directory in the file's place reads as EISDIR, which stands in for any failing read.
    let inPlaceOfFile = root.appending(component: "safety.json", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inPlaceOfFile, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try FileLedgerStore(url: inPlaceOfFile).load() }
    #expect(exists(inPlaceOfFile))
    #expect(!exists(root.appending(component: "safety.json.corrupt")))

    // The same for a path whose parent is a file (ENOTDIR).
    let file = root.appending(component: "plain")
    try Data("x".utf8).write(to: file)
    #expect(throws: (any Error).self) { try FileLedgerStore(url: file.appending(component: "safety.json")).load() }
    #expect(exists(file))
}

@Test func secondCorruptFileReplacesTheFirst() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)

    try Data("first".utf8).write(to: url)
    #expect(try store.load() == nil)
    try Data("second".utf8).write(to: url)
    #expect(try store.load() == nil)

    #expect(try Data(contentsOf: root.appending(component: "safety.json.corrupt")) == Data("second".utf8))
}

@Test func settingAFileAsideRaisesTheEventOnce() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)
    try Data("garbage".utf8).write(to: url)
    #expect(!store.takeSetAsideEvent())

    #expect(try store.load() == nil)
    #expect(store.takeSetAsideEvent())
    #expect(!store.takeSetAsideEvent())

    // The file has gone, so this load is an ordinary missing file.
    #expect(try store.load() == nil)
    #expect(!store.takeSetAsideEvent())
}

@Test func aFileThatCannotBeMovedRaisesTheEventOnEveryLoad() throws {
    let root = try makeTempDirectory()
    defer {
        chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appending(component: "safety.json")
    let lines = LogLines()
    let store = FileLedgerStore(url: url, log: { lines.append($0) })
    try Data("garbage".utf8).write(to: url)
    #expect(chmod(root.path, 0o500) == 0)

    for _ in 0..<2 {
        #expect(try store.load() == nil)
        #expect(store.takeSetAsideEvent())
        #expect(exists(url))
    }
    #expect(lines.all.contains { $0.contains("renaming it failed") })
}

@Test func otherUnreadableFormsRaiseTheEvent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)

    var future = makeLedger()
    future.schemaVersion = 2
    try store.save(future)
    #expect(try store.load() == nil)
    #expect(store.takeSetAsideEvent())

    try store.save(makeLedger())
    #expect(chmod(url.path, 0) == 0)
    #expect(try store.load() == nil)
    #expect(store.takeSetAsideEvent())
}

/// The app or `adguardian restore` can reach a bad file first. The guardian's store then finds a plain
/// missing file, which must not read as the session being cleared.
@Test func aSetAsideByAnotherStoreRaisesTheEventOnce() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let guardian = FileLedgerStore(url: url)
    let app = FileLedgerStore(url: url)
    try app.save(makeLedger())
    #expect(try guardian.load() == makeLedger())
    #expect(!guardian.takeSetAsideEvent())

    try Data("garbage".utf8).write(to: url)
    #expect(try app.load() == nil)
    #expect(app.takeSetAsideEvent())

    #expect(try guardian.load() == nil)
    #expect(guardian.takeSetAsideEvent())
    #expect(!guardian.takeSetAsideEvent())
    #expect(try guardian.load() == nil)
    #expect(!guardian.takeSetAsideEvent())

    // Another bad file replaces the `.corrupt` one, and that's a new event.
    try Data("more garbage".utf8).write(to: url)
    #expect(try app.load() == nil)
    #expect(guardian.takeSetAsideEvent())
    #expect(!guardian.takeSetAsideEvent())
}

/// Starting after the fact is out of scope, and a months-old file must not look like news.
@Test func aCorruptFileFromBeforeTheStoreIsNotAnEvent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let corrupt = root.appending(component: "safety.json.corrupt")
    try Data("old".utf8).write(to: corrupt)

    let store = FileLedgerStore(url: root.appending(component: "safety.json"))

    #expect(try store.load() == nil)
    #expect(!store.takeSetAsideEvent())
}

@Test func aCorruptFileThatChangesOrReturnsIsAnEvent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let corrupt = root.appending(component: "safety.json.corrupt")
    try Data("old".utf8).write(to: corrupt)
    let store = FileLedgerStore(url: root.appending(component: "safety.json"))

    // The same inode with a new modification time.
    let later = Date(timeIntervalSinceReferenceDate: 800_000_000)
    try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: corrupt.path)
    #expect(store.takeSetAsideEvent())
    #expect(!store.takeSetAsideEvent())

    // Removing it isn't an event, and its coming back is.
    try FileManager.default.removeItem(at: corrupt)
    #expect(!store.takeSetAsideEvent())
    try Data("new".utf8).write(to: corrupt)
    #expect(store.takeSetAsideEvent())
    #expect(!store.takeSetAsideEvent())
}

@Test func anOrdinaryLoadRaisesNoEvent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)

    #expect(try store.load() == nil)
    #expect(!store.takeSetAsideEvent())

    try store.save(makeLedger())
    #expect(try store.load() != nil)
    #expect(!store.takeSetAsideEvent())

    try store.clear()
    #expect(try store.load() == nil)
    #expect(!store.takeSetAsideEvent())
}

@Test func clearRemovesFile() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let store = FileLedgerStore(url: url)
    try store.save(makeLedger())

    try store.clear()

    #expect(!exists(url))
    #expect(try store.load() == nil)
    // `session end` with no session must succeed, so clearing nothing does too.
    try store.clear()
}

@Test func clearThrowsWhenTheFileCannotBeRemoved() throws {
    let root = try makeTempDirectory()
    defer {
        chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
    let store = FileLedgerStore(url: root.appending(component: "safety.json"))
    try store.save(makeLedger())

    #expect(chmod(root.path, 0o500) == 0)
    #expect(throws: (any Error).self) { try store.clear() }
}

// MARK: - The in-memory store

@Test func inMemoryStoreRoundTripsAndClears() throws {
    let store = InMemoryLedgerStore()
    #expect(try store.load() == nil)

    try store.save(makeLedger())
    #expect(try store.load() == makeLedger())

    try store.clear()
    #expect(try store.load() == nil)
}

@Test func inMemoryStoreFailsOnSaveWhenAsked() throws {
    let store = InMemoryLedgerStore()
    try store.save(makeLedger(state: .starting))

    store.failOnSave = true
    #expect(store.failOnSave)
    #expect(throws: (any Error).self) { try store.save(makeLedger(state: .active)) }
    #expect(try store.load()?.state == .starting)

    store.failOnSave = false
    try store.save(makeLedger(state: .active))
    #expect(try store.load()?.state == .active)
}

@Test func inMemoryStoreActsOutASetAside() throws {
    let store = InMemoryLedgerStore(ledger: makeLedger())
    #expect(!store.takeSetAsideEvent())

    store.setAsideOnNextLoad()
    #expect(try store.load() == nil)
    #expect(store.takeSetAsideEvent())
    #expect(!store.takeSetAsideEvent())

    // The contents went with it.
    #expect(try store.load() == nil)
    #expect(!store.takeSetAsideEvent())
}

@Test func inMemoryStoreActsOutAStuckFileUntilASave() throws {
    let store = InMemoryLedgerStore(ledger: makeLedger())
    store.unreadableAndStuck = true

    for _ in 0..<2 {
        #expect(try store.load() == nil)
        #expect(store.takeSetAsideEvent())
    }

    try store.save(makeLedger())
    #expect(!store.unreadableAndStuck)
    #expect(try store.load() == makeLedger())
    #expect(!store.takeSetAsideEvent())
}
