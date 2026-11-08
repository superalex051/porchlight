import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Testing

@testable import ADEngine

/// A second call arriving partway through a sequence. Each test holds the sequence at a display switch
/// until the second call is waiting its turn, so the second call really does arrive mid-sequence.
@MainActor
@Suite struct SessionInterleavingTests {
    private let picked = ScreenSize(w: 1900, h: 1188)

    private func started() async throws -> SessionRig {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        return rig
    }

    private func end(_ rig: SessionRig) async throws -> EndOutcome {
        try await rig.session.end(client: "parsec", force: false, reason: "test")
    }

    @Test func endDuringStart() async throws {
        let rig = try SessionRig()
        let session = rig.session!
        let ending = Box<Task<EndOutcome, any Error>>()
        rig.atFirstSwitch(enabling: false) {
            #expect(session.status().state == .starting)
            ending.value = Task { try await session.end(client: "parsec", force: false, reason: "test") }
            while session.turnsWaiting == 0 { await Task.yield() }
        }

        let status = try await rig.session.start(parsec())
        let outcome = try await #require(ending.value).value

        #expect(status.state == .active, "The start ran to its end first")
        #expect(outcome == EndOutcome())
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        rig.expectNothingLeftDark()
    }

    @Test func topologyEventAndPollTickDuringEnd() async throws {
        let rig = try await started()
        let session = rig.session!
        let event = Box<Task<Void, Never>>()
        let tick = Box<Task<Void, Never>>()
        rig.atFirstSwitch(enabling: true) {
            #expect(session.status().state == .ending)
            event.value = Task { await session.topologyChanged() }
            tick.value = Task { await session.startupPollTick() }
            while session.turnsWaiting < 2 { await Task.yield() }
        }
        let disables = rig.countOfPrefix("disable")
        let additions = rig.countOfPrefix("addVirtual")

        _ = try await end(rig)
        await event.value?.value
        await tick.value?.value

        #expect(rig.countOfPrefix("disable") == disables, "Nothing turned a returning monitor back off")
        #expect(rig.countOfPrefix("addVirtual") == additions, "Nothing recreated the screen")
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        rig.expectNothingLeftDark()
    }

    @Test func resizeDuringEnd() async throws {
        let rig = try await started()
        let session = rig.session!
        let size = picked
        let resizing = Box<Task<SessionStatus, any Error>>()
        rig.atFirstSwitch(enabling: true) {
            resizing.value = Task { try await session.resize(looksLike: size, hiDPI: true, hz: 60) }
            while session.turnsWaiting == 0 { await Task.yield() }
        }

        _ = try await end(rig)
        let task = try #require(resizing.value)

        await #expect(throws: SessionError(reason: "no session")) {
            try await task.value
        }
        #expect(rig.countOfPrefix("setVirtualMode") == 0)
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        rig.expectNothingLeftDark()
    }

    @Test func startDuringEnd() async throws {
        let rig = try await started()
        let session = rig.session!
        let starting = Box<Task<SessionStatus, any Error>>()
        let request = parsec()
        rig.atFirstSwitch(enabling: true) {
            starting.value = Task { try await session.start(request) }
            while session.turnsWaiting == 0 { await Task.yield() }
        }

        let outcome = try await end(rig)
        let status = try await #require(starting.value).value

        #expect(outcome == EndOutcome())
        #expect(status.state == .active, "It ran after the end, as a new session")
        rig.expectMonitorsOff()
        #expect(rig.simulated.topology().main?.id == status.displayID)
        rig.expectNothingLeftDark()

        // It recorded the desk as the end left it, so its own end comes back to the same place.
        let ledger = try #require(try rig.ledger)
        #expect(ledger.state == .active)
        #expect(ledger.physical.first { $0.id == lg }?.origin == lgOrigin)
        #expect(ledger.physical.first { $0.id == m34 }?.origin == m34Origin)
        #expect(ledger.physical.first { $0.id == lg }?.wasMain == true)

        _ = try await end(rig)
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        rig.expectNothingLeftDark()
    }
}
