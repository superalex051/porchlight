import ADDisplays
import ADFoundation
import ADModel
import ADVirtualScreens
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionEnforcementTests {
    private func started(_ keepOn: [String] = []) async throws -> SessionRig {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec(keepOn: keepOn))
        return rig
    }

    @Test func wakeReconnectIsUndone() async throws {
        let rig = try await started()
        rig.simulated.simulateWake(reconnecting: [lg])
        #expect(rig.simulated.topology().onlineIDs.contains(lg))

        await rig.session.topologyChanged()

        rig.expectMonitorsOff()
        #expect(rig.count("disable \(lg)") == 2)
        #expect(rig.session.status().state == .active)
    }

    @Test func anEventWaitsOutTheDebounceBeforeActing() async throws {
        let rig = try await started()
        rig.simulated.simulateWake(reconnecting: [lg])
        rig.clock.holdDebounce()

        let session = rig.session!
        let event = Task { await session.topologyChanged() }
        while rig.clock.heldCount < 1 { await Task.yield() }
        #expect(rig.count("disable \(lg)") == 1, "Only the start's so far")

        rig.clock.releaseDebounce()
        await event.value

        rig.expectMonitorsOff()
    }

    @Test func aBurstOfEventsActsOnce() async throws {
        let rig = try await started()
        // A failed disconnect leaves the LG on, so a second pass would try again and show up here.
        rig.backend.update { $0.failDisable = [lg] }
        rig.simulated.simulateWake(reconnecting: [lg])
        rig.clock.holdDebounce()

        let session = rig.session!
        let first = Task { await session.topologyChanged() }
        let second = Task { await session.topologyChanged() }
        while rig.clock.heldCount < 2 { await Task.yield() }
        rig.clock.releaseDebounce()
        await first.value
        await second.value

        #expect(rig.logText.components(separatedBy: "Turning display \(lg) off again failed").count == 2)
    }

    @Test func enforcementStopsAfter5In60sAndGoesDegraded() async throws {
        let rig = try await started()
        for _ in 1...5 {
            rig.simulated.simulateWake(reconnecting: [lg])
            await rig.session.topologyChanged()
            rig.expectMonitorsOff()
        }
        #expect(rig.session.status().state == .active)
        let changes = rig.changes

        rig.simulated.simulateWake(reconnecting: [lg])
        await rig.session.topologyChanged()

        #expect(rig.simulated.topology().onlineIDs.contains(lg), "Left on")
        #expect(rig.session.status().state == .degraded)
        #expect(rig.session.status().physicalOff == [m34])
        #expect(rig.changes == changes + 1)
        #expect(rig.count("disable \(lg)") == 6, "The start's, and five more")
        #expect(rig.logText.contains("stopped enforcing"))

        // It has stopped, and it stays stopped.
        await rig.session.topologyChanged()
        await rig.session.startupPollTick()
        #expect(rig.count("disable \(lg)") == 6)
        #expect(rig.changes == changes + 1)

        // The session still works, and still ends.
        _ = try await rig.session.end(client: "parsec", force: false, reason: "test")
        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func enforcementBudgetResets() async throws {
        let rig = try await started()
        for _ in 1...5 {
            rig.simulated.simulateWake(reconnecting: [lg])
            await rig.session.topologyChanged()
        }

        rig.clock.advance(by: 61)

        for _ in 1...5 {
            rig.simulated.simulateWake(reconnecting: [lg])
            await rig.session.topologyChanged()
            rig.expectMonitorsOff()
        }
        #expect(rig.session.status().state == .active)
        #expect(rig.count("disable \(lg)") == 11)
    }

    @Test func budgetIsPerDisplay() async throws {
        let rig = try await started()
        for _ in 1...5 {
            rig.simulated.simulateWake(reconnecting: [lg])
            await rig.session.topologyChanged()
        }

        rig.simulated.simulateWake(reconnecting: [m34])
        await rig.session.topologyChanged()

        rig.expectMonitorsOff()
        #expect(rig.session.status().state == .active)
    }

    @Test func mainStolenIsRetaken() async throws {
        let rig = try await started([lgUUID])
        let id = try rig.screenID
        try rig.simulated.commit([.origin(lg, DisplayOrigin(x: 0, y: 0))])
        #expect(rig.simulated.topology().main?.id == lg)

        await rig.session.topologyChanged()

        let topology = rig.simulated.topology()
        #expect(topology.main?.id == id)
        #expect(topology.display(id)?.origin == DisplayOrigin(x: 0, y: 0))
        #expect(topology.onlineIDs.contains(lg), "A kept display stays on")
    }

    @Test func screenVanishedIsRecreated() async throws {
        let rig = try await started()
        let old = rig.session.status()
        let id = try #require(old.displayID)
        rig.simulated.removeVirtual(id)
        let changes = rig.changes
        let declares = rig.power.declareCount
        var declaredBeforeCreate = 0
        rig.screens.beforeCreate = { declaredBeforeCreate = rig.power.declareCount }

        await rig.session.topologyChanged()

        #expect(declaredBeforeCreate > declares, "The mode check needs the screen active")
        let new = rig.session.status()
        let newID = try #require(new.displayID)
        #expect(newID != id)
        #expect(new.uuid == old.uuid)
        #expect(new.looksLike == old.looksLike)
        #expect(rig.simulated.topology().main?.id == newID)
        rig.expectMonitorsOff()
        #expect(rig.changes == changes + 1)
        #expect(try rig.ledger?.state == .active)
    }

    @Test func screenEndedBySystemIsRecreatedOnce() async throws {
        let rig = try await started()
        let old = try #require(rig.session.activeScreen)
        let additions = rig.countOfPrefix("addVirtual")

        rig.provider.simulateTermination(of: old)
        await rig.session.recoveryFinished()
        // The topology event for the same loss finds nothing left to do.
        await rig.session.topologyChanged()

        let new = try #require(rig.session.activeScreen)
        #expect(new.displayID != old.displayID)
        #expect(new.uuid == old.uuid)
        #expect(rig.countOfPrefix("addVirtual") == additions + 1)
        #expect(rig.simulated.topology().main?.id == new.displayID)
    }

    @Test func screenThatCannotBeRecreatedEndsTheSession() async throws {
        let rig = try await started()
        rig.simulated.removeVirtual(try rig.screenID)
        rig.screens.createFailures = 1

        await rig.session.topologyChanged()

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func startupPollCatchesReconnectWithoutEvent() async throws {
        let rig = try await started()
        rig.simulated.simulateWake(reconnecting: [lg])

        await rig.session.startupPollTick()

        rig.expectMonitorsOff()
    }

    @Test func startupPollStopsAfter15Seconds() async throws {
        let rig = try await started()
        rig.clock.advance(by: 16)
        rig.simulated.simulateWake(reconnecting: [lg])

        await rig.session.startupPollTick()
        #expect(rig.simulated.topology().onlineIDs.contains(lg), "Past the poll, only an event acts")

        await rig.session.topologyChanged()
        rig.expectMonitorsOff()
    }

    @Test func parsecVirtualAppearingIsIgnored() async throws {
        let rig = try await started()
        let status = rig.session.status()
        let parsecMode = mode(1920, 1080, hz: 60)
        _ = rig.simulated.addVirtual(
            identity: DisplayIdentity(vendor: 0x1234, model: 0x5678, serial: 1, productName: "Parsec Virtual Display"),
            mode: parsecMode,
            modes: [parsecMode]
        )
        let mutations = rig.mutations

        await rig.session.topologyChanged()

        #expect(rig.mutations == mutations)
        #expect(rig.simulated.topology().main?.id == status.displayID)
        #expect(rig.session.status() == status)
    }

    @Test func aKeptDisplayIsLeftAlone() async throws {
        let rig = try await started([lgUUID])

        await rig.session.topologyChanged()

        #expect(rig.count("disable \(lg)") == 0)
        #expect(rig.simulated.topology().onlineIDs.contains(lg))
    }

    @Test func nothingHappensWithNoSession() async throws {
        let rig = try SessionRig()

        await rig.session.topologyChanged()
        await rig.session.startupPollTick()

        #expect(rig.mutations.isEmpty)
        #expect(rig.changes == 0)
    }

    @Test func enforcementRespectsTheNeverZeroRule() async throws {
        let rig = try await started()
        rig.simulated.simulateWake(reconnecting: [lg])
        // The screen stops counting, so the LG is the last display that does.
        rig.backend.update { script in
            script.rewrite = { topology in
                for index in topology.displays.indices where topology.displays[index].kind == .ownVirtual {
                    topology.displays[index].kind = .otherVirtual
                }
            }
        }

        await rig.session.topologyChanged()

        #expect(rig.simulated.topology().onlineIDs.contains(lg))
        #expect(rig.count("disable \(lg)") == 1)
    }

    @Test func degradedStillRecreatesTheScreen() async throws {
        let rig = try await started()
        for _ in 1...6 {
            rig.simulated.simulateWake(reconnecting: [lg])
            await rig.session.topologyChanged()
        }
        #expect(rig.session.status().state == .degraded)
        let id = try rig.screenID
        rig.simulated.removeVirtual(id)

        await rig.session.topologyChanged()

        #expect(try rig.screenID != id)
        #expect(rig.session.status().state == .degraded)
        #expect(rig.count("disable \(lg)") == 6)
    }

    // MARK: Budgets for main and the screen

    /// The LG takes (0,0), and so main, and the screen moves aside.
    private func stealMain(_ rig: SessionRig) async throws {
        try rig.simulated.commit([.origin(lg, DisplayOrigin(x: 0, y: 0))])
        await rig.session.topologyChanged()
    }

    @Test func retakingMainStopsAfter5In60sAndGoesDegraded() async throws {
        let rig = try await started([lgUUID])
        let id = try rig.screenID
        for _ in 1...5 {
            try await stealMain(rig)
            #expect(rig.simulated.topology().main?.id == id)
        }
        #expect(rig.session.status().state == .active)
        let changes = rig.changes

        try await stealMain(rig)

        #expect(rig.simulated.topology().main?.id == lg, "It stopped fighting")
        #expect(rig.session.status().state == .degraded)
        #expect(rig.changes == changes + 1)
        #expect(rig.logText.contains("Something keeps taking main"))
        #expect(rig.logText.contains("stopped enforcing"))
        #expect(rig.session.status().displayID == id, "The session still works")

        try await stealMain(rig)
        #expect(rig.simulated.topology().main?.id == lg)
        #expect(rig.changes == changes + 1)
    }

    @Test func aScreenThatIsMainSpendsNoBudget() async throws {
        let rig = try await started([lgUUID])

        for _ in 1...10 {
            await rig.session.topologyChanged()
        }

        #expect(rig.session.status().state == .active)
    }

    @Test func retakingMainBudgetResets() async throws {
        let rig = try await started([lgUUID])
        for _ in 1...5 {
            try await stealMain(rig)
        }

        rig.clock.advance(by: 61)

        try await stealMain(rig)
        #expect(rig.session.status().state == .active)
        #expect(rig.simulated.topology().main?.id == (try rig.screenID))
    }

    /// With both monitors off, past the budget nothing would be showing.
    @Test func recreatingTheScreenPastTheBudgetWithMonitorsOffEndsTheSession() async throws {
        let rig = try await started()
        for _ in 1...5 {
            rig.simulated.removeVirtual(try rig.screenID)
            await rig.session.topologyChanged()
            rig.expectMonitorsOff()
            #expect(rig.session.status().state == .active)
        }
        #expect(rig.countOfPrefix("addVirtual") == 6)

        rig.simulated.removeVirtual(try rig.screenID)
        await rig.session.topologyChanged()

        #expect(rig.countOfPrefix("addVirtual") == 6)
        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        #expect(rig.logText.contains("The screen keeps going away"))
    }

    /// With a monitor on, something is showing, so the session stays and stops fighting.
    @Test func recreatingTheScreenPastTheBudgetWithAMonitorOnGoesDegraded() async throws {
        let rig = try await started([lgUUID])
        for _ in 1...5 {
            rig.simulated.removeVirtual(try rig.screenID)
            await rig.session.topologyChanged()
        }
        let additions = rig.countOfPrefix("addVirtual")
        let changes = rig.changes

        rig.simulated.removeVirtual(try rig.screenID)
        await rig.session.topologyChanged()

        let status = rig.session.status()
        #expect(status.state == .degraded)
        #expect(status.displayID == nil, "It doesn't name a screen that has gone")
        #expect(rig.countOfPrefix("addVirtual") == additions)
        #expect(rig.changes == changes + 1)
        #expect(rig.simulated.topology().onlineIDs.contains(lg))
        #expect(try rig.ledger?.state == .active)

        // Once the budget has refilled there's a screen again.
        rig.clock.advance(by: 61)
        await rig.session.topologyChanged()
        #expect(rig.countOfPrefix("addVirtual") == additions + 1)
        #expect(rig.session.status().displayID != nil)
        #expect(rig.session.status().state == .degraded)

        // And it still ends properly.
        _ = try await rig.session.end(client: "parsec", force: false, reason: "test")
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func aScreenEndedBySystemCountsAgainstTheBudgetToo() async throws {
        let rig = try await started()
        for _ in 1...5 {
            rig.provider.simulateTermination(of: try #require(rig.session.activeScreen))
            await rig.session.recoveryFinished()
        }
        #expect(rig.countOfPrefix("addVirtual") == 6)

        rig.provider.simulateTermination(of: try #require(rig.session.activeScreen))
        await rig.session.recoveryFinished()

        #expect(rig.countOfPrefix("addVirtual") == 6)
        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func aFailedReadIsNotTakenForAVanishedScreen() async throws {
        let rig = try await started()
        let id = try rig.screenID
        // A failed read says nothing about what isn't on it.
        rig.simulated.setListReadFails(1)
        rig.backend.update { script in
            script.rewrite = { topology in
                if topology.listReadFailed { topology.displays.removeAll() }
            }
        }

        await rig.session.topologyChanged()

        #expect(try rig.screenID == id)
        #expect(rig.countOfPrefix("addVirtual") == 1)
    }

    @Test func aFailedDisconnectIsLoggedAndCountsAgainstTheBudget() async throws {
        let rig = try await started()
        rig.backend.update { $0.failDisable = [lg] }

        rig.simulated.simulateWake(reconnecting: [lg])
        for _ in 1...5 {
            await rig.session.topologyChanged()
            #expect(rig.session.status().state == .active)
        }
        await rig.session.topologyChanged()

        #expect(rig.session.status().state == .degraded)
        #expect(rig.logText.contains("scripted failure disabling display 2"))
    }
}
