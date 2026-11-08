import ADDisplays
import ADFoundation
import ADModel
import Foundation
import Synchronization
import Testing

@testable import ADDisplayConfig

private func restorer(
    _ backend: any DisplayBackend,
    clock: any ADClock = AutoAdvancingClock(),
    power: any PowerAsserting = FakePowerAssertions(),
    lockURL: URL = temporaryLockURL(),
    blockedCallHeartbeat: BlockedCallHeartbeat = BlockedCallHeartbeat(),
    onProgress: @escaping @Sendable () -> Void = {}
) -> PhysicalRestorer {
    PhysicalRestorer(
        backend: backend,
        clock: clock,
        power: power,
        lockURL: lockURL,
        blockedCallHeartbeat: blockedCallHeartbeat,
        onProgress: onProgress
    )
}

private func enables(_ mutations: some Sequence<String>) -> [String] {
    mutations.filter { $0.hasPrefix("enable") }
}

/// Holds a lock until `release`, from whichever thread the clock's hook runs on.
private final class LockHolder: Sendable {
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

// MARK: The Nov 6 cases

@Test func restoreFromFallbackEnablesByRecordedID() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    #expect(backend.topology().displays.map(\.kind) == [.osFallback])
    let before = backend.mutations.count

    let report = await restorer(backend).restore(recorded)

    #expect(report == RestoreReport(restored: [lg, m34], missing: [], attempts: 1, verified: true, anyReturned: true))
    #expect(enables(backend.mutations.dropFirst(before)) == ["enable 2", "enable 4"])
    expectDeskRestored(backend)
}

@Test func naiveOnlineGatedRestoreWouldFail() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count

    for record in recorded where !backend.legacyIsOnline(record.id) {
        try backend.setEnabled(record.id, true)
    }

    #expect(backend.mutations.count == before, "The per-ID check says online for both, so nothing was enabled")
    #expect(backend.topology().displays.map(\.kind) == [.osFallback], "And both monitors are still dark")
}

@Test func restoreWithVirtualStillAliveSucceeds() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    let screen = addScreen(backend)
    try await DisplayOperations(backend: backend, clock: AutoAdvancingClock()).setMain(screen)
    try bothOff(backend)
    #expect(backend.topology().main?.id == screen)
    let before = backend.mutations.count

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    expectDeskRestored(backend)
    #expect(backend.topology().display(screen)?.isOnline == true, "The restorer leaves the screen alone")
    #expect(backend.topology().display(screen)?.origin != lgOrigin, "macOS moved it aside")
    #expect(
        !backend.mutations.dropFirst(before).contains { $0.contains("origin \(screen) ") },
        "The restorer doesn't position it"
    )
}

// MARK: Unstable displays

@Test(arguments: [2, 20, 100])
func flappingDisplayRetriesUntilVerified(offlineReads: Int) async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.scriptFlap(lg, offlineReads: offlineReads)

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    #expect(!backend.mutations.contains { $0.hasPrefix("commit failed") }, "It never committed while the LG was offline")
    expectDeskRestored(backend)
}

/// The spike's second run: every enable succeeded and everything read online, and a moment later one
/// display was gone. Step 2 is already over by then, so step 4 is what has to wait for it.
@Test func displayThatDropsAfterAllReadOnlineIsWaitedFor() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.scriptFlap(m34, offlineReads: 12)
    let before = backend.mutations.count

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    #expect(report.attempts == 1)
    #expect(enables(backend.mutations.dropFirst(before)) == ["enable 2", "enable 4"], "Step 3 didn't run")
    #expect(!backend.mutations.contains { $0.hasPrefix("commit failed") })
    expectDeskRestored(backend)
}

@Test func transactionFailure1001Retries() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    var script = ScriptedBackend.Script()
    script.commitFailures = 1
    let power = FakePowerAssertions()

    let report = await restorer(ScriptedBackend(inner, script: script), power: power).restore(recorded)

    #expect(report.attempts == 2)
    #expect(report.verified)
    #expect(power.declareCount == 2, "Once at the start, and once after the failed commit")
    expectDeskRestored(inner)
}

@Test func arrangementThatDoesNotStickIsRetried() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try inner.commit([.mode(lg, lg144)])
    try bothOff(inner)
    var script = ScriptedBackend.Script()
    script.ignoredCommits = 2

    let report = await restorer(ScriptedBackend(inner, script: script)).restore(recorded)

    #expect(report.attempts == 3)
    #expect(report.verified)
    expectDeskRestored(inner)
}

@Test func arrangementThatNeverSticksStopsAfterEightAttempts() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try inner.commit([.mode(lg, lg144)])
    try bothOff(inner)
    var script = ScriptedBackend.Script()
    script.ignoredCommits = .max

    let report = await restorer(ScriptedBackend(inner, script: script)).restore(recorded)

    #expect(report.attempts == 8)
    #expect(!report.verified)
    #expect(report.anyReturned)
    #expect(report.restored == [lg, m34])
}

@Test func displayThatNeverSettlesStillEndsInTime() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let reads = Mutex(0)
    var script = ScriptedBackend.Script()
    // The LG reads offline on every other read, for the whole run.
    script.rewrite = { topology in
        let isOffline = reads.withLock {
            $0 += 1
            return $0.isMultiple(of: 2)
        }
        guard isOffline, let index = topology.displays.firstIndex(where: { $0.id == lg }) else { return }
        topology.displays[index].isOnline = false
    }
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(!report.verified)
    #expect(report.anyReturned)
    #expect(report.restored.contains(m34))
    #expect(clock.now().timeIntervalSince(start) < 170, "It has to end before the guardian's 180 s limit")
    #expect(inner.topology().display(m34)?.origin == m34Origin, "The steady monitor still gets arranged")
    #expect(!inner.mutations.contains { $0.contains("origin 2 ") }, "The unsettled one doesn't get committed")
}

/// One read at step 4's limit mustn't decide that a display has stayed away.
@Test func displayGoingOnAndOffForTheWholeRunIsNotVerified() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var script = ScriptedBackend.Script()
    // The LG is on for 1.2 s and off for 1.0 s, which is never the 1.5 s step 4 asks for.
    script.rewrite = { topology in
        let phase = clock.now().timeIntervalSince(start).truncatingRemainder(dividingBy: 2.2)
        guard phase >= 1.2, let index = topology.displays.firstIndex(where: { $0.id == lg }) else { return }
        topology.displays[index].isOnline = false
    }

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(!report.verified)
    #expect(report.anyReturned)
    #expect(clock.now().timeIntervalSince(start) < 170)
    #expect(inner.topology().display(m34)?.origin == m34Origin, "The steady monitor still gets arranged")
}

/// The run used to end at 21.3 s, verified, with the LG coming back at 25 s and staying at 144 Hz.
@Test func displayReturningLateIsWaitedForAndGetsItsRecordedMode() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try inner.commit([.mode(lg, lg144)])
    try bothOff(inner)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var script = ScriptedBackend.Script()
    script.rewrite = { topology in
        guard clock.now().timeIntervalSince(start) < 25,
            let index = topology.displays.firstIndex(where: { $0.id == lg })
        else { return }
        topology.displays[index].isOnline = false
    }

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    #expect(clock.now().timeIntervalSince(start) >= 25)
    expectDeskRestored(inner)
}

@Test func displayThatDropsOutGetsAnotherEnable() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count
    let dropped = Mutex(false)
    // Everything reads online at 1 s, and then the LG goes off and doesn't come back by itself.
    let clock = HookClock { [backend] elapsed in
        guard elapsed >= 1.2 else { return }
        let isFirst = dropped.withLock { dropped in
            defer { dropped = true }
            return !dropped
        }
        if isFirst { try? backend.setEnabled(lg, false) }
    }

    let report = await restorer(backend, clock: clock).restore(recorded)

    #expect(enables(backend.mutations.dropFirst(before)) == ["enable 2", "enable 4", "enable 2"])
    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    expectDeskRestored(backend)
}

@Test func displayHiddenByTheFallbackGetsAnotherEnableByRecordedID() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count
    let dropped = Mutex(false)
    // Both go off at once, so the fallback comes up and no list shows either of them.
    let clock = HookClock { [backend] elapsed in
        guard elapsed >= 1.2 else { return }
        let isFirst = dropped.withLock { dropped in
            defer { dropped = true }
            return !dropped
        }
        if isFirst { try? bothOff(backend) }
    }

    let report = await restorer(backend, clock: clock).restore(recorded)

    #expect(enables(backend.mutations.dropFirst(before)).prefix(4) == ["enable 2", "enable 4", "enable 2", "enable 4"])
    #expect(report.verified)
    expectDeskRestored(backend)
}

@Test func displayThatReturnsThenLeavesTheListIsMissing() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let reads = Mutex(0)
    var script = ScriptedBackend.Script()
    // The M34WQ comes back, and a few reads later is unplugged, so it's on no list.
    script.rewrite = { topology in
        let isGone = reads.withLock {
            $0 += 1
            return $0 > 6
        }
        if isGone { topology.displays.removeAll { $0.id == m34 } }
    }
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(report.restored == [lg])
    #expect(report.missing == recorded.filter { $0.id == m34 })
    #expect(report.verified)
    #expect(!inner.mutations.contains { $0.contains("origin 4 ") }, "A commit naming it would have failed")
    #expect(clock.now().timeIntervalSince(start) < 120)
}

@Test func displayThatReturnsThenStaysDarkOnTheListIsNotVerified() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let reads = Mutex(0)
    var script = ScriptedBackend.Script()
    // The M34WQ comes back, and a few reads later reads offline for good.
    script.rewrite = { topology in
        let isGone = reads.withLock {
            $0 += 1
            return $0 > 6
        }
        guard isGone, let index = topology.displays.firstIndex(where: { $0.id == m34 }) else { return }
        topology.displays[index].isOnline = false
    }
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(report.restored == [lg])
    #expect(report.stillDark == recorded.filter { $0.id == m34 })
    #expect(report.missing.isEmpty, "It's still plugged in, so it isn't missing: it's dark")
    #expect(!report.verified)
    #expect(!inner.mutations.contains { $0.contains("origin 4 ") }, "A commit naming it would have failed")
    #expect(clock.now().timeIntervalSince(start) < 120)
}

// MARK: What gets restored

@Test func restoresRecordedRateNotCurrent() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try backend.commit([.mode(lg, lg144)])
    try bothOff(backend)

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(backend.topology().display(lg)?.mode?.refreshHz == 120)
    #expect(backend.mutations.last?.contains("mode 2 2560x1440@120") == true)
    #expect(backend.mutations.last?.contains("mode 4") == false, "The M34WQ's mode didn't differ")
}

@Test func recordedModeNoLongerOfferedIsSkippedAndTheOriginStillApplies() async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    let m34At100 = mode(3440, 1440, hz: 100)
    var seed = desk.topology()
    let index = try #require(seed.displays.firstIndex { $0.id == m34 })
    seed.displays[index].mode = m34At100
    let backend = SimulatedDisplayBackend(
        seed: seed,
        modes: [
            lg: desk.modes(of: lg),
            m34: desk.modes(of: m34).filter { $0.refreshHz.rounded() != 144 },
        ]
    )
    try backend.commit([.mode(lg, lg144), .origin(m34, DisplayOrigin(x: 0, y: 1440))])
    let before = backend.mutations.count
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(backend, clock: clock).restore(recorded)
    let changes = backend.mutations.dropFirst(before)

    #expect(report.verified, "The M34WQ can't do better than its origin, and that read back")
    #expect(report.attempts > 1, "It kept trying for the mode first")
    #expect(clock.now().timeIntervalSince(start) >= 10)
    #expect(report.modeNotOffered == recorded.filter { $0.id == m34 })
    #expect(report.restored == [lg, m34])
    #expect(!changes.contains { $0.hasPrefix("commit failed") })
    #expect(!changes.contains { $0.contains("mode 4 ") })
    #expect(changes.contains { $0.contains("mode 2 2560x1440@120") }, "The LG's mode is still offered, so it's set")
    #expect(backend.topology().display(m34)?.origin == m34Origin)
    #expect(backend.topology().display(m34)?.mode?.matches(m34At100) == true)
    #expect(backend.topology().display(lg)?.mode?.matches(lg120) == true)
}

/// The hardware run of 2026-11-07: the restore child read the M34WQ while it was off, and its copy of
/// the display stayed stale after the monitor returned, with no modes. An empty list is a failed read,
/// so every commit asked for the mode, every commit failed, and eight attempts arranged nothing. Now
/// each commit still sets the origins, and once the commits have said for 10 s that the mode isn't
/// there, the display goes without it.
@Test func aStaleEmptyModeListStillGetsTheOriginsAndGoesWithoutTheMode() async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    let m34At100 = mode(3440, 1440, hz: 100)
    var seed = desk.topology()
    let index = try #require(seed.displays.firstIndex { $0.id == m34 })
    seed.displays[index].mode = m34At100
    let inner = SimulatedDisplayBackend(seed: seed, modes: [lg: desk.modes(of: lg), m34: [m34At100]])
    try inner.commit([.origin(m34, DisplayOrigin(x: 0, y: 1440))])
    var script = ScriptedBackend.Script()
    script.rewriteModes = { id, modes in id == m34 ? [] : modes }
    let before = inner.mutations.count
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)
    let changes = inner.mutations.dropFirst(before)

    let firstApplied = changes.first { $0.hasPrefix("commit ") && !$0.contains("left out") && !$0.contains("failed") }
    #expect(firstApplied?.contains("origin 4 (-446,1440)") == true, "The first commit already set the origin")
    #expect(changes.contains("commit left out mode 4 3440x1440@144"), "It asked for the mode first")
    #expect(report.verified)
    #expect(report.modeNotOffered == recorded.filter { $0.id == m34 })
    #expect(clock.now().timeIntervalSince(start) >= 10)
    #expect(inner.topology().display(m34)?.origin == m34Origin)
    #expect(inner.topology().display(lg)?.origin == lgOrigin)
}

/// An empty list says nothing about the mode, so a commit that fails for another reason mustn't count
/// toward the 10 seconds. Here every commit fails, and the mode is asked for to the end.
@Test func anEmptyModeListWithFailingCommitsNeverSkipsTheMode() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try inner.commit([.mode(m34, mode(3440, 1440, hz: 100)), .origin(m34, DisplayOrigin(x: 0, y: 1440))])
    var script = ScriptedBackend.Script()
    script.rewriteModes = { id, modes in id == m34 ? [] : modes }
    script.commitFailures = .max
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(!report.verified)
    #expect(clock.now().timeIntervalSince(start) >= 10, "Long enough that the 10 seconds would have run out")
    #expect(report.modeNotOffered.isEmpty)
}

/// A monitor's list can lack the recorded mode just after it returns, and that must not leave the LG
/// at 144 Hz with `rescued` written.
@Test func modeMissingFromTheListAtFirstIsRetriedAndApplied() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try inner.commit([.mode(lg, lg144)])
    try bothOff(inner)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var script = ScriptedBackend.Script()
    script.rewriteModes = { id, modes in
        guard id == lg, clock.now().timeIntervalSince(start) < 5 else { return modes }
        return modes.filter { $0.refreshHz.rounded() != 120 }
    }

    let report = await restorer(ScriptedBackend(inner, script: script), clock: clock).restore(recorded)

    #expect(report.verified)
    #expect(report.modeNotOffered.isEmpty)
    #expect(report.attempts > 1, "The first attempts found the list without it")
    #expect(!inner.mutations.contains { $0.hasPrefix("commit failed") })
    expectDeskRestored(inner)
}

@Test func anOfferedModeIsNotReportedAsSkipped() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try backend.commit([.mode(lg, lg144)])

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(report.modeNotOffered.isEmpty)
    expectDeskRestored(backend)
}

@Test func restoreTreatsSleepingDisplayAsPresent() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try backend.commit([.origin(m34, DisplayOrigin(x: 2560, y: 0))])
    backend.setAsleep(m34, true)
    let before = backend.mutations.count

    let report = await restorer(backend).restore(recorded)

    #expect(enables(backend.mutations.dropFirst(before)).isEmpty, "Online but asleep needs no enable")
    #expect(report.verified)
    #expect(backend.topology().display(m34)?.origin == m34Origin)
    #expect(backend.topology().display(m34)?.isActive == false, "And it's still asleep")
}

@Test func restoreReportsMissingDisplayAndFinishes() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.removePhysical(m34)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(backend, clock: clock).restore(recorded)

    #expect(report.missing == recorded.filter { $0.id == m34 })
    #expect(report.restored == [lg])
    #expect(report.verified)
    #expect(report.anyReturned)
    #expect(backend.topology().display(lg)?.origin == lgOrigin)
    #expect(clock.now().timeIntervalSince(start) < 120)
}

@Test func missingOldMainStillVerifiesTheRest() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.removePhysical(lg)

    let report = await restorer(backend).restore(recorded)

    // With no display at (0,0), macOS shifts everything to keep a main there, so the M34WQ can't read
    // back as (-446,1440). That mustn't count as a failed arrangement.
    #expect(report.missing == recorded.filter { $0.id == lg })
    #expect(report.restored == [m34])
    #expect(report.attempts == 1)
    #expect(report.verified)
}

@Test func idChangeFallsBackToIdentityMatch() async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    let newID: DisplayID = 9
    var seed = desk.topology()
    let index = try #require(seed.displays.firstIndex { $0.id == lg })
    seed.displays[index].id = newID
    seed.displays[index].isOnline = false
    seed.displays[index].isActive = false
    seed.displays[index].isMain = false
    let backend = SimulatedDisplayBackend(seed: seed, modes: [newID: desk.modes(of: lg), m34: desk.modes(of: m34)])

    let report = await restorer(backend).restore(recorded)

    #expect(enables(backend.mutations).prefix(4) == [
        "enable 2 failed 1001", "enable 2 failed 1001", "enable 2 failed 1001", "enable 9",
    ])
    #expect(report.restored == [newID, m34])
    #expect(report.missing.isEmpty)
    #expect(report.verified)
    #expect(backend.topology().display(newID)?.origin == lgOrigin)
    #expect(backend.topology().display(m34)?.origin == m34Origin)
}

@Test func anotherMonitorUnderTheRecordedIDIsNotTheRecordedDisplay() async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    var seed = desk.topology()
    // A different monitor has taken ID 4 since the session started.
    let index = try #require(seed.displays.firstIndex { $0.id == m34 })
    seed.displays[index].identity.serial += 1
    let backend = SimulatedDisplayBackend(seed: seed, modes: [lg: desk.modes(of: lg), m34: desk.modes(of: m34)])

    let report = await restorer(backend).restore(recorded)

    #expect(report.restored == [lg])
    #expect(report.missing == recorded.filter { $0.id == m34 })
    #expect(!backend.mutations.contains { $0.contains("origin 4 ") }, "It must not get the recorded display's origin")
}

@Test func vanishedDisplayReadingOnlineIsNotPresent() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    inner.removePhysical(m34)
    var script = ScriptedBackend.Script()
    // The recorded ID goes on reading online, as the all-ones empty pipe a vanished display turns into.
    script.rewrite = { topology in
        topology.displays.append(
            DisplaySnapshot(
                id: m34,
                identity: DisplayIdentity(vendor: 0xFFFF_FFFF, model: 0xFFFF_FFFF, serial: 0xFFFF_FFFF),
                kind: .emptyPipe,
                isOnline: true,
                isActive: false,
                isMain: false,
                isAsleep: false,
                origin: DisplayOrigin(x: 0, y: 0)
            )
        )
    }

    let report = await restorer(ScriptedBackend(inner, script: script)).restore(recorded)

    #expect(report.missing == recorded.filter { $0.id == m34 })
    #expect(report.restored == [lg])
    #expect(report.verified)
    #expect(!inner.mutations.contains { $0.hasPrefix("commit failed") })
}

/// With the list unread, a monitor that's off looks like one that has been unplugged.
@Test func failedListReadAtReadBackDoesNotMakeADarkMonitorLookUnplugged() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    inner.setEnableFails(m34, .max)
    var script = ScriptedBackend.Script()
    script.beforeCommit = { [inner] in inner.setListReadFails(1) }

    let report = await restorer(ScriptedBackend(inner, script: script)).restore(recorded)

    #expect(!report.verified)
    #expect(report.restored == [lg])
    #expect(report.stillDark == recorded.filter { $0.id == m34 })
    #expect(report.missing.isEmpty)
}

@Test func failedListReadAtTheEndDoesNotCallAMonitorMissing() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(m34, .max)
    backend.setListReadFails(.max)

    let report = await restorer(backend).restore(recorded)

    #expect(!report.verified)
    #expect(report.restored == [lg])
    #expect(report.stillDark == recorded.filter { $0.id == m34 })
    #expect(report.missing.isEmpty)
}

@Test func failedListReadFailsOneReadBackEvenWithEverythingOnline() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let failures = Mutex(1)
    var script = ScriptedBackend.Script()
    script.beforeCommit = { [inner] in
        let isDue = failures.withLock { left in
            defer { left = 0 }
            return left > 0
        }
        if isDue { inner.setListReadFails(1) }
    }

    let report = await restorer(ScriptedBackend(inner, script: script)).restore(recorded)

    #expect(report.verified)
    #expect(report.attempts == 2)
    expectDeskRestored(inner)
}

/// Neither the recorded ID nor the recorded port lists it, and a listing that only has the same vendor,
/// model and serial is no sign of a dark monitor: a monitor plugged in elsewhere comes up lit by itself.
/// It still gets an enable, as every offline display does, but it can't hold up the read-back.
@Test func offlineListingOnAnotherPortGetsAnEnableButIsMissingNotDark() async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    let newID: DisplayID = 9
    var seed = desk.topology()
    let index = try #require(seed.displays.firstIndex { $0.id == m34 })
    seed.displays[index].id = newID
    seed.displays[index].identity.registryLocation = "IOService:/another/port"
    seed.displays[index].isOnline = false
    seed.displays[index].isActive = false
    let backend = SimulatedDisplayBackend(seed: seed, modes: [lg: desk.modes(of: lg), newID: desk.modes(of: m34)])
    backend.setEnableFails(newID, .max)

    let report = await restorer(backend).restore(recorded)

    #expect(enables(backend.mutations).contains("enable 9 failed 1014"))
    #expect(report.verified)
    #expect(report.restored == [lg])
    #expect(report.missing == recorded.filter { $0.id == m34 })
    #expect(report.stillDark.isEmpty)
}

/// Dark under the recorded ID, or at the recorded port under a new one, is still dark.
@Test(arguments: [false, true])
func offlineListingUnderTheRecordedIDOrAtTheRecordedPortIsDark(newID: Bool) async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    let id: DisplayID = newID ? 9 : m34
    var seed = desk.topology()
    let index = try #require(seed.displays.firstIndex { $0.id == m34 })
    seed.displays[index].id = id
    seed.displays[index].isOnline = false
    seed.displays[index].isActive = false
    let backend = SimulatedDisplayBackend(seed: seed, modes: [lg: desk.modes(of: lg), id: desk.modes(of: m34)])
    backend.setEnableFails(id, .max)

    let report = await restorer(backend).restore(recorded)

    #expect(!report.verified)
    #expect(report.restored == [lg])
    #expect(report.stillDark == recorded.filter { $0.id == m34 })
    #expect(report.missing.isEmpty)
}

@Test func noDisplayReturnsReportsAnyReturnedFalse() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)
    backend.setEnableFails(m34, .max)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(backend, clock: clock).restore(recorded)

    // The fallback is up, and it hides every list, so nothing shows they've gone.
    #expect(report == RestoreReport(restored: [], missing: [], stillDark: recorded, attempts: 0, verified: false, anyReturned: false))
    #expect(clock.now().timeIntervalSince(start) < 60)
}

@Test func nothingRecordedHasNothingToBringBack() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let power = FakePowerAssertions()

    let report = await restorer(backend, power: power).restore([])

    #expect(report == RestoreReport(restored: [], missing: [], attempts: 0, verified: true, anyReturned: true))
    #expect(backend.mutations.isEmpty)
    #expect(power.calls.isEmpty)
}

// MARK: Sleep and enable failures

@Test func declaresUserActivityFirst() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count
    let mutationsAtDeclare = Mutex<[Int]>([])
    let power = FakePowerAssertions(onDeclare: { [backend] in
        let count = backend.mutations.count
        mutationsAtDeclare.withLock { $0.append(count) }
    })

    _ = await restorer(backend, power: power).restore(recorded)

    #expect(power.calls.first == "declare")
    #expect(mutationsAtDeclare.withLock { $0.first } == before, "Before any enable")
}

@Test func restoreWakesDisplaysWhenEverythingIsAsleep() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)
    #expect(throws: DisplayBackendError.self, "With nothing awake, an enable fails") {
        try backend.setEnabled(lg, true)
    }

    let power = FakePowerAssertions(onDeclare: backend.wakeAll)
    let report = await restorer(backend, power: power).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    expectDeskRestored(backend)
}

/// The first declare doesn't wake anything in time, so the wake wait runs out and the first enable
/// fails, and the declare before its retry is the one that works.
@Test func wakeThatTakesASecondDeclareStillRestores() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)
    let before = backend.mutations.count
    let declares = Mutex(0)
    let power = FakePowerAssertions(onDeclare: { [backend] in
        let count = declares.withLock {
            $0 += 1
            return $0
        }
        if count >= 2 { backend.wakeAll() }
    })
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(backend, clock: clock, power: power).restore(recorded)

    #expect(enables(backend.mutations.dropFirst(before)) == ["enable 2 failed 1014", "enable 2", "enable 4"])
    #expect(report.verified)
    #expect(clock.now().timeIntervalSince(start) >= 5, "It waited for the first declare to work")
    expectDeskRestored(backend)
}

@Test func enableFailureIsRetriedAfterDeclaringActivity() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, 1)
    let before = backend.mutations.count
    let power = FakePowerAssertions()

    let report = await restorer(backend, power: power).restore(recorded)

    #expect(enables(backend.mutations.dropFirst(before)) == ["enable 2 failed 1014", "enable 2", "enable 4"])
    #expect(power.declareCount == 2, "Once at the start, and once for the retry")
    #expect(report.verified)
}

@Test func enableFailingThreeTimesMovesOnToNextDisplay() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, 3)
    let before = backend.mutations.count

    let report = await restorer(backend).restore(recorded)

    #expect(enables(backend.mutations.dropFirst(before)) == [
        "enable 2 failed 1014", "enable 2 failed 1014", "enable 2 failed 1014", "enable 4",
        // Step 3 gets it back, as an offline display with a vendor.
        "enable 2",
    ])
    #expect(report.verified)
    expectDeskRestored(backend)
}

@Test func enableThatAlwaysFailsIsNotVerifiedAndTheOtherDisplayIsStillRestored() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    backend.setEnableFails(lg, .max)

    let report = await restorer(backend).restore(recorded)

    #expect(report.restored == [m34])
    #expect(report.stillDark == recorded.filter { $0.id == lg })
    #expect(report.missing.isEmpty, "The LG is still on the list, so it's dark, not unplugged")
    #expect(report.anyReturned)
    #expect(!report.verified)
    #expect(report.attempts == 8)
    #expect(backend.topology().display(m34)?.mode?.matches(m34144) == true)
}

@Test func holdsNoDisplaySleepForWholeRun() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let power = FakePowerAssertions()
    let holds = Mutex<[Int]>([])
    var script = ScriptedBackend.Script()
    script.beforeCall = {
        let held = power.activeHoldCount
        holds.withLock { $0.append(held) }
    }
    let clock = HookClock { _ in
        let held = power.activeHoldCount
        holds.withLock { $0.append(held) }
    }

    _ = await restorer(ScriptedBackend(inner, script: script), clock: clock, power: power).restore(recorded)

    let seen = holds.withLock { $0 }
    #expect(seen.count > 5)
    #expect(seen.allSatisfy { $0 == 1 }, "Held at every call and every wait")
    #expect(power.activeHoldCount == 0, "Released at the end")
    #expect(power.calls.last?.hasPrefix("release") == true)
}

// MARK: Heartbeat

/// Runs `body` with a callback that records the clock, and checks that no gap between `start`, the
/// beats and the end of the run is over 2 seconds of clock time.
private func expectSteadyHeartbeat(
    clock: AutoAdvancingClock,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (@escaping @Sendable () -> Void) async -> Void
) async {
    let beats = Mutex<[Date]>([clock.now()])
    await body {
        let now = clock.now()
        beats.withLock { $0.append(now) }
    }
    let times = beats.withLock { $0 } + [clock.now()]
    let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
    #expect(times.count > 3, sourceLocation: sourceLocation)
    #expect((gaps.max() ?? 0) <= 2, "Longest gap \(gaps.max() ?? 0) s", sourceLocation: sourceLocation)
}

@Test func progressCallbackFires() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    // This takes every wait: a failed enable, 15 s for all online, 3 s after step 3, and the 30 s one.
    backend.removePhysical(m34)
    backend.scriptFlap(lg, offlineReads: 100)
    let clock = AutoAdvancingClock()

    await expectSteadyHeartbeat(clock: clock) { beat in
        let report = await restorer(backend, clock: clock, onProgress: beat).restore(recorded)
        #expect(report.verified)
    }
}

@Test func heartbeatKeepsGoingThroughABlockingCall() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let beats = Mutex(0)
    let beatsDuringCall = Mutex<Int?>(nil)
    var script = ScriptedBackend.Script()
    // A live call can block for about 10 seconds, and no clock moves in the meantime.
    script.beforeCall = {
        let alreadyBlocked = beatsDuringCall.withLock { $0 != nil }
        guard !alreadyBlocked else { return }
        let before = beats.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.5)
        let after = beats.withLock { $0 }
        beatsDuringCall.withLock { $0 = after - before }
    }

    _ = await restorer(
        ScriptedBackend(inner, script: script),
        blockedCallHeartbeat: BlockedCallHeartbeat(interval: 0.05),
        onProgress: { beats.withLock { $0 += 1 } }
    ).restore(recorded)

    #expect((beatsDuringCall.withLock { $0 } ?? 0) >= 1)
}

/// A call that never returns must not look like a restore making progress, or the guardian would
/// wait on it forever.
@Test func heartbeatStopsInsideAHungCall() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: inner)
    try bothOff(inner)
    let beats = Mutex(0)
    let counts = Mutex<(atStart: Int, pastLimit: Int, later: Int)?>(nil)
    var script = ScriptedBackend.Script()
    script.beforeCall = {
        let alreadyBlocked = counts.withLock { $0 != nil }
        guard !alreadyBlocked else { return }
        let atStart = beats.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.9)
        let pastLimit = beats.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.3)
        let later = beats.withLock { $0 }
        counts.withLock { $0 = (atStart, pastLimit, later) }
    }

    _ = await restorer(
        ScriptedBackend(inner, script: script),
        blockedCallHeartbeat: BlockedCallHeartbeat(interval: 0.05, limit: 0.5),
        onProgress: { beats.withLock { $0 += 1 } }
    ).restore(recorded)

    let seen = try #require(counts.withLock { $0 })
    #expect(seen.pastLimit > seen.atStart, "It beat while the call was within the limit")
    #expect(seen.later == seen.pastLimit, "And stopped once it was past it")
}

// MARK: Order and locking

@Test func oldMainGoesFirst() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count

    let report = await restorer(backend).restore(Array(recorded.reversed()))

    #expect(recorded.first(where: \.wasMain)?.id == lg)
    #expect(enables(backend.mutations.dropFirst(before)) == ["enable 2", "enable 4"])
    #expect(report.restored == [lg, m34])
}

@Test func takesLockAndWaitsForHolder() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count
    let lockURL = temporaryLockURL()
    let holder = try LockHolder(url: lockURL)
    let mutationsAtRelease = Mutex<Int?>(nil)
    let clock = HookClock { [backend] elapsed in
        guard elapsed >= 5 else { return }
        let alreadyReleased = mutationsAtRelease.withLock { $0 != nil }
        guard !alreadyReleased else { return }
        let count = backend.mutations.count
        mutationsAtRelease.withLock { $0 = count }
        holder.release()
    }

    let report = await restorer(backend, clock: clock, lockURL: lockURL).restore(recorded)

    #expect(mutationsAtRelease.withLock { $0 } == before, "Nothing happened while the other restorer held the lock")
    #expect(report.verified)
    expectDeskRestored(backend)

    let afterwards = FileLock(url: lockURL)
    #expect(afterwards.tryLock(), "The run let go of it")
}

@Test func lockHeldTooLongGivesUp() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let before = backend.mutations.count
    let lockURL = temporaryLockURL()
    let holder = try LockHolder(url: lockURL)
    defer { holder.release() }
    let clock = AutoAdvancingClock()
    let start = clock.now()
    let power = FakePowerAssertions()

    await expectSteadyHeartbeat(clock: clock) { beat in
        let report = await restorer(backend, clock: clock, power: power, lockURL: lockURL, onProgress: beat)
            .restore(recorded)
        #expect(report == RestoreReport(restored: [], missing: [], stillDark: recorded, attempts: 0, verified: false, anyReturned: false))
    }

    let elapsed = clock.now().timeIntervalSince(start)
    #expect(elapsed >= 60 && elapsed < 61)
    #expect(backend.mutations.count == before)
    #expect(power.calls.isEmpty)
}

@Test func lockThatCannotBeCreatedDoesNotBlockTheRestore() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let report = await restorer(backend, clock: clock, lockURL: try unusableLockURL()).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg, m34])
    #expect(clock.now().timeIntervalSince(start) < 10, "It didn't sit out the lock wait")
    expectDeskRestored(backend)
}

@Test func lockGiveUpStillSaysWhatIsOnline() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try backend.setEnabled(m34, false)
    let lockURL = temporaryLockURL()
    let holder = try LockHolder(url: lockURL)
    defer { holder.release() }

    let report = await restorer(backend, lockURL: lockURL).restore(recorded)

    #expect(report.restored == [lg])
    #expect(report.stillDark == recorded.filter { $0.id == m34 })
    #expect(report.missing.isEmpty)
    #expect(report.anyReturned)
    #expect(!report.verified)
}

@Test func cancelledRestoreStopsAndLetsGo() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    try bothOff(backend)
    let power = FakePowerAssertions()
    let lockURL = temporaryLockURL()

    let report = await restorer(backend, clock: CancelledClock(), power: power, lockURL: lockURL).restore(recorded)

    #expect(!report.verified)
    #expect(power.activeHoldCount == 0)
    let afterwards = FileLock(url: lockURL)
    #expect(afterwards.tryLock())
}
