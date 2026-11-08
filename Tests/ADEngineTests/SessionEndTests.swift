import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import ADVirtualScreens
import Dispatch
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionEndTests {
    private func started(_ rig: SessionRig, keepOn: [String] = []) async throws {
        _ = try await rig.session.start(parsec(keepOn: keepOn))
    }

    private func end(_ rig: SessionRig) async throws -> EndOutcome {
        try await rig.session.end(client: "parsec", force: false, reason: "test")
    }

    @Test func endRestoresArrangementAndRate() async throws {
        let rig = try SessionRig()
        // The LG sits at the rate it flickers at, and its pin says what a restore brings it back to.
        try rig.simulated.commit([.mode(lg, lg144)])
        try rig.registry.update(from: rig.simulated.topology())
        try rig.registry.pin(uuid: lgUUID, hz: 120)
        try await started(rig)
        let commits = rig.countOfPrefix("commit")

        let outcome = try await end(rig)

        #expect(outcome == EndOutcome())
        #expect(outcome.warning == nil)
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        #expect(rig.session.status().statusLine == "state=idle")
        #expect(rig.countOfPrefix("commit") == commits + 1, "Nothing moved, so no second fix")
        #expect(rig.power.activeHoldCount == 0)
    }

    @Test func endKeepsScreenAliveUntilMonitorsReturn() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let before = rig.mutations.count

        _ = try await end(rig)

        let lines = Array(rig.mutations.dropFirst(before))
        let removed = try #require(lines.firstIndex { $0.hasPrefix("removeVirtual") })
        let lastEnable = try #require(lines.lastIndex { $0.hasPrefix("enable") })
        let lastCommit = try #require(lines.lastIndex { $0.hasPrefix("commit") })
        #expect(lastEnable < removed)
        #expect(lastCommit < removed)
        #expect(rig.simulated.fallbackAppearances == 0, "Something was showing all along")
    }

    @Test func endWithNoSessionSucceeds() async throws {
        let rig = try SessionRig()

        let outcome = try await end(rig)

        #expect(outcome == EndOutcome())
        #expect(rig.mutations.isEmpty)
        #expect(rig.power.declareCount == 0)
        #expect(rig.changes == 0)
    }

    @Test func endTwiceSucceeds() async throws {
        let rig = try SessionRig()
        try await started(rig)

        _ = try await end(rig)
        let mutations = rig.mutations
        let outcome = try await end(rig)

        #expect(outcome == EndOutcome())
        #expect(rig.mutations == mutations)
    }

    @Test func endFromOtherClientRefused() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let mutations = rig.mutations

        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.end(client: "vnc", force: false, reason: "test")
        }

        #expect(rig.mutations == mutations)
        #expect(rig.session.status().state == .active)
        #expect(try rig.ledger?.state == .active)
    }

    @Test func endWithNoClientNameIsTheDefaultClient() async throws {
        let rig = try SessionRig()
        try await started(rig)

        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.end(client: nil, force: false, reason: "test")
        }

        _ = try await end(rig)
        let request = SessionRequest(client: "default", looksLike: defaultSize, hiDPI: true, hz: 60)
        _ = try await rig.session.start(request)
        _ = try await rig.session.end(client: nil, force: false, reason: "test")
        #expect(rig.session.status().state == .idle)
    }

    @Test func forceEndFromOtherClientWorks() async throws {
        let rig = try SessionRig()
        try await started(rig)

        _ = try await rig.session.end(client: "vnc", force: true, reason: "owner-died")

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
        #expect(rig.logText.contains("owner-died"))
    }

    @Test func endWarnsAboutMissingDisplayAndExitsOK() async throws {
        let rig = try SessionRig()
        try await started(rig)
        rig.simulated.removePhysical(m34)

        let outcome = try await end(rig)

        #expect(outcome.missing == ["M34WQ"])
        #expect(outcome.warning == "not restored: M34WQ")
        #expect(rig.simulated.topology().main?.id == lg)
        #expect(rig.simulated.topology().display(lg)?.origin == lgOrigin)
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func endWarnsAboutAModeNoLongerOffered() async throws {
        let rig = try SessionRig()
        try rig.registry.update(from: rig.simulated.topology())
        try rig.registry.pin(uuid: lgUUID, hz: 75)
        try await started(rig)

        let outcome = try await end(rig)

        #expect(outcome.notAtRecordedMode == ["27GL850"])
        #expect(outcome.warning == "not restored at recorded mode: 27GL850")
        #expect(rig.simulated.topology().display(lg)?.origin == lgOrigin)
        #expect(try rig.ledger == nil)
    }

    @Test func severalWarningsAreJoined() {
        let outcome = EndOutcome(missing: ["A", "B"], notAtRecordedMode: ["C"])

        #expect(outcome.warning == "not restored: A; not restored: B; not restored at recorded mode: C")
    }

    @Test func endWhenNothingReturnsKeepsScreenAndLedger() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let id = try rig.screenID
        rig.simulated.removePhysical(lg)
        rig.simulated.removePhysical(m34)
        let changes = rig.changes

        await #expect(throws: SessionError(reason: "could not restore any display")) {
            try await end(rig)
        }

        #expect(rig.simulated.topology().display(id) != nil)
        #expect(try rig.ledger?.state == .ending)
        #expect(rig.session.status().state == .ending)
        #expect(rig.changes == changes + 1)
    }

    @Test func endWhenADisplayStaysDarkKeepsScreenAndLedgerAndCanRetry() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let id = try rig.screenID
        rig.simulated.setEnableFails(m34, .max)

        await #expect(throws: SessionError(reason: "a display did not come back correctly")) {
            try await end(rig)
        }

        #expect(rig.simulated.topology().display(id) != nil)
        #expect(try rig.ledger?.state == .ending)
        #expect(rig.session.status().state == .ending)
        // Whoever comes along next can't start over a session that hasn't ended. The same client is
        // told what to do about it.
        await #expect(throws: SessionError(reason: "the last session did not end cleanly; run porchlight rescue")) {
            try await rig.session.start(parsec())
        }
        let other = SessionRequest(client: "vnc", looksLike: defaultSize, hiDPI: true, hz: 60)
        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.start(other)
        }

        // Stopped moving, so the guardian's frozen row can act.
        let frozenAt = try #require(try rig.ledger).updatedAt
        rig.clock.advance(by: 61)
        #expect(try rig.ledger?.updatedAt == frozenAt)

        rig.simulated.setEnableFails(m34, 0)
        _ = try await end(rig)
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func endReverifiesAfterDestroyingScreen() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let commits = rig.countOfPrefix("commit")
        // macOS moves something once the screen has gone.
        let simulated = rig.simulated
        rig.screens.afterDestroy = {
            try? simulated.commit([.origin(m34, DisplayOrigin(x: 100, y: 1440))])
        }

        _ = try await end(rig)

        rig.expectDeskRestored()
        // The restorer's own, the test's, and the fix.
        #expect(rig.countOfPrefix("commit") == commits + 3)
        #expect(try rig.ledger == nil)
    }

    @Test func endFailsIfTheFixDoesNotHoldKeepingTheLedger() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let simulated = rig.simulated
        rig.screens.afterDestroy = {
            // The monitor drops off right as the screen goes, and won't come back.
            simulated.setEnableFails(m34, .max)
            try? simulated.setEnabled(m34, false)
        }

        await #expect(throws: SessionError(reason: "a display did not come back correctly")) {
            try await end(rig)
        }

        #expect(try rig.ledger?.state == .ending)
        #expect(rig.session.status().state == .ending)
    }

    @Test func endFailsIfEverythingGoesDarkAsTheScreenGoes() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let simulated = rig.simulated
        rig.screens.afterDestroy = {
            for id in [m34, lg] {
                simulated.setEnableFails(id, .max)
                try? simulated.setEnabled(id, false)
            }
        }

        await #expect(throws: SessionError(reason: "could not restore any display")) {
            try await end(rig)
        }

        #expect(try rig.ledger?.state == .ending)
    }

    @Test func endWithAKeptMainPutsTheOtherMonitorBack() async throws {
        let rig = try SessionRig()
        try await started(rig, keepOn: [lgUUID])

        _ = try await end(rig)

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func endWithRescuedLedgerClearsIt() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .rescued))

        _ = try await end(rig)

        #expect(try rig.ledger == nil)
        #expect(rig.mutations.isEmpty)
    }

    @Test func endOfARunningSessionFoundRescuedOnlyDropsTheScreen() async throws {
        let rig = try SessionRig()
        try await started(rig)
        var rescued = try #require(try rig.ledger)
        rescued.state = .rescued
        try rig.memory.save(rescued)
        let enables = rig.countOfPrefix("enable")

        _ = try await end(rig)

        #expect(rig.countOfPrefix("enable") == enables)
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func endTakesRestoreLock() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let lockURL = rig.lockURL
        let wasHeld = Recorder<Bool>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, enabled in
                guard enabled else { return }
                let probe = FileLock(url: lockURL)
                wasHeld.append(!probe.tryLock())
                probe.unlock()
            }
        }

        _ = try await end(rig)

        #expect(wasHeld.values == [true, true])
    }

    @Test func endWakesDisplaysWhenEverythingIsAsleep() async throws {
        let rig = try SessionRig(wakesOnDeclare: true)
        try await started(rig)
        rig.simulated.setAsleep(try rig.screenID, true)
        let declares = rig.power.declareCount

        _ = try await end(rig)

        #expect(rig.power.declareCount > declares)
        #expect(!rig.mutations.contains { $0.contains("failed") }, "Woken before the first enable")
        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func noDisplaySleepHeldUntilLedgerCleared() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let power = rig.power
        let holds = Recorder<Int>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, _ in holds.append(power.activeHoldCount) }
        }
        var holdsAtDestroy = 0
        rig.screens.afterDestroy = { holdsAtDestroy = power.activeHoldCount }

        _ = try await end(rig)

        #expect(holds.values.allSatisfy { $0 >= 1 })
        #expect(holdsAtDestroy >= 1)
        #expect(rig.power.activeHoldCount == 0)
    }

    @Test func updatedAtMovesWhileRestoringAndStartedAtNeverChanges() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let startedAt = try #require(try rig.ledger).startedAt

        _ = try await end(rig)

        let ending = rig.store.saves.filter { $0.ledger.state == .ending }
        #expect(ending.count > 1, "The restorer's heartbeat")
        #expect(rig.store.saves.allSatisfy { $0.ledger.startedAt == startedAt })
        let times = ending.map(\.ledger.updatedAt)
        #expect(times == times.sorted())
        #expect(Set(times).count > 1)
    }

    @Test func secondEndWhileEndingGetsTheSameOutcome() async throws {
        let rig = try SessionRig()
        try await started(rig)
        rig.simulated.removePhysical(m34)
        let removals = rig.countOfPrefix("removeVirtual")
        let commits = rig.countOfPrefix("commit")

        // Holds the first end at its first enable until the second has joined it.
        let session = rig.session!
        let second = Box<Task<EndOutcome, any Error>>()
        let joined = DispatchSemaphore(value: 0)
        let isFirst = Recorder<Bool>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, enabled in
                guard enabled, isFirst.values.isEmpty else { return }
                isFirst.append(true)
                Task { @MainActor in
                    await #expect(throws: SessionError(reason: "session held by parsec")) {
                        try await session.end(client: "vnc", force: false, reason: "test")
                    }
                    second.value = Task { try await session.end(client: "vnc", force: true, reason: "test") }
                    while session.endWaiterCount == 0 { await Task.yield() }
                    joined.signal()
                }
                joined.wait()
            }
        }

        let first = try await end(rig)
        let other = try await #require(second.value).value

        #expect(first.missing == ["M34WQ"])
        #expect(other == first)
        #expect(rig.countOfPrefix("removeVirtual") == removals + 1)
        #expect(rig.countOfPrefix("commit") == commits + 1)
    }

    @Test func endWaitsForScreenToLeaveTheTopologySoAStartCanFollow() async throws {
        let rig = try SessionRig()
        try await started(rig)
        let id = try rig.screenID
        rig.simulated.scriptVirtualLinger(id, reads: 3)

        _ = try await end(rig)
        _ = try await rig.session.start(parsec())

        let gone = try #require(rig.mutations.firstIndex(of: "gone \(id)"))
        let added = try #require(rig.mutations.lastIndex { $0.hasPrefix("addVirtual") })
        #expect(gone < added)
    }

    @Test func endGivesUpWaitingForScreenAfterTwoSeconds() async throws {
        let rig = try SessionRig()
        try await started(rig)
        rig.simulated.scriptVirtualLinger(try rig.screenID, reads: .max)
        let clock = rig.clock
        var destroyedAt: Date?
        rig.screens.afterDestroy = { destroyedAt = clock.now() }

        _ = try await end(rig)

        let waited = rig.clock.now().timeIntervalSince(try #require(destroyedAt))
        #expect(waited >= 3)
        #expect(waited < 4)
        #expect(rig.logText.contains("still listed"))
        #expect(try rig.ledger == nil)
    }

    @Test func endStillRestoresWhenLedgerCannotBeWritten() async throws {
        let rig = try SessionRig()
        try await started(rig)
        rig.memory.failOnSave = true

        _ = try await end(rig)

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func endFailsIfLedgerCannotBeClearedAndCanRetry() async throws {
        let rig = try SessionRig()
        try await started(rig)
        rig.store.failOnClear = true

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await end(rig)
        }
        rig.expectDeskRestored()
        #expect(try rig.ledger?.state == .ending)
        #expect(rig.session.status().state == .ending)

        rig.store.failOnClear = false
        _ = try await end(rig)
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func endFailsIfLedgerCannotBeReadWithNoSessionInMemory() async throws {
        let rig = try SessionRig()
        rig.store.failOnLoad = true

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await end(rig)
        }
    }

    @Test func endGoesOnFromMemoryIfLedgerCannotBeRead() async throws {
        let rig = try SessionRig()
        try await started(rig)
        rig.store.failOnLoad = true

        _ = try await end(rig)

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func endOfALedgerFoundOnDiskRestoresFromIt() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active))
        try rig.simulated.setEnabled(m34, false)
        rig.relaunch()

        _ = try await end(rig)

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
        #expect(rig.store.saves.first?.ledger.app == relaunchedRef, "A restore can find this process")
    }

    @Test func endOfAnOtherClientsLedgerFoundOnDiskIsRefused() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active))

        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.end(client: "vnc", force: false, reason: "test")
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger?.state == .active)
        #expect(rig.session.status().state == .idle)
    }

    @Test func endDiscardsALedgerFromAnotherBoot() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active, bootSession: "boot-0"))

        _ = try await end(rig)

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
    }
}

/// The heartbeat comes from any thread, so these are about what it can't do.
@Suite struct SessionLedgerWriterTests {
    private func ledger(at clock: AutoAdvancingClock) -> SafetyLedger {
        SafetyLedger(
            state: .ending,
            client: "parsec",
            looksLike: defaultSize,
            hiDPI: true,
            hz: 60,
            bootSessionID: boot,
            startedAt: clock.now(),
            updatedAt: clock.now()
        )
    }

    @Test func aBeatWritesOnlyWhileBeating() throws {
        let clock = AutoAdvancingClock()
        let store = InMemoryLedgerStore()
        let writer = SessionLedgerWriter(store: store, clock: clock, log: { _ in })
        let written = try writer.save(ledger(at: clock))

        clock.advance(by: 5)
        writer.beat()
        #expect(try store.load()?.updatedAt == written.updatedAt, "A failed end stays frozen")

        writer.setBeating(true)
        writer.beat()
        #expect(try store.load()?.updatedAt == clock.now())
        #expect(try store.load()?.startedAt == written.startedAt)

        writer.setBeating(false)
        clock.advance(by: 5)
        writer.beat()
        #expect(try store.load()?.updatedAt == written.updatedAt.addingTimeInterval(5))
    }

    @Test func aLateBeatCannotBringBackAClearedLedger() throws {
        let clock = AutoAdvancingClock()
        let store = InMemoryLedgerStore()
        let writer = SessionLedgerWriter(store: store, clock: clock, log: { _ in })
        try writer.save(ledger(at: clock))
        writer.setBeating(true)

        try writer.clear()
        writer.beat()
        writer.touch()

        #expect(try store.load() == nil)
    }

    @Test func beatsFromManyThreadsNeverUndoAClear() throws {
        let clock = AutoAdvancingClock()
        let store = InMemoryLedgerStore()
        let writer = SessionLedgerWriter(store: store, clock: clock, log: { _ in })
        try writer.save(ledger(at: clock))
        writer.setBeating(true)

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            writer.beat()
            if index == 100 { try? writer.clear() }
        }

        #expect(try store.load() == nil)
    }

    @Test func aFailedBeatIsLoggedOnceAndDoesNotThrow() throws {
        let clock = AutoAdvancingClock()
        let store = InMemoryLedgerStore()
        let lines = Recorder<String>()
        let writer = SessionLedgerWriter(store: store, clock: clock, log: { lines.append($0) })
        try writer.save(ledger(at: clock))
        writer.setBeating(true)
        store.failOnSave = true

        writer.beat()
        writer.beat()

        #expect(lines.values.count == 1)
    }
}
