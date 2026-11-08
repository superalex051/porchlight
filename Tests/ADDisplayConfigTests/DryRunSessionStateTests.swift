import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Testing

@testable import ADDisplayConfig

private let boot = "boot-1"

private func ledger(_ recorded: [PhysicalRecord], state: LedgerState, bootSession: String = boot) -> SafetyLedger {
    let at = Date(timeIntervalSinceReferenceDate: 0)
    return SafetyLedger(
        state: state,
        client: "parsec",
        looksLike: ScreenSize(w: 1728, h: 1080),
        hiDPI: true,
        hz: 60,
        physical: recorded,
        app: ProcessRef(pid: 4242, startTime: 1000),
        bootSessionID: bootSession,
        startedAt: at,
        updatedAt: at
    )
}

private func temporaryRegistryURL() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(component: "ADDisplayConfigTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(component: "devices.json", directoryHint: .notDirectory)
}

/// A dry-run restore's copy is made from the real Mac, where the monitors are on. Without this, the
/// restore found them on, turned nothing on, and still reported them back, so it proved nothing.
@Test func aLiveLedgerTurnsItsMonitorsOffInTheCopySoTheRestoreHasToBringThemBack() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    #expect(recorded.count == 2, "Or this test proves nothing")
    let session = ledger(recorded, state: .active)

    let actedOut = DryRunSessionState.actOut(session, on: backend, currentBoot: boot)

    #expect(actedOut == backend.mutations.count)
    #expect(Set(backend.mutations) == ["disable \(lg)", "disable \(m34)"])
    #expect(!backend.topology().online.contains { $0.kind == .physical })

    let succeeded = await RestoreJob(
        ledger: InMemoryLedgerStore(ledger: session),
        registryURL: try temporaryRegistryURL(),
        backend: backend,
        processes: FakeProcessInspector(),
        clock: AutoAdvancingClock(),
        power: FakePowerAssertions(onDeclare: { backend.wakeAll() }),
        lockURL: temporaryLockURL(),
        bootSession: boot
    ).run()

    #expect(succeeded)
    let plan = Array(backend.mutations.dropFirst(actedOut))
    #expect(plan.contains("enable \(lg)"))
    #expect(plan.contains("enable \(m34)"))
    #expect(!plan.contains { $0.hasPrefix("disable ") })
}

@Test(arguments: [LedgerState.starting, .active, .ending])
func everyLiveStateActsOut(_ state: LedgerState) {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let actedOut = DryRunSessionState.actOut(ledger(records(of: backend), state: state), on: backend, currentBoot: boot)
    #expect(actedOut == 2)
}

/// Rescued means they're back already. No ledger and another boot's ledger say nothing about what's off
/// now, and a restore doesn't go by either.
@Test func otherwiseTheCopyStaysAsTheRealMacIs() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)

    #expect(DryRunSessionState.actOut(nil, on: backend, currentBoot: boot) == 0)
    #expect(DryRunSessionState.actOut(ledger(recorded, state: .rescued), on: backend, currentBoot: boot) == 0)
    #expect(DryRunSessionState.actOut(ledger(recorded, state: .active, bootSession: "boot-0"), on: backend, currentBoot: boot) == 0)
    #expect(backend.mutations.isEmpty)
}

/// A recorded display that isn't on now, say one unplugged, is left alone.
@Test func aRecordThatIsntOnIsSkipped() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: backend)
    backend.removePhysical(m34)

    let actedOut = DryRunSessionState.actOut(ledger(recorded, state: .active), on: backend, currentBoot: boot)

    #expect(actedOut == 1)
    #expect(backend.mutations == ["disable \(lg)"])
}
