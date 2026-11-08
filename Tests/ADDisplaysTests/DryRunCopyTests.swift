import ADModel
import Testing

@testable import ADDisplays

private let monitor: DisplayID = 2
private let stalePipe: DisplayID = 4
private let monitorMode = DisplayMode(pointsWide: 2560, pointsHigh: 1440, pixelsWide: 2560, pixelsHigh: 1440, refreshHz: 120)

/// What a live read gives: a monitor that's on, and an offline display with a vendor but no UUID and
/// no mode, like the M34WQ's old pipe on the test desk.
private func liveRead() -> (Topology, [DisplayID: [DisplayMode]]) {
    let on = DisplaySnapshot(
        id: monitor,
        identity: DisplayIdentity(uuid: "40A936A8-FEB4-4F0F-ADA4-F81E1BC66A25", vendor: 7789, model: 23423, serial: 198_499),
        kind: .physical,
        isOnline: true,
        isActive: true,
        isMain: true,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0),
        mode: monitorMode
    )
    let off = DisplaySnapshot(
        id: stalePipe,
        identity: DisplayIdentity(vendor: 7252, model: 13314, serial: 332),
        kind: .physical,
        isOnline: false,
        isActive: false,
        isMain: false,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0),
        mode: nil
    )
    return (Topology(displays: [on, off]), [monitor: [monitorMode], stalePipe: []])
}

/// The copy knows nothing about a display that was off when it was made: no UUID, no mode. Brought on,
/// it would be online with no mode, and a session start in the copy would refuse, unable to read it. On
/// the real Mac such a display has been a stale pipe that every reconnect waited on in vain.
@Test func aDisplayOffWhenTheCopyIsMadeCantBeBroughtOnInTheCopy() {
    let (topology, modes) = liveRead()
    let copy = SimulatedDisplayBackend.copy(of: topology, modes: modes)

    #expect(throws: DisplayBackendError.self) { try copy.setEnabled(stalePipe, true) }
    #expect(copy.topology().display(stalePipe)?.isOnline == false)
    #expect(copy.mutations.last?.hasPrefix("enable \(stalePipe) failed") == true)
}

@Test func aDisplayOnWhenTheCopyIsMadeGoesOffAndComesBack() throws {
    let (topology, modes) = liveRead()
    let copy = SimulatedDisplayBackend.copy(of: topology, modes: modes)

    try copy.setEnabled(monitor, false)
    try copy.setEnabled(monitor, true)

    #expect(copy.topology().display(monitor)?.isOnline == true)
    #expect(copy.topology().display(monitor)?.mode == monitorMode)
}
