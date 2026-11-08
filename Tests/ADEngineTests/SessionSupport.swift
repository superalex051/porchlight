import ADDisplayConfig
import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import ADVirtualScreens
import Foundation
import Synchronization
import Testing

@testable import ADEngine

let lg: DisplayID = 2
let m34: DisplayID = 4
let lgUUID = "40A936A8-FEB4-4F0F-ADA4-F81E1BC66A25"
let lgOrigin = DisplayOrigin(x: 0, y: 0)
let m34Origin = DisplayOrigin(x: -446, y: 1440)
let boot = "boot-1"
let appRef = ProcessRef(pid: 4242, startTime: 1000)
let relaunchedRef = ProcessRef(pid: 4343, startTime: 3000)
let ownerRef = ProcessRef(pid: 5151, startTime: 2000)
let secondOwnerRef = ProcessRef(pid: 5252, startTime: 2500)
let defaultSize = ScreenSize(w: 1728, h: 1080)

func mode(_ w: Int, _ h: Int, hz: Double, scale: Int = 1) -> DisplayMode {
    DisplayMode(pointsWide: w, pointsHigh: h, pixelsWide: w * scale, pixelsHigh: h * scale, refreshHz: hz)
}

let lg120 = mode(2560, 1440, hz: 120)
let lg144 = mode(2560, 1440, hz: 144)
let m34144 = mode(3440, 1440, hz: 144)

func parsec(
    size: ScreenSize = defaultSize,
    hiDPI: Bool = true,
    hz: Int = 60,
    owners: [Int32] = [ownerRef.pid],
    keepOn: [String] = []
) -> SessionRequest {
    SessionRequest(client: "parsec", looksLike: size, hiDPI: hiDPI, hz: hz, ownerPIDs: owners, keepOn: keepOn)
}

/// A thread-safe list, for what a hook sees from whichever thread it runs on.
final class Recorder<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])

    func append(_ item: Element) {
        items.withLock { $0.append(item) }
    }

    var values: [Element] {
        items.withLock { $0 }
    }
}

/// Holds something a task sets and the test reads back, both on the main actor.
@MainActor
final class Box<Value> {
    var value: Value?
}

/// An `AutoAdvancingClock` that can also hold the topology debounce's 1 second sleep, so a test can see
/// what happens during it. Every other sleep moves time forward at once.
final class SessionTestClock: ADClock {
    private struct Held {
        var isHolding = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private static let debounceSeconds = 1.0

    private let inner = AutoAdvancingClock()
    private let held = Mutex(Held())

    func now() -> Date { inner.now() }

    func advance(by seconds: Double) {
        inner.advance(by: seconds)
    }

    func sleep(seconds: Double) async throws {
        if seconds == Self.debounceSeconds {
            await withCheckedContinuation { continuation in
                let keep: CheckedContinuation<Void, Never>? = held.withLock { held in
                    guard held.isHolding else { return continuation }
                    held.waiting.append(continuation)
                    return nil
                }
                keep?.resume()
            }
        }
        try await inner.sleep(seconds: seconds)
    }

    func holdDebounce() {
        held.withLock { $0.isHolding = true }
    }

    var heldCount: Int {
        held.withLock { $0.waiting.count }
    }

    func releaseDebounce() {
        let waiting = held.withLock { held in
            held.isHolding = false
            defer { held.waiting = [] }
            return held.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// A simulated Mac with faults the simulator can't act out by itself.
final class ScriptedBackend: DisplayBackend {
    struct Script: Sendable {
        /// Turning these off throws.
        var failDisable: Set<DisplayID> = []
        /// Turning these off reports success and changes nothing.
        var ignoreDisable: Set<DisplayID> = []
        /// Runs before each `setEnabled`, on whichever thread called it. A call with a list of displays
        /// runs it for each of them before any switches.
        var beforeSetEnabled: (@Sendable (DisplayID, Bool) -> Void)?
        /// Runs once before each `setEnabled` with a list of displays, after `beforeSetEnabled`.
        var beforeTransaction: (@Sendable ([DisplayID], Bool) -> Void)?
        /// Every `setEnabled` with a list of displays throws and changes nothing. One display at a time
        /// still works.
        var failTransactions = false
        /// Left out of what a `setEnabled` with a list of displays sends to the Mac, which still reports
        /// success. One display at a time still works.
        var ignoreInTransactions: Set<DisplayID> = []
        /// Rewrites what `topology()` reads.
        var rewrite: (@Sendable (inout Topology) -> Void)?
    }

    let inner: SimulatedDisplayBackend
    private let script = Mutex(Script())

    init(_ inner: SimulatedDisplayBackend) {
        self.inner = inner
    }

    func update(_ change: (inout Script) -> Void) {
        script.withLock { change(&$0) }
    }

    func topology() -> Topology {
        var topology = inner.topology()
        script.withLock { $0.rewrite }?(&topology)
        return topology
    }

    func modes(of id: DisplayID) -> [DisplayMode] {
        inner.modes(of: id)
    }

    func setEnabled(_ id: DisplayID, _ enabled: Bool) throws {
        let current = script.withLock { $0 }
        current.beforeSetEnabled?(id, enabled)
        if !enabled, current.failDisable.contains(id) {
            throw DisplayBackendError(code: 1001, message: "scripted failure disabling display \(id)")
        }
        if !enabled, current.ignoreDisable.contains(id) { return }
        try inner.setEnabled(id, enabled)
    }

    /// One transaction: a display in `failDisable` fails all of them, and one in `ignoreDisable` is
    /// left out of what reaches the Mac.
    func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws {
        // Read afresh for each display, as separate calls would, so a hook that holds the first one
        // and is cleared before it lets go doesn't hold the next.
        for id in ids {
            script.withLock { $0.beforeSetEnabled }?(id, enabled)
        }
        let current = script.withLock { $0 }
        current.beforeTransaction?(ids, enabled)
        if current.failTransactions {
            throw DisplayBackendError(code: 1001, message: "scripted failure of the transaction")
        }
        if !enabled, let failing = ids.first(where: { current.failDisable.contains($0) }) {
            throw DisplayBackendError(code: 1001, message: "scripted failure disabling display \(failing)")
        }
        let ignored = current.ignoreInTransactions.union(enabled ? [] : current.ignoreDisable)
        try inner.setEnabled(ids.filter { !ignored.contains($0) }, enabled)
    }

    func commit(_ changes: [DisplayChange]) throws {
        try inner.commit(changes)
    }
}

/// A ledger store that remembers each save, with how many mutations the Mac had seen at that moment.
final class RecordingStore: LedgerStoring {
    struct Save: Sendable {
        var ledger: SafetyLedger
        var mutationsBefore: Int
    }

    private struct Faults {
        var failOnClear = false
        var failOnLoad = false
    }

    let inner: InMemoryLedgerStore
    private let simulated: SimulatedDisplayBackend
    private let recorded = Recorder<Save>()
    private let faults = Mutex(Faults())

    init(inner: InMemoryLedgerStore, simulated: SimulatedDisplayBackend) {
        self.inner = inner
        self.simulated = simulated
    }

    var saves: [Save] { recorded.values }

    var failOnClear: Bool {
        get { faults.withLock { $0.failOnClear } }
        set { faults.withLock { $0.failOnClear = newValue } }
    }

    var failOnLoad: Bool {
        get { faults.withLock { $0.failOnLoad } }
        set { faults.withLock { $0.failOnLoad = newValue } }
    }

    func load() throws -> SafetyLedger? {
        if failOnLoad { throw POSIXError(.EIO) }
        return try inner.load()
    }

    func save(_ ledger: SafetyLedger) throws {
        let count = simulated.mutations.count
        try inner.save(ledger)
        recorded.append(Save(ledger: ledger, mutationsBefore: count))
    }

    func clear() throws {
        if failOnClear { throw POSIXError(.EIO) }
        try inner.clear()
    }

    func takeSetAsideEvent() -> Bool {
        inner.takeSetAsideEvent()
    }
}

/// Simulated virtual screens with faults and hooks.
@MainActor
final class ScriptedScreens: VirtualScreenProviding {
    let inner: SimulatedVirtualScreenProvider
    var createFailures = 0
    var reconfigureFailures = 0
    /// The system ends the screen in the middle of the next `reconfigure`, which also throws.
    var terminateDuringReconfigure = false
    var beforeCreate: (() -> Void)?
    var afterDestroy: (() -> Void)?

    init(inner: SimulatedVirtualScreenProvider) {
        self.inner = inner
    }

    var onScreenTerminated: ((ActiveVirtualScreen) -> Void)? {
        get { inner.onScreenTerminated }
        set { inner.onScreenTerminated = newValue }
    }

    func create(_ spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen {
        beforeCreate?()
        if createFailures > 0 {
            createFailures -= 1
            throw VirtualScreenError(reason: "scripted failure creating \(spec.name)")
        }
        return try await inner.create(spec)
    }

    func reconfigure(_ screen: ActiveVirtualScreen, to spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen {
        if terminateDuringReconfigure {
            terminateDuringReconfigure = false
            inner.simulateTermination(of: screen)
            throw VirtualScreenError(reason: "display \(screen.displayID) ended during the change")
        }
        if reconfigureFailures > 0 {
            reconfigureFailures -= 1
            throw VirtualScreenError(reason: "scripted failure reconfiguring display \(screen.displayID)")
        }
        return try await inner.reconfigure(screen, to: spec)
    }

    func destroy(_ screen: ActiveVirtualScreen) {
        inner.destroy(screen)
        afterDestroy?()
    }
}

/// The test desk in memory, with a session controller on it.
@MainActor
final class SessionRig {
    let simulated = SimulatedDisplayBackend.twoMonitorDesk()
    let backend: ScriptedBackend
    let memory = InMemoryLedgerStore()
    let store: RecordingStore
    let registry: DeviceRegistry
    let power: FakePowerAssertions
    let processes = FakeProcessInspector(alive: [appRef, relaunchedRef, ownerRef, secondOwnerRef])
    let clock = SessionTestClock()
    let folder: URL
    let lockURL: URL
    let logURL: URL
    private let guardianAlive: Bool

    private(set) var provider: SimulatedVirtualScreenProvider
    private(set) var screens: ScriptedScreens
    private(set) var session: SessionController!
    private(set) var changes = 0

    /// `wakesOnDeclare` makes declaring user activity wake the simulated displays, as it does for real.
    init(guardianAlive: Bool = true, wakesOnDeclare: Bool = false, registryWritable: Bool = true) throws {
        self.guardianAlive = guardianAlive
        folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lockURL = folder.appending(component: "restore.lock", directoryHint: .notDirectory)
        logURL = folder.appending(component: "session.log", directoryHint: .notDirectory)

        let registryURL = registryWritable
            ? folder.appending(component: "devices.json", directoryHint: .notDirectory)
            : folder.appending(component: "missing/devices.json", directoryHint: .notDirectory)
        registry = DeviceRegistry(url: registryURL, bootSession: boot)

        let simulated = simulated
        backend = ScriptedBackend(simulated)
        store = RecordingStore(inner: memory, simulated: simulated)
        power = FakePowerAssertions(onDeclare: {
            if wakesOnDeclare { simulated.wakeAll() }
        })
        provider = SimulatedVirtualScreenProvider(backend: simulated)
        screens = ScriptedScreens(inner: provider)
        session = makeController(selfRef: appRef)
    }

    /// A new app process finding the same Mac and the same ledger. Anything scripted on the old
    /// provider stays there.
    func relaunch(selfRef: ProcessRef = relaunchedRef) {
        provider = SimulatedVirtualScreenProvider(backend: simulated)
        screens = ScriptedScreens(inner: provider)
        session = makeController(selfRef: selfRef)
    }

    /// The app dies: its screen goes with it, and nothing else on the Mac changes.
    func crash() {
        if let id = session.status().displayID {
            simulated.removeVirtual(id)
        }
    }

    private func makeController(selfRef: ProcessRef) -> SessionController {
        let backend = backend
        let clock = clock
        let power = power
        let lockURL = lockURL
        return SessionController(
            backend: backend,
            screens: screens,
            ledger: store,
            registry: registry,
            power: power,
            guardian: FakeGuardianProbe(alive: guardianAlive),
            processes: processes,
            clock: clock,
            operations: DisplayOperations(backend: backend, clock: clock),
            restorer: { onProgress in
                PhysicalRestorer(backend: backend, clock: clock, power: power, lockURL: lockURL, onProgress: onProgress)
            },
            bootSession: boot,
            selfRef: selfRef,
            onChange: { [weak self] in self?.changes += 1 },
            log: SessionLog(url: logURL)
        )
    }

    var mutations: [String] { simulated.mutations }

    var logText: String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    var ledger: SafetyLedger? {
        get throws { try memory.load() }
    }

    /// The screen from the latest status, for a test to act on.
    var screenID: DisplayID {
        get throws { try #require(session.status().displayID) }
    }

    func count(_ line: String) -> Int {
        mutations.filter { $0 == line }.count
    }

    func countOfPrefix(_ prefix: String) -> Int {
        mutations.filter { $0.hasPrefix(prefix) }.count
    }

    func expectMonitorsOff(sourceLocation: SourceLocation = #_sourceLocation) {
        let online = simulated.topology().onlineIDs
        #expect(!online.contains(lg), sourceLocation: sourceLocation)
        #expect(!online.contains(m34), sourceLocation: sourceLocation)
    }

    func expectDeskRestored(sourceLocation: SourceLocation = #_sourceLocation) {
        let topology = simulated.topology()
        #expect(topology.main?.id == lg, sourceLocation: sourceLocation)
        #expect(topology.display(lg)?.origin == lgOrigin, sourceLocation: sourceLocation)
        #expect(topology.display(lg)?.mode?.matches(lg120) == true, sourceLocation: sourceLocation)
        #expect(topology.display(m34)?.origin == m34Origin, sourceLocation: sourceLocation)
        #expect(topology.display(m34)?.mode?.matches(m34144) == true, sourceLocation: sourceLocation)
    }

    /// A monitor may be off only with a screen showing, and nothing may have gone dark on the way here:
    /// the fallback display comes up whenever the last real display goes.
    func expectNothingLeftDark(sourceLocation: SourceLocation = #_sourceLocation) {
        let topology = simulated.topology()
        let aMonitorIsOff = !topology.onlineIDs.isSuperset(of: [lg, m34])
        let aScreenIsUp = topology.online.contains { $0.kind == .ownVirtual }
        #expect(!aMonitorIsOff || aScreenIsUp, sourceLocation: sourceLocation)
        #expect(simulated.fallbackAppearances == 0, sourceLocation: sourceLocation)
    }

    /// Our screen reads as something that doesn't count toward the never-zero rule.
    func makeScreenStopCounting() {
        backend.update { script in
            script.rewrite = { topology in
                for index in topology.displays.indices where topology.displays[index].kind == .ownVirtual {
                    topology.displays[index].kind = .otherVirtual
                }
            }
        }
    }

    /// Runs `interleave` on the main actor at the first display switch of this direction, and holds
    /// that switch until `interleave` has returned, so whatever it sets going arrives mid-sequence.
    func atFirstSwitch(enabling: Bool, interleave: @escaping @MainActor () async -> Void) {
        let fired = Recorder<Bool>()
        let finished = DispatchSemaphore(value: 0)
        backend.update { script in
            script.beforeSetEnabled = { _, enabled in
                guard enabled == enabling, fired.values.isEmpty else { return }
                fired.append(true)
                Task { @MainActor in
                    await interleave()
                    finished.signal()
                }
                finished.wait()
            }
        }
    }

    func expectNoScreen(sourceLocation: SourceLocation = #_sourceLocation) {
        let screens = simulated.topology().displays.filter { $0.kind == .ownVirtual }
        #expect(screens.isEmpty, sourceLocation: sourceLocation)
    }

    /// A ledger as a session would have written it, with the desk's records.
    func seededLedger(
        state: LedgerState,
        owners: [ProcessRef] = [ownerRef],
        bootSession: String = boot,
        size: ScreenSize = defaultSize
    ) -> SafetyLedger {
        let past = clock.now().addingTimeInterval(-100)
        return SafetyLedger(
            state: state,
            client: "parsec",
            looksLike: size,
            hiDPI: true,
            hz: 60,
            physical: deskRecords(),
            owners: owners,
            app: appRef,
            bootSessionID: bootSession,
            startedAt: past,
            updatedAt: past
        )
    }

    /// What a session records from the desk as it is now.
    func deskRecords() -> [PhysicalRecord] {
        simulated.topology().online.filter { $0.kind == .physical }.map { display in
            PhysicalRecord(
                id: display.id,
                identity: display.identity,
                origin: display.origin,
                mode: display.mode ?? mode(1, 1, hz: 0),
                wasMain: display.isMain
            )
        }
    }
}
