import ADDisplays
import ADFoundation
import ADModel
import Foundation
import Synchronization
import Testing

@testable import ADDisplayConfig

let lg: DisplayID = 2
let m34: DisplayID = 4
let lgOrigin = DisplayOrigin(x: 0, y: 0)
let m34Origin = DisplayOrigin(x: -446, y: 1440)

func mode(_ w: Int, _ h: Int, hz: Double, scale: Int = 1) -> DisplayMode {
    DisplayMode(pointsWide: w, pointsHigh: h, pixelsWide: w * scale, pixelsHigh: h * scale, refreshHz: hz)
}

let lg120 = mode(2560, 1440, hz: 120)
let lg144 = mode(2560, 1440, hz: 144)
let m34144 = mode(3440, 1440, hz: 144)

func addScreen(_ backend: SimulatedDisplayBackend) -> DisplayID {
    let screen = mode(1728, 1080, hz: 60, scale: 2)
    return backend.addVirtual(
        identity: DisplayIdentity(
            vendor: DisplayClassifier.ownVendor,
            model: DisplayClassifier.ownProduct,
            serial: 0xD249_C71D,
            productName: "Porch Light (Parsec)"
        ),
        mode: screen,
        modes: [screen]
    )
}

/// What a session writes before it turns the monitors off.
func records(of backend: any DisplayBackend) -> [PhysicalRecord] {
    backend.topology().online.filter { $0.kind == .physical }.map { display in
        PhysicalRecord(
            id: display.id,
            identity: display.identity,
            origin: display.origin,
            mode: display.mode ?? mode(1, 1, hz: 0),
            wasMain: display.isMain
        )
    }
}

func bothOff(_ backend: SimulatedDisplayBackend) throws {
    try backend.setEnabled(m34, false)
    try backend.setEnabled(lg, false)
}

func temporaryLockURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(component: "ADDisplayConfigTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(component: "restore.lock", directoryHint: .notDirectory)
}

/// A regular file where the lock's folder should be, so the lock file can't be created.
func unusableLockURL() throws -> URL {
    let file = FileManager.default.temporaryDirectory
        .appending(component: "ADDisplayConfigTests-\(UUID().uuidString)", directoryHint: .notDirectory)
    try Data().write(to: file)
    return file.appending(component: "restore.lock", directoryHint: .notDirectory)
}

func expectDeskRestored(_ backend: any DisplayBackend, sourceLocation: SourceLocation = #_sourceLocation) {
    let topology = backend.topology()
    #expect(topology.main?.id == lg, sourceLocation: sourceLocation)
    #expect(topology.display(lg)?.origin == lgOrigin, sourceLocation: sourceLocation)
    #expect(topology.display(lg)?.mode?.matches(lg120) == true, sourceLocation: sourceLocation)
    #expect(topology.display(m34)?.origin == m34Origin, sourceLocation: sourceLocation)
    #expect(topology.display(m34)?.mode?.matches(m34144) == true, sourceLocation: sourceLocation)
}

/// An `AutoAdvancingClock` that runs `onSleep` with the seconds since it started after each sleep,
/// so a test can change the world at a chosen moment of a run.
final class HookClock: ADClock {
    private let inner = AutoAdvancingClock()
    private let start: Date
    private let onSleep: @Sendable (Double) -> Void

    init(onSleep: @escaping @Sendable (Double) -> Void) {
        start = inner.now()
        self.onSleep = onSleep
    }

    func now() -> Date { inner.now() }

    func sleep(seconds: Double) async throws {
        try await inner.sleep(seconds: seconds)
        onSleep(inner.now().timeIntervalSince(start))
    }
}

/// Every sleep throws, as a real one does once its task is cancelled.
struct CancelledClock: ADClock {
    func now() -> Date { Date(timeIntervalSinceReferenceDate: 0) }
    func sleep(seconds: Double) async throws { throw CancellationError() }
}

/// A simulated Mac with faults the simulator can't act out by itself.
final class ScriptedBackend: DisplayBackend {
    struct Script: Sendable {
        /// The next commits throw 1001.
        var commitFailures = 0
        /// The next commits report success and change nothing.
        var ignoredCommits = 0
        /// Disconnects report success and change nothing.
        var ignoreDisable = false
        /// Enables report success and change nothing.
        var ignoreEnable = false
        /// Runs before each `setEnabled` and `commit`.
        var beforeCall: (@Sendable () -> Void)?
        /// Runs before each `commit`. The next read after a commit is its read-back.
        var beforeCommit: (@Sendable () -> Void)?
        /// Rewrites what `topology()` reads.
        var rewrite: (@Sendable (inout Topology) -> Void)?
        /// Rewrites what `modes(of:)` reads.
        var rewriteModes: (@Sendable (DisplayID, [DisplayMode]) -> [DisplayMode])?
    }

    let inner: SimulatedDisplayBackend
    private let script: Mutex<Script>

    init(_ inner: SimulatedDisplayBackend, script: Script = Script()) {
        self.inner = inner
        self.script = Mutex(script)
    }

    func topology() -> Topology {
        var topology = inner.topology()
        script.withLock { $0.rewrite }?(&topology)
        return topology
    }

    func modes(of id: DisplayID) -> [DisplayMode] {
        let modes = inner.modes(of: id)
        return script.withLock { $0.rewriteModes }?(id, modes) ?? modes
    }

    func setEnabled(_ id: DisplayID, _ enabled: Bool) throws {
        let current = script.withLock { $0 }
        current.beforeCall?()
        if enabled ? current.ignoreEnable : current.ignoreDisable { return }
        try inner.setEnabled(id, enabled)
    }

    func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws {
        let current = script.withLock { $0 }
        current.beforeCall?()
        if enabled ? current.ignoreEnable : current.ignoreDisable { return }
        try inner.setEnabled(ids, enabled)
    }

    func commit(_ changes: [DisplayChange]) throws {
        let current = script.withLock { $0 }
        current.beforeCall?()
        current.beforeCommit?()
        let outcome: (fail: Bool, ignore: Bool) = script.withLock { script in
            if script.commitFailures > 0 {
                script.commitFailures -= 1
                return (true, false)
            }
            if script.ignoredCommits > 0 {
                script.ignoredCommits -= 1
                return (false, true)
            }
            return (false, false)
        }
        if outcome.fail { throw DisplayBackendError(code: 1001, message: "scripted transaction failure") }
        if outcome.ignore { return }
        try inner.commit(changes)
    }
}
