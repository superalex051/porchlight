import ADFoundation
import ADSafety
import Foundation
import Synchronization
import Testing

// MARK: - Fakes

private final class FakePinger: AppPinging {
    private struct State {
        var answers = true
        var pingTimes: [Date] = []
        var endReasons: [String] = []
    }

    private let state = Mutex(State())
    private let clock: any ADClock

    init(clock: any ADClock) {
        self.clock = clock
    }

    var answers: Bool {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    var pingTimes: [Date] {
        state.withLock { $0.pingTimes }
    }

    var endReasons: [String] {
        state.withLock { $0.endReasons }
    }

    func ping() async -> Bool {
        let now = clock.now()
        return state.withLock {
            $0.pingTimes.append(now)
            return $0.answers
        }
    }

    func askToEnd(reason: String) async -> Bool {
        state.withLock { $0.endReasons.append(reason) }
        return true
    }
}

private final class FakeLauncher: AppLaunching {
    private let launches = Mutex(0)

    var count: Int {
        launches.withLock { $0 }
    }

    func launch() {
        launches.withLock { $0 += 1 }
    }
}

private final class FakeRestorer: RestoreSpawning {
    private struct State {
        var startTimes: [Date] = []
        var succeeds = false
    }

    private let state = Mutex(State())
    private let clock: any ADClock
    private let duringRestore: @Sendable () -> Void

    /// `duringRestore` runs inside the restore, for what the real child does: move the clock and
    /// write the ledger.
    init(clock: any ADClock, duringRestore: @escaping @Sendable () -> Void = {}) {
        self.clock = clock
        self.duringRestore = duringRestore
    }

    var succeeds: Bool {
        get { state.withLock { $0.succeeds } }
        set { state.withLock { $0.succeeds = newValue } }
    }

    var startTimes: [Date] {
        state.withLock { $0.startTimes }
    }

    func restore() async -> Bool {
        let now = clock.now()
        state.withLock { $0.startTimes.append(now) }
        duringRestore()
        return state.withLock { $0.succeeds }
    }
}

private final class FakeNotifier: GuardianNotifying {
    private let notifications = Mutex(0)

    var count: Int {
        notifications.withLock { $0 }
    }

    func restoreFailed() {
        notifications.withLock { $0 += 1 }
    }
}

/// A window shown stays up until the test closes it, the way the real one waits for OK or its timeout.
private final class FakeAlerter: UserAlerting {
    struct Shown: Equatable {
        var title: String
        var message: String
        var timeoutSeconds: Int
    }

    private struct State {
        var shown: [Shown] = []
        var up = false
        var shownAfterAnExit = false
    }

    private let state = Mutex(State())
    private let exits: ExitRecorder

    /// `exits` tells this whether the runner had already exited, which a real process can't come back from.
    init(exits: ExitRecorder) {
        self.exits = exits
    }

    var shown: [Shown] {
        state.withLock { $0.shown }
    }

    var shownAfterAnExit: Bool {
        state.withLock { $0.shownAfterAnExit }
    }

    var isShowingAlert: Bool {
        state.withLock { $0.up }
    }

    /// OK, or the timeout.
    func close() {
        state.withLock { $0.up = false }
    }

    func showAlert(title: String, message: String, timeoutSeconds: Int) {
        let exited = exits.count > 0
        state.withLock {
            $0.shown.append(Shown(title: title, message: message, timeoutSeconds: timeoutSeconds))
            $0.up = true
            $0.shownAfterAnExit = $0.shownAfterAnExit || exited
        }
    }
}

private final class ExitRecorder: Sendable {
    private let exits = Mutex(0)

    var count: Int {
        exits.withLock { $0 }
    }

    func record() {
        exits.withLock { $0 += 1 }
    }
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

/// A process that won't die: `kill` is recorded and does nothing.
private final class UnkillableInspector: ProcessInspecting {
    private let inner: FakeProcessInspector
    private let kills = Mutex<[ProcessRef]>([])

    init(alive: Set<ProcessRef>) {
        inner = FakeProcessInspector(alive: alive)
    }

    var killed: [ProcessRef] {
        kills.withLock { $0 }
    }

    func reference(forPID pid: Int32) -> ProcessRef? {
        inner.reference(forPID: pid)
    }

    func isAlive(_ ref: ProcessRef) -> Bool {
        inner.isAlive(ref)
    }

    func kill(_ ref: ProcessRef) {
        kills.withLock { $0.append(ref) }
    }
}

/// Wraps the in-memory store, to fail its reads on demand and count them.
private final class ScriptedStore: LedgerStoring {
    private struct State {
        var failLoads = false
        var loads = 0
    }

    let inner = InMemoryLedgerStore()
    private let state = Mutex(State())

    var failLoads: Bool {
        get { state.withLock { $0.failLoads } }
        set { state.withLock { $0.failLoads = newValue } }
    }

    var loads: Int {
        state.withLock { $0.loads }
    }

    func load() throws -> SafetyLedger? {
        let fail = state.withLock {
            $0.loads += 1
            return $0.failLoads
        }
        if fail { throw POSIXError(.EIO) }
        return try inner.load()
    }

    func save(_ ledger: SafetyLedger) throws {
        try inner.save(ledger)
    }

    func clear() throws {
        try inner.clear()
    }

    func takeSetAsideEvent() -> Bool {
        inner.takeSetAsideEvent()
    }
}

// MARK: - The harness

/// A runner with every seam faked, and helpers that advance time the way `run` does.
private struct Harness {
    let store = ScriptedStore()
    let clock = AutoAdvancingClock(start: sessionStart)
    let pinger: FakePinger
    let launcher = FakeLauncher()
    let restorer: FakeRestorer
    let notifier = FakeNotifier()
    let alerter: FakeAlerter
    let logs = LogLines()
    let exits = ExitRecorder()
    let processes: any ProcessInspecting
    let runner: GuardianRunner

    init(
        alive: Set<ProcessRef> = [appRef, ownerRef],
        processes: (any ProcessInspecting)? = nil,
        bootSession: String = testBoot,
        ledgerStore: (any LedgerStoring)? = nil,
        duringRestore: (@Sendable (ScriptedStore, AutoAdvancingClock) -> Void)? = nil
    ) {
        let pinger = FakePinger(clock: clock)
        let store = store
        let clock = clock
        let restorer = FakeRestorer(clock: clock, duringRestore: { duringRestore?(store, clock) })
        let inspector = processes ?? FakeProcessInspector(alive: alive)
        let logs = logs
        let exits = exits
        self.pinger = pinger
        self.restorer = restorer
        self.processes = inspector
        let alerter = FakeAlerter(exits: exits)
        self.alerter = alerter
        let usedStore: any LedgerStoring = ledgerStore ?? store
        runner = GuardianRunner(
            ledger: usedStore,
            processes: inspector,
            pinger: pinger,
            launcher: launcher,
            restorer: restorer,
            notifier: notifier,
            alerter: alerter,
            clock: clock,
            bootSession: bootSession,
            log: { logs.append($0) },
            exit: { exits.record() }
        )
    }

    var inspector: FakeProcessInspector {
        processes as! FakeProcessInspector
    }

    var elapsed: TimeInterval {
        clock.now().timeIntervalSince(sessionStart)
    }

    func put(_ ledger: SafetyLedger) {
        try! store.inner.save(ledger)
    }

    /// Ticks every 0.25 seconds, as `run` does, for this long.
    func runFor(seconds: Double) async {
        for _ in 0..<Int(seconds / 0.25) {
            await runner.tick()
            clock.advance(by: 0.25)
        }
    }

    /// Ticks until `done` holds, and fails after a generous limit rather than hanging.
    func runUntil(limit: Double = 300, _ done: () -> Bool) async {
        var left = limit
        while !done(), left > 0 {
            await runner.tick()
            clock.advance(by: 0.25)
            left -= 0.25
        }
        #expect(done(), "condition not reached within \(limit) simulated seconds")
    }
}

// MARK: - Process identity

@Test func reusedOwnerPIDCountsAsDead() async {
    // The owner's PID is running again, but as another process.
    let impostor = ProcessRef(pid: ownerRef.pid, startTime: ownerRef.startTime + 500)
    let harness = Harness(alive: [appRef, impostor])
    harness.put(makeLedger(state: .active))

    await harness.runner.tick()

    #expect(harness.pinger.endReasons == ["owner-died"])
    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.isEmpty)
}

@Test func reusedAppPIDCountsAsDead() async {
    let impostor = ProcessRef(pid: appRef.pid, startTime: appRef.startTime + 500)
    let harness = Harness(alive: [impostor, ownerRef])
    harness.put(makeLedger(state: .active))

    await harness.runner.tick()

    // It isn't our app, so it's neither pinged nor killed.
    #expect(harness.pinger.pingTimes.isEmpty)
    #expect(harness.inspector.killed.isEmpty)
    #expect(harness.launcher.count == 1)
}

// MARK: - Restore

@Test func restoreSuccessStopsRetrying() async {
    let harness = Harness(alive: [], duringRestore: { store, clock in
        // What `adguardian restore` does on success.
        var ledger = try! store.inner.load()!
        ledger.state = .rescued
        ledger.updatedAt = clock.now()
        try! store.inner.save(ledger)
    })
    harness.restorer.succeeds = true
    harness.put(makeLedger())

    await harness.runFor(seconds: 120)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.launcher.count == 0)
    #expect(harness.notifier.count == 0)
    #expect(try! harness.store.load()?.state == .rescued)
}

/// The child succeeded but couldn't write `rescued`. Left as `active`, the policy would relaunch the
/// app, and the app would turn the monitors off again.
@Test func restoreSuccessIsRecordedEvenIfTheChildDidNotWriteIt() async {
    let harness = Harness(alive: [])
    harness.restorer.succeeds = true
    harness.put(makeLedger())

    await harness.runFor(seconds: 120)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.launcher.count == 0)
    let ledger = try! harness.store.load()
    #expect(ledger?.state == .rescued)
    #expect(ledger?.startedAt == sessionStart)
    // Written on the tick after the restore, with the time it was written.
    #expect(ledger?.updatedAt == sessionStart.addingTimeInterval(0.25))
}

@Test func restoreSuccessStopsRetryingEvenIfTheLedgerCannotBeWritten() async {
    let harness = Harness(alive: [])
    harness.restorer.succeeds = true
    harness.put(makeLedger())
    harness.store.inner.failOnSave = true

    await harness.runFor(seconds: 120)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.launcher.count == 0)
    #expect(harness.notifier.count == 0)

    // When the disk recovers, the record catches up.
    harness.store.inner.failOnSave = false
    await harness.runFor(seconds: 1)
    #expect(try! harness.store.load()?.state == .rescued)
}

@Test func afterThreeFailuresRetriesEvery60sAndNotifiesOnce() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())

    await harness.runUntil { harness.restorer.startTimes.count == 3 }
    // Told at the third failure, not a tick or a minute later.
    #expect(harness.notifier.count == 1)

    await harness.runFor(seconds: 300)

    let starts = harness.restorer.startTimes
    #expect(starts.count == 8)
    for (earlier, later) in zip(starts.dropFirst(2), starts.dropFirst(3)) {
        #expect(later.timeIntervalSince(earlier) >= 60)
        #expect(later.timeIntervalSince(earlier) <= 60.5)
    }
    #expect(harness.notifier.count == 1)
    #expect(harness.launcher.count == 0)
    // The ledger stays, so a manual rescue still has the records.
    #expect(try! harness.store.load()?.state == .active)
}

/// The retries run for as long as the ledger is live, and a retry can still be the one that works.
@Test func aLateRetryCanStillSucceed() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())
    await harness.runFor(seconds: 200)
    #expect(harness.restorer.startTimes.count > 3)

    harness.restorer.succeeds = true
    let attempts = harness.restorer.startTimes.count
    await harness.runFor(seconds: 300)

    #expect(harness.restorer.startTimes.count == attempts + 1)
    #expect(try! harness.store.load()?.state == .rescued)
    #expect(harness.notifier.count == 1)
}

/// `RestoreJob` found the app it was told to kill gone and restored the monitors, and a relaunched
/// app then took the session over. Stamping that live session `rescued` would stop watching it.
@Test func resumedAppIsNotMarkedRescued() async {
    let harness = Harness(alive: [ownerRef])
    harness.restorer.succeeds = true
    harness.put(makeLedger())
    await harness.runUntil { harness.restorer.startTimes.count == 1 }
    #expect(harness.launcher.count == 1)

    let resumed = ProcessRef(pid: 101, startTime: 7000)
    harness.inspector.alive.insert(resumed)
    harness.put(makeLedger(app: resumed))

    // Still starting up: it gets the normal grace, with no leftover restore aimed at it.
    harness.pinger.answers = false
    await harness.runFor(seconds: 5)
    #expect(harness.restorer.startTimes.count == 1)
    #expect(try! harness.store.load()?.state == .active)

    harness.pinger.answers = true
    await harness.runFor(seconds: 60)
    #expect(try! harness.store.load()?.state == .active)
    #expect(try! harness.store.load()?.app == resumed)
    #expect(harness.restorer.startTimes.count == 1)

    // It's a watched session: when it dies, the guardian acts.
    harness.inspector.alive.remove(resumed)
    await harness.runFor(seconds: 1)
    #expect(harness.launcher.count == 2)
}

@Test func restoreSpacingCountsFromTheEndOfTheAttempt() async {
    // A real attempt can take minutes. The next must still wait 5 seconds after it finishes.
    let harness = Harness(alive: [], duringRestore: { _, clock in clock.advance(by: 40) })
    harness.put(makeLedger())

    await harness.runUntil { harness.restorer.startTimes.count == 2 }

    let starts = harness.restorer.startTimes
    #expect(starts[1].timeIntervalSince(starts[0]) >= 45)
    #expect(starts[1].timeIntervalSince(starts[0]) <= 45.5)
}

@Test func askToEndThatFinishesTheSessionNeedsNoRestore() async {
    let harness = Harness(alive: [appRef])
    harness.put(makeLedger())

    await harness.runUntil { harness.pinger.endReasons.count == 1 }

    // The app ends the session.
    try! harness.store.inner.clear()
    await harness.runFor(seconds: 30)

    #expect(harness.pinger.endReasons == ["owner-died"])
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.launcher.count == 0)
}

@Test func askToEndThatGetsNowhereRestoresAfter8Seconds() async {
    let harness = Harness(alive: [appRef])
    harness.put(makeLedger())

    await harness.runFor(seconds: 7.75)
    #expect(harness.pinger.endReasons == ["owner-died"])
    #expect(harness.restorer.startTimes.isEmpty)

    await harness.runUntil(limit: 1) { harness.restorer.startTimes.count == 1 }
}

// MARK: - Kill, relaunch, resume

@Test func killThenRelaunchSequence() async {
    let harness = Harness()
    harness.put(makeLedger())

    await harness.runFor(seconds: 1)
    #expect(harness.inspector.killed.isEmpty)
    harness.pinger.answers = false

    await harness.runUntil { !harness.inspector.killed.isEmpty }
    #expect(harness.inspector.killed == [appRef])
    // It answered at 0, so 15 seconds of silence ends at 15.
    #expect(harness.elapsed >= 15)
    #expect(harness.elapsed <= 15.5)
    #expect(harness.launcher.count == 0)

    await harness.runner.tick()
    #expect(harness.launcher.count == 1)
    #expect(harness.restorer.startTimes.isEmpty)

    // The new app comes up, writes its reference, and answers. The session carries on.
    let newApp = ProcessRef(pid: 101, startTime: 7000)
    harness.inspector.alive.insert(newApp)
    harness.pinger.answers = true
    harness.put(makeLedger(app: newApp))
    await harness.runFor(seconds: 30)

    #expect(harness.inspector.killed == [appRef])
    #expect(harness.launcher.count == 1)
    #expect(harness.restorer.startTimes.isEmpty)
}

/// "SIGKILL it, then treat it as dead." A process stuck in the kernel can outlive the signal, and
/// waiting on it would keep the monitors off for good.
@Test func anAppThatSurvivesSIGKILLIsTreatedAsDead() async {
    let inspector = UnkillableInspector(alive: [appRef, ownerRef])
    let harness = Harness(processes: inspector)
    harness.pinger.answers = false
    harness.put(makeLedger())

    await harness.runUntil { !inspector.killed.isEmpty }
    await harness.runUntil { harness.launcher.count == 1 }
    await harness.runUntil(limit: 11) { harness.restorer.startTimes.count == 1 }

    #expect(inspector.killed == [appRef])
}

@Test func relaunchThatNeverComesBackRestoresAfter10Seconds() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger())

    await harness.runner.tick()
    #expect(harness.launcher.count == 1)

    await harness.runFor(seconds: 9.5)
    #expect(harness.restorer.startTimes.isEmpty)

    await harness.runUntil(limit: 1) { harness.restorer.startTimes.count == 1 }
    #expect(harness.launcher.count == 1)
}

@Test func crashLoopHitsTheRelaunchBudgetAndRestores() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger(app: nil))

    // Each life: relaunched, comes up, answers, dies.
    for life in 1...2 {
        await harness.runUntil { harness.launcher.count == life }
        let app = ProcessRef(pid: 500 + Int32(life), startTime: 1000 + Double(life))
        harness.inspector.alive.insert(app)
        harness.put(makeLedger(app: app))
        await harness.runFor(seconds: 3)
        #expect(harness.restorer.startTimes.isEmpty)
        harness.inspector.alive.remove(app)
    }

    // The third death had no healthy stretch before it, so this time it's a restore.
    await harness.runFor(seconds: 0.5)
    #expect(harness.launcher.count == 2)
    #expect(harness.restorer.startTimes.count == 1)
}

/// Slow enough that a 60 second window never held two relaunches: that relaunched forever, with the
/// monitors off and nobody told.
@Test func aResumeThatCrashesEvery35SecondsGetsTwoLivesThenARestoreAndOneNotification() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger(app: nil))

    for life in 1...2 {
        await harness.runUntil { harness.launcher.count == life }
        let app = ProcessRef(pid: 500 + Int32(life), startTime: 1000 + Double(life))
        harness.inspector.alive.insert(app)
        harness.put(makeLedger(app: app))
        await harness.runFor(seconds: 35)
        harness.inspector.alive.remove(app)
    }

    await harness.runFor(seconds: 600)

    #expect(harness.launcher.count == 2)
    #expect(harness.restorer.startTimes.count >= 3)
    #expect(harness.notifier.count == 1)
}

/// Hardware test 6B: macOS 27's MenuBarAgent relaunched the app 20 to 50 ms after a `kill -9`, and the
/// new app named itself in the ledger before the guardian's next tick. Here each new app takes over
/// between two ticks, so no tick ever sees a dead app.
@Test func appsReplacedBetweenTwoTicksStillSpendTheBudget() async {
    let harness = Harness()
    harness.restorer.succeeds = true
    harness.put(makeLedger())
    await harness.runFor(seconds: 6)

    var current = appRef
    for life in 1...3 {
        let next = ProcessRef(pid: 600 + Int32(life), startTime: 2000 + Double(life))
        harness.inspector.alive.remove(current)
        harness.inspector.alive.insert(next)
        harness.put(makeLedger(app: next))
        current = next
        await harness.runFor(seconds: 7)
    }

    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.count == 1)
    #expect(try! harness.store.load()?.state == .rescued)
    #expect(
        harness.logs.all.filter { $0.contains(" took over from ") } == [
            "app 601 took over from app 100, counting it as relaunch 1 of 2",
            "app 602 took over from app 601, counting it as relaunch 2 of 2",
            "app 603 took over from app 602, and the relaunches are used up",
        ])
}

/// Test 6B as it ran: kill 1 replaced before any tick, kill 2 seen and relaunched by the guardian,
/// kill 3 seen. It logged "1 of 2" at kill 2 and "2 of 2" at kill 3, and never restored.
@Test func aMissedKillThenTwoSeenOnesRestoreOnTheThird() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 6)

    let first = ProcessRef(pid: 601, startTime: 2001)
    harness.inspector.alive = [ownerRef, first]
    harness.put(makeLedger(app: first))
    await harness.runFor(seconds: 7)
    #expect(harness.launcher.count == 0)

    harness.inspector.alive = [ownerRef]
    await harness.runFor(seconds: 0.25)
    #expect(harness.launcher.count == 1)
    let second = ProcessRef(pid: 602, startTime: 2002)
    harness.inspector.alive.insert(second)
    harness.put(makeLedger(app: second))
    await harness.runFor(seconds: 7)

    harness.inspector.alive = [ownerRef]
    await harness.runFor(seconds: 0.5)

    #expect(harness.launcher.count == 1)
    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.logs.all.contains("the app is not running, relaunching it, 2 of 2"))
}

// MARK: - Doing nothing

@Test func doesNothingOutsideSessionEvenIfAppDies() async {
    for ledger in [nil, makeLedger(state: .rescued)] {
        let harness = Harness(alive: [])
        if let ledger { harness.put(ledger) }

        await harness.runFor(seconds: 120)

        #expect(harness.pinger.pingTimes.isEmpty)
        #expect(harness.pinger.endReasons.isEmpty)
        #expect(harness.launcher.count == 0)
        #expect(harness.restorer.startTimes.isEmpty)
        #expect(harness.inspector.killed.isEmpty)
        #expect(harness.notifier.count == 0)
        #expect(try! harness.store.load() == ledger)
    }
}

/// The session is over but the app is still running, silent, with its owner gone. It's not ours to
/// ping, ask or kill.
@Test func aRescuedSessionsLiveAppIsLeftAlone() async {
    let harness = Harness(alive: [appRef])
    harness.pinger.answers = false
    harness.put(makeLedger(state: .rescued))

    await harness.runFor(seconds: 120)

    #expect(harness.pinger.pingTimes.isEmpty)
    #expect(harness.pinger.endReasons.isEmpty)
    #expect(harness.inspector.killed.isEmpty)
    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.isEmpty)
}

@Test func aHealthySessionIsLeftAlone() async {
    let harness = Harness()
    harness.put(makeLedger())

    await harness.runFor(seconds: 300)

    #expect(harness.pinger.endReasons.isEmpty)
    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.inspector.killed.isEmpty)
    #expect(try! harness.store.load() == makeLedger())
}

@Test func staleLedgerIsCleared() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger(boot: otherBoot))

    await harness.runFor(seconds: 30)

    #expect(try! harness.store.load() == nil)
    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.pinger.pingTimes.isEmpty)
}

@Test func unknownBootKeepsTheLedgerAndTheProtection() async {
    let harness = Harness(alive: [ownerRef], bootSession: "")
    harness.put(makeLedger())

    await harness.runner.tick()

    #expect(try! harness.store.load() != nil)
    #expect(harness.launcher.count == 1)
}

// MARK: - A ledger that can't be read

/// A read error isn't "no ledger". Taking it for one would forget the session and its timers.
@Test func aReadErrorDoesNotRestartTheTimers() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger())

    await harness.runner.tick()
    #expect(harness.launcher.count == 1)

    harness.store.failLoads = true
    await harness.runFor(seconds: 4)
    harness.store.failLoads = false

    // Still the same relaunch window: no second relaunch, and the restore comes on schedule.
    await harness.runUntil(limit: 7) { harness.restorer.startTimes.count == 1 }
    #expect(harness.launcher.count == 1)
    #expect(harness.logs.all.filter { $0.contains("cannot read the ledger") }.count == 1)
}

@Test func readErrorKeepsUsingLastGoodLedger() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    // The reads start failing, and then the app dies. The guardian still acts on what it knew.
    harness.store.failLoads = true
    harness.inspector.alive = [ownerRef]
    await harness.runFor(seconds: 1)
    #expect(harness.launcher.count == 1)

    await harness.runUntil(limit: 11) { harness.restorer.startTimes.count == 1 }
    #expect(harness.launcher.count == 1)
    #expect(harness.exits.count == 0)
}

@Test func readErrorWithAnOwnerDeathStillRestores() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    harness.store.failLoads = true
    harness.inspector.alive = []
    await harness.runFor(seconds: 1)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.launcher.count == 0)
}

/// A restore that works during read errors can't be recorded by reading the ledger back, and the copy
/// must not go on looking live.
@Test func aRestoreDuringReadErrorsIsRecordedOnTheCopy() async {
    let harness = Harness()
    harness.restorer.succeeds = true
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    harness.store.failLoads = true
    harness.inspector.alive = []
    await harness.runFor(seconds: 20)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.launcher.count == 0)
}

@Test func readErrorPast30sNotifiesAndExits() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    harness.store.failLoads = true
    await harness.runFor(seconds: 30)
    #expect(harness.exits.count == 0)
    #expect(harness.notifier.count == 0)

    await harness.runFor(seconds: 0.25)
    #expect(harness.exits.count == 1)
    #expect(harness.notifier.count == 1)

    // A real exit doesn't come back. The seam does, and the guardian still says it only once.
    await harness.runFor(seconds: 60)
    #expect(harness.exits.count == 1)
    #expect(harness.notifier.count == 1)
}

@Test func readErrorsThatPassDoNotAddUp() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    for _ in 0..<3 {
        harness.store.failLoads = true
        await harness.runFor(seconds: 20)
        harness.store.failLoads = false
        await harness.runFor(seconds: 1)
    }

    #expect(harness.exits.count == 0)
    #expect(harness.notifier.count == 0)
}

@Test func aSleepDoesNotCountTowardTheReadErrorLimit() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    harness.store.failLoads = true
    await harness.runFor(seconds: 5)
    harness.clock.advance(by: 3600)
    await harness.runFor(seconds: 20)

    #expect(harness.exits.count == 0)
}

/// With no copy there's no way to know a session exists, so nothing is relaunched, restored or killed.
@Test func readErrorWithNoLastGoodLedgerStaysSafe() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())
    harness.store.failLoads = true

    await harness.runFor(seconds: 29)

    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.pinger.pingTimes.isEmpty)
    #expect(harness.inspector.killed.isEmpty)
    #expect(harness.notifier.count == 0)
    #expect(harness.exits.count == 0)
    #expect(try! harness.store.inner.load() == makeLedger())

    await harness.runFor(seconds: 2)
    #expect(harness.notifier.count == 1)
    #expect(harness.restorer.startTimes.isEmpty)
}

/// Reads have never worked in this process, so a restart gains nothing, and exiting would only repeat
/// the notification about every 35 seconds.
@Test func neverReadSuccessfullyStaysUpAndNotifiesOnce() async {
    let harness = Harness()
    harness.put(makeLedger())
    harness.store.failLoads = true

    await harness.runFor(seconds: 300)
    #expect(harness.exits.count == 0)
    #expect(harness.notifier.count == 1)
    #expect(harness.pinger.pingTimes.isEmpty)

    // It keeps trying, so the session is picked up as soon as a read works.
    harness.store.failLoads = false
    await harness.runFor(seconds: 1)
    #expect(!harness.pinger.pingTimes.isEmpty)

    // It has a copy now, and reads that fail from here on take the notify and exit path.
    harness.store.failLoads = true
    await harness.runFor(seconds: 31)
    #expect(harness.exits.count == 1)
    #expect(harness.notifier.count == 2)
}

/// This process could read before, so the fault may be its own and a fresh one may do better. No
/// session is lost, and a fresh process that can't read stays up, so this can't become a loop.
@Test func readErrorAfterReadingNoLedgerExits() async {
    let harness = Harness()
    await harness.runFor(seconds: 1)

    harness.store.failLoads = true
    await harness.runFor(seconds: 31)

    #expect(harness.exits.count == 1)
    #expect(harness.notifier.count == 1)
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.launcher.count == 0)
}

// MARK: - A ledger set aside

/// The file was unreadable. Its disappearing mustn't look like the session being cleared.
@Test(arguments: [false, true])
func setAsideLedgerKeepsUsingLastGoodCopy(stuck: Bool) async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    if stuck {
        harness.store.inner.unreadableAndStuck = true
    } else {
        harness.store.inner.setAsideOnNextLoad()
    }
    await harness.runFor(seconds: 5)
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.notifier.count == 0)

    harness.inspector.alive = [ownerRef]
    await harness.runFor(seconds: 1)
    #expect(harness.launcher.count == 1)

    await harness.runUntil(limit: 11) { harness.restorer.startTimes.count == 1 }
    #expect(harness.launcher.count == 1)
}

/// The app rewrites the ledger on its next step. From there the file is the truth again, including
/// when it's really cleared.
@Test func aNewLedgerReplacesTheCopyAndClearingThenCounts() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)
    harness.store.inner.setAsideOnNextLoad()
    await harness.runFor(seconds: 1)

    harness.put(makeLedger(updatedAt: sessionStart.addingTimeInterval(2)))
    await harness.runFor(seconds: 1)

    try! harness.store.inner.clear()
    harness.inspector.alive = []
    await harness.runFor(seconds: 60)

    #expect(harness.launcher.count == 0)
    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.notifier.count == 0)
}

@Test(arguments: [false, true])
func setAsideWithNoCopyRunsOneRestoreAndNotifies(stuck: Bool) async {
    let harness = Harness(alive: [])
    if stuck {
        harness.store.inner.unreadableAndStuck = true
    } else {
        harness.store.inner.setAsideOnNextLoad()
    }

    await harness.runFor(seconds: 120)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.notifier.count == 1)
    #expect(harness.launcher.count == 0)
    #expect(harness.inspector.killed.isEmpty)
    #expect(harness.exits.count == 0)
}

@Test func aLaterSetAsideWithNoCopyIsANewEvent() async {
    let harness = Harness(alive: [])
    harness.store.inner.setAsideOnNextLoad()
    await harness.runFor(seconds: 5)
    #expect(harness.restorer.startTimes.count == 1)

    harness.store.inner.setAsideOnNextLoad()
    await harness.runFor(seconds: 5)

    #expect(harness.restorer.startTimes.count == 2)
    #expect(harness.notifier.count == 2)
}

/// End to end on real files, with another store standing in for the app or `adguardian restore`.
@Test func aSetAsideByAnotherProcessStillReachesTheGuardian() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let app = FileLedgerStore(url: url)
    let harness = Harness(ledgerStore: FileLedgerStore(url: url))
    try app.save(makeLedger())
    await harness.runFor(seconds: 1)

    try Data("garbage".utf8).write(to: url)
    #expect(try app.load() == nil)
    await harness.runFor(seconds: 5)
    #expect(harness.notifier.count == 0)

    // The file is gone, and the guardian still knows the session exists.
    harness.inspector.alive = [ownerRef]
    await harness.runFor(seconds: 1)
    #expect(harness.launcher.count == 1)
    await harness.runUntil(limit: 11) { harness.restorer.startTimes.count == 1 }
}

/// A bad file set aside and a good one written, both between two ticks. The event arrives along with
/// a ledger that reads, and that ledger is the truth.
@Test func aLedgerThatReadsWinsOverASetAsideEvent() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "safety.json")
    let app = FileLedgerStore(url: url)
    let harness = Harness(ledgerStore: FileLedgerStore(url: url))
    try app.save(makeLedger())
    await harness.runFor(seconds: 1)

    try Data("garbage".utf8).write(to: url)
    #expect(try app.load() == nil)
    try app.save(makeLedger(state: .rescued))
    harness.inspector.alive = []
    await harness.runFor(seconds: 30)

    #expect(harness.restorer.startTimes.isEmpty)
    #expect(harness.launcher.count == 0)
}

/// A stale copy being discarded must not come straight back and be discarded forever.
@Test func aDiscardedCopyIsGone() async {
    let harness = Harness(alive: [], bootSession: otherBoot)
    harness.put(makeLedger())
    await harness.runner.tick()
    #expect(try! harness.store.load() == nil)

    harness.store.inner.setAsideOnNextLoad()
    await harness.runFor(seconds: 1)

    #expect(harness.restorer.startTimes.count == 1)
}

// MARK: - Sessions

@Test func aNewSessionGetsAFreshRestoreBudget() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())
    await harness.runUntil { harness.notifier.count == 1 }
    #expect(harness.restorer.startTimes.count == 3)

    // A new session replaces the ledger before any tick sees it empty, and its app and owner die too.
    harness.put(makeLedger(startedAt: sessionStart.addingTimeInterval(1000)))
    await harness.runFor(seconds: 1)
    #expect(harness.restorer.startTimes.count == 4)

    // If those fail as well, the user is told again: this is a new failure, not the old one.
    await harness.runFor(seconds: 30)
    #expect(harness.restorer.startTimes.count == 6)
    #expect(harness.notifier.count == 2)
}

/// The record of a successful restore applies to that session only. Letting it reach a later one
/// would leave that session unprotected.
@Test func aSessionAfterASuccessfulRestoreIsStillWatched() async {
    let harness = Harness(alive: [])
    harness.restorer.succeeds = true
    harness.put(makeLedger())
    await harness.runUntil { harness.restorer.startTimes.count == 1 }
    await harness.runFor(seconds: 1)
    #expect(try! harness.store.load()?.state == .rescued)
    #expect(harness.launcher.count == 0)

    harness.inspector.alive = [ownerRef]
    harness.put(makeLedger(startedAt: sessionStart.addingTimeInterval(1000)))
    await harness.runFor(seconds: 1)

    #expect(try! harness.store.load()?.state == .active)
    #expect(harness.launcher.count == 1)
}

@Test func aRelaunchedAppKeepsTheSessionsBudget() async {
    // Same `startedAt` after a resume, so the same session: the attempts aren't forgotten.
    let newApp = ProcessRef(pid: 101, startTime: 7000)
    let harness = Harness(alive: [])
    harness.put(makeLedger())
    await harness.runUntil { harness.restorer.startTimes.count == 2 }

    harness.put(makeLedger(app: newApp))
    await harness.runFor(seconds: 30)

    #expect(harness.restorer.startTimes.count == 3)
    #expect(harness.notifier.count == 1)
}

// MARK: - Pings

@Test func runnerPingsAtMostEvery2Seconds() async {
    let harness = Harness()
    harness.put(makeLedger())

    await harness.runFor(seconds: 20)

    let times = harness.pinger.pingTimes
    #expect(times.count == 10)
    for (earlier, later) in zip(times, times.dropFirst()) {
        #expect(later.timeIntervalSince(earlier) >= 2)
    }
}

@Test func deadAppIsNotPinged() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger())

    await harness.runFor(seconds: 5)

    #expect(harness.pinger.pingTimes.isEmpty)
}

// MARK: - Time

@Test func aSleepDoesNotKillAHealthyApp() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 2)

    // The Mac sleeps for an hour. On wake, the app misses its first ping.
    harness.clock.advance(by: 3600)
    harness.pinger.answers = false
    await harness.runFor(seconds: 14.5)
    #expect(harness.inspector.killed.isEmpty)

    // Silence over the guardian's own waking time still counts.
    await harness.runUntil(limit: 1) { harness.inspector.killed == [appRef] }
}

/// Through the runner, with the second kill leading to a restore. An hour asleep isn't an hour healthy.
@Test func aSleepDoesNotCountAsAHealthyStretch() async {
    let harness = Harness()
    harness.put(makeLedger())
    harness.pinger.answers = false
    await harness.runUntil { harness.launcher.count == 1 }
    #expect(harness.inspector.killed == [appRef])

    let resumed = ProcessRef(pid: 101, startTime: 7000)
    harness.inspector.alive.insert(resumed)
    harness.put(makeLedger(app: resumed))
    harness.pinger.answers = true
    await harness.runFor(seconds: 10)

    harness.clock.advance(by: 3600)
    await harness.runFor(seconds: 10)

    harness.pinger.answers = false
    await harness.runUntil(limit: 30) { harness.inspector.killed.count == 2 }
    await harness.runFor(seconds: 0.5)

    #expect(harness.launcher.count == 1)
    #expect(harness.restorer.startTimes.count == 1)
}

@Test func aClockSetBackDoesNotStretchTheRelaunchWindow() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger())
    await harness.runner.tick()
    #expect(harness.launcher.count == 1)

    harness.clock.advance(by: -3600)
    await harness.runUntil(limit: 11) { harness.restorer.startTimes.count == 1 }
}

@Test func aClockSetBackDoesNotStretchTheRestoreSpacing() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())
    await harness.runner.tick()
    #expect(harness.restorer.startTimes.count == 1)

    harness.clock.advance(by: -3600)
    await harness.runUntil(limit: 6) { harness.restorer.startTimes.count == 2 }
}

@Test func aClockSetBackDoesNotStretchTheEndWait() async {
    let harness = Harness(alive: [appRef])
    harness.put(makeLedger())
    await harness.runner.tick()
    #expect(harness.pinger.endReasons == ["owner-died"])

    harness.clock.advance(by: -3600)
    await harness.runUntil(limit: 9) { harness.restorer.startTimes.count == 1 }
}

@Test func aClockSetBackDoesNotFreezeTheHealthyStretch() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger(app: nil))

    // Two relaunches spend the budget, and the second app stays up.
    for life in 1...2 {
        await harness.runUntil { harness.launcher.count == life }
        harness.inspector.alive = [ownerRef]
        let app = ProcessRef(pid: 500 + Int32(life), startTime: 1000 + Double(life))
        harness.inspector.alive.insert(app)
        harness.put(makeLedger(app: app))
        await harness.runFor(seconds: 3)
        if life == 1 { harness.inspector.alive = [ownerRef] }
    }

    // An hour back, then over 5 minutes of answers. The budget resets as it normally would.
    harness.clock.advance(by: -3600)
    await harness.runFor(seconds: 305)
    harness.inspector.alive = [ownerRef]
    await harness.runFor(seconds: 0.5)

    #expect(harness.launcher.count == 3)
    #expect(harness.restorer.startTimes.isEmpty)
}

@Test func aClockSetBackDoesNotStopThePings() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)
    #expect(harness.pinger.pingTimes.count == 1)

    harness.clock.advance(by: -3600)
    await harness.runFor(seconds: 5)
    #expect(harness.pinger.pingTimes.count >= 3)
}

// MARK: - Logging

@Test func logsEachChangeOnceNotEveryTick() async {
    let harness = Harness(alive: [ownerRef])
    harness.put(makeLedger())

    await harness.runFor(seconds: 5)

    let lines = harness.logs.all
    #expect(lines.filter { $0.contains("relaunching") }.count == 1)
    #expect(lines.filter { $0.contains("waiting for the app") }.count == 1)
    // 20 ticks, one action and one wait, and no line per tick.
    #expect(lines.count <= 3)
}

@Test func logsEveryRestoreAttemptAndTheNotification() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())

    await harness.runFor(seconds: 80)

    let lines = harness.logs.all
    #expect(lines.contains { $0.contains("attempt 1") })
    #expect(lines.contains { $0.contains("attempt 2") })
    #expect(lines.contains { $0.contains("attempt 3") })
    #expect(lines.contains { $0.contains("attempt 4") })
    #expect(lines.filter { $0.contains("3 restores failed") }.count == 1)
}

/// A live ledger on a full disk: `rescued` can't be written, so "cannot mark" and "idle" take turns on
/// every tick, which a check against the last line alone doesn't stop.
@Test func repeatedLogLinesAreLimitedToOncePerMinute() async {
    let harness = Harness(alive: [])
    harness.restorer.succeeds = true
    harness.put(makeLedger())
    harness.store.inner.failOnSave = true

    await harness.runFor(seconds: 300)

    let lines = harness.logs.all
    for line in Set(lines) {
        #expect(lines.filter { $0 == line }.count <= 6, "\(line)")
    }
    #expect(lines.count <= 20)
    // It's limited, not silenced.
    #expect(lines.filter { $0.contains("cannot mark the ledger rescued") }.count >= 4)
}

@Test func aLineThatStaysTheSameIsNotRepeated() async {
    let harness = Harness(alive: [])

    await harness.runFor(seconds: 600)

    #expect(harness.logs.all == ["idle"])
}

// MARK: - The alert window

/// macOS mutes notification banners while the display is shared, which is when Parsec is connected.
@Test func theAlertWindowComesWithTheRestoreFailureNotification() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())

    await harness.runUntil { harness.restorer.startTimes.count == 3 }

    #expect(harness.notifier.count == 1)
    #expect(
        harness.alerter.shown == [
            FakeAlerter.Shown(
                title: "Porch Light needs attention",
                message: GuardianAlert.message(for: .restoresFailed),
                timeoutSeconds: 600
            )
        ]
    )

    // The retries that follow don't post the notification again, so they don't bring a window either.
    harness.alerter.close()
    await harness.runFor(seconds: 300)
    #expect(harness.notifier.count == 1)
    #expect(harness.alerter.shown.count == 1)
}

@Test func noSecondAlertWindowWhileOneIsUpButTheNotificationStillPosts() async {
    let harness = Harness(alive: [])
    harness.put(makeLedger())
    await harness.runUntil { harness.notifier.count == 1 }

    // A new session's restores fail too, while the first window is still up.
    harness.put(makeLedger(startedAt: sessionStart.addingTimeInterval(1000)))
    await harness.runUntil { harness.notifier.count == 2 }
    #expect(harness.alerter.shown.count == 1)
    #expect(harness.logs.all.contains("the alert window is still up, so only the notification was posted"))

    // Once it's closed, the next notification brings a window again.
    harness.alerter.close()
    harness.put(makeLedger(startedAt: sessionStart.addingTimeInterval(2000)))
    await harness.runUntil { harness.notifier.count == 3 }
    #expect(harness.alerter.shown.count == 2)
    #expect(harness.alerter.isShowingAlert)
}

/// Shown before the exit, which a real process doesn't come back from.
@Test func theAlertWindowComesWithTheReadFailureNotificationBeforeTheExit() async {
    let harness = Harness()
    harness.put(makeLedger())
    await harness.runFor(seconds: 1)

    harness.store.failLoads = true
    await harness.runFor(seconds: 30.25)

    #expect(harness.notifier.count == 1)
    #expect(harness.exits.count == 1)
    #expect(harness.alerter.shown.map(\.message) == [GuardianAlert.message(for: .ledgerUnreadable)])
    #expect(!harness.alerter.shownAfterAnExit)
}

@Test func theAlertWindowComesWithTheNoCopyReconnectNotification() async {
    let harness = Harness(alive: [])
    harness.store.inner.setAsideOnNextLoad()

    await harness.runFor(seconds: 5)

    #expect(harness.restorer.startTimes.count == 1)
    #expect(harness.notifier.count == 1)
    #expect(harness.alerter.shown.map(\.message) == [GuardianAlert.message(for: .ledgerUnreadable)])
}

// MARK: - run

@Test func runTicksEveryQuarterSecondAndStopsWhenCancelled() async {
    let store = ScriptedStore()
    try! store.inner.save(makeLedger())
    let clock = AutoAdvancingClock(start: sessionStart)
    let pinger = FakePinger(clock: clock)
    let launcher = FakeLauncher()
    let runner = GuardianRunner(
        ledger: store,
        processes: FakeProcessInspector(alive: [appRef, ownerRef]),
        pinger: pinger,
        launcher: launcher,
        restorer: FakeRestorer(clock: clock),
        notifier: FakeNotifier(),
        alerter: FakeAlerter(exits: ExitRecorder()),
        clock: clock,
        bootSession: testBoot,
        log: { _ in }
    )

    let task = Task { await runner.run() }
    while clock.now().timeIntervalSince(sessionStart) < 30 {
        await Task.yield()
    }
    task.cancel()
    await task.value

    let elapsed = clock.now().timeIntervalSince(sessionStart)
    let loads = Double(store.loads)
    #expect(abs(loads - elapsed / 0.25) <= 2)

    let pings = pinger.pingTimes
    #expect(!pings.isEmpty)
    #expect(Double(pings.count) <= elapsed / 2 + 1)
    for (earlier, later) in zip(pings, pings.dropFirst()) {
        #expect(later.timeIntervalSince(earlier) >= 2)
    }
    #expect(launcher.count == 0)
}
