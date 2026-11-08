import ADDisplays
import ADFoundation
import ADModel
import ADVirtualScreens
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionResizeTests {
    private let picked = ScreenSize(w: 1900, h: 1188)
    /// Past the max a screen gets when it's created at the default size.
    private let pastMax = ScreenSize(w: 2200, h: 1300)

    private func started() async throws -> SessionRig {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        return rig
    }

    @Test func resizeInPlaceWritesLedgerFirst() async throws {
        let rig = try await started()
        let id = try rig.screenID
        let changes = rig.changes

        let status = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)

        let save = try #require(rig.store.saves.first { $0.ledger.looksLike == picked })
        let change = try #require(rig.mutations.firstIndex { $0.hasPrefix("setVirtualMode") })
        #expect(save.mutationsBefore <= change, "The new size was on disk before the screen changed")
        #expect(save.ledger.state == .active)

        #expect(status.displayID == id, "In place")
        #expect(status.looksLike == picked)
        #expect(status.pixels == ScreenSize(w: 3800, h: 2376))
        #expect(rig.simulated.topology().display(id)?.mode?.matches(mode(1900, 1188, hz: 60, scale: 2)) == true)
        #expect(rig.changes == changes + 1)
        #expect(rig.countOfPrefix("removeVirtual") == 0)
    }

    @Test func resizePastMaxRecreatesAndUpdatesDisplayID() async throws {
        let rig = try await started()
        let old = rig.session.status()
        let oldID = try #require(old.displayID)

        let status = try await rig.session.resize(looksLike: pastMax, hiDPI: true, hz: 60)

        let newID = try #require(status.displayID)
        #expect(newID != oldID)
        #expect(status.uuid == old.uuid, "A recreate keeps the identity")
        #expect(status.pixels == ScreenSize(w: 4400, h: 2600))
        let topology = rig.simulated.topology()
        #expect(topology.display(oldID) == nil)
        #expect(topology.main?.id == newID)
        #expect(topology.display(newID)?.mode?.matches(mode(2200, 1300, hz: 60, scale: 2)) == true)
        #expect(try rig.ledger?.looksLike == pastMax)
    }

    @Test func resizeNeverTouchesPhysical() async throws {
        let rig = try await started()
        let before = rig.mutations.count

        _ = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        _ = try await rig.session.resize(looksLike: pastMax, hiDPI: true, hz: 60)

        let lines = rig.mutations.dropFirst(before)
        #expect(!lines.contains { $0.hasPrefix("enable") || $0.hasPrefix("disable") })
        rig.expectMonitorsOff()
    }

    @Test func resizeFailureRevertsSize() async throws {
        let rig = try await started()
        let before = rig.session.status()
        let id = try #require(before.displayID)
        rig.provider.failNextReconfigure = true

        await #expect(throws: SessionError(reason: "simulated failure reconfiguring display \(id)")) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }

        #expect(rig.session.status() == before)
        #expect(try rig.ledger?.looksLike == defaultSize)
        #expect(rig.simulated.topology().display(id)?.mode?.matches(mode(1728, 1080, hz: 60, scale: 2)) == true)
        rig.expectMonitorsOff()
    }

    @Test func aFailedRecreateMakesTheOldSizeAgain() async throws {
        let rig = try await started()
        let before = rig.session.status()
        let id = try #require(before.displayID)
        rig.provider.failNextCreate = true
        let changes = rig.changes

        await #expect(throws: SessionError(reason: "simulated failure creating Porch Light (parsec)")) {
            try await rig.session.resize(looksLike: pastMax, hiDPI: true, hz: 60)
        }

        let status = rig.session.status()
        let newID = try #require(status.displayID)
        #expect(newID != id, "The old screen went first, so this one is new")
        #expect(status.uuid == before.uuid)
        #expect(status.looksLike == defaultSize)
        #expect(status.state == .active)
        #expect(try rig.ledger?.looksLike == defaultSize)
        #expect(rig.simulated.topology().main?.id == newID)
        #expect(rig.simulated.topology().display(newID)?.mode?.matches(mode(1728, 1080, hz: 60, scale: 2)) == true)
        rig.expectMonitorsOff()
        #expect(rig.changes == changes + 1, "The display ID changed")
    }

    @Test func aFailedRevertInPlaceFallsBackToARecreate() async throws {
        let rig = try await started()
        let id = try rig.screenID
        rig.screens.reconfigureFailures = 2

        await #expect(throws: SessionError(reason: "scripted failure reconfiguring display \(id)")) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }

        let status = rig.session.status()
        #expect(status.state == .active)
        #expect(status.looksLike == defaultSize)
        #expect(status.displayID != id)
        #expect(rig.simulated.topology().display(id) == nil, "Not left beside the new one")
    }

    @Test func aFailedRevertEndsTheSession() async throws {
        let rig = try await started()
        let id = try rig.screenID
        rig.screens.reconfigureFailures = 2
        rig.screens.createFailures = 1

        await #expect(
            throws: SessionError(
                reason: "scripted failure reconfiguring display \(id); the previous size could not be restored, so the session ended"
            )
        ) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }

        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
    }

    @Test func aFailedRevertWhoseEndFailsSaysSo() async throws {
        let rig = try await started()
        let id = try rig.screenID
        rig.screens.reconfigureFailures = 2
        rig.screens.createFailures = 1
        rig.simulated.setEnableFails(m34, .max)

        await #expect(
            throws: SessionError(
                reason: "scripted failure reconfiguring display \(id); the previous size could not be restored, and ending the session failed: a display did not come back correctly"
            )
        ) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }

        #expect(try rig.ledger?.state == .ending, "For the guardian's frozen row")
        #expect(rig.session.status().state == .ending)
        #expect(rig.simulated.topology().onlineIDs.contains(lg), "One monitor did come back")
    }

    @Test func aScreenEndingDuringAResizeIsRecreatedOnce() async throws {
        let rig = try await started()
        let id = try rig.screenID
        let additions = rig.countOfPrefix("addVirtual")
        rig.screens.terminateDuringReconfigure = true

        await #expect(throws: SessionError(reason: "display \(id) ended during the change")) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }
        await rig.session.recoveryFinished()

        #expect(rig.countOfPrefix("addVirtual") == additions + 1, "Throwing and the report are one loss")
        #expect(rig.session.status().looksLike == defaultSize)
        #expect(rig.simulated.topology().main?.id == (try rig.screenID))
        rig.expectMonitorsOff()
    }

    @Test func resizeTo1xWorks() async throws {
        let rig = try await started()
        let id = try rig.screenID
        let size = ScreenSize(w: 2560, h: 1440)

        let status = try await rig.session.resize(looksLike: size, hiDPI: false, hz: 60)

        #expect(status.displayID == id, "It fits, so in place")
        #expect(status.pixels == size)
        #expect(rig.simulated.topology().display(id)?.mode?.isHiDPI == false)
        #expect(try rig.ledger?.hiDPI == false)
    }

    @Test func aBadReadAfterAResizeKeepsTheCaptureTarget() async throws {
        let rig = try await started()
        let before = rig.session.status()
        rig.backend.update { script in
            script.rewrite = { topology in topology.displays = [] }
        }

        let status = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)

        #expect(status.displayID != nil)
        #expect(status.displayID == before.displayID)
        #expect(status.uuid == before.uuid)
        #expect(status.looksLike == picked)
    }

    @Test func resizeWithNoSessionFails() async throws {
        let rig = try SessionRig()

        await #expect(throws: SessionError(reason: "no session")) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }

        #expect(rig.mutations.isEmpty)
        #expect(try rig.ledger == nil)
    }

    @Test func resizeWithABadSizeChangesNothing() async throws {
        let rig = try await started()
        let saves = rig.store.saves.count
        let mutations = rig.mutations

        await #expect(throws: SessionError(reason: "lookslike height must be 360 to 2400")) {
            try await rig.session.resize(looksLike: ScreenSize(w: 1920, h: 100), hiDPI: true, hz: 60)
        }

        #expect(rig.store.saves.count == saves)
        #expect(rig.mutations == mutations)
    }

    @Test func resizeRefusedWhenLedgerCannotBeWritten() async throws {
        let rig = try await started()
        let mutations = rig.mutations
        rig.memory.failOnSave = true

        await #expect(throws: SessionError(reason: "cannot write state")) {
            try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        }

        #expect(rig.mutations == mutations)
        #expect(rig.session.status().looksLike == defaultSize)
    }

    @Test func resizeDeclaresUserActivity() async throws {
        let rig = try await started()
        let declares = rig.power.declareCount

        _ = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)

        #expect(rig.power.declareCount > declares)
    }

    @Test func resizeUpdatesLedgerSoCrashRecoveryKeepsSize() async throws {
        let rig = try await started()
        _ = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)
        #expect(try rig.ledger?.looksLike == picked)

        rig.crash()
        rig.relaunch()
        await rig.session.resumeAtLaunch(safeMode: false)

        let status = rig.session.status()
        #expect(status.state == .active)
        #expect(status.looksLike == picked)
        #expect(status.pixels == ScreenSize(w: 3800, h: 2376))
    }

    @Test func resizeKeepsStartedAt() async throws {
        let rig = try await started()
        let startedAt = try #require(try rig.ledger).startedAt

        _ = try await rig.session.resize(looksLike: picked, hiDPI: true, hz: 60)

        #expect(try rig.ledger?.startedAt == startedAt)
    }
}
