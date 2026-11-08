import ADDisplayConfig
import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import ADVirtualScreens
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionResumeTests {
    /// A session running, then the app dead with its screen gone, and a new process about to resume.
    private func crashedSession() async throws -> SessionRig {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        rig.crash()
        rig.relaunch()
        return rig
    }

    @Test func resumeNoLedgerDoesNothing() async throws {
        let rig = try SessionRig()

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.mutations.isEmpty)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.changes == 0)
        #expect(rig.session.status().state == .idle)
    }

    @Test func resumeStaleBootDiscards() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active, bootSession: "boot-0"))

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(try rig.ledger == nil)
        #expect(rig.mutations.isEmpty)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.session.status().state == .idle)
    }

    @Test func resumeSafeModeRestoresAndClears() async throws {
        let rig = try await crashedSession()
        let additions = rig.countOfPrefix("addVirtual")

        await rig.session.resumeAtLaunch(safeMode: true)

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(rig.countOfPrefix("addVirtual") == additions, "Safe mode skips screens")
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func resumeRescuedClears() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .rescued))

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(try rig.ledger == nil)
        #expect(rig.mutations.isEmpty)
    }

    @Test func resumeStartingRunsEnd() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .starting))
        try rig.simulated.setEnabled(m34, false)
        try rig.simulated.setEnabled(lg, false)

        await rig.session.resumeAtLaunch(safeMode: false)

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.changes == 1)
    }

    @Test func resumeEndingFinishes() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .ending))
        try rig.simulated.setEnabled(m34, false)

        await rig.session.resumeAtLaunch(safeMode: false)

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    /// A rescue through the helper kills the app, and the guardian can relaunch it. That app must not
    /// take the session back up and turn the monitors off again, whatever became of the rescue.
    @Test func resumeAfterAFailedRescueEndsTheSessionAndDisconnectsNothing() async throws {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        #expect(try rig.ledger?.state == .active)
        rig.crash()
        rig.simulated.setEnableFails(lg, .max)
        rig.simulated.setEnableFails(m34, .max)

        let rescued = await RestoreJob(
            ledger: rig.store,
            registryURL: rig.folder.appending(component: "devices.json", directoryHint: .notDirectory),
            backend: rig.backend,
            processes: rig.processes,
            clock: rig.clock,
            power: rig.power,
            lockURL: rig.lockURL,
            bootSession: boot
        ).run()

        #expect(!rescued)
        #expect(rig.processes.killed == [appRef])
        #expect(try rig.ledger?.state == .ending)

        rig.simulated.setEnableFails(lg, 0)
        rig.simulated.setEnableFails(m34, 0)
        rig.relaunch()
        let disconnects = rig.countOfPrefix("disable")
        let additions = rig.countOfPrefix("addVirtual")

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.countOfPrefix("disable") == disconnects)
        #expect(rig.countOfPrefix("addVirtual") == additions, "It doesn't bring the screen back either")
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func resumeActiveDeadOwnerEnds() async throws {
        let rig = try await crashedSession()
        rig.processes.alive.remove(ownerRef)
        let additions = rig.countOfPrefix("addVirtual")

        await rig.session.resumeAtLaunch(safeMode: false)

        rig.expectDeskRestored()
        #expect(rig.countOfPrefix("addVirtual") == additions)
        #expect(try rig.ledger == nil)
    }

    @Test func resumeActiveRecreatesWithSameIdentityAndSize() async throws {
        let rig = try SessionRig()
        let first = try await rig.session.start(parsec())
        let firstID = try #require(first.displayID)
        rig.crash()
        rig.relaunch()
        let changes = rig.changes

        await rig.session.resumeAtLaunch(safeMode: false)

        let status = rig.session.status()
        let id = try #require(status.displayID)
        #expect(status.state == .active)
        #expect(id != firstID)
        #expect(status.uuid == first.uuid)
        #expect(status.looksLike == first.looksLike)
        #expect(status.pixels == first.pixels)
        #expect(status.hz == first.hz)
        #expect(status.physicalOff == [lg, m34])
        rig.expectMonitorsOff()
        #expect(rig.simulated.topology().main?.id == id)
        #expect(rig.changes == changes + 1)
        #expect(try rig.ledger?.state == .active)
        #expect(try rig.ledger?.app == relaunchedRef)
    }

    @Test func resumeWritesAppReferenceBeforeAnyDisplayStep() async throws {
        let rig = try await crashedSession()
        let mutations = rig.mutations.count
        let saves = rig.store.saves.count

        await rig.session.resumeAtLaunch(safeMode: false)

        let first = rig.store.saves[saves]
        #expect(first.ledger.app == relaunchedRef)
        #expect(first.mutationsBefore == mutations)
        #expect(rig.mutations.count > mutations, "It did go on to change something")
    }

    @Test func resumeWritesAppReferenceBeforeEndingToo() async throws {
        let rig = try await crashedSession()
        rig.processes.alive.remove(ownerRef)
        let mutations = rig.mutations.count
        let saves = rig.store.saves.count

        await rig.session.resumeAtLaunch(safeMode: false)

        let first = rig.store.saves[saves]
        #expect(first.ledger.app == relaunchedRef)
        #expect(first.ledger.state == .active)
        #expect(first.mutationsBefore == mutations)
    }

    @Test func resumeChangesNothingIfAppReferenceCannotBeWritten() async throws {
        let rig = try await crashedSession()
        let mutations = rig.mutations
        rig.memory.failOnSave = true

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.mutations == mutations)
        #expect(try rig.ledger?.app == appRef, "The guardian carries on from what it knows")
    }

    @Test func resumeActiveReDisconnectsAnythingBackOn() async throws {
        let rig = try await crashedSession()
        rig.simulated.simulateWake(reconnecting: [lg, m34])
        #expect(rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))

        await rig.session.resumeAtLaunch(safeMode: false)

        rig.expectMonitorsOff()
        #expect(rig.session.status().state == .active)
        #expect(rig.simulated.topology().main?.id == (try rig.screenID))
    }

    @Test func resumeDeclaresUserActivityBeforeCreating() async throws {
        let rig = try await crashedSession()
        let declares = rig.power.declareCount
        var declaredBeforeCreate = 0
        rig.screens.beforeCreate = { declaredBeforeCreate = rig.power.declareCount }

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(declaredBeforeCreate > declares)
    }

    @Test func resumeKeepsStartedAt() async throws {
        let rig = try await crashedSession()
        let startedAt = try #require(try rig.ledger).startedAt

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(try rig.ledger?.startedAt == startedAt)
    }

    @Test func resumeStartsTheStartupPollOver() async throws {
        let rig = try await crashedSession()
        rig.clock.advance(by: 100)

        await rig.session.resumeAtLaunch(safeMode: false)
        rig.simulated.simulateWake(reconnecting: [lg])
        await rig.session.startupPollTick()

        rig.expectMonitorsOff()
    }

    @Test func aFailedCreateOnResumeEndsTheSession() async throws {
        let rig = try await crashedSession()
        rig.screens.createFailures = 1

        await rig.session.resumeAtLaunch(safeMode: false)

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func aFailedResumeFromActiveMovesLedgerToEnding() async throws {
        let rig = try await crashedSession()
        rig.screens.createFailures = 1
        rig.simulated.setEnableFails(lg, .max)
        rig.simulated.setEnableFails(m34, .max)

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(try rig.ledger?.state == .ending)
        #expect(try rig.ledger?.app == relaunchedRef)
        #expect(rig.session.status().state == .ending)
    }

    @Test func aFailedDisconnectOnResumeEndsTheSession() async throws {
        let rig = try await crashedSession()
        rig.simulated.simulateWake(reconnecting: [lg])
        rig.backend.update { $0.failDisable = [lg] }

        await rig.session.resumeAtLaunch(safeMode: false)

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func resumeRefusesToLeaveNoWorkingDisplay() async throws {
        let rig = try await crashedSession()
        rig.simulated.simulateWake(reconnecting: [lg])
        rig.makeScreenStopCounting()
        let disables = rig.count("disable \(lg)")

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.count("disable \(lg)") == disables, "The check comes before the disconnect")
        #expect(rig.logText.contains("The resume failed: would leave no working display"))
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func resumeSetAsideReconnectsFromTheRegistry() async throws {
        let rig = try await crashedSession()
        rig.memory.setAsideOnNextLoad()

        await rig.session.resumeAtLaunch(safeMode: false)

        let online = rig.simulated.topology().onlineIDs
        #expect(online.isSuperset(of: [lg, m34]))
        #expect(rig.session.status().state == .idle)
        #expect(try rig.ledger == nil)
        #expect(rig.logText.contains("set aside"))
        #expect(rig.logText.contains("The reconnect finished with a physical display online"))
    }

    @Test func resumeSetAsideLogsAReconnectThatBroughtNothingBack() async throws {
        let rig = try await crashedSession()
        rig.simulated.setEnableFails(lg, .max)
        rig.simulated.setEnableFails(m34, .max)
        rig.memory.setAsideOnNextLoad()

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.logText.contains("The reconnect finished with no physical display online"))
    }

    @Test func resumeSetAsideTakesRestoreLock() async throws {
        let rig = try await crashedSession()
        let lockURL = rig.lockURL
        let wasHeld = Recorder<Bool>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, _ in
                let probe = FileLock(url: lockURL)
                wasHeld.append(!probe.tryLock())
                probe.unlock()
            }
        }
        rig.memory.setAsideOnNextLoad()

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(wasHeld.values == [true, true])
    }

    @Test func resumeSetAsideRetriesAFailedEnable() async throws {
        let rig = try await crashedSession()
        rig.simulated.setEnableFails(lg, 1)
        rig.memory.setAsideOnNextLoad()

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.simulated.topology().onlineIDs.contains(lg))
        #expect(rig.count("enable \(lg) failed 1014") == 1)
    }

    @Test func resumeLeavesEverythingAloneIfTheLedgerCannotBeRead() async throws {
        let rig = try await crashedSession()
        let mutations = rig.mutations
        rig.store.failOnLoad = true

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.mutations == mutations)
        #expect(rig.session.status().state == .idle)
    }

    @Test func endAfterAResumeRestoresTheDesk() async throws {
        let rig = try await crashedSession()
        await rig.session.resumeAtLaunch(safeMode: false)

        _ = try await rig.session.end(client: "parsec", force: false, reason: "test")

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    // MARK: A restore running at launch

    private static let waitLine = "a restore is running, so this app leaves the displays to it"

    /// Starts a resume, which the caller has made find `restore.lock` held, and returns once the clock
    /// has moved `seconds` on, or the resume has had 10,000 turns to get there.
    private func resumeWhileARestoreRuns(_ rig: SessionRig, waiting seconds: Double) async -> Task<Void, Never> {
        let resume = Task { await rig.session.resumeAtLaunch(safeMode: false) }
        let started = rig.clock.now()
        var turns = 0
        while rig.clock.now().timeIntervalSince(started) < seconds, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        return resume
    }

    /// The guardian's restore holds `restore.lock` for its whole run, and MenuBarAgent can bring the app
    /// back meanwhile. That app keeps its hands off the displays and the ledger until the restore is
    /// done, then goes by what the ledger says.
    @Test func anAppLaunchingDuringARestoreWaitsThenIdlesOnRescued() async throws {
        let rig = try await crashedSession()
        let restore = FileLock(url: rig.lockURL)
        try #require(restore.tryLock())
        let mutations = rig.mutations.count
        let saves = rig.store.saves.count

        let resume = await resumeWhileARestoreRuns(rig, waiting: 5)

        #expect(rig.logText.contains(Self.waitLine))
        #expect(rig.mutations.count == mutations, "No display call while it waits")
        #expect(rig.store.saves.count == saves, "No ledger write either")
        var rescued = try #require(try rig.ledger)
        rescued.state = .rescued
        try rig.memory.save(rescued)
        restore.unlock()
        await resume.value

        #expect(try rig.ledger == nil, "A rescued ledger is cleared, as at any launch")
        #expect(rig.mutations.count == mutations)
        #expect(rig.session.status().state == .idle)
    }

    @Test func anAppThatWaitedForARestoreFinishesAnEndingLedger() async throws {
        let rig = try await crashedSession()
        let restore = FileLock(url: rig.lockURL)
        try #require(restore.tryLock())

        let resume = await resumeWhileARestoreRuns(rig, waiting: 5)

        #expect(rig.logText.contains(Self.waitLine))
        var ending = try #require(try rig.ledger)
        ending.state = .ending
        try rig.memory.save(ending)
        restore.unlock()
        await resume.value

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    /// A restore stops itself within 190 seconds, so a lock held past 200 isn't one. The app logs that
    /// and goes by the ledger as it reads then, which here still says `active`.
    @Test func aRestoreLockHeldPast200SecondsLetsTheAppGoOn() async throws {
        let rig = try await crashedSession()
        let stuck = FileLock(url: rig.lockURL)
        try #require(stuck.tryLock())
        defer { stuck.unlock() }
        let started = rig.clock.now()

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.clock.now().timeIntervalSince(started) >= 200)
        #expect(rig.logText.contains(Self.waitLine))
        #expect(rig.logText.contains("restore.lock is still held after 200 seconds, so this app goes on"))
        #expect(rig.session.status().state == .active)
        rig.expectMonitorsOff()
    }

    /// With no restore running the app resumes as before, and never holds the lock while it does.
    @Test func aResumeDoesNotHoldTheRestoreLock() async throws {
        let rig = try await crashedSession()
        rig.simulated.simulateWake(reconnecting: [lg, m34])
        let lockURL = rig.lockURL
        let wasHeld = Recorder<Bool>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, _ in
                let probe = FileLock(url: lockURL)
                wasHeld.append(!probe.tryLock())
                probe.unlock()
            }
        }

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(!wasHeld.values.isEmpty, "Or this test proves nothing")
        #expect(wasHeld.values.allSatisfy { !$0 })
        #expect(!rig.logText.contains(Self.waitLine))
        #expect(rig.session.status().state == .active)
        rig.expectMonitorsOff()
    }
}
