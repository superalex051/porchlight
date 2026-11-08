import ADModel
import CoreGraphics
import Testing

@testable import ADDisplays

private let lg: DisplayID = 2
private let m34: DisplayID = 4
private let lgUUID = "40A936A8-FEB4-4F0F-ADA4-F81E1BC66A25"
private let m34UUID = "0A4FA257-A531-4885-BA5E-76B9D0C0EF8D"

private func mode(_ w: Int, _ h: Int, hz: Double, scale: Int = 1) -> DisplayMode {
    DisplayMode(pointsWide: w, pointsHigh: h, pixelsWide: w * scale, pixelsHigh: h * scale, refreshHz: hz)
}

private let screenMode = mode(1728, 1080, hz: 60, scale: 2)

private func virtualIdentity(serial: UInt32 = 0xD249_C71D) -> DisplayIdentity {
    DisplayIdentity(
        vendor: DisplayClassifier.ownVendor,
        model: DisplayClassifier.ownProduct,
        serial: serial,
        productName: "Porch Light (Parsec)"
    )
}

private func addScreen(_ backend: SimulatedDisplayBackend, serial: UInt32 = 0xD249_C71D) -> DisplayID {
    backend.addVirtual(identity: virtualIdentity(serial: serial), mode: screenMode, modes: [screenMode])
}

private func bothOff(_ backend: SimulatedDisplayBackend) throws {
    try backend.setEnabled(m34, false)
    try backend.setEnabled(lg, false)
}

// MARK: The desk

@Test func twoMonitorDeskMatchesSpike() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let topology = backend.topology()

    #expect(topology.displays.map(\.id) == [2, 4, 1, 3, 5], "The order SLSGetDisplayList gave in the spike")
    #expect(topology.onlineIDs == [2, 4])
    #expect(topology.main?.id == lg)

    let lgRead = try #require(topology.display(lg))
    #expect(lgRead.kind == .physical)
    #expect(lgRead.identity.uuid == lgUUID)
    #expect(lgRead.identity.productName == "27GL850")
    #expect(lgRead.identity.vendor == 7789)
    #expect(lgRead.origin == DisplayOrigin(x: 0, y: 0))
    #expect(lgRead.mode == mode(2560, 1440, hz: 120))
    #expect(lgRead.isOnline && lgRead.isActive && lgRead.isMain && !lgRead.isAsleep)

    let m34Read = try #require(topology.display(m34))
    #expect(m34Read.kind == .physical)
    #expect(m34Read.identity.uuid == m34UUID)
    #expect(m34Read.identity.productName == "M34WQ")
    #expect(m34Read.identity.vendor == 7252)
    #expect(m34Read.origin == DisplayOrigin(x: -446, y: 1440))
    #expect(m34Read.mode == mode(3440, 1440, hz: 144))
    #expect(m34Read.isOnline && m34Read.isActive && !m34Read.isMain)

    for pipe: DisplayID in [1, 3, 5] {
        let read = try #require(topology.display(pipe))
        #expect(read.kind == .emptyPipe)
        #expect(read.identity.vendor == 0)
        #expect(read.identity.uuid == nil)
        #expect(read.mode == nil)
        #expect(!read.isOnline && !read.isActive)
        #expect(read.identity.registryLocation != nil)
        #expect(backend.modes(of: pipe).isEmpty)
    }

    // Selected by `-n=M34` in the golden corpus, and matched on location by the restorer.
    #expect(lgRead.identity.registryLocation?.contains("dispext0@B0000000") == true)
    #expect(m34Read.identity.registryLocation?.contains("dispext3@4000000") == true)

    // The LG flickers at 144 Hz, so a restore has to be able to tell these apart.
    let lgAtFullSize = backend.modes(of: lg).filter {
        $0.pointsWide == 2560 && $0.pointsHigh == 1440 && $0.pixelsWide == 2560
    }
    #expect(lgAtFullSize.filter { $0.refreshHz == 120 }.count == 1)
    #expect(lgAtFullSize.filter { $0.refreshHz == 144 }.count == 2)
    #expect(backend.modes(of: lg).contains(mode(1280, 720, hz: 120, scale: 2)), "Low-resolution duplicates are listed")
    #expect(backend.modes(of: m34).contains(mode(3440, 1440, hz: 144)))
    #expect(backend.mutations.isEmpty)
}

@Test func emptySeedHasNoDisplays() {
    let backend = SimulatedDisplayBackend()
    #expect(backend.topology().displays.isEmpty)
    #expect(backend.topology().main == nil)
}

// MARK: Disconnect

@Test func disableRemovesFromOnlineAndNilsUUID() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)

    let topology = backend.topology()
    #expect(topology.onlineIDs == [lg])
    #expect(topology.display(uuid: m34UUID) == nil)

    // Measured in the spike's sleep test: still listed, only some fields stay readable.
    let off = try #require(topology.display(m34))
    #expect(off.identity.uuid == nil)
    #expect(off.identity.productName == nil)
    #expect(off.identity.vendor == 7252)
    #expect(off.identity.model == 13314)
    #expect(off.identity.serial == 332)
    #expect(off.identity.registryLocation?.contains("dispext3@4000000") == true)
    #expect(off.origin == DisplayOrigin(x: -446, y: 1440))
    #expect(!off.isOnline && !off.isActive && !off.isMain && !off.isAsleep)
    #expect(off.mode == nil, "It reads as a 1x1 stub on the real Mac, which nothing may record")
    #expect(backend.modes(of: m34).isEmpty)

    // Both ends of the trip, and the ID doesn't change.
    try backend.setEnabled(m34, true)
    let back = try #require(backend.topology().display(uuid: m34UUID))
    #expect(back.id == m34)
    #expect(back.mode == mode(3440, 1440, hz: 144))
}

@Test func mainMovesToAnotherDisplayWhenMainGoesOff() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(lg, false)
    let topology = backend.topology()
    #expect(topology.main?.id == m34)
    #expect(topology.display(m34)?.origin == DisplayOrigin(x: 0, y: 0))
}

// MARK: The fallback display

@Test func lastDisplayOffBringsFallback() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    #expect(backend.topology().displays.contains { $0.kind == .osFallback } == false)
    try backend.setEnabled(lg, false)

    let fallback = try #require(backend.topology().main)
    #expect(fallback.kind == .osFallback)
    #expect(fallback.id > 5, "A new ID")
    #expect(fallback.identity.vendor == 0x756E_6B6E)
    #expect(fallback.identity.model == 0x7669_7274)
    #expect(fallback.identity.serial == 0)
    #expect(fallback.identity.productName == nil)
    #expect(fallback.identity.uuid == "A8AD2690-9F4D-4D59-8538-A5FE7CFE0F02")
    #expect(fallback.mode == mode(1920, 1080, hz: 60))
    #expect(fallback.isOnline && fallback.isActive && fallback.isMain)
    #expect(fallback.origin == DisplayOrigin(x: 0, y: 0))
}

@Test func fallbackHidesPhysicalIDs() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)

    let topology = backend.topology()
    #expect(topology.displays.count == 1, "Only the fallback, with no physicals and no empty pipes")
    #expect(topology.display(lg) == nil)
    #expect(topology.display(m34) == nil)
    #expect(topology.display(1) == nil)
    #expect(backend.modes(of: lg).isEmpty)
}

@Test func legacyOnlineCheckLiesDuringFallback() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    #expect(backend.legacyIsOnline(lg))

    // Off with another display still up: the old check tells the truth.
    try backend.setEnabled(m34, false)
    #expect(!backend.legacyIsOnline(m34))

    // Everything off: it says online, which is how the first restore enabled nothing.
    try backend.setEnabled(lg, false)
    #expect(backend.legacyIsOnline(lg))
    #expect(backend.legacyIsOnline(m34))
    #expect(!backend.topology().onlineIDs.contains(lg))
    #expect(!backend.legacyIsOnline(1), "Not for an empty pipe")
    #expect(!backend.legacyIsOnline(99), "Not for an ID nobody knows")

    try backend.setEnabled(lg, true)
    #expect(!backend.legacyIsOnline(m34), "The truth again once the fallback is gone")
}

@Test func enableByRecordedIDWorksDuringFallback() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)
    try backend.setEnabled(lg, true)
    #expect(backend.topology().display(lg)?.isOnline == true)
    #expect(backend.topology().display(lg)?.identity.uuid == lgUUID)
}

@Test func fallbackGoesWhenMonitorReturns() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)
    let firstFallback = try #require(backend.topology().main?.id)

    try backend.setEnabled(m34, true)
    let topology = backend.topology()
    #expect(!topology.displays.contains { $0.kind == .osFallback })
    #expect(topology.display(firstFallback) == nil)
    #expect(topology.main?.id == m34)
    #expect(Set(topology.displays.map(\.id)) == [1, 2, 3, 4, 5], "The physical IDs are listed again")

    // IDs are never reused, so the next fallback gets a new one.
    try backend.setEnabled(m34, false)
    let secondFallback = try #require(backend.topology().main)
    #expect(secondFallback.kind == .osFallback)
    #expect(secondFallback.id > firstFallback)
}

@Test func creatingAVirtualScreenEndsFallback() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)
    let screen = addScreen(backend)

    let topology = backend.topology()
    #expect(!topology.displays.contains { $0.kind == .osFallback })
    #expect(topology.main?.id == screen)
    #expect(topology.onlineIDs == [screen])
    #expect(Set(topology.displays.map(\.id)) == [1, 2, 3, 4, 5, screen])
    #expect(!backend.legacyIsOnline(lg))
}

@Test func losingTheLastVirtualScreenBringsFallback() throws {
    // `kill -9` of the owner with both monitors off, from the spike.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try bothOff(backend)
    #expect(backend.topology().main?.id == screen)

    backend.removeVirtual(screen)
    #expect(backend.topology().main?.kind == .osFallback)
    #expect(backend.topology().displays.count == 1)
}

@Test func virtualScreensAloneDoNotBringFallbackWhileAsleep() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)
    #expect(!backend.topology().displays.contains { $0.kind == .osFallback })
}

// MARK: Commit

@Test func commitOnOfflineThrows1001() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)

    let error = #expect(throws: DisplayBackendError.self) {
        try backend.commit([
            .origin(lg, DisplayOrigin(x: 10, y: 0)),
            .origin(m34, DisplayOrigin(x: 0, y: 1440)),
        ])
    }
    #expect(error?.code == 1001)
    #expect(error?.message.isEmpty == false)

    // One unstable display fails the whole transaction, so the LG didn't move.
    #expect(backend.topology().display(lg)?.origin == DisplayOrigin(x: 0, y: 0))
}

@Test func commitOnHiddenPhysicalThrows1001DuringFallback() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)
    let error = #expect(throws: DisplayBackendError.self) {
        try backend.commit([.origin(lg, DisplayOrigin(x: 0, y: 0))])
    }
    #expect(error?.code == 1001)
}

@Test func commitAppliesOriginsAndModesTogether() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.commit([
        .mode(lg, mode(2560, 1440, hz: 144)),
        .origin(m34, DisplayOrigin(x: 0, y: 1440)),
    ])
    let topology = backend.topology()
    #expect(topology.display(lg)?.mode?.refreshHz == 144)
    #expect(topology.display(m34)?.origin == DisplayOrigin(x: 0, y: 1440))
}

/// A process's copy of a display's modes can be stale, as the hardware run of 2026-11-07 found, so a
/// mode that isn't listed mustn't stop the rest. It's left out, and the error names the display.
@Test func commitLeavesOutAnUnlistedModeAndAppliesTheRest() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let error = #expect(throws: DisplayBackendError.self) {
        try backend.commit([
            .origin(m34, DisplayOrigin(x: 0, y: 1440)),
            .mode(lg, mode(1234, 567, hz: 60)),
            .origin(lg, DisplayOrigin(x: 0, y: 0)),
        ])
    }

    #expect(error?.code == 1001)
    #expect(error?.modesNotApplied == [lg])
    #expect(error?.message == "display 2 has no mode 1234x567@60")
    let topology = backend.topology()
    #expect(topology.display(m34)?.origin == DisplayOrigin(x: 0, y: 1440))
    #expect(topology.display(lg)?.mode?.refreshHz == 120)
    #expect(backend.mutations.suffix(2) == ["commit origin 4 (0,1440), origin 2 (0,0)", "commit left out mode 2 1234x567@60"])
}

@Test func commitOfOnlyAnUnlistedModeChangesNothingAndNamesTheDisplay() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let before = backend.topology()

    let error = #expect(throws: DisplayBackendError.self) {
        try backend.commit([.mode(lg, mode(1234, 567, hz: 60))])
    }

    #expect(error?.modesNotApplied == [lg])
    #expect(backend.topology() == before)
    #expect(backend.mutations.last == "commit left out mode 2 1234x567@60")
}

/// An offline target still fails everything, and then nothing was applied, so no mode is named.
@Test func commitWithAnOfflineTargetAndAnUnlistedModeChangesNothing() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)

    let error = #expect(throws: DisplayBackendError.self) {
        try backend.commit([
            .origin(lg, DisplayOrigin(x: 10, y: 0)),
            .mode(lg, mode(1234, 567, hz: 60)),
            .origin(m34, DisplayOrigin(x: 0, y: 1440)),
        ])
    }

    #expect(error?.code == 1001)
    #expect(error?.modesNotApplied == [])
    #expect(backend.topology().display(lg)?.origin == DisplayOrigin(x: 0, y: 0))
}

@Test func commitMatchesRefreshRoundedNotTruncated() throws {
    // A real 119.88 Hz mode is 120 Hz. `Int(hz)` would call it 119 and never find it.
    let listed = mode(2560, 1440, hz: 119.88)
    let other = mode(2560, 1440, hz: 60)
    let seed = Topology(displays: [
        DisplaySnapshot(
            id: 1,
            identity: DisplayIdentity(uuid: "AAAA", vendor: 1, model: 1, serial: 1),
            kind: .physical,
            isOnline: true,
            isActive: true,
            isMain: true,
            isAsleep: false,
            origin: DisplayOrigin(x: 0, y: 0),
            mode: other
        )
    ])
    let backend = SimulatedDisplayBackend(seed: seed, modes: [1: [other, listed]])
    try backend.commit([.mode(1, mode(2560, 1440, hz: 120))])
    #expect(backend.topology().display(1)?.mode == listed)
}

@Test func commitToOriginZeroMovesMain() throws {
    // `setMain` from the plan: everything shifts by the screen's old origin, in one transaction.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try backend.commit([.origin(screen, DisplayOrigin(x: -1728, y: 0))])
    try backend.commit([
        .origin(screen, DisplayOrigin(x: 0, y: 0)),
        .origin(lg, DisplayOrigin(x: 1728, y: 0)),
        .origin(m34, DisplayOrigin(x: 1282, y: 1440)),
    ])
    let topology = backend.topology()
    #expect(topology.main?.id == screen)
    #expect(topology.display(lg)?.isMain == false)
    #expect(topology.display(lg)?.origin == DisplayOrigin(x: 1728, y: 0))
    #expect(topology.display(m34)?.origin == DisplayOrigin(x: 1282, y: 1440))
}

@Test func mainStaysAtOriginZeroWhenItIsMovedAlone() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.commit([.origin(lg, DisplayOrigin(x: 100, y: -50))])
    let topology = backend.topology()
    #expect(topology.main?.id == lg)
    #expect(topology.display(lg)?.origin == DisplayOrigin(x: 0, y: 0))
    #expect(topology.display(m34)?.origin == DisplayOrigin(x: -546, y: 1490))
}

@Test func restoreWithScreenAliveMovesItAsideAsInSpike() throws {
    // The spike's end path. The screen is main at (0,0), and the restorer doesn't position it.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try backend.commit([.origin(screen, DisplayOrigin(x: -1728, y: 0))])
    try backend.commit([
        .origin(screen, DisplayOrigin(x: 0, y: 0)),
        .origin(lg, DisplayOrigin(x: 1728, y: 0)),
        .origin(m34, DisplayOrigin(x: 1282, y: 1440)),
    ])
    try bothOff(backend)

    // Off, they keep the origin they had when they went off.
    let during = backend.topology()
    #expect(during.display(lg)?.origin == DisplayOrigin(x: 1728, y: 0))
    #expect(during.display(m34)?.origin == DisplayOrigin(x: 1282, y: 1440))

    try backend.setEnabled(lg, true)
    try backend.setEnabled(m34, true)
    try backend.commit([
        .origin(lg, DisplayOrigin(x: 0, y: 0)),
        .origin(m34, DisplayOrigin(x: -446, y: 1440)),
    ])

    let after = backend.topology()
    #expect(after.main?.id == lg)
    #expect(after.display(lg)?.origin == DisplayOrigin(x: 0, y: 0))
    #expect(after.display(m34)?.origin == DisplayOrigin(x: -446, y: 1440))
    #expect(after.display(screen)?.origin == DisplayOrigin(x: -1728, y: 0), "Measured in the spike's end path")

    // Destroying the screen afterward left the arrangement intact.
    backend.removeVirtual(screen)
    let end = backend.topology()
    #expect(end.main?.id == lg)
    #expect(end.display(m34)?.origin == DisplayOrigin(x: -446, y: 1440))
}

// MARK: Flap

@Test func flapGoesOfflineThenReturns() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.scriptFlap(lg, offlineReads: 2)
    let screen = addScreen(backend)
    try bothOff(backend)
    #expect(!backend.topology().onlineIDs.contains(lg), "Nothing happens before the enable")

    try backend.setEnabled(lg, true)
    #expect(backend.topology().onlineIDs.contains(lg), "The one online read")

    let first = backend.topology()
    #expect(!first.onlineIDs.contains(lg), "First offline read")
    #expect(first.display(lg)?.identity.uuid == nil)
    #expect(first.onlineIDs == [screen])

    // The spike's failure: enable said yes, a second later the arrangement step failed.
    let error = #expect(throws: DisplayBackendError.self) {
        try backend.commit([.origin(lg, DisplayOrigin(x: 0, y: 0))])
    }
    #expect(error?.code == 1001)

    #expect(!backend.topology().onlineIDs.contains(lg), "Second offline read")
    #expect(backend.topology().onlineIDs.contains(lg), "Back")
    #expect(backend.topology().onlineIDs.contains(lg), "And it stays back")
    try backend.commit([.origin(lg, DisplayOrigin(x: 0, y: 0))])
}

@Test func flapOnTheOnlyDisplayBringsFallbackWhileItIsDown() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)
    backend.scriptFlap(lg, offlineReads: 1)
    try backend.setEnabled(lg, true)

    #expect(backend.topology().onlineIDs == [lg])
    #expect(backend.topology().main?.kind == .osFallback)
    let back = backend.topology()
    #expect(back.main?.id == lg)
    #expect(!back.displays.contains { $0.kind == .osFallback })
}

@Test func enablingDuringAFlapDoesNotRestartIt() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.scriptFlap(m34, offlineReads: 2)
    try backend.setEnabled(m34, false)
    try backend.setEnabled(m34, true)
    #expect(backend.topology().onlineIDs.contains(m34))
    #expect(!backend.topology().onlineIDs.contains(m34))
    try backend.setEnabled(m34, true)
    #expect(!backend.topology().onlineIDs.contains(m34), "The second offline read still happens")
    #expect(backend.topology().onlineIDs.contains(m34))
}

// MARK: Sleep

@Test func sleepingIsOnlineNotActive() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.setAsleep(lg, true)
    backend.setAsleep(m34, true)

    let topology = backend.topology()
    #expect(topology.onlineIDs == [lg, m34])
    let read = try #require(topology.display(lg))
    #expect(read.isOnline && !read.isActive && read.isAsleep)
    #expect(read.identity.uuid == lgUUID)
    #expect(read.mode == mode(2560, 1440, hz: 120))
    #expect(read.isMain)

    backend.wakeAll()
    let awake = try #require(backend.topology().display(lg))
    #expect(awake.isActive && !awake.isAsleep)
}

@Test func enableThrows1014WhileNothingIsActive() throws {
    // Monitors off, then the screen sleeps too. On the real Mac this blocks about 10 s first.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)
    #expect(backend.topology().onlineIDs == [screen])
    #expect(!backend.topology().displays.contains { $0.isActive })

    for id in [lg, m34] {
        let error = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(id, true) }
        #expect(error?.code == 1014)
    }
    #expect(backend.topology().onlineIDs == [screen], "No monitor came back")
}

@Test func enableWorksAfterWakeAll() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)

    backend.wakeAll()
    try backend.setEnabled(lg, true)
    try backend.setEnabled(m34, true)
    #expect(backend.topology().onlineIDs == [lg, m34, screen])
}

@Test func declaringUserActivityCanWakeTheSimulator() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try bothOff(backend)
    backend.setAsleep(screen, true)

    let power = FakePowerAssertions(onDeclare: backend.wakeAll)
    power.declareUserActivity()
    try backend.setEnabled(lg, true)
    #expect(backend.topology().onlineIDs.contains(lg))
}

@Test func disconnectAndArrangeWorkWhileAsleep() throws {
    // Starting a session during display sleep: all of it succeeded, and the new screen was active.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.setAsleep(lg, true)
    backend.setAsleep(m34, true)
    let screen = addScreen(backend)
    #expect(backend.topology().display(screen)?.isActive == true)

    try backend.commit([.origin(m34, DisplayOrigin(x: 0, y: 1440))])
    try bothOff(backend)
    #expect(backend.topology().onlineIDs == [screen])
    #expect(backend.topology().main?.id == screen)
}

@Test func wakeLeavesADisconnectAlone() throws {
    // The sleep test: a disconnect made during sleep held through the wake.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    backend.setAsleep(lg, true)
    backend.setAsleep(m34, true)
    try bothOff(backend)
    backend.wakeAll()
    #expect(backend.topology().onlineIDs == [screen])
}

@Test func wakeReconnectsDisabled() throws {
    // The Nov 5 failure the spec still guards against: a wake that undoes a disconnect.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    backend.setAsleep(screen, true)
    try backend.setEnabled(m34, false)
    try backend.setEnabled(lg, false)

    backend.simulateWake(reconnecting: [m34])

    let topology = backend.topology()
    #expect(topology.onlineIDs == [m34, screen])
    #expect(topology.display(m34)?.identity.uuid == m34UUID)
    #expect(topology.display(screen)?.isAsleep == false)
    #expect(topology.display(lg)?.isOnline == false)
    #expect(!backend.mutations.contains { $0.contains("enable \(m34)") }, "The wake did it, not a caller")
}

// MARK: Scripted failures

@Test func scriptedEnableFailuresRunOutThenItWorks() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    backend.setEnableFails(m34, 2)

    for _ in 0..<2 {
        let error = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(m34, true) }
        #expect(error?.code == 1014)
    }
    #expect(!backend.topology().onlineIDs.contains(m34))

    try backend.setEnabled(m34, true)
    #expect(backend.topology().onlineIDs.contains(m34))
}

@Test func removePhysicalIsUnplugged() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.removePhysical(m34)

    #expect(backend.topology().display(m34) == nil)
    #expect(!backend.legacyIsOnline(m34))
    let enable = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(m34, true) }
    #expect(enable?.code == 1001)
    let commit = #expect(throws: DisplayBackendError.self) {
        try backend.commit([.origin(m34, DisplayOrigin(x: 0, y: 1440))])
    }
    #expect(commit?.code == 1001)
}

@Test func removingTheLastPhysicalBringsFallback() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.removePhysical(m34)
    backend.removePhysical(lg)
    #expect(backend.topology().main?.kind == .osFallback)
}

@Test func displayIDZeroThrows1001() {
    // What a UUID lookup returns for a monitor that's off. The live backend refuses it the same way.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let enable = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(0, true) }
    #expect(enable?.code == 1001)
    let disable = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(0, false) }
    #expect(disable?.code == 1001)
    let commit = #expect(throws: DisplayBackendError.self) {
        try backend.commit([.origin(0, DisplayOrigin(x: 0, y: 0))])
    }
    #expect(commit?.code == 1001)
}

@Test func enablingAnEmptyPipeFails() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let error = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(1, true) }
    #expect(error?.code == 1001)
}

// MARK: Stale twins

private let earlierPort = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext2@0/IOMobileFramebufferShim"

@Test func staleTwinReadsAsAnEmptyPipeWhileItsMonitorIsOnline() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let twin = try #require(backend.scriptStaleTwin(of: m34, registryLocation: earlierPort))

    let topology = backend.topology()
    #expect(twin == 6, "A new ID, as the real record has")
    #expect(topology.displays.map(\.id) == [2, 4, 1, 3, 5, 6])
    let read = try #require(topology.display(twin))
    let real = try #require(topology.display(m34))
    #expect(read.kind == .emptyPipe)
    #expect(!read.isOnline && !read.isActive)
    #expect(read.mode == nil)
    #expect(read.identity.uuid == nil)
    #expect(read.identity.productName == nil)
    #expect(read.identity.vendor == real.identity.vendor)
    #expect(read.identity.model == real.identity.model)
    #expect(read.identity.serial == real.identity.serial)
    #expect(read.identity.registryLocation == earlierPort)
    #expect(backend.modes(of: twin).isEmpty)
    #expect(backend.mutations.isEmpty, "Scripting the world isn't a mutation")

    let error = #expect(throws: DisplayBackendError.self) { try backend.setEnabled(twin, true) }
    #expect(error?.code == 1001)
    #expect(backend.mutations == ["enable 6 failed 1001"])
    #expect(!backend.topology().onlineIDs.contains(twin))
}

@Test func staleTwinReadsAsPhysicalWhileItsMonitorIsOffAndNeverComesOn() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let twin = try #require(backend.scriptStaleTwin(of: m34, registryLocation: earlierPort))
    try backend.setEnabled(m34, false)

    #expect(backend.topology().display(twin)?.kind == .physical)
    #expect(backend.topology().display(m34)?.kind == .physical)
    #expect(throws: DisplayBackendError.self) { try backend.setEnabled(twin, true) }
    backend.simulateWake(reconnecting: [twin])
    #expect(backend.topology().display(twin)?.isOnline == false)

    try backend.setEnabled(m34, true)
    #expect(backend.topology().display(twin)?.kind == .emptyPipe)
}

@Test func staleTwinNeedsAMonitorToCopy() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    #expect(backend.scriptStaleTwin(of: 1, registryLocation: earlierPort) == nil, "An empty pipe")
    #expect(backend.scriptStaleTwin(of: screen, registryLocation: earlierPort) == nil)
    #expect(backend.scriptStaleTwin(of: 99, registryLocation: earlierPort) == nil)
}

// MARK: Virtual screens

@Test func virtualIDsIncreaseAndUUIDStable() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    let first = addScreen(backend)
    #expect(first > 5)
    let firstRead = try #require(backend.topology().display(first))
    #expect(firstRead.kind == .ownVirtual)
    #expect(firstRead.mode == screenMode)
    #expect(firstRead.isOnline && firstRead.isActive)
    let uuid = try #require(firstRead.identity.uuid)

    backend.removeVirtual(first)
    #expect(backend.topology().display(first) == nil)

    let second = addScreen(backend)
    #expect(second > first, "The ID changes every time, and callers have to re-read it")
    #expect(backend.topology().display(second)?.identity.uuid == uuid)

    let other = addScreen(backend, serial: 0x933B_5BDE)
    #expect(other > second)
    #expect(backend.topology().display(other)?.identity.uuid != uuid)

    // Across processes too, so the same fixture always gives the same answer.
    let elsewhere = SimulatedDisplayBackend.twoMonitorDesk()
    let there = addScreen(elsewhere)
    #expect(elsewhere.topology().display(there)?.identity.uuid == uuid)
}

@Test func virtualUUIDIgnoresWhatTheCallerPassed() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    var identity = virtualIdentity()
    identity.uuid = "NOT-A-REAL-UUID"
    let id = backend.addVirtual(identity: identity, mode: screenMode, modes: [screenMode])
    let plain = addScreen(backend)
    let expected = try #require(backend.topology().display(plain)?.identity.uuid)
    #expect(backend.topology().display(id)?.identity.uuid == expected)
}

@Test func setVirtualModeChangesItInPlace() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    let bigger = mode(1920, 1200, hz: 60, scale: 2)

    backend.setVirtualMode(screen, bigger)

    #expect(backend.topology().display(screen)?.mode == bigger)
    #expect(backend.modes(of: screen) == [bigger])
}

@Test func virtualHooksIgnorePhysicalDisplays() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.removeVirtual(lg)
    backend.setVirtualMode(lg, screenMode)
    #expect(backend.topology().display(lg)?.mode == mode(2560, 1440, hz: 120))
    #expect(backend.mutations.isEmpty)
}

@Test func newVirtualKindComesFromTheClassifier() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let parsec = backend.addVirtual(
        identity: DisplayIdentity(vendor: 0x1234, model: 0x5678, serial: 1, productName: "Parsec Virtual Display"),
        mode: mode(1920, 1080, hz: 60),
        modes: [mode(1920, 1080, hz: 60)]
    )
    #expect(backend.topology().display(parsec)?.kind == .parsecVirtual)
}

// MARK: Mutation log

@Test func mutationsAreRecorded() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    try backend.setEnabled(m34, true)
    try backend.commit([.origin(m34, DisplayOrigin(x: 0, y: 1440)), .mode(lg, mode(2560, 1440, hz: 120))])
    let screen = addScreen(backend)
    backend.setVirtualMode(screen, mode(1512, 982, hz: 60, scale: 2))
    backend.removeVirtual(screen)

    #expect(backend.mutations == [
        "disable 4",
        "enable 4",
        "commit origin 4 (0,1440), mode 2 2560x1440@120",
        "addVirtual 6 1728x1080@60 hiDPI",
        "setVirtualMode 6 1512x982@60 hiDPI",
        "removeVirtual 6",
    ])
}

@Test func failedAttemptsAreRecordedAsFailed() throws {
    // A restorer test has to be able to count retries and see what never reached the display.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    backend.setEnableFails(m34, 1)
    #expect(throws: DisplayBackendError.self) { try backend.setEnabled(m34, true) }
    #expect(throws: DisplayBackendError.self) { try backend.commit([.origin(m34, DisplayOrigin(x: 0, y: 0))]) }

    #expect(backend.mutations == [
        "disable 4",
        "enable 4 failed 1014",
        "commit failed 1001: display 4 is offline",
    ])
}

@Test func anEmptyCommitChangesNothing() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.commit([])
    #expect(backend.mutations.isEmpty)
}

@Test func testHooksAreNotMutations() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.setAsleep(lg, true)
    backend.wakeAll()
    backend.simulateWake(reconnecting: [])
    backend.scriptFlap(lg, offlineReads: 1)
    backend.setEnableFails(lg, 1)
    backend.removePhysical(m34)
    #expect(backend.mutations.isEmpty)
}

// MARK: Seeding

@Test func seedKeepsOfflineDisplaysOfflineUntilEnabled() throws {
    let online = DisplaySnapshot(
        id: 7,
        identity: DisplayIdentity(uuid: "ONLINE", vendor: 1, model: 1, serial: 1),
        kind: .physical,
        isOnline: true,
        isActive: true,
        isMain: true,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0),
        mode: mode(1920, 1080, hz: 60)
    )
    let offline = DisplaySnapshot(
        id: 9,
        identity: DisplayIdentity(vendor: 2, model: 2, serial: 2),
        kind: .physical,
        isOnline: false,
        isActive: false,
        isMain: false,
        isAsleep: false,
        origin: DisplayOrigin(x: 1920, y: 0)
    )
    let backend = SimulatedDisplayBackend(seed: Topology(displays: [offline, online]))

    #expect(backend.topology().onlineIDs == [7])
    #expect(backend.topology().main?.id == 7)
    #expect(backend.modes(of: 7) == [mode(1920, 1080, hz: 60)], "With no list, the current mode is the list")

    try backend.setEnabled(9, true)
    #expect(backend.topology().onlineIDs == [7, 9])

    let screen = addScreen(backend)
    #expect(screen == 10, "Past every seeded ID")
}

@Test func seedWithOnlyDisabledPhysicalsIsInFallback() {
    let offline = DisplaySnapshot(
        id: 3,
        identity: DisplayIdentity(vendor: 2, model: 2, serial: 2),
        kind: .physical,
        isOnline: false,
        isActive: false,
        isMain: false,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0)
    )
    let backend = SimulatedDisplayBackend(seed: Topology(displays: [offline]))
    #expect(backend.topology().main?.kind == .osFallback)
}

@Test func seedAlreadyInFallbackKeepsItsFallback() throws {
    let fallback = DisplaySnapshot(
        id: 12,
        identity: DisplayIdentity(uuid: "A8AD2690-9F4D-4D59-8538-A5FE7CFE0F02", vendor: 0x756E_6B6E, model: 0x7669_7274, serial: 0),
        kind: .osFallback,
        isOnline: true,
        isActive: true,
        isMain: true,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0),
        mode: mode(1920, 1080, hz: 60)
    )
    let backend = SimulatedDisplayBackend(seed: Topology(displays: [fallback]))
    #expect(backend.topology().main?.id == 12)

    let screen = addScreen(backend)
    #expect(screen == 13)
    #expect(backend.topology().display(12) == nil)
    #expect(backend.topology().main?.id == screen)
}

// MARK: Events and power

@Test func manualEventsReachEverySubscriber() async {
    let source = ManualTopologyEvents()
    var first = source.events().makeAsyncIterator()
    var second = source.events().makeAsyncIterator()

    source.fire()

    #expect(await first.next() != nil)
    #expect(await second.next() != nil)
}

@Test func liveEventsIgnoreBeginFlags() {
    #expect(!LiveTopologyEvents.isChangeFinished(CGDisplayChangeSummaryFlags.beginConfigurationFlag))
    // Values from the spike's log, including the empty one seen at display sleep.
    #expect(LiveTopologyEvents.isChangeFinished(CGDisplayChangeSummaryFlags(rawValue: 0x111A)))
    #expect(LiveTopologyEvents.isChangeFinished(CGDisplayChangeSummaryFlags(rawValue: 0x1000)))
    #expect(LiveTopologyEvents.isChangeFinished(CGDisplayChangeSummaryFlags(rawValue: 0)))
}

@Test func fakePowerRecordsCalls() {
    let declared = FakePowerAssertions()
    declared.declareUserActivity()
    let token = declared.holdNoDisplaySleep(reason: "restore")
    #expect(declared.activeHoldCount == 1)
    token.release()
    token.release()
    #expect(declared.activeHoldCount == 0)
    #expect(declared.declareCount == 1)
    #expect(declared.calls == ["declare", "hold restore", "release restore"])
}

@Test func fakePowerRunsItsDeclareHook() {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    backend.setAsleep(lg, true)
    let power = FakePowerAssertions(onDeclare: backend.wakeAll)
    power.declareUserActivity()
    #expect(backend.topology().display(lg)?.isActive == true)
}

@Test func droppedTokenReleasesItsHold() {
    let power = FakePowerAssertions()
    do {
        _ = power.holdNoDisplaySleep(reason: "dropped")
    }
    #expect(power.activeHoldCount == 0)
}

@Test func failedListReadShowsOnlyWhatIsOnlineAndSaysSo() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    backend.setListReadFails(1)

    let failed = backend.topology()
    #expect(failed.listReadFailed)
    #expect(failed.displays.map(\.id) == [lg])

    let next = backend.topology()
    #expect(!next.listReadFailed)
    #expect(next.display(m34) != nil)
}
