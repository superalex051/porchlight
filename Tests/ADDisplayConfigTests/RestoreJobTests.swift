import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Synchronization
import Testing

@testable import ADDisplayConfig

private let boot = "boot-1"
private let app = ProcessRef(pid: 4242, startTime: 1000)
private let longAgo = Date(timeIntervalSinceReferenceDate: -1000)

private func ledger(
    _ recorded: [PhysicalRecord],
    state: LedgerState = .ending,
    app appRef: ProcessRef? = app,
    bootSession: String = boot
) -> SafetyLedger {
    SafetyLedger(
        state: state,
        client: "parsec",
        looksLike: ScreenSize(w: 1728, h: 1080),
        hiDPI: true,
        hz: 60,
        physical: recorded,
        app: appRef,
        bootSessionID: bootSession,
        startedAt: longAgo,
        updatedAt: longAgo
    )
}

private func temporaryRegistryURL() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(component: "ADDisplayConfigTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(component: "devices.json", directoryHint: .notDirectory)
}

private func job(
    ledger store: any LedgerStoring,
    registryURL: URL,
    backend: any DisplayBackend,
    processes: any ProcessInspecting = FakeProcessInspector(),
    clock: any ADClock = AutoAdvancingClock(),
    power: any PowerAsserting = FakePowerAssertions(),
    lockURL: URL = temporaryLockURL(),
    bootSession: String = boot
) -> RestoreJob {
    RestoreJob(
        ledger: store,
        registryURL: registryURL,
        backend: backend,
        processes: processes,
        clock: clock,
        power: power,
        lockURL: lockURL,
        bootSession: bootSession
    )
}

/// A process whose copy of one display has no modes, as a restore child's did in the hardware run of
/// 2026-11-07, when it started with that monitor off: the list reads empty, and a commit can't find any
/// mode for it, so it leaves the mode out, applies the rest and names the display.
private final class ModeBlindBackend: DisplayBackend {
    private let inner: SimulatedDisplayBackend
    private let blindTo: DisplayID

    init(_ inner: SimulatedDisplayBackend, blindTo: DisplayID) {
        self.inner = inner
        self.blindTo = blindTo
    }

    func topology() -> Topology { inner.topology() }

    func modes(of id: DisplayID) -> [DisplayMode] {
        id == blindTo ? [] : inner.modes(of: id)
    }

    func setEnabled(_ id: DisplayID, _ enabled: Bool) throws {
        try inner.setEnabled(id, enabled)
    }

    func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws {
        try inner.setEnabled(ids, enabled)
    }

    func commit(_ changes: [DisplayChange]) throws {
        let blind = changes.filter { change in
            if case .mode(let id, _) = change { return id == blindTo }
            return false
        }
        let rest = changes.filter { !blind.contains($0) }
        if !rest.isEmpty { try inner.commit(rest) }
        guard blind.isEmpty else {
            throw DisplayBackendError(code: 1001, message: "display \(blindTo) has no such mode", modesNotApplied: [blindTo])
        }
    }
}

/// The test desk with the M34WQ at another rate than the one recorded, so a restore has its mode to set.
private func deskWithM34AtAnotherRate() throws -> (SimulatedDisplayBackend, [PhysicalRecord]) {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    let other = try #require(
        backend.modes(of: m34).first { $0.pointsWide == 3440 && $0.pointsHigh == 1440 && $0.refreshHz.rounded() != 144 }
    )
    try backend.commit([.mode(m34, other)])
    return (backend, recorded)
}

private func childJob(_ store: any LedgerStoring, _ backend: any DisplayBackend) throws -> RestoreJob {
    RestoreJob(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: FakeProcessInspector(),
        clock: AutoAdvancingClock(),
        power: FakePowerAssertions(),
        lockURL: temporaryLockURL(),
        bootSession: boot,
        insistOnRecordedModes: true
    )
}

/// `load` always throws, as an I/O error would.
private final class ThrowingLedgerStore: LedgerStoring {
    private let inner = InMemoryLedgerStore()
    func load() throws -> SafetyLedger? { throw POSIXError(.EIO) }
    func save(_ ledger: SafetyLedger) throws { try inner.save(ledger) }
    func clear() throws { try inner.clear() }
    func takeSetAsideEvent() -> Bool { inner.takeSetAsideEvent() }
}

/// Reports how many display changes had happened when the kill arrived.
private final class WatchingInspector: ProcessInspecting {
    private let inner: FakeProcessInspector
    private let backend: SimulatedDisplayBackend
    private let mutationsAtKill = Mutex<Int?>(nil)

    init(alive: Set<ProcessRef>, backend: SimulatedDisplayBackend) {
        inner = FakeProcessInspector(alive: alive)
        self.backend = backend
    }

    var killed: [ProcessRef] { inner.killed }
    var mutationCountAtKill: Int? { mutationsAtKill.withLock { $0 } }

    func reference(forPID pid: Int32) -> ProcessRef? { inner.reference(forPID: pid) }
    func isAlive(_ ref: ProcessRef) -> Bool { inner.isAlive(ref) }

    func kill(_ ref: ProcessRef) {
        let count = backend.mutations.count
        mutationsAtKill.withLock { $0 = count }
        inner.kill(ref)
    }
}

/// What happened, in order, across the store, the process inspector and the backend.
private final class EventLog: Sendable {
    private let events = Mutex<[String]>([])

    func append(_ event: String) {
        events.withLock { $0.append(event) }
    }

    var values: [String] {
        events.withLock { $0 }
    }
}

private final class EventStore: LedgerStoring {
    private let inner: InMemoryLedgerStore
    private let events: EventLog

    init(inner: InMemoryLedgerStore, events: EventLog) {
        self.inner = inner
        self.events = events
    }

    func load() throws -> SafetyLedger? { try inner.load() }

    func save(_ ledger: SafetyLedger) throws {
        events.append("save \(ledger.state.rawValue)")
        try inner.save(ledger)
    }

    func clear() throws { try inner.clear() }
    func takeSetAsideEvent() -> Bool { inner.takeSetAsideEvent() }
}

private final class EventInspector: ProcessInspecting {
    private let inner: FakeProcessInspector
    private let events: EventLog

    init(alive: Set<ProcessRef>, events: EventLog) {
        inner = FakeProcessInspector(alive: alive)
        self.events = events
    }

    func reference(forPID pid: Int32) -> ProcessRef? { inner.reference(forPID: pid) }
    func isAlive(_ ref: ProcessRef) -> Bool { inner.isAlive(ref) }

    func kill(_ ref: ProcessRef) {
        events.append("kill")
        inner.kill(ref)
    }
}

// MARK: With a ledger

/// A rescue kills the app, and the guardian can relaunch it while this runs. The ledger has to say
/// `ending` by then, or that app would resume the session and turn the monitors back off.
@Test func endingIsWrittenBeforeTheKillAndBeforeAnyDisplayCall() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let events = EventLog()
    var script = ScriptedBackend.Script()
    script.beforeCall = { events.append("display call") }

    let succeeded = await job(
        ledger: EventStore(inner: InMemoryLedgerStore(ledger: ledger(recorded, state: .active)), events: events),
        registryURL: try temporaryRegistryURL(),
        backend: ScriptedBackend(inner, script: script),
        processes: EventInspector(alive: [app], events: events)
    ).run()

    #expect(succeeded)
    let seen = events.values
    #expect(seen.first == "save ending")
    let kill = try #require(seen.firstIndex(of: "kill"))
    let firstCall = try #require(seen.firstIndex(of: "display call"))
    #expect(kill < firstCall)
    #expect(!seen.contains("save active"), "Nothing writes the old state back")
    #expect(seen.last == "save rescued")
}

@Test(arguments: [LedgerState.active, .starting])
func aFailedRescueLeavesEnding(state: LedgerState) async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)
    backend.setEnableFails(m34, .max)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, state: state))

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(!succeeded)
    let written = try #require(try store.load())
    #expect(written.state == .ending, "So a relaunched app finishes the end, and doesn't resume")
    #expect(written.startedAt == longAgo, "That's what identifies the session")
    #expect(written.updatedAt != longAgo)
}

@Test func aFailedEndingWriteDoesNotStopTheRestore() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, state: .active))
    store.failOnSave = true
    let processes = FakeProcessInspector(alive: [app])

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded)
    #expect(processes.killed == [app])
    expectDeskRestored(backend)
}

/// The guardian leaves a `rescued` ledger alone, and `ending` would have it relaunch the app.
@Test func aRescuedLedgerIsNotMovedBackToEnding() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)
    backend.setEnableFails(m34, .max)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, state: .rescued))

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(!succeeded)
    #expect(try store.load()?.state == .rescued)
}

@Test func killsLiveAppFirst() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count
    let processes = WatchingInspector(alive: [app], backend: backend)

    let succeeded = await job(
        ledger: InMemoryLedgerStore(ledger: ledger(recorded)),
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded)
    #expect(processes.killed == [app])
    #expect(processes.mutationCountAtKill == before, "Before the restore changed anything")
    expectDeskRestored(backend)
}

@Test func anAppThatIsAlreadyGoneIsNotKilled() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let processes = FakeProcessInspector()

    let succeeded = await job(
        ledger: InMemoryLedgerStore(ledger: ledger(recorded)),
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded)
    #expect(processes.killed.isEmpty)
}

@Test func writesRescuedOnSuccess() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    let clock = AutoAdvancingClock()

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        clock: clock
    ).run()

    #expect(succeeded)
    let written = try #require(try store.load())
    #expect(written.state == .rescued)
    #expect(written.updatedAt == clock.now())
    #expect(written.physical == recorded, "Only the state and the time change")
}

@Test func failureLeavesLedgerUnrescued() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)
    backend.setEnableFails(m34, .max)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(!succeeded)
    #expect(try store.load()?.state == .ending)
}

@Test func rescuedIsWrittenWithAnUnpluggedDisplayMissing() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.removePhysical(m34)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(succeeded, "It left the list, so it's unplugged, and the rest is back")
    #expect(try store.load()?.state == .rescued)
    #expect(try store.load()?.physical == recorded)
}

@Test func rescuedIsNotWrittenOverAMonitorStillDark() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(!succeeded, "The LG is plugged in and dark, and `rescued` would stop the guardian trying")
    #expect(try store.load()?.state == .ending)
}

@Test func theReportGoesToTheCaller() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)
    let reports = Mutex<[RestoreReport]>([])

    let succeeded = await RestoreJob(
        ledger: InMemoryLedgerStore(ledger: ledger(recorded)),
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: FakeProcessInspector(),
        clock: AutoAdvancingClock(),
        power: FakePowerAssertions(),
        lockURL: temporaryLockURL(),
        bootSession: boot,
        onReport: { report in reports.withLock { $0.append(report) } }
    ).run()

    #expect(!succeeded)
    #expect(reports.withLock { $0.count } == 1)
    let report = try #require(reports.withLock { $0.first })
    #expect(report.stillDark.map(\.id) == [lg], "`adguardian restore` logs this to guardian.log")
}

// MARK: A restore child that can't see a display's modes

/// The hardware run of 2026-11-07: the arrangement verified, but the child never saw the M34WQ's modes.
/// It must not write `rescued`, so that the guardian's next try is a fresh process that can.
@Test func aChildMissingAModeDoesNotWriteRescued() async throws {
    let (backend, recorded) = try deskWithM34AtAnotherRate()
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let outcome = try await childJob(store, ModeBlindBackend(backend, blindTo: m34)).runWithOutcome()

    #expect(outcome == .modesNotRestored(recorded.filter { $0.id == m34 }))
    #expect(!outcome.wroteRescued)
    #expect(try store.load()?.state == .ending)
    #expect(try store.load()?.restoreMissedModes == true, "So the next child knows it's the second")
    #expect(backend.topology().display(m34)?.origin == m34Origin, "The arrangement is still set")
}

@Test func aFreshChildThatSeesTheModeRestoresItAndWritesRescued() async throws {
    let (backend, recorded) = try deskWithM34AtAnotherRate()
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    _ = try await childJob(store, ModeBlindBackend(backend, blindTo: m34)).runWithOutcome()

    let outcome = try await childJob(store, backend).runWithOutcome()

    #expect(outcome == .restored)
    #expect(try store.load()?.state == .rescued)
    #expect(backend.topology().display(m34)?.mode?.matches(m34144) == true)
}

/// Two fresh processes in a row found the mode missing, so it really is gone, and the guardian mustn't
/// try forever.
@Test func aSecondChildMissingTheSameModeAcceptsItAndWritesRescued() async throws {
    let (backend, recorded) = try deskWithM34AtAnotherRate()
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    _ = try await childJob(store, ModeBlindBackend(backend, blindTo: m34)).runWithOutcome()

    let outcome = try await childJob(store, ModeBlindBackend(backend, blindTo: m34)).runWithOutcome()

    #expect(outcome == .restoredWithoutModes(recorded.filter { $0.id == m34 }))
    #expect(outcome.wroteRescued)
    #expect(try store.load()?.state == .rescued)
}

/// Without the flag, a mode not offered counts as restored at once, as before.
@Test func withoutTheFlagAMissingModeStillCountsAsRestored() async throws {
    let (backend, recorded) = try deskWithM34AtAnotherRate()
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let job = job(ledger: store, registryURL: try temporaryRegistryURL(), backend: ModeBlindBackend(backend, blindTo: m34))
    let outcome = await job.runWithOutcome()

    #expect(outcome == .restoredWithoutModes(recorded.filter { $0.id == m34 }))
    #expect(try store.load()?.state == .rescued)
    #expect(try store.load()?.restoreMissedModes == nil)
}

@Test func runIsTrueOnlyWhenRescuedIsWritten() async throws {
    let (backend, recorded) = try deskWithM34AtAnotherRate()
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    #expect(try await childJob(store, ModeBlindBackend(backend, blindTo: m34)).run() == false)
    #expect(try await childJob(store, ModeBlindBackend(backend, blindTo: m34)).run())
}

@Test func unverifiedArrangementIsNotASuccess() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    var script = ScriptedBackend.Script()
    script.commitFailures = .max
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: ScriptedBackend(inner, script: script)
    ).run()

    #expect(!succeeded)
    #expect(try store.load()?.state == .ending)
}

@Test func lockContentionIsNotASuccess() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    let lockURL = temporaryLockURL()
    let holder = FileLock(url: lockURL)
    try #require(holder.tryLock())
    defer { holder.unlock() }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        lockURL: lockURL
    ).run()

    #expect(!succeeded)
    #expect(try store.load()?.state == .ending)
}

@Test func nothingRecordedCountsAsRescued() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let store = InMemoryLedgerStore(ledger: ledger([]))

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(succeeded, "A session that kept every monitor on leaves nothing to bring back")
    #expect(try store.load()?.state == .rescued)
    #expect(backend.mutations.isEmpty)
}

/// Every monitor was kept on, so the ledger records none of them. One has since been turned off by hand
/// and the other unplugged, and with the app gone, only the OS fallback display is left.
@Test func nothingRecordedStillBringsBackAKeptMonitor() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try backend.setEnabled(lg, false)
    backend.removePhysical(m34)
    #expect(backend.topology().displays.map(\.kind) == [.osFallback])
    let store = InMemoryLedgerStore(ledger: ledger([]))
    let processes = FakeProcessInspector(alive: [app])

    let succeeded = await job(ledger: store, registryURL: registryURL, backend: backend, processes: processes).run()

    #expect(succeeded)
    #expect(processes.killed == [app], "So that it can't turn the monitor back off")
    #expect(backend.topology().onlineIDs.contains(lg))
    #expect(try store.load()?.state == .rescued)
}

@Test func nothingRecordedAndNoMonitorLeftIsNotRescued() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    backend.removePhysical(m34)
    backend.removePhysical(lg)
    let store = InMemoryLedgerStore(ledger: ledger([]))

    let succeeded = await job(ledger: store, registryURL: registryURL, backend: backend).run()

    #expect(!succeeded, "The fallback display doesn't count")
    #expect(try store.load()?.state == .ending)
}

@Test func nothingRecordedAndAMonitorThatWontComeBackIsNotRescued() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try backend.setEnabled(lg, false)
    backend.removePhysical(m34)
    backend.setEnableFails(lg, .max)
    let store = InMemoryLedgerStore(ledger: ledger([]))

    let succeeded = await job(ledger: store, registryURL: registryURL, backend: backend).run()

    #expect(!succeeded, "`rescued` would stop the guardian trying")
    #expect(try store.load()?.state == .ending)
}

@Test func nothingRecordedWithTheLockHeldIsNotRescued() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let store = InMemoryLedgerStore(ledger: ledger([]))
    let lockURL = temporaryLockURL()
    let holder = FileLock(url: lockURL)
    try #require(holder.tryLock())
    defer { holder.unlock() }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        lockURL: lockURL
    ).run()

    #expect(!succeeded, "A physical display is online, but this restore never ran")
    #expect(try store.load()?.state == .ending)
}

/// A watcher has to be able to see this path making progress too.
@Test func nothingRecordedStillMovesUpdatedAt() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try backend.setEnabled(lg, false)
    backend.removePhysical(m34)
    let store = InMemoryLedgerStore(ledger: ledger([]))
    let stamps = Mutex<Set<Date>>([])
    let clock = HookClock { _ in
        guard let current = try? store.load(), current.state == .ending else { return }
        stamps.withLock { _ = $0.insert(current.updatedAt) }
    }

    let succeeded = await job(ledger: store, registryURL: registryURL, backend: backend, clock: clock).run()

    #expect(succeeded)
    #expect(stamps.withLock { $0.subtracting([longAgo]).count } >= 1, "It moved before the end of the run")
}

/// The restorer verified the arrangement, and then the monitors went. That can't be called rescued.
@Test func rescuedIsNotWrittenIfNoMonitorIsOnlineAtTheEnd() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))

    let succeeded = await RestoreJob(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: FakeProcessInspector(),
        clock: AutoAdvancingClock(),
        power: FakePowerAssertions(),
        lockURL: temporaryLockURL(),
        bootSession: boot,
        onReport: { report in
            #expect(report.verified && report.anyReturned, "Or this test proves nothing")
            backend.removePhysical(m34)
            backend.removePhysical(lg)
        }
    ).run()

    #expect(!succeeded)
    #expect(try store.load()?.state == .ending)
}

// MARK: The ledger while it runs

@Test func heartbeatMovesUpdatedAtAndNothingElse() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    let seen = Mutex<[SafetyLedger]>([])
    let clock = HookClock { _ in
        guard let current = try? store.load() else { return }
        seen.withLock { $0.append(current) }
    }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        clock: clock
    ).run()

    #expect(succeeded)
    let reads = seen.withLock { $0 }
    #expect(reads.allSatisfy { $0.state == .ending && $0.physical == recorded })
    let stamps = Set(reads.map(\.updatedAt)).subtracting([longAgo])
    #expect(stamps.count >= 2, "It moved during the run")
}

/// The job's writes go by `startedAt` alone, so a session started after this one, even by the same
/// app, is someone else's and stays as written.
@Test func aNewSessionStartedMeanwhileStaysLive() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    var newSession = ledger(recorded, state: .active)
    newSession.startedAt = Date(timeIntervalSinceReferenceDate: 1)
    newSession.updatedAt = Date(timeIntervalSinceReferenceDate: 1)
    let startedNew = Mutex(false)
    let started = newSession
    let clock = HookClock { elapsed in
        guard elapsed >= 1 else { return }
        let isFirst = startedNew.withLock { done in
            defer { done = true }
            return !done
        }
        if isFirst { try? store.save(started) }
    }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        clock: clock
    ).run()

    #expect(succeeded)
    #expect(try store.load() == newSession, "Neither the heartbeat nor the rescue wrote over the new session")
}

/// A relaunched app that named itself in this session's ledger is still this session: `rescued`
/// goes over it, because the restore wins within its session.
@Test func rescuedGoesOverARelaunchedAppInTheSameSession() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    let tookOver = Mutex(false)
    let clock = HookClock { elapsed in
        guard elapsed >= 2 else { return }
        let isFirst = tookOver.withLock { done in
            defer { done = true }
            return !done
        }
        if isFirst { namesItself(store, as: relaunched, state: .ending) }
    }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        clock: clock
    ).run()

    #expect(succeeded)
    #expect(try store.load()?.app == relaunched, "Or this test proves nothing")
    #expect(try store.load()?.state == .rescued)
}

@Test func aFailedRescueWriteDoesNotChangeTheAnswer() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded))
    store.failOnSave = true

    let succeeded = await job(ledger: store, registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(succeeded, "The monitors are back, and the guardian handles a ledger that still looks live")
    expectDeskRestored(backend)
}

// MARK: The relaunch race

private let relaunched = ProcessRef(pid: 4343, startTime: 3000)

/// What a relaunched app writes when it names itself in the ledger: the state it read, and itself.
private func namesItself(_ store: any LedgerStoring, as process: ProcessRef, state: LedgerState) {
    guard var current = try? store.load() else { return }
    current.app = process
    current.state = state
    try? store.save(current)
}

/// Keeps every save, and runs `afterFirstLoad` once, right after the first load has read the file, as
/// another process writing between this job's read and its next write would.
private final class InterleavingStore: LedgerStoring {
    private let inner: InMemoryLedgerStore
    private let afterFirstLoad: Mutex<(@Sendable () -> Void)?>
    private let saved = Mutex<[SafetyLedger]>([])

    init(inner: InMemoryLedgerStore, afterFirstLoad: (@Sendable () -> Void)? = nil) {
        self.inner = inner
        self.afterFirstLoad = Mutex(afterFirstLoad)
    }

    var saves: [SafetyLedger] { saved.withLock { $0 } }

    func load() throws -> SafetyLedger? {
        let found = try inner.load()
        let hook = afterFirstLoad.withLock { hook in
            defer { hook = nil }
            return hook
        }
        hook?()
        return found
    }

    func save(_ ledger: SafetyLedger) throws {
        try inner.save(ledger)
        saved.withLock { $0.append(ledger) }
    }

    func clear() throws { try inner.clear() }
    func takeSetAsideEvent() -> Bool { inner.takeSetAsideEvent() }
}

/// MenuBarAgent: each kill of a live app brings up the next process on the list at once, which then
/// does with the ledger what `onRelaunch` says, as that new app would.
private final class RelaunchingInspector: ProcessInspecting {
    private let inner: FakeProcessInspector
    private let next: Mutex<[ProcessRef]>
    private let onRelaunch: @Sendable (ProcessRef) -> Void

    init(alive: Set<ProcessRef>, relaunches: [ProcessRef], onRelaunch: @escaping @Sendable (ProcessRef) -> Void) {
        inner = FakeProcessInspector(alive: alive)
        next = Mutex(relaunches)
        self.onRelaunch = onRelaunch
    }

    var killed: [ProcessRef] { inner.killed }

    func reference(forPID pid: Int32) -> ProcessRef? { inner.reference(forPID: pid) }
    func isAlive(_ ref: ProcessRef) -> Bool { inner.isAlive(ref) }

    func kill(_ ref: ProcessRef) {
        let wasAlive = inner.isAlive(ref)
        inner.kill(ref)
        guard wasAlive, let process = next.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return }
        inner.alive.insert(process)
        onRelaunch(process)
    }
}

/// The relaunched app read `active` and named itself in the ledger between this job's read and its
/// `ending` write, so it's about to resume. `ending` still goes over its write, and it's killed too.
@Test func anAppThatNamedItselfInBeforeEndingStillGetsEndingAndIsKilled() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let inner = InMemoryLedgerStore(ledger: ledger(recorded, state: .active))
    let store = InterleavingStore(inner: inner) { namesItself(inner, as: relaunched, state: .active) }
    let processes = FakeProcessInspector(alive: [app, relaunched])

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded)
    #expect(store.saves.first?.state == .ending)
    #expect(store.saves.first?.app == relaunched, "Ending went over the new app's write")
    #expect(processes.killed == [app, relaunched])
    #expect(try inner.load()?.state == .rescued)
}

/// The relaunched app read `active` before the `ending` write landed, and resumed after the kill.
@Test func anAppThatResumedAfterTheKillIsKilledAndEndingIsWrittenAgain() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InterleavingStore(inner: InMemoryLedgerStore(ledger: ledger(recorded, state: .active)))
    let processes = RelaunchingInspector(alive: [app], relaunches: [relaunched]) { process in
        namesItself(store, as: process, state: .active)
    }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded)
    #expect(processes.killed == [app, relaunched])
    #expect(!processes.isAlive(relaunched))
    let saves = store.saves
    let resumed = try #require(saves.firstIndex { $0.app == relaunched && $0.state == .active })
    let endingAgain = try #require(saves.lastIndex { $0.app == relaunched && $0.state == .ending })
    #expect(resumed < endingAgain)
    #expect(saves.last?.state == .rescued)
}

/// A relaunched app that read `ending` finishes the end, which helps.
@Test func anAppFinishingTheEndIsLeftAlone() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, state: .active))
    let processes = RelaunchingInspector(alive: [app], relaunches: [relaunched]) { process in
        namesItself(store, as: process, state: .ending)
    }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded)
    #expect(processes.killed == [app])
    #expect(processes.isAlive(relaunched))
}

/// Every kill can bring another relaunch, so the job stops at three and gets on with the restore.
@Test func aRestoreKillsAtMostThreeResumedApps() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, state: .active))
    let relaunches = (1...4).map { ProcessRef(pid: 5000 + Int32($0), startTime: 4000 + Double($0)) }
    let processes = RelaunchingInspector(alive: [app], relaunches: relaunches) { process in
        namesItself(store, as: process, state: .active)
    }

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes
    ).run()

    #expect(succeeded, "The restore still ran")
    #expect(processes.killed == [app] + relaunches.prefix(3))
    #expect(processes.isAlive(relaunches[3]))
    expectDeskRestored(backend)
}

// MARK: The lock

/// Holds a lock until `release`, from whichever thread calls it.
private final class HeldLock: Sendable {
    private let lock: Mutex<FileLock?>

    init(url: URL) throws {
        let held = FileLock(url: url)
        try #require(held.tryLock())
        lock = Mutex(held)
    }

    func release() {
        lock.withLock {
            $0?.unlock()
            $0 = nil
        }
    }
}

/// True if another holder has the lock. A probe that gets it lets it go at once.
private func isHeld(_ url: URL) -> Bool {
    let probe = FileLock(url: url)
    defer { probe.unlock() }
    return !probe.tryLock()
}

/// Kills like `FakeProcessInspector`, and a kill of `app` lets go of its lock, as a dead process's does.
private final class LockReleasingInspector: ProcessInspecting {
    private let inner: FakeProcessInspector
    private let appsLock: HeldLock

    init(alive: Set<ProcessRef>, appsLock: HeldLock) {
        inner = FakeProcessInspector(alive: alive)
        self.appsLock = appsLock
    }

    var killed: [ProcessRef] { inner.killed }

    func reference(forPID pid: Int32) -> ProcessRef? { inner.reference(forPID: pid) }
    func isAlive(_ ref: ProcessRef) -> Bool { inner.isAlive(ref) }

    func kill(_ ref: ProcessRef) {
        inner.kill(ref)
        if ref == app { appsLock.release() }
    }
}

/// The job takes `restore.lock` before its first read of the ledger and holds it until it returns,
/// and its restorer works under that hold. Taking the lock again on a second descriptor would conflict
/// with the job's own, and the restorer would wait out its 60 seconds and give up.
@Test func theJobHoldsTheLockForItsWholeRunAndItsRestorerDoesNotWaitOnIt() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let lockURL = temporaryLockURL()
    let heldAtLoad = Mutex<[Bool]>([])
    let heldAtCall = Mutex<[Bool]>([])
    let store = ProbingStore(inner: InMemoryLedgerStore(ledger: ledger(recorded, state: .active))) {
        let held = isHeld(lockURL)
        heldAtLoad.withLock { $0.append(held) }
    }
    var script = ScriptedBackend.Script()
    script.beforeCall = {
        let held = isHeld(lockURL)
        heldAtCall.withLock { $0.append(held) }
    }
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: ScriptedBackend(inner, script: script),
        clock: clock,
        lockURL: lockURL
    ).run()

    #expect(succeeded)
    let loads = heldAtLoad.withLock { $0 }
    let calls = heldAtCall.withLock { $0 }
    #expect(!loads.isEmpty && loads.allSatisfy { $0 }, "Held from the first read")
    #expect(!calls.isEmpty && calls.allSatisfy { $0 }, "Held through every display call")
    #expect(clock.now().timeIntervalSince(start) < 60, "Nothing waited out the lock limit")
    #expect(!isHeld(lockURL), "Let go once the run returned")
    expectDeskRestored(inner)
}

/// Runs `onLoad` before each load.
private final class ProbingStore: LedgerStoring {
    private let inner: InMemoryLedgerStore
    private let onLoad: @Sendable () -> Void

    init(inner: InMemoryLedgerStore, onLoad: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onLoad = onLoad
    }

    func load() throws -> SafetyLedger? {
        onLoad()
        return try inner.load()
    }

    func save(_ ledger: SafetyLedger) throws { try inner.save(ledger) }
    func clear() throws { try inner.clear() }
    func takeSetAsideEvent() -> Bool { inner.takeSetAsideEvent() }
}

/// The CLI's rescue runs this job when the app couldn't rescue, and that app may still hold
/// `restore.lock`, stuck in its own restore. Before the job took the lock, it killed the app first,
/// which freed the lock. It still does: a busy lock gets `ending` and the kill at once, then the wait.
@Test func aRescueWhileTheAppHoldsTheLockKillsTheAppAndRestores() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let lockURL = temporaryLockURL()
    let appsLock = try HeldLock(url: lockURL)
    defer { appsLock.release() }
    let processes = LockReleasingInspector(alive: [app], appsLock: appsLock)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, state: .active))
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes,
        clock: clock,
        lockURL: lockURL
    ).run()

    #expect(succeeded)
    #expect(processes.killed == [app])
    #expect(clock.now().timeIntervalSince(start) < 60, "It didn't wait out the lock limit")
    #expect(try store.load()?.state == .rescued)
    expectDeskRestored(backend)
}

/// The whole-run limit counts the caller's wait for the lock, as it counts a restorer's own wait, so a
/// job that waited still ends inside the guardian's limit.
@Test func aCallersWaitForTheLockCountsAgainstTheWholeRun() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    let lockURL = temporaryLockURL()
    let other = try HeldLock(url: lockURL)
    defer { other.release() }

    let report = await PhysicalRestorer(
        backend: backend,
        clock: clock,
        power: FakePowerAssertions(),
        lockURL: lockURL,
        lockHeldByCallerSince: clock.now().addingTimeInterval(-170)
    ).restore(recorded)

    #expect(report.attempts == 0, "The limit had passed before it began")
    #expect(!report.verified)
    #expect(clock.now().timeIntervalSince(start) < 60, "It didn't wait for the lock, which another holds")
}

// MARK: With no usable ledger

private func registry(at url: URL, listing backend: SimulatedDisplayBackend, bootSession: String = boot) throws {
    try DeviceRegistry(url: url, bootSession: bootSession).update(from: backend.topology())
}

@Test func restoreJobWithNoLedgerReconnectsFromRegistry() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try bothOff(backend)
    #expect(backend.topology().displays.map(\.kind) == [.osFallback])
    let before = backend.mutations.count
    let store = InMemoryLedgerStore()

    let succeeded = await job(ledger: store, registryURL: registryURL, backend: backend).run()

    #expect(succeeded)
    let changes = Array(backend.mutations.dropFirst(before))
    #expect(changes == ["enable 2", "enable 4"], "It reconnects, and doesn't rearrange")
    #expect(try store.load() == nil, "And there's no ledger to mark")
}

@Test func noLedgerWakesDisplaysAndHoldsThemAwake() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)
    let power = FakePowerAssertions(onDeclare: backend.wakeAll)

    let succeeded = await job(ledger: InMemoryLedgerStore(), registryURL: registryURL, backend: backend, power: power).run()

    #expect(succeeded)
    #expect(power.calls.first == "declare")
    #expect(power.activeHoldCount == 0)
    #expect(backend.topology().onlineIDs.isSuperset(of: [lg, m34]))
}

@Test func noLedgerSkipsOtherKindsAndOtherBoots() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    // A monitor last seen in an earlier boot, under an ID that means nothing in this one.
    var earlier = try #require(backend.topology().display(lg))
    earlier.id = 77
    try DeviceRegistry(url: registryURL, bootSession: "boot-0").update(from: Topology(displays: [earlier]))
    // Seen in this boot, but a virtual screen isn't a monitor to reconnect.
    let screen = addScreen(backend)
    let screenRead = try #require(backend.topology().display(screen))
    try DeviceRegistry(url: registryURL, bootSession: boot).update(from: Topology(displays: [screenRead]))
    let before = backend.mutations.count

    let succeeded = await job(ledger: InMemoryLedgerStore(), registryURL: registryURL, backend: backend).run()

    #expect(succeeded, "The monitors are online")
    #expect(backend.mutations.count == before, "And nothing was enabled")
}

@Test func noLedgerEnablesAnOfflineDisplayTheRegistryDoesNotKnow() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    let before = backend.mutations.count

    let succeeded = await job(ledger: InMemoryLedgerStore(), registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(succeeded)
    #expect(Array(backend.mutations.dropFirst(before)) == ["enable 4"], "And not the empty pipes")
}

@Test func noLedgerWithEmptyRegistryAndNothingOnlineFails() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)

    let succeeded = await job(ledger: InMemoryLedgerStore(), registryURL: try temporaryRegistryURL(), backend: backend).run()

    #expect(!succeeded, "The fallback display is online, and it doesn't count")
}

@Test func noLedgerWithLockHeldFails() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let lockURL = temporaryLockURL()
    let holder = FileLock(url: lockURL)
    try #require(holder.tryLock())
    defer { holder.unlock() }

    let succeeded = await job(
        ledger: InMemoryLedgerStore(),
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        lockURL: lockURL
    ).run()

    #expect(!succeeded, "A physical display is online, but this restore never ran")
}

@Test func throwingLoadCountsAsNoLedger() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try bothOff(backend)

    let succeeded = await job(ledger: ThrowingLedgerStore(), registryURL: registryURL, backend: backend).run()

    #expect(succeeded)
    #expect(backend.topology().onlineIDs == [lg, m34])
}

@Test func ledgerFromAnotherBootIsNotUsed() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try bothOff(backend)
    let stale = ledger(recorded, bootSession: "boot-0")
    let store = InMemoryLedgerStore(ledger: stale)
    let processes = FakeProcessInspector(alive: [app])
    let before = backend.mutations.count

    let succeeded = await job(ledger: store, registryURL: registryURL, backend: backend, processes: processes).run()

    #expect(succeeded)
    #expect(processes.killed.isEmpty, "Its app reference is from another boot")
    #expect(Array(backend.mutations.dropFirst(before)) == ["enable 2", "enable 4"], "Reconnected from the registry")
    #expect(try store.load() == stale, "Discarding it is the guardian's and the app's job")
}

/// An empty ID means the boot is unknown, never another boot, as in the guardian's policy. Treating it
/// as another boot would skip killing the app, and lose the session's records.
@Test(arguments: [(ledgerBoot: "", currentBoot: boot), (ledgerBoot: boot, currentBoot: "")])
func unknownBootIsNotAnotherBoot(ledgerBoot: String, currentBoot: String) async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let store = InMemoryLedgerStore(ledger: ledger(recorded, bootSession: ledgerBoot))
    let processes = FakeProcessInspector(alive: [app])

    let succeeded = await job(
        ledger: store,
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: processes,
        bootSession: currentBoot
    ).run()

    #expect(succeeded)
    #expect(processes.killed == [app])
    #expect(try store.load()?.state == .rescued)
    expectDeskRestored(backend)
}

@Test func noLedgerWithAnUnknownBootStillReconnectsFromRegistry() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try bothOff(backend)

    let succeeded = await job(
        ledger: InMemoryLedgerStore(),
        registryURL: registryURL,
        backend: backend,
        bootSession: ""
    ).run()

    #expect(succeeded, "The fallback hides every list, so the registry is all there is to go on")
    #expect(backend.topology().onlineIDs == [lg, m34])
}

@Test func noLedgerWithAnUnusableLockStillReconnects() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    try registry(at: registryURL, listing: backend)
    try bothOff(backend)

    let succeeded = await job(
        ledger: InMemoryLedgerStore(),
        registryURL: registryURL,
        backend: backend,
        lockURL: try unusableLockURL()
    ).run()

    #expect(succeeded)
    #expect(backend.topology().onlineIDs == [lg, m34])
}

@Test func registryIsReadWhenTheJobRuns() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let registryURL = try temporaryRegistryURL()
    let restoreJob = job(ledger: InMemoryLedgerStore(), registryURL: registryURL, backend: backend)
    // Written after the job was built, as another process would.
    try registry(at: registryURL, listing: backend)
    try bothOff(backend)

    let succeeded = await restoreJob.run()

    #expect(succeeded)
    #expect(backend.topology().onlineIDs == [lg, m34])
}

// MARK: Threads

private func isOnMainThread() -> Bool {
    Thread.isMainThread
}

/// A live call can block for about 10 seconds, so none of them may reach the main actor, even when
/// the caller is on it, as the session controller is.
@MainActor @Test func displayCallsNeverRunOnTheMainActor() async throws {
    #expect(isOnMainThread(), "Or this test proves nothing")

    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    let screen = addScreen(inner)
    let calls = Mutex(0)
    let callsOnMain = Mutex(0)
    var script = ScriptedBackend.Script()
    script.beforeCall = {
        calls.withLock { $0 += 1 }
        if Thread.isMainThread { callsOnMain.withLock { $0 += 1 } }
    }
    let backend = ScriptedBackend(inner, script: script)
    let clock = AutoAdvancingClock()
    let operations = DisplayOperations(backend: backend, clock: clock)
    let registryURL = try temporaryRegistryURL()

    try await operations.setMain(screen)
    _ = try await operations.setPlacement(m34, DisplayOrigin(x: 5000, y: 0))
    try await operations.selectMode(m34, resolution: nil, refreshHz: 100, hiDPI: nil)
    try await operations.disconnect(m34)
    try await operations.connect(m34)
    _ = await PhysicalRestorer(
        backend: backend,
        clock: clock,
        power: FakePowerAssertions(),
        lockURL: temporaryLockURL()
    ).restore(recorded)
    try inner.setEnabled(m34, false)
    _ = await job(ledger: InMemoryLedgerStore(ledger: ledger(recorded)), registryURL: registryURL, backend: backend).run()
    try inner.setEnabled(m34, false)
    _ = await job(ledger: InMemoryLedgerStore(), registryURL: registryURL, backend: backend).run()

    #expect(calls.withLock { $0 } >= 8)
    #expect(callsOnMain.withLock { $0 } == 0)
}
