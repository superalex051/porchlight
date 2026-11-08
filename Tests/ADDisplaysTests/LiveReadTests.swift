import ADFoundation
import ADModel
import Testing

@testable import ADDisplays

// Read only. Nothing here may call a live mutator: the guard's crash would kill the test runner.
// These hold in every state the Mac can be in, including a Parsec session with the monitors off.

@Test func liveTopologyHasMainOnline() throws {
    let topology = LiveDisplayBackend().topology()
    let main = try #require(topology.main)
    #expect(main.isOnline)
    #expect(topology.displays.filter(\.isMain).count == 1)
    #expect(Set(topology.displays.map(\.id)).count == topology.displays.count, "The union holds no duplicates")
    #expect(!topology.listReadFailed)
}

@Test func testBundleGuardWouldBlock() {
    #expect(TestBundleGuard.isRunningInTestBundle)
}

@Test func displayIDZeroIsRefusedBeforeAnyLiveCall() throws {
    // The check `setEnabled` and `commit` run first. It changes nothing, so it can run here.
    let error = #expect(throws: DisplayBackendError.self) { try LiveDisplayBackend.requireDisplay(0) }
    #expect(error?.code == 1001)
    try LiveDisplayBackend.requireDisplay(2)
}

@Test func liveOnlineDisplaysHaveAModeAndAreNotEmptyPipes() throws {
    let backend = LiveDisplayBackend()
    for display in backend.topology().online {
        #expect(display.kind != .emptyPipe)
        let mode = try #require(display.mode)
        #expect(mode.pixelsWide > 1, "Not the stub a display reads as while it's off")
        #expect(backend.modes(of: display.id).contains { $0.matches(mode) })
    }
}

@Test func liveOfflineDisplaysHaveNoMode() {
    let backend = LiveDisplayBackend()
    for display in backend.topology().displays where !display.isOnline {
        #expect(display.mode == nil)
        #expect(backend.modes(of: display.id).isEmpty)
        #expect(!display.isActive)
    }
}

@Test func liveVendorZeroIsAlwaysAnEmptyPipe() {
    for display in LiveDisplayBackend().topology().displays where display.identity.vendor == 0 {
        #expect(display.kind == .emptyPipe || display.kind == .otherVirtual)
    }
}

/// A stale twin, as the M34WQ left on 2026-11-07, never reads as a monitor while its monitor is online.
@Test func liveOfflineMonitorNeverSharesAnOnlineMonitorsIdentity() {
    let topology = LiveDisplayBackend().topology()
    let online = topology.online.filter { $0.kind == .physical }
    for display in topology.displays where !display.isOnline && display.kind == .physical {
        #expect(!online.contains {
            $0.identity.vendor == display.identity.vendor
                && $0.identity.model == display.identity.model
                && $0.identity.serial == display.identity.serial
        })
    }
}

@Test func seededFromLiveMatchesTheLiveRead() throws {
    let live = LiveDisplayBackend().topology()
    let seeded = SimulatedDisplayBackend.seededFromLive()
    let topology = seeded.topology()

    #expect(topology.onlineIDs == live.onlineIDs)
    #expect(topology.main?.id == live.main?.id)
    for display in live.online {
        let read = try #require(topology.display(display.id))
        #expect(read.identity == display.identity)
        #expect(read.origin == display.origin)
        #expect(read.mode == display.mode)
        #expect(read.kind == display.kind)
    }
    #expect(seeded.mutations.isEmpty)
}
