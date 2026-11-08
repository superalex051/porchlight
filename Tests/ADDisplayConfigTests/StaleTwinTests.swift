import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Testing

@testable import ADDisplayConfig

// A stale twin is the record macOS keeps of a monitor on a port it used earlier, with the monitor's
// vendor, model and serial, no mode and no UUID. It never comes online. The real Mac had one for the
// M34WQ on 2026-11-07. In the desk fixture the M34WQ is ID 4, so its twin here is ID 6.

private let earlierPort = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext2@0/IOMobileFramebufferShim"
private let twinID: DisplayID = 6

private func deskWithTwin() throws -> SimulatedDisplayBackend {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let twin = try #require(backend.scriptStaleTwin(of: m34, registryLocation: earlierPort))
    try #require(twin == twinID)
    return backend
}

private func restorer(_ backend: any DisplayBackend, clock: any ADClock = AutoAdvancingClock()) -> PhysicalRestorer {
    PhysicalRestorer(backend: backend, clock: clock, power: FakePowerAssertions(), lockURL: temporaryLockURL())
}

/// A registry entry for a desk monitor, as `devices.json` holds it, under whatever ID it last had.
private func entry(for id: DisplayID, of backend: SimulatedDisplayBackend, lastID: DisplayID? = nil) throws -> RegistryEntry {
    let display = try #require(backend.topology().display(id))
    return RegistryEntry(identity: display.identity, lastID: lastID ?? id, bootSessionID: "boot-1", tagID: Int(id), kind: .physical)
}

private func enables(_ backend: SimulatedDisplayBackend) -> [String] {
    backend.mutations.filter { $0.hasPrefix("enable") }
}

// MARK: A session's end

/// The check asked for: with the real monitor back and matched, its twin mustn't fail the read-back.
/// With the screen alive the lists stay readable, so the twin is listed the whole time.
@Test(arguments: [false, true])
func sessionEndWithAStaleTwinVerifies(screenAlive: Bool) async throws {
    let backend = try deskWithTwin()
    let recorded = records(of: backend)
    if screenAlive { _ = addScreen(backend) }
    try bothOff(backend)

    let report = await restorer(backend).restore(recorded)

    #expect(report == RestoreReport(restored: [lg, m34], missing: [], attempts: 1, verified: true, anyReturned: true))
    #expect(enables(backend) == ["enable 2", "enable 4"], "Never the twin")
    expectDeskRestored(backend)
}

/// Where the M34WQ was plugged back in during the session.
enum Replug: String, CaseIterable, Sendable {
    /// The port it was recorded on, under a new ID.
    case samePort
    /// Another port, under a new ID, with nothing left under its old ID.
    case otherPort
    /// Another port, under a new ID, with a stale twin left on the recorded port.
    case otherPortWithTwinLeft
}

/// macOS turns a monitor that's plugged in on by itself, so the M34WQ comes back lit under a new ID.
/// Matched by its port it's present, and on another port it's missing. It's never dark, so it can't
/// stop the end from verifying, and a twin left behind is never enabled.
@Test(arguments: Replug.allCases)
func aMonitorRepluggedDuringTheSessionIsPresentOrMissingNeverDark(replug: Replug) async throws {
    let desk = SimulatedDisplayBackend.twoMonitorDesk()
    let recorded = records(of: desk)
    let recordedPort = try #require(recorded[1].identity.registryLocation)
    let movedID: DisplayID = 9
    var seed = desk.topology()
    let lgIndex = try #require(seed.displays.firstIndex { $0.id == lg })
    seed.displays[lgIndex].isOnline = false
    seed.displays[lgIndex].isActive = false
    seed.displays[lgIndex].isMain = false
    seed.displays.removeAll { $0.id == m34 }
    var moved = try #require(desk.topology().display(m34))
    moved.id = movedID
    moved.identity.registryLocation = replug == .samePort ? recordedPort : "IOService:/another/port"
    seed.displays.append(moved)
    let backend = SimulatedDisplayBackend(seed: seed, modes: [lg: desk.modes(of: lg), movedID: desk.modes(of: m34)])
    let twin = replug == .otherPortWithTwinLeft ? backend.scriptStaleTwin(of: movedID, registryLocation: recordedPort) : nil

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(report.stillDark.isEmpty)
    if replug == .samePort {
        #expect(report.restored == [lg, movedID])
        #expect(report.missing.isEmpty)
        #expect(backend.topology().display(movedID)?.origin == m34Origin)
    } else {
        #expect(report.restored == [lg])
        #expect(report.missing == recorded.filter { $0.id == m34 })
    }
    if let twin {
        #expect(!enables(backend).contains { $0.hasPrefix("enable \(twin)") })
    }
}

/// The review's case: the M34WQ unplugged, with its twin listed on the port it used before. The twin
/// matches only by vendor, model and serial, so the M34WQ is missing, not dark, and the end verifies.
@Test func anUnpluggedMonitorWithItsTwinListedIsMissingAndTheRestoreVerifies() async throws {
    let backend = try deskWithTwin()
    let recorded = records(of: backend)
    _ = addScreen(backend)
    try bothOff(backend)
    backend.removePhysical(m34)
    #expect(backend.topology().display(twinID)?.kind == .physical, "With no M34WQ online, it isn't marked")

    let report = await restorer(backend).restore(recorded)

    #expect(report.verified)
    #expect(report.restored == [lg])
    #expect(report.missing == recorded.filter { $0.id == m34 })
    #expect(report.stillDark.isEmpty)
    #expect(backend.topology().main?.id == lg)
    #expect(backend.topology().display(lg)?.mode?.matches(lg120) == true)
}

// MARK: The reconnect with no ledger

/// What the hardware run saw: a rescue with every monitor on took about 17 seconds, because the last
/// tier enabled the twin and then waited 15 seconds for it to come online.
@Test func reconnectWithEveryMonitorOnSkipsAStaleTwin() async throws {
    let backend = try deskWithTwin()
    let entries = [try entry(for: lg, of: backend), try entry(for: m34, of: backend)]
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let succeeded = await restorer(backend, clock: clock).reconnect(entries)

    #expect(succeeded)
    #expect(backend.mutations.isEmpty)
    #expect(clock.now().timeIntervalSince(start) < 1)
}

@Test func reconnectSkipsARegistryEntryLeftOnAStaleTwin() async throws {
    let backend = try deskWithTwin()
    let entries = [try entry(for: lg, of: backend), try entry(for: m34, of: backend, lastID: twinID)]
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let succeeded = await restorer(backend, clock: clock).reconnect(entries)

    #expect(succeeded)
    #expect(backend.mutations.isEmpty)
    #expect(clock.now().timeIntervalSince(start) < 1)
}

/// Turning the monitor on makes its twin stale, so the twin is left alone after that.
@Test func reconnectWithNoEntriesEnablesTheMonitorAndNotItsTwin() async throws {
    let backend = try deskWithTwin()
    try backend.setEnabled(m34, false)
    let before = backend.mutations.count

    let succeeded = await restorer(backend).reconnect([])

    #expect(succeeded)
    #expect(Array(backend.mutations.dropFirst(before)) == ["enable 4"])
}

/// With the monitor off the twin is a candidate, so an entry left on it gets its enable. Once the
/// monitor is on, the twin is stale, and the reconnect doesn't wait for it.
@Test func reconnectTriesATwinWhileItsMonitorIsOffAndDoesNotWaitForItAfter() async throws {
    let backend = try deskWithTwin()
    let entries = [try entry(for: m34, of: backend, lastID: twinID)]
    try backend.setEnabled(m34, false)
    let before = backend.mutations.count
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let succeeded = await restorer(backend, clock: clock).reconnect(entries)

    #expect(succeeded)
    #expect(Array(backend.mutations.dropFirst(before)) == [
        "enable 6 failed 1001", "enable 6 failed 1001", "enable 6 failed 1001", "enable 4",
    ])
    #expect(backend.topology().onlineIDs.contains(m34))
    #expect(clock.now().timeIntervalSince(start) < 5)
}

/// desk-mode's rescue with the M34WQ unplugged: its ID has left the list and its twin only shares its
/// vendor, model and serial, so neither is waited for.
@Test func reconnectWithTheMonitorUnpluggedAndItsTwinListedDoesNotWaitForEither() async throws {
    let backend = try deskWithTwin()
    let entries = [try entry(for: lg, of: backend), try entry(for: m34, of: backend)]
    backend.removePhysical(m34)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let succeeded = await restorer(backend, clock: clock).reconnect(entries)

    #expect(succeeded)
    #expect(clock.now().timeIntervalSince(start) < 10)
}

/// While the fallback is up no list shows the monitors, so one not listed may still be coming on, and
/// the reconnect has to wait for it rather than call it gone.
@Test func reconnectKeepsWaitingWhileTheFallbackHidesTheList() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    let entries = [try entry(for: lg, of: inner), try entry(for: m34, of: inner)]
    try bothOff(inner)
    var script = ScriptedBackend.Script()
    script.ignoreEnable = true
    // The LG comes on by itself 5 seconds after its enable, as a slow monitor can.
    let clock = HookClock { seconds in
        if seconds >= 5, !inner.topology().onlineIDs.contains(lg) { try? inner.setEnabled(lg, true) }
    }
    let restorer = PhysicalRestorer(
        backend: ScriptedBackend(inner, script: script),
        clock: clock,
        power: FakePowerAssertions(),
        lockURL: temporaryLockURL()
    )

    let succeeded = await restorer.reconnect(entries)

    #expect(succeeded)
}

// MARK: Never zero

@Test func aStaleTwinDoesNotCountForNeverZero() throws {
    let backend = try deskWithTwin()
    let twin = try #require(backend.topology().display(twinID))
    #expect(!NeverZeroRule.counts(twin, inProtectedSession: true))

    func isRefused(disconnecting ids: Set<DisplayID>) -> Bool {
        let result = NeverZeroRule.check(topology: backend.topology(), disconnecting: ids, inProtectedSession: false)
        if case .failure = result { return true }
        return false
    }
    #expect(isRefused(disconnecting: [lg, m34]))
    #expect(!isRefused(disconnecting: [lg]))

    // With its monitor off, the twin is a candidate to bring back, but it still isn't showing anything.
    try backend.setEnabled(m34, false)
    #expect(isRefused(disconnecting: [lg]))
}
