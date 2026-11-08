import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionRescueTests {
    private func deskOff(_ rig: SessionRig, registryKnowsTheDesk: Bool = true) throws {
        if registryKnowsTheDesk {
            try rig.registry.update(from: rig.simulated.topology())
        }
        try rig.simulated.setEnabled(m34, false)
        try rig.simulated.setEnabled(lg, false)
    }

    @Test func rescueForceEndsASession() async throws {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())

        let outcome = try await rig.session.rescue()

        #expect(outcome == EndOutcome())
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        #expect(rig.logText.contains("Ending the session: rescue"))
    }

    @Test func rescuePassesOnAnEndsWarning() async throws {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        rig.simulated.removePhysical(m34)

        let outcome = try await rig.session.rescue()

        #expect(outcome.missing == ["M34WQ"])
    }

    @Test func rescuePassesOnAnEndsFailure() async throws {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        rig.simulated.setEnableFails(m34, .max)

        await #expect(throws: SessionError(reason: "a display did not come back correctly")) {
            try await rig.session.rescue()
        }

        #expect(try rig.ledger?.state == .ending)
    }

    @Test func rescueEndsASessionFoundOnlyOnDisk() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .active))
        try deskOff(rig, registryKnowsTheDesk: false)

        _ = try await rig.session.rescue()

        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func rescueWithNoSessionReconnectsFromTheRegistry() async throws {
        let rig = try SessionRig()
        try deskOff(rig)
        let changes = rig.changes

        let outcome = try await rig.session.rescue()

        #expect(outcome == EndOutcome())
        #expect(rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
        #expect(rig.session.status().state == .idle)
        #expect(rig.changes == changes + 1)
        #expect(rig.logText.contains("The reconnect finished with a physical display online"))
    }

    @Test func rescueWithNoSessionTakesRestoreLock() async throws {
        let rig = try SessionRig()
        try deskOff(rig)
        let lockURL = rig.lockURL
        let wasHeld = Recorder<Bool>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, _ in
                let probe = FileLock(url: lockURL)
                wasHeld.append(!probe.tryLock())
                probe.unlock()
            }
        }

        _ = try await rig.session.rescue()

        #expect(wasHeld.values == [true, true])
    }

    @Test func rescueWithNoSessionFailsIfNoPhysicalDisplayIsOnlineAfterward() async throws {
        let rig = try SessionRig()
        try deskOff(rig, registryKnowsTheDesk: false)

        await #expect(throws: SessionError(reason: "could not restore any display")) {
            try await rig.session.rescue()
        }

        #expect(rig.logText.contains("The reconnect finished with no physical display online"))
    }

    @Test func rescueWithAnUnreadableLedgerStillReconnects() async throws {
        let rig = try SessionRig()
        try deskOff(rig)
        rig.store.failOnLoad = true

        _ = try await rig.session.rescue()

        #expect(rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
    }

    @Test func rescueClearsAFinishedLedgerAndReconnects() async throws {
        let rig = try SessionRig()
        try rig.memory.save(rig.seededLedger(state: .rescued))
        try deskOff(rig)

        _ = try await rig.session.rescue()

        #expect(try rig.ledger == nil)
        #expect(rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
    }

    @Test func rescueWaitsItsTurnBehindAStart() async throws {
        let rig = try SessionRig()
        let session = rig.session!
        let rescue = Box<Task<EndOutcome, any Error>>()
        rig.atFirstSwitch(enabling: false) {
            rescue.value = Task { try await session.rescue() }
            while session.turnsWaiting == 0 { await Task.yield() }
        }

        let status = try await rig.session.start(parsec())
        _ = try await #require(rescue.value).value

        #expect(status.state == .active, "The start ran to its end first")
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        rig.expectNothingLeftDark()
    }
}
