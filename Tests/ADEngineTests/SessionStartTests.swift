import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import ADVirtualScreens
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionStartTests {
    @Test func startHappyPath() async throws {
        let rig = try SessionRig()

        let status = try await rig.session.start(parsec())

        let id = try #require(status.displayID)
        let topology = rig.simulated.topology()
        let screen = try #require(topology.display(id))
        #expect(topology.main?.id == id)
        #expect(screen.kind == .ownVirtual)
        #expect(screen.mode?.matches(mode(1728, 1080, hz: 60, scale: 2)) == true)
        #expect(screen.mode?.pixelsWide == 3456)
        #expect(screen.mode?.pixelsHigh == 2160)
        rig.expectMonitorsOff()

        let ledger = try #require(try rig.ledger)
        #expect(ledger.state == .active)
        #expect(ledger.client == "parsec")
        #expect(ledger.physical.map(\.id) == [lg, m34])
        #expect(ledger.owners == [ownerRef])
        #expect(ledger.app == appRef)
        #expect(ledger.bootSessionID == boot)

        let uuid = try #require(screen.identity.uuid)
        #expect(
            status.statusLine
                == "state=active client=parsec displayID=\(id) UUID=\(uuid) lookslike=1728x1080 pixels=3456x2160 hz=60 off=2,4"
        )
        #expect(rig.session.status() == status)
    }

    @Test func startWritesLedgerBeforeEveryMutation() async throws {
        let rig = try SessionRig()

        _ = try await rig.session.start(parsec())

        let first = try #require(rig.store.saves.first { !$0.ledger.physical.isEmpty })
        #expect(first.ledger.state == .starting)
        #expect(first.mutationsBefore == 0)
        #expect(first.ledger.physical.map(\.id) == [lg, m34])
        #expect(rig.mutations.first?.hasPrefix("addVirtual") == true)
    }

    @Test func startRefusedWhenGuardianDown() async throws {
        let rig = try SessionRig(guardianAlive: false)

        await #expect(throws: SessionError(reason: "guardian not running")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
        #expect(rig.power.declareCount == 0)
        #expect(rig.session.status().state == .idle)
    }

    @Test func startRefusedWhenLedgerCannotBeWritten() async throws {
        let rig = try SessionRig()
        rig.memory.failOnSave = true

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations.isEmpty)
        #expect(rig.power.declareCount == 0)
        #expect(rig.session.status().state == .idle)
    }

    @Test func startRefusedWhenRegistryCannotBeWritten() async throws {
        let rig = try SessionRig(registryWritable: false)

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
        #expect(rig.power.activeHoldCount == 0)
    }

    @Test func startRefusedForDeadOwner() async throws {
        let rig = try SessionRig()

        await #expect(throws: SessionError(reason: "owner process 9999 is not running")) {
            try await rig.session.start(parsec(owners: [ownerRef.pid, 9999]))
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
    }

    @Test func startRefusedForBadSize() async throws {
        let rig = try SessionRig()

        await #expect(throws: SessionError(reason: "lookslike width must be 640 to 3840")) {
            try await rig.session.start(parsec(size: ScreenSize(w: 100, h: 1080)))
        }
        await #expect(throws: SessionError(reason: "hz must be 24 to 240")) {
            try await rig.session.start(parsec(hz: 10))
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
    }

    @Test func startRefusedWhenOtherClientActive() async throws {
        let rig = try SessionRig()
        let running = try await rig.session.start(parsec())
        let mutations = rig.mutations

        let other = SessionRequest(client: "vnc", looksLike: defaultSize, hiDPI: true, hz: 60)
        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.start(other)
        }

        #expect(rig.mutations == mutations)
        #expect(rig.session.status() == running)
    }

    @Test func startRefusedWithALiveLedgerItDoesNotKnow() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active))

        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger?.state == .active)
    }

    @Test func startReplacesARescuedLedger() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .rescued))

        let status = try await rig.session.start(parsec())

        #expect(status.state == .active)
        #expect(try rig.ledger?.state == .active)
    }

    @Test func secondStartKeepsPickedSize() async throws {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        let picked = ScreenSize(w: 1900, h: 1188)
        _ = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        let changesBefore = rig.changes

        let status = try await rig.session.start(parsec(owners: [secondOwnerRef.pid]))

        #expect(status.looksLike == picked)
        #expect(status.pixels == ScreenSize(w: 3800, h: 2376))
        #expect(try rig.ledger?.looksLike == picked)
        #expect(try rig.ledger?.owners == [ownerRef, secondOwnerRef])
        #expect(rig.countOfPrefix("addVirtual") == 1)
        #expect(rig.changes == changesBefore)
    }

    @Test func secondStartFailsIfItsOwnerCannotBeRecorded() async throws {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        rig.memory.failOnSave = true

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await rig.session.start(parsec(owners: [secondOwnerRef.pid]))
        }
    }

    @Test func concurrentStartsMakeOneScreen() async throws {
        let rig = try SessionRig()
        let session = rig.session!

        async let first = session.start(parsec())
        async let second = session.start(parsec(owners: [secondOwnerRef.pid]))
        let statuses = try await [first, second]

        #expect(statuses[0].displayID == statuses[1].displayID)
        #expect(rig.countOfPrefix("addVirtual") == 1)
        #expect(Set(try #require(try rig.ledger).owners) == [ownerRef, secondOwnerRef])
    }

    @Test func startRecordsAndDisconnectsSleepingDisplays() async throws {
        let rig = try SessionRig()
        rig.simulated.setAsleep(lg, true)
        var declaredBeforeCreate = 0
        rig.screens.beforeCreate = { declaredBeforeCreate = rig.power.declareCount }

        _ = try await rig.session.start(parsec())

        #expect(declaredBeforeCreate >= 1)
        #expect(rig.power.calls.first == "declare")
        #expect(try rig.ledger?.physical.map(\.id) == [lg, m34])
        rig.expectMonitorsOff()
    }

    @Test func startUsesPinnedRate() async throws {
        let rig = try SessionRig()
        try rig.simulated.commit([.mode(lg, lg144)])
        try rig.registry.update(from: rig.simulated.topology())
        try rig.registry.pin(uuid: lgUUID, hz: 120)

        _ = try await rig.session.start(parsec())

        let recorded = try #require(try rig.ledger?.physical.first { $0.id == lg })
        #expect(recorded.mode.matches(lg120))
    }

    @Test func startKeepOnLeavesDisplay() async throws {
        let rig = try SessionRig()

        // A different letter case is still the same UUID.
        let status = try await rig.session.start(parsec(keepOn: [lgUUID.lowercased()]))

        let topology = rig.simulated.topology()
        #expect(topology.onlineIDs.contains(lg))
        #expect(!topology.onlineIDs.contains(m34))
        #expect(topology.main?.id == status.displayID)
        #expect(try rig.ledger?.physical.map(\.id) == [m34])
        #expect(status.physicalOff == [m34])
    }

    @Test func displayAlreadyOffNotRecorded() async throws {
        let rig = try SessionRig()
        try rig.simulated.setEnabled(m34, false)

        let status = try await rig.session.start(parsec())

        #expect(try rig.ledger?.physical.map(\.id) == [lg])
        #expect(rig.count("disable \(m34)") == 1, "Only the test's own")
        #expect(status.physicalOff == [lg])

        _ = try await rig.session.end(client: "parsec", force: false, reason: "test")
        #expect(!rig.simulated.topology().onlineIDs.contains(m34), "It stays off")
    }

    @Test func oldMainDisconnectedLast() async throws {
        let rig = try SessionRig()

        _ = try await rig.session.start(parsec())

        let disables = rig.mutations.filter { $0.hasPrefix("disable") }
        #expect(disables == ["disable \(m34)", "disable \(lg)"])
    }

    @Test func screenIsMainBeforeAnyDisconnect() async throws {
        let rig = try SessionRig()
        let simulated = rig.simulated
        let mainKinds = Recorder<DisplayKind?>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, enabled in
                if !enabled { mainKinds.append(simulated.topology().main?.kind) }
            }
        }

        _ = try await rig.session.start(parsec())

        #expect(mainKinds.values == [.ownVirtual, .ownVirtual])
    }

    @Test func startRollsBackIfCreateFails() async throws {
        let rig = try SessionRig()
        rig.provider.failNextCreate = true

        await #expect(throws: SessionError(reason: "simulated failure creating Porch Light (parsec)")) {
            try await rig.session.start(parsec())
        }

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        #expect(rig.power.activeHoldCount == 0)
    }

    @Test func startRollsBackIfDisconnectFails() async throws {
        let rig = try SessionRig()
        rig.backend.update { $0.failDisable = [lg] }

        await #expect(throws: SessionError(reason: "scripted failure disabling display 2")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.count("disable \(m34)") == 1, "The first monitor had gone off")
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func startRollsBackIfADisconnectDoesNotHold() async throws {
        let rig = try SessionRig()
        rig.backend.update { $0.ignoreDisable = [lg] }

        await #expect(throws: SessionError(reason: "display 2 is still online 3 seconds after turning it off")) {
            try await rig.session.start(parsec())
        }

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func startRollsBackIfActiveCannotBeWritten() async throws {
        let rig = try SessionRig()
        // The disk fills up as the monitors are about to go off, so the write of `active` fails.
        let memory = rig.memory
        rig.backend.update { script in
            script.beforeSetEnabled = { id, enabled in
                if id == lg, !enabled { memory.failOnSave = true }
            }
        }

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await rig.session.start(parsec())
        }

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func startFailureKeepsLedgerAndScreenIfRollbackFails() async throws {
        let rig = try SessionRig()
        rig.backend.update { $0.failDisable = [lg] }
        rig.simulated.setEnableFails(m34, .max)

        await #expect(
            throws: SessionError(reason: "scripted failure disabling display 2; a display did not come back correctly")
        ) {
            try await rig.session.start(parsec())
        }

        #expect(try rig.ledger?.state == .ending)
        #expect(rig.simulated.topology().displays.contains { $0.kind == .ownVirtual })
        #expect(rig.session.status().state == .ending)
    }

    @Test func startRefusesToLeaveNoWorkingDisplay() async throws {
        let rig = try SessionRig()
        // The screen stops counting, so turning the monitors off would leave nothing.
        rig.backend.update { script in
            script.rewrite = { topology in
                for index in topology.displays.indices where topology.displays[index].kind == .ownVirtual {
                    topology.displays[index].kind = .otherVirtual
                }
            }
        }

        await #expect(throws: SessionError(reason: "would leave no working display")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.countOfPrefix("disable") == 0)
        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func startRefusedWhenAModeCannotBeRead() async throws {
        let rig = try SessionRig()
        rig.backend.update { script in
            script.rewrite = { topology in
                for index in topology.displays.indices where topology.displays[index].id == lg {
                    topology.displays[index].mode = nil
                }
            }
        }

        await #expect(throws: SessionError(reason: "cannot read display 27GL850")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
    }

    // MARK: Over the OS fallback

    /// Both monitors off with nothing else up, so the fallback display is all that's listed.
    private func fallbackUp(_ rig: SessionRig, registryKnowsTheDesk: Bool) throws {
        if registryKnowsTheDesk {
            try rig.registry.update(from: rig.simulated.topology())
        }
        try rig.simulated.setEnabled(m34, false)
        try rig.simulated.setEnabled(lg, false)
        #expect(rig.simulated.topology().online.map(\.kind) == [.osFallback])
    }

    @Test func startOverTheFallbackReconnectsFirst() async throws {
        let rig = try SessionRig()
        try fallbackUp(rig, registryKnowsTheDesk: true)

        let status = try await rig.session.start(parsec())

        #expect(status.state == .active)
        #expect(status.physicalOff == [lg, m34])
        #expect(try rig.ledger?.physical.map(\.id) == [lg, m34], "The record has what an end needs")
        #expect(rig.count("enable \(lg)") == 1)
        #expect(rig.count("enable \(m34)") == 1)
        rig.expectMonitorsOff()

        _ = try await rig.session.end(client: "parsec", force: false, reason: "test")
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
    }

    @Test func startOverTheFallbackWithNothingKnownIsRefused() async throws {
        let rig = try SessionRig()
        try fallbackUp(rig, registryKnowsTheDesk: false)
        let mutations = rig.mutations

        await #expect(throws: SessionError(reason: "no physical display to return to")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations == mutations)
        #expect(rig.store.saves.isEmpty)
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func startOverTheFallbackWhenNothingComesBackIsRefused() async throws {
        let rig = try SessionRig()
        try fallbackUp(rig, registryKnowsTheDesk: true)
        rig.simulated.setEnableFails(lg, .max)
        rig.simulated.setEnableFails(m34, .max)

        await #expect(throws: SessionError(reason: "no physical display to return to")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.countOfPrefix("addVirtual") == 0)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.session.status().state == .idle)
        #expect(rig.power.activeHoldCount == 0)
    }

    @Test func startOverTheFallbackChangesNothingIfTheGuardianIsDown() async throws {
        let rig = try SessionRig(guardianAlive: false)
        try fallbackUp(rig, registryKnowsTheDesk: true)
        let mutations = rig.mutations

        await #expect(throws: SessionError(reason: "guardian not running")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations == mutations)
    }

    @Test func startOverTheFallbackWithALiveLedgerDoesNotReconnect() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active))
        try fallbackUp(rig, registryKnowsTheDesk: true)
        let mutations = rig.mutations

        await #expect(throws: SessionError(reason: "session held by parsec")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations == mutations)
    }

    @Test func startRefusedIfTheFallbackOnlyShowsAfterAnEmptyRead() async throws {
        let rig = try SessionRig()
        try fallbackUp(rig, registryKnowsTheDesk: false)
        let reads = Recorder<Bool>()
        rig.backend.update { script in
            script.rewrite = { topology in
                if reads.values.isEmpty { topology.displays = [] }
                reads.append(true)
            }
        }

        await #expect(throws: SessionError(reason: "no physical display to return to")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.countOfPrefix("addVirtual") == 0)
        #expect(try rig.ledger == nil)
    }

    @Test func startRefusedWithOnlyAnotherVirtualDisplayUp() async throws {
        let rig = try SessionRig()
        let parsecMode = mode(1920, 1080, hz: 60)
        _ = rig.simulated.addVirtual(
            identity: DisplayIdentity(vendor: 0x1234, model: 0x5678, serial: 1, productName: "Parsec Virtual Display"),
            mode: parsecMode,
            modes: [parsecMode]
        )
        try rig.simulated.setEnabled(m34, false)
        try rig.simulated.setEnabled(lg, false)
        #expect(rig.simulated.topology().online.map(\.kind) == [.parsecVirtual], "No fallback comes up")
        let mutations = rig.mutations

        await #expect(throws: SessionError(reason: "no physical display to return to")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations == mutations)
        #expect(try rig.ledger == nil)
        #expect(rig.power.activeHoldCount == 0)
        #expect(rig.session.status().state == .idle)
    }

    // MARK: Empty reads

    @Test func aBadReadAfterAStartKeepsTheCaptureTarget() async throws {
        let rig = try SessionRig()
        // From the moment `active` is on disk, every read comes back empty.
        let memory = rig.memory
        rig.backend.update { script in
            script.rewrite = { topology in
                if (try? memory.load())?.state == .active { topology.displays = [] }
            }
        }

        let status = try await rig.session.start(parsec())

        #expect(status.state == .active)
        let id = try #require(status.displayID)
        #expect(rig.simulated.topology().display(id)?.kind == .ownVirtual)
        #expect(status.uuid == rig.simulated.topology().display(id)?.identity.uuid)
        #expect(status.uuid != nil)
    }

    @Test func startWaitsOutAnEmptyRead() async throws {
        let rig = try SessionRig()
        let reads = Recorder<Bool>()
        rig.backend.update { script in
            script.rewrite = { topology in
                if reads.values.count < 3 { topology.displays = [] }
                reads.append(true)
            }
        }

        let status = try await rig.session.start(parsec())

        #expect(status.state == .active)
        #expect(try rig.ledger?.physical.map(\.id) == [lg, m34])
        rig.expectMonitorsOff()
    }

    @Test func startRefusedWhenEveryReadIsEmpty() async throws {
        let rig = try SessionRig()
        rig.backend.update { script in
            script.rewrite = { topology in topology.displays = [] }
        }

        await #expect(throws: SessionError(reason: "no displays found")) {
            try await rig.session.start(parsec())
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
        #expect(rig.power.activeHoldCount == 0)
        #expect(rig.session.status().state == .idle)
    }

    @Test func keepingEveryDisplayOnIsNotAnEmptyRead() async throws {
        let rig = try SessionRig()
        let status = try await rig.session.start(parsec(keepOn: [lgUUID, "0A4FA257-A531-4885-BA5E-76B9D0C0EF8D"]))

        #expect(status.state == .active)
        #expect(try rig.ledger?.physical.isEmpty == true)
    }

    @Test func noDisplaySleepHeldDuringStartThenReleased() async throws {
        let rig = try SessionRig()
        let power = rig.power
        let holds = Recorder<Int>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, _ in holds.append(power.activeHoldCount) }
        }

        _ = try await rig.session.start(parsec())

        #expect(holds.values == [1, 1])
        #expect(rig.power.activeHoldCount == 0)
        #expect(rig.power.calls.contains { $0.hasPrefix("hold") })
    }

    @Test func onChangeFires() async throws {
        let rig = try SessionRig()
        #expect(rig.changes == 0)

        _ = try await rig.session.start(parsec())

        #expect(rig.changes == 1)
    }
}
