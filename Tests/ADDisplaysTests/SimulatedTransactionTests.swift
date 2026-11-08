import ADModel
import Testing

@testable import ADDisplays

// `setEnabled` with a list of displays: one transaction, all or nothing.

private let lg: DisplayID = 2
private let m34: DisplayID = 4

private func addScreen(_ backend: SimulatedDisplayBackend) -> DisplayID {
    let mode = DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 60)
    return backend.addVirtual(
        identity: DisplayIdentity(vendor: DisplayClassifier.ownVendor, model: DisplayClassifier.ownProduct, serial: 1),
        mode: mode,
        modes: [mode]
    )
}

@Test func aListSwitchesInOneTransaction() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)

    try backend.setEnabled([m34, lg], false)

    #expect(backend.topology().onlineIDs == [screen])
    #expect(backend.switchTransactions == ["disable 4 2"])
    #expect(backend.mutations.suffix(2) == ["disable 4", "disable 2"], "One line per display, as before")
    #expect(backend.fallbackAppearances == 0)
}

@Test func aSingleSwitchIsATransactionOfOne() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try backend.setEnabled(m34, false)

    #expect(backend.switchTransactions == ["disable 4"])
    #expect(backend.mutations == ["disable 4"])
}

@Test func anEmptyListDoesNothing() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try backend.setEnabled([], false)
    try backend.setEnabled([], true)

    #expect(backend.switchTransactions.isEmpty)
    #expect(backend.mutations.isEmpty)
    #expect(backend.topology().onlineIDs == [lg, m34])
}

@Test func oneBadIDInAListChangesNothing() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    let error = #expect(throws: DisplayBackendError.self) { try backend.setEnabled([m34, 77], false) }

    #expect(error?.code == 1001)
    #expect(error?.message == "there is no display 77 to switch")
    #expect(backend.topology().onlineIDs == [lg, m34], "The good one stayed on too")
    #expect(backend.switchTransactions == ["disable 4 77 failed 1001"])
}

@Test func turningBothOffAtOnceBringsTheFallbackUpOnce() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try backend.setEnabled([m34, lg], false)

    #expect(backend.fallbackAppearances == 1)
    #expect(backend.topology().online.map(\.kind) == [.osFallback])
}

@Test func aListComesBackInOneTransaction() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled([m34, lg], false)

    try backend.setEnabled([lg, m34], true)

    #expect(backend.topology().onlineIDs == [lg, m34])
    #expect(backend.switchTransactions == ["disable 4 2", "enable 2 4"])
}

@Test func aScriptedEnableFailureInAListBringsNothingBack() throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try backend.setEnabled([m34, lg], false)
    backend.setEnableFails(m34, 1)

    let error = #expect(throws: DisplayBackendError.self) { try backend.setEnabled([lg, m34], true) }

    #expect(error?.code == 1014)
    #expect(backend.topology().onlineIDs == [screen])
    #expect(backend.switchTransactions.last == "enable 2 4 failed 1014")

    try backend.setEnabled([lg, m34], true)
    #expect(backend.topology().onlineIDs == [lg, m34, screen], "The failure was used up")
}
