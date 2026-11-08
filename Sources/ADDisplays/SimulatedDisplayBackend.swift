import ADFoundation
import ADModel
import Foundation
import Synchronization

/// A Mac in memory, for tests and dry runs. It behaves the way the 2026-11-06 spike measured, because
/// later tests only catch real bugs if it does.
///
/// What the spike measured:
/// - When the last real display goes away, a fallback display appears with a new ID, and while it's up
///   it is all `topology()` lists. `legacyIsOnline(_:)` says true for the physical IDs it hides, and
///   enabling one of them by ID works. It goes when any real display returns.
/// - A disconnected display keeps its ID, vendor, model, serial, location and origin, but reads with
///   no UUID and no name. Its 1x1 stub mode reads as nil, the same as `LiveDisplayBackend`.
/// - A sleeping display is online but not active, and with nothing active an enable throws 1014. The
///   hardware blocks about 10 seconds first, and this doesn't. A new virtual screen comes up awake,
///   and sleep doesn't stop a disconnect or a commit. A wake leaves a disconnected display off.
/// - A commit with an offline target throws 1001 and applies nothing.
/// - A display a commit doesn't name moves aside if a display it does name lands on top of it.
/// - The same vendor, product and serial give a virtual screen the same UUID, but never the same ID.
///
/// What is a guess, because nothing tested it:
/// - Which display becomes main when main goes away. Here, the lowest ID online, and everything online
///   shifts to keep it at (0,0), so a main display moved alone ends up back at (0,0).
/// - A display returning on top of another moves aside, as in a commit.
/// - Where a new screen opens. Here, to the right of everything online. The real Mac doesn't always do
///   that: the spike's recreated screen opened at (-1728,0), so nothing may depend on this position.
/// - Enabling an unplugged display or an empty pipe throws 1001. So does a commit with an unknown mode.
/// - Enabling a stale twin throws 1001. On the real Mac one never came online, and a rescue that tried
///   it took about 17 seconds, which fits three enables that fail at once and the 15 second wait.
/// - How long a released virtual screen stays listed. macOS tears it down some time after the release,
///   and nobody has measured that. Here it goes at once, unless `scriptVirtualLinger` says otherwise.
/// - The fallback's sleep state when everything else sleeps. Here, it stays awake unless told to sleep.
/// - A `setEnabled` with several IDs. Here, all of them switch at once and the world settles once, or
///   none does if one fails its check. Nobody has measured what macOS does inside such a transaction.
/// - macOS's gap handling on origins. Here, a commit's origins stay as given, gaps included, where the
///   real Mac may pull displays together. A caller must read back the origins it set.
public final class SimulatedDisplayBackend: DisplayBackend {
    private let state: Mutex<SimulatedMac>

    /// `modes` gives each display's list. Without one, its current mode is the whole list.
    public init(seed: Topology = .init(displays: []), modes: [DisplayID: [DisplayMode]] = [:]) {
        state = Mutex(SimulatedMac(seed: seed, modes: modes))
    }

    /// One line for each `setEnabled`, `commit`, `addVirtual`, `removeVirtual` and `setVirtualMode`, in
    /// order. Attempts that failed are here too, marked `failed`, so a test can count retries:
    /// `enable 2`, `enable 2 failed 1014`, `disable 4`, `commit origin 2 (0,0), mode 4 3440x1440@144`,
    /// `commit failed 1001: display 2 is offline`, `addVirtual 6 1728x1080@60 hiDPI`. A commit that left
    /// out a mode the display doesn't list adds `commit left out mode 4 3440x1440@144` after what it applied.
    /// A `setEnabled` with several IDs adds a line for each, in its order, the same as one call per ID
    /// would; `switchTransactions` shows how they were grouped.
    /// The other hooks stand in for the world, not for a caller, so they aren't listed. The one
    /// exception is `gone 6`, when a scripted linger ends, so a test can order it against what follows.
    public var mutations: [String] {
        state.withLock { $0.mutations }
    }

    /// One line for each `setEnabled` call, single or several IDs, so a test can see what went in one
    /// transaction: `disable 4 2`, `enable 2`, `disable 4 2 failed 1001`.
    public var switchTransactions: [String] {
        state.withLock { $0.switchTransactions }
    }

    /// How many times the fallback display has come up, including any that came and went inside one
    /// call, where no test could read them.
    public var fallbackAppearances: Int {
        state.withLock { $0.fallbackAppearances }
    }

    public func topology() -> Topology {
        state.withLock { $0.readTopology() }
    }

    public func modes(of id: DisplayID) -> [DisplayMode] {
        state.withLock { $0.modes(of: id) }
    }

    public func setEnabled(_ id: DisplayID, _ enabled: Bool) throws {
        try state.withLock { try $0.setEnabled([id], enabled) }
    }

    /// All at once: every ID is checked before any changes, and the world settles once, after the last.
    public func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws {
        try state.withLock { try $0.setEnabled(ids, enabled) }
    }

    public func commit(_ changes: [DisplayChange]) throws {
        try state.withLock { try $0.commit(changes) }
    }

    /// What `CGDisplayIsOnline` would say, which is the wrong question during fallback. Exists so a
    /// test can prove that a restore gated on it enables nothing.
    public func legacyIsOnline(_ id: DisplayID) -> Bool {
        state.withLock { $0.legacyIsOnline(id) }
    }

    // MARK: Virtual screen hooks

    /// Adds a virtual screen and returns its new ID. Its UUID comes from the identity's vendor, model
    /// and serial, as on the real Mac, so any UUID passed here is ignored.
    public func addVirtual(identity: DisplayIdentity, mode: DisplayMode, modes: [DisplayMode]) -> DisplayID {
        state.withLock { $0.addVirtual(identity: identity, mode: mode, modes: modes) }
    }

    /// Removes a virtual screen, as if its owner released it or died. Other IDs are ignored.
    public func removeVirtual(_ id: DisplayID) {
        state.withLock { $0.removeVirtual(id) }
    }

    /// Replaces a virtual screen's mode and its mode list, as the real settings call does when it's
    /// given one mode. Other IDs are ignored.
    public func setVirtualMode(_ id: DisplayID, _ mode: DisplayMode) {
        state.withLock { $0.setVirtualMode(id, mode) }
    }

    // MARK: Scripted world

    /// The next `removeVirtual` of this display doesn't finish at once: it stays listed as it was for
    /// the next `reads` calls to `topology()`, and only then goes, as `gone <id>` in `mutations`. Until
    /// then it still counts as a display, so no fallback comes up. Pass `.max` for one that never goes.
    public func scriptVirtualLinger(_ id: DisplayID, reads: Int) {
        state.withLock { $0.scriptVirtualLinger(id, reads: reads) }
    }

    /// After the next enable of this display, one `topology()` reads it online and the next
    /// `offlineReads` read it offline. A commit naming it in that stretch throws 1001.
    public func scriptFlap(_ id: DisplayID, offlineReads: Int) {
        state.withLock { $0.scriptFlap(id, offlineReads: offlineReads) }
    }

    /// Sleeps or wakes one display. It stays online but stops being active.
    public func setAsleep(_ id: DisplayID, _ asleep: Bool) {
        state.withLock { $0.setAsleep(id, asleep) }
    }

    /// Wakes every display. A disconnected display stays off, as in the spike's sleep test.
    public func wakeAll() {
        state.withLock { $0.wake(reconnecting: []) }
    }

    /// Wakes every display, and undoes the disconnect of the ones listed. This is the unexplained
    /// Nov 5 failure, where a disconnect around the moment Parsec woke the displays didn't stick.
    public func simulateWake(reconnecting ids: [DisplayID]) {
        state.withLock { $0.wake(reconnecting: ids) }
    }

    /// The next `times` enables of this display throw 1014. Pass 0 to clear, or `.max` for always.
    public func setEnableFails(_ id: DisplayID, _ times: Int) {
        state.withLock { $0.setEnableFails(id, times) }
    }

    /// Unplugs a monitor. It leaves every list and every call about it fails.
    public func removePhysical(_ id: DisplayID) {
        state.withLock { $0.removePhysical(id) }
    }

    /// The next `times` reads of `topology()` can't get the full list, so they show only what's
    /// online, the way `LiveDisplayBackend` falls back. Pass 0 to clear, or `.max` for always.
    public func setListReadFails(_ times: Int) {
        state.withLock { $0.setListReadFails(times) }
    }

    /// Adds a stale twin of a monitor and returns its new ID: an offline record with the monitor's
    /// vendor, model and serial at `registryLocation`, with no mode and no UUID, like the one macOS kept
    /// for the M34WQ on 2026-11-07 on a port it had used earlier. It never comes online. Nil unless
    /// `id` is a physical display.
    @discardableResult
    public func scriptStaleTwin(of id: DisplayID, registryLocation: String) -> DisplayID? {
        state.withLock { $0.scriptStaleTwin(of: id, registryLocation: registryLocation) }
    }
}

// MARK: - Fixtures

extension SimulatedDisplayBackend {
    /// A two-monitor desk as read from a real Mac on 2026-11-06, with its full mode lists.
    ///
    /// Test only, and it crashes anywhere else. The desk's monitors can't be named in `Sources`, so the
    /// data is in `Tests/Fixtures/Displays/two-monitor-desk.json`, found from this source file's path. The
    /// golden corpus is found the same way, and it holds for anything built from this checkout.
    public static func twoMonitorDesk() -> SimulatedDisplayBackend {
        guard TestBundleGuard.isRunningInTestBundle else {
            fatalError("twoMonitorDesk() is a test fixture. A dry run uses seededFromLive().")
        }
        return SimulatedDisplayBackend(seed: deskFixture.topology, modes: deskFixture.modesByID)
    }

    private struct DeskFixture: Decodable, Sendable {
        var topology: Topology
        var modes: [String: [DisplayMode]]

        var modesByID: [DisplayID: [DisplayMode]] {
            Dictionary(uniqueKeysWithValues: modes.compactMap { key, value in
                DisplayID(key).map { ($0, value) }
            })
        }
    }

    private static let deskFixture: DeskFixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ADDisplays
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // the repo
            .appendingPathComponent("Tests/Fixtures/Displays/two-monitor-desk.json")
        do {
            return try JSONDecoder().decode(DeskFixture.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Can't read \(url.path): \(error)")
        }
    }()

    /// A copy of the real Mac for a dry run, made using only `topology()` and `modes(of:)`, so it changes
    /// nothing.
    public static func seededFromLive() -> SimulatedDisplayBackend {
        let live = LiveDisplayBackend()
        let topology = live.topology()
        var modes: [DisplayID: [DisplayMode]] = [:]
        for display in topology.displays {
            modes[display.id] = live.modes(of: display.id)
        }
        return copy(of: topology, modes: modes)
    }

    /// A display that's off when the copy is made has no UUID or mode list to copy, so it gets neither,
    /// and the copy can't bring it on: every enable fails. Brought on, it would be online with no mode,
    /// and a session start in the copy would refuse, unable to read it. On the test desk such a display has
    /// been a stale pipe that every reconnect waited on in vain, so this is also the closer copy.
    static func copy(of topology: Topology, modes: [DisplayID: [DisplayMode]]) -> SimulatedDisplayBackend {
        let backend = SimulatedDisplayBackend(seed: topology, modes: modes)
        for display in topology.displays where !display.isOnline && display.kind != .emptyPipe {
            backend.setEnableFails(display.id, .max)
        }
        return backend
    }
}

// MARK: - The model

private struct SimulatedDisplay: Sendable {
    enum Flap: Sendable {
        /// Waiting for the next enable.
        case armed(offlineReads: Int)
        /// The next read is online, and the ones after it offline.
        case onlineRead(offlineReads: Int)
        case offline(readsLeft: Int)
    }

    let id: DisplayID
    /// As an online read shows it. `snapshot` removes what a disconnected display doesn't report.
    var identity: DisplayIdentity
    let kind: DisplayKind
    var origin: DisplayOrigin
    var mode: DisplayMode?
    var modes: [DisplayMode]
    var isEnabled: Bool
    var isAsleep = false
    var flap: Flap?
    var enableFailuresLeft = 0
    /// Reads it stays listed after `removeVirtual`. They only count down once `isLeaving` is set.
    var lingerReads = 0
    var isLeaving = false
    /// Made by `scriptStaleTwin`. It reads as physical, and nothing turns it on.
    var isStaleTwin = false

    var readsOnline: Bool {
        if case .offline = flap { return false }
        return isEnabled
    }

    var isRealDisplay: Bool {
        kind != .osFallback && kind != .emptyPipe && !isStaleTwin
    }

    var isVirtualScreen: Bool {
        kind == .ownVirtual || kind == .parsecVirtual || kind == .otherVirtual
    }

    var snapshot: DisplaySnapshot {
        var shown = identity
        if !readsOnline {
            shown.uuid = nil
            shown.productName = nil
            shown.alphanumericSerial = nil
            shown.weekOfManufacture = nil
            shown.yearOfManufacture = nil
        }
        return DisplaySnapshot(
            id: id,
            identity: shown,
            kind: kind,
            isOnline: readsOnline,
            isActive: readsOnline && !isAsleep,
            isMain: false,
            isAsleep: readsOnline && isAsleep,
            origin: origin,
            mode: readsOnline ? mode : nil
        )
    }

    func overlaps(_ other: SimulatedDisplay) -> Bool {
        guard let mode, let otherMode = other.mode else { return false }
        return Int(origin.x) < Int(other.origin.x) + otherMode.pointsWide
            && Int(other.origin.x) < Int(origin.x) + mode.pointsWide
            && Int(origin.y) < Int(other.origin.y) + otherMode.pointsHigh
            && Int(other.origin.y) < Int(origin.y) + mode.pointsHigh
    }
}

private struct SimulatedMac: Sendable {
    private static let offlineCode: Int32 = 1001
    private static let nothingAwakeCode: Int32 = 1014

    /// Kept in ID order, which IDs only ever increasing makes easy.
    private var displays: [SimulatedDisplay]
    private var nextID: DisplayID
    private var mainID: DisplayID?
    /// macOS only needs a fallback once a real display has gone away, so an empty seed stays empty.
    private var hasHadRealDisplay: Bool
    private var listReadFailuresLeft = 0
    private(set) var mutations: [String] = []
    private(set) var switchTransactions: [String] = []
    private(set) var fallbackAppearances = 0

    init(seed: Topology, modes: [DisplayID: [DisplayMode]]) {
        displays = seed.displays.sorted { $0.id < $1.id }.map { snapshot in
            SimulatedDisplay(
                id: snapshot.id,
                identity: snapshot.identity,
                kind: snapshot.kind,
                origin: snapshot.origin,
                mode: snapshot.mode,
                modes: modes[snapshot.id] ?? snapshot.mode.map { [$0] } ?? [],
                isEnabled: snapshot.isOnline,
                isAsleep: snapshot.isOnline && !snapshot.isActive
            )
        }
        nextID = (displays.last?.id ?? 0) + 1
        mainID = seed.main?.id
        hasHadRealDisplay = displays.contains(where: \.isRealDisplay)

        // A seed is taken as written, so nothing shifts to put main at (0,0).
        reconcileFallback()
        if !displays.contains(where: { $0.id == mainID && $0.readsOnline }) {
            mainID = displays.first(where: \.readsOnline)?.id
        }
    }

    // MARK: Reads

    /// In the order the spike saw from `SLSGetDisplayList`: online first, each group by ID.
    mutating func readTopology() -> Topology {
        let listed = displays.contains { $0.kind == .osFallback } ? displays.filter { $0.kind == .osFallback } : displays
        let listReadFailed = listReadFailuresLeft > 0
        if listReadFailed { listReadFailuresLeft -= 1 }
        let ordered = listed.filter(\.readsOnline) + (listReadFailed ? [] : listed.filter { !$0.readsOnline })
        let snapshots = ordered.map { display in
            var snapshot = display.snapshot
            snapshot.isMain = display.id == mainID
            return snapshot
        }
        let topology = Topology(displays: DisplayClassifier.markingStaleTwins(snapshots), listReadFailed: listReadFailed)
        advanceFlaps()
        advanceLingers()
        return topology
    }

    func modes(of id: DisplayID) -> [DisplayMode] {
        guard let display = display(id), display.readsOnline else { return [] }
        return display.modes
    }

    func legacyIsOnline(_ id: DisplayID) -> Bool {
        guard let display = display(id) else { return false }
        let fallbackIsUp = displays.contains { $0.kind == .osFallback }
        return display.readsOnline || (fallbackIsUp && display.isRealDisplay)
    }

    // MARK: Backend calls

    /// One call, one transaction: if any ID fails its check, nothing changes.
    mutating func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws {
        guard !ids.isEmpty else { return }
        let action = enabled ? "enable" : "disable"
        let named = ids.map(String.init).joined(separator: " ")
        do {
            try enabled ? connect(ids) : disconnect(ids)
            mutations += ids.map { "\(action) \($0)" }
            switchTransactions.append("\(action) \(named)")
        } catch let error as DisplayBackendError {
            mutations += ids.map { "\(action) \($0) failed \(error.code)" }
            switchTransactions.append("\(action) \(named) failed \(error.code)")
            throw error
        }
    }

    private mutating func disconnect(_ ids: [DisplayID]) throws {
        let indices = try ids.map { try realDisplayIndex($0) }
        for index in indices {
            displays[index].isEnabled = false
            // A flap waiting for the next enable still waits, but one already under way is over.
            if case .armed = displays[index].flap {} else { displays[index].flap = nil }
        }
        settle()
    }

    private mutating func connect(_ ids: [DisplayID]) throws {
        let indices = try ids.map { try realDisplayIndex($0) }
        guard displays.contains(where: { $0.readsOnline && !$0.isAsleep }) else {
            let named = ids.map(String.init).joined(separator: ", ")
            throw DisplayBackendError(code: Self.nothingAwakeCode, message: "no display is awake to enable \(named)")
        }
        if let failing = indices.first(where: { displays[$0].enableFailuresLeft > 0 }) {
            displays[failing].enableFailuresLeft -= 1
            let id = displays[failing].id
            throw DisplayBackendError(code: Self.nothingAwakeCode, message: "scripted failure enabling display \(id)")
        }
        var returned: [DisplayID] = []
        for index in indices {
            if switchOn(index) { returned.append(displays[index].id) }
        }
        settle(returning: returned)
    }

    private func realDisplayIndex(_ id: DisplayID) throws -> Int {
        guard let index = index(id), displays[index].isRealDisplay else {
            throw DisplayBackendError(code: Self.offlineCode, message: "there is no display \(id) to switch")
        }
        return index
    }

    /// Without the checks, for a wake that reconnects a display by itself.
    private mutating func reconnect(_ index: Int) {
        let id = displays[index].id
        let wasOff = switchOn(index)
        settle(returning: wasOff ? [id] : [])
    }

    /// Turns it on without settling. True if it was off.
    private mutating func switchOn(_ index: Int) -> Bool {
        let wasOff = !displays[index].isEnabled
        displays[index].isEnabled = true
        if wasOff { displays[index].isAsleep = false }
        if case .armed(let offlineReads) = displays[index].flap {
            displays[index].flap = offlineReads > 0 ? .onlineRead(offlineReads: offlineReads) : nil
        }
        return wasOff
    }

    /// As `LiveDisplayBackend` does, a mode the display doesn't list is left out, the rest is applied,
    /// and then the error names the display. An offline target still fails everything.
    mutating func commit(_ changes: [DisplayChange]) throws {
        let unlisted = changes.filter { change in
            guard case .mode(let id, let mode) = change else { return false }
            return !modes(of: id).contains { $0.matches(mode) }
        }
        let applicable = changes.filter { !unlisted.contains($0) }
        if !applicable.isEmpty {
            try apply(applicable)
        }
        guard unlisted.isEmpty else {
            mutations.append("commit left out " + unlisted.map(Self.describe).joined(separator: ", "))
            var ids: [DisplayID] = []
            var problems: [String] = []
            for case .mode(let id, let mode) in unlisted {
                ids.append(id)
                problems.append("display \(id) has no mode \(Self.describe(mode))")
            }
            throw DisplayBackendError(
                code: Self.offlineCode,
                message: problems.joined(separator: "; "),
                modesNotApplied: ids
            )
        }
    }

    private mutating func apply(_ changes: [DisplayChange]) throws {
        do {
            for change in changes {
                try validate(change)
            }
        } catch let error as DisplayBackendError {
            mutations.append("commit failed \(error.code): \(error.message)")
            throw error
        }

        var named: [DisplayID] = []
        for change in changes {
            switch change {
            case .origin(let id, let origin):
                if let index = index(id) { displays[index].origin = origin }
                named.append(id)
            case .mode(let id, let mode):
                if let index = index(id) { displays[index].mode = listedMode(of: displays[index], matching: mode) }
                named.append(id)
            }
        }
        moveAside(displays.filter { $0.readsOnline && !named.contains($0.id) }.map(\.id), onlyFrom: named)
        settle()
        mutations.append("commit " + changes.map(Self.describe).joined(separator: ", "))
    }

    /// `commit` has already taken out any mode the display doesn't list.
    private func validate(_ change: DisplayChange) throws {
        let id: DisplayID
        switch change {
        case .origin(let target, _): id = target
        case .mode(let target, _): id = target
        }
        guard let display = display(id), display.readsOnline else {
            throw DisplayBackendError(code: Self.offlineCode, message: "display \(id) is offline")
        }
    }

    /// An exact match first, then one whose refresh rate rounds the same, as `LiveDisplayBackend` does.
    private func listedMode(of display: SimulatedDisplay, matching wanted: DisplayMode) -> DisplayMode? {
        display.modes.first { $0 == wanted } ?? display.modes.first { $0.matches(wanted) }
    }

    // MARK: Virtual screens

    mutating func addVirtual(identity: DisplayIdentity, mode: DisplayMode, modes: [DisplayMode]) -> DisplayID {
        let id = takeID()
        var derived = identity
        derived.uuid = Self.virtualUUID(vendor: identity.vendor, model: identity.model, serial: identity.serial)
        let rightEdge = displays.filter(\.readsOnline)
            .compactMap { display in display.mode.map { Int(display.origin.x) + $0.pointsWide } }
            .max() ?? 0
        displays.append(
            SimulatedDisplay(
                id: id,
                identity: derived,
                kind: DisplayClassifier.kind(
                    isVirtual: true,
                    vendor: identity.vendor,
                    model: identity.model,
                    name: identity.productName
                ),
                origin: DisplayOrigin(x: Int32(rightEdge), y: 0),
                mode: mode,
                modes: modes.contains(mode) ? modes : [mode] + modes,
                isEnabled: true
            )
        )
        hasHadRealDisplay = true
        settle()
        mutations.append("addVirtual \(id) \(Self.describe(mode))")
        return id
    }

    mutating func removeVirtual(_ id: DisplayID) {
        guard let index = index(id), displays[index].isVirtualScreen, !displays[index].isLeaving else { return }
        if displays[index].lingerReads > 0 {
            displays[index].isLeaving = true
        } else {
            displays.remove(at: index)
            settle()
        }
        mutations.append("removeVirtual \(id)")
    }

    mutating func setVirtualMode(_ id: DisplayID, _ mode: DisplayMode) {
        guard let index = index(id), displays[index].isVirtualScreen else { return }
        displays[index].mode = mode
        displays[index].modes = [mode]
        mutations.append("setVirtualMode \(id) \(Self.describe(mode))")
    }

    /// Readable, and one-to-one: it's the vendor, model and serial in hex.
    private static func virtualUUID(vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        String(
            format: "%08X-%04X-%04X-%04X-%012X",
            vendor,
            model >> 16,
            model & 0xFFFF,
            serial >> 16,
            serial & 0xFFFF
        )
    }

    // MARK: Scripted world

    mutating func scriptVirtualLinger(_ id: DisplayID, reads: Int) {
        guard let index = index(id), displays[index].isVirtualScreen else { return }
        displays[index].lingerReads = reads
    }

    mutating func scriptFlap(_ id: DisplayID, offlineReads: Int) {
        guard let index = index(id) else { return }
        displays[index].flap = .armed(offlineReads: offlineReads)
    }

    mutating func setAsleep(_ id: DisplayID, _ asleep: Bool) {
        guard let index = index(id) else { return }
        displays[index].isAsleep = asleep
    }

    mutating func wake(reconnecting ids: [DisplayID]) {
        for index in displays.indices {
            displays[index].isAsleep = false
        }
        for id in ids {
            guard let index = index(id), displays[index].isRealDisplay else { continue }
            reconnect(index)
        }
    }

    mutating func setEnableFails(_ id: DisplayID, _ times: Int) {
        guard let index = index(id) else { return }
        displays[index].enableFailuresLeft = times
    }

    mutating func setListReadFails(_ times: Int) {
        listReadFailuresLeft = times
    }

    mutating func removePhysical(_ id: DisplayID) {
        guard let index = index(id), displays[index].kind == .physical else { return }
        displays.remove(at: index)
        settle()
    }

    mutating func scriptStaleTwin(of id: DisplayID, registryLocation: String) -> DisplayID? {
        guard let monitor = display(id), monitor.kind == .physical, !monitor.isStaleTwin else { return nil }
        let twin = takeID()
        displays.append(
            SimulatedDisplay(
                id: twin,
                identity: DisplayIdentity(
                    vendor: monitor.identity.vendor,
                    model: monitor.identity.model,
                    serial: monitor.identity.serial,
                    registryLocation: registryLocation
                ),
                kind: .physical,
                origin: DisplayOrigin(x: 0, y: 0),
                mode: nil,
                modes: [],
                isEnabled: false,
                isStaleTwin: true
            )
        )
        return twin
    }

    // MARK: Rules

    /// Consumes one read from every flap in progress.
    private mutating func advanceFlaps() {
        var returned: [DisplayID] = []
        var changed = false
        for index in displays.indices {
            switch displays[index].flap {
            case .onlineRead(let offlineReads):
                displays[index].flap = .offline(readsLeft: offlineReads)
                changed = true
            case .offline(let readsLeft) where readsLeft > 1:
                displays[index].flap = .offline(readsLeft: readsLeft - 1)
            case .offline:
                displays[index].flap = nil
                returned.append(displays[index].id)
                changed = true
            case .armed, nil:
                break
            }
        }
        if changed { settle(returning: returned) }
    }

    /// Consumes one read from every released virtual screen still on its way out.
    private mutating func advanceLingers() {
        var changed = false
        for index in displays.indices.reversed() where displays[index].isLeaving {
            displays[index].lingerReads -= 1
            guard displays[index].lingerReads == 0 else { continue }
            mutations.append("gone \(displays[index].id)")
            displays.remove(at: index)
            changed = true
        }
        if changed { settle() }
    }

    private mutating func settle(returning returned: [DisplayID] = []) {
        reconcileFallback()
        moveAside(returned, onlyFrom: nil)
        reconcileMain()
    }

    private mutating func reconcileFallback() {
        let fallback = displays.firstIndex { $0.kind == .osFallback }
        if displays.contains(where: { $0.isRealDisplay && $0.readsOnline }) {
            if let fallback { displays.remove(at: fallback) }
        } else if fallback == nil && hasHadRealDisplay {
            displays.append(makeFallback())
        }
    }

    private mutating func makeFallback() -> SimulatedDisplay {
        fallbackAppearances += 1
        let mode = DisplayMode(pointsWide: 1920, pointsHigh: 1080, pixelsWide: 1920, pixelsHigh: 1080, refreshHz: 60)
        return SimulatedDisplay(
            id: takeID(),
            identity: DisplayIdentity(
                uuid: "A8AD2690-9F4D-4D59-8538-A5FE7CFE0F02",
                vendor: 0x756E_6B6E,
                model: 0x7669_7274,
                serial: 0
            ),
            kind: .osFallback,
            origin: DisplayOrigin(x: 0, y: 0),
            mode: mode,
            modes: [mode],
            isEnabled: true
        )
    }

    /// The display at (0,0) is main. With none there, the current main stays if it's online, the
    /// lowest ID online takes over if not, and everything online shifts to keep main at (0,0).
    private mutating func reconcileMain() {
        let online = displays.filter(\.readsOnline)
        if let atOrigin = online.first(where: { $0.origin.x == 0 && $0.origin.y == 0 }) {
            mainID = atOrigin.id
            return
        }
        guard let next = online.first(where: { $0.id == mainID }) ?? online.first else {
            mainID = nil
            return
        }
        mainID = next.id
        for index in displays.indices where displays[index].readsOnline {
            displays[index].origin.x -= next.origin.x
            displays[index].origin.y -= next.origin.y
        }
    }

    /// Moves each display to the left of whatever online display it overlaps. With `onlyFrom`, a
    /// display only moves if it overlaps one of those. In the spike, a screen 1728 wide at (0,0) ended
    /// up at (-1728,0) when a monitor named in a commit took (0,0).
    private mutating func moveAside(_ ids: [DisplayID], onlyFrom triggers: [DisplayID]?) {
        for id in ids {
            guard let index = index(id) else { continue }
            if let triggers {
                let isCovered = displays.contains { triggers.contains($0.id) && $0.overlaps(displays[index]) }
                guard isCovered else { continue }
            }
            while let other = displays.first(where: {
                $0.id != id && $0.readsOnline && $0.overlaps(displays[index])
            }) {
                let width = displays[index].mode?.pointsWide ?? 0
                displays[index].origin = DisplayOrigin(x: other.origin.x - Int32(width), y: other.origin.y)
            }
        }
    }

    // MARK: Helpers

    private func index(_ id: DisplayID) -> Int? {
        displays.firstIndex { $0.id == id }
    }

    private func display(_ id: DisplayID) -> SimulatedDisplay? {
        displays.first { $0.id == id }
    }

    private mutating func takeID() -> DisplayID {
        defer { nextID += 1 }
        return nextID
    }

    private static func describe(_ change: DisplayChange) -> String {
        switch change {
        case .origin(let id, let origin): "origin \(id) (\(origin.x),\(origin.y))"
        case .mode(let id, let mode): "mode \(id) \(describe(mode))"
        }
    }

    private static func describe(_ mode: DisplayMode) -> String {
        "\(mode.pointsWide)x\(mode.pointsHigh)@\(Int(mode.refreshHz.rounded()))\(mode.isHiDPI ? " hiDPI" : "")"
    }
}
