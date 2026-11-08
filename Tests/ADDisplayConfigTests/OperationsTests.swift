import ADDisplays
import ADFoundation
import ADModel
import Testing

@testable import ADDisplayConfig

private func operations(_ backend: any DisplayBackend, clock: any ADClock = AutoAdvancingClock()) -> DisplayOperations {
    DisplayOperations(backend: backend, clock: clock)
}

// MARK: Main

@Test func setMainShiftsAllOrigins() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    try backend.commit([.origin(screen, DisplayOrigin(x: -1728, y: 0))])
    let before = backend.mutations.count

    try await operations(backend).setMain(screen)

    let topology = backend.topology()
    #expect(topology.main?.id == screen)
    #expect(topology.display(screen)?.origin == DisplayOrigin(x: 0, y: 0))
    #expect(topology.display(lg)?.origin == DisplayOrigin(x: 1728, y: 0))
    #expect(topology.display(m34)?.origin == DisplayOrigin(x: 1282, y: 1440))
    #expect(backend.mutations.dropFirst(before).count == 1, "One transaction")
}

@Test func setMainLeavesAnEmptyPipeReadingOnlineOutOfTheTransaction() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    var script = ScriptedBackend.Script()
    // A display that has just gone away reads as all ones, and can read online once.
    script.rewrite = { topology in
        topology.displays.append(
            DisplaySnapshot(
                id: 40,
                identity: DisplayIdentity(vendor: 0xFFFF_FFFF, model: 0xFFFF_FFFF, serial: 0xFFFF_FFFF),
                kind: .emptyPipe,
                isOnline: true,
                isActive: false,
                isMain: false,
                isAsleep: false,
                origin: DisplayOrigin(x: 0, y: 0)
            )
        )
    }

    try await operations(ScriptedBackend(backend, script: script)).setMain(screen)

    #expect(backend.topology().main?.id == screen)
}

@Test func setMainOnTheMainDisplayChangesNothing() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try await operations(backend).setMain(lg)

    #expect(backend.mutations.isEmpty)
}

@Test func setMainThrowsIfTheDisplayIsNotOnline() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)
    let before = backend.mutations.count

    await #expect(throws: DisplayOperationError.notOnline(m34)) {
        try await operations(backend).setMain(m34)
    }
    #expect(backend.mutations.count == before)
}

@Test func setMainThrowsIfItDoesNotTakeHold() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)
    var script = ScriptedBackend.Script()
    script.ignoredCommits = .max

    await #expect(throws: DisplayOperationError.notMain(screen)) {
        try await operations(ScriptedBackend(backend, script: script)).setMain(screen)
    }
}

// MARK: Placement

@Test func placementReturnsActualOrigin() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let wanted = DisplayOrigin(x: 2560, y: 0)

    let placed = try await operations(backend).setPlacement(m34, wanted)
    #expect(placed == wanted)
    #expect(backend.topology().display(m34)?.origin == wanted)

    // Main can't leave (0,0), so moving it alone stays where it was, and the answer has to say so.
    let moved = try await operations(backend).setPlacement(lg, DisplayOrigin(x: 100, y: 100))
    #expect(moved == DisplayOrigin(x: 0, y: 0))
}

@Test func placementThrowsIfTheDisplayIsNotOnline() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)

    await #expect(throws: DisplayOperationError.notOnline(m34)) {
        try await operations(backend).setPlacement(m34, DisplayOrigin(x: 2560, y: 0))
    }
}

// MARK: Connect and disconnect

@Test func disconnectVerifiesLeavingOnlineList() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try await operations(backend).disconnect(m34)

    #expect(backend.topology().onlineIDs == [lg])
    #expect(backend.mutations == ["disable 4"])
}

@Test func disconnectThrowsIfStillOnlineAfter3s() async throws {
    var script = ScriptedBackend.Script()
    script.ignoreDisable = true
    let clock = AutoAdvancingClock()
    let start = clock.now()

    await #expect(throws: DisplayOperationError.stillOnline(m34)) {
        try await operations(ScriptedBackend(.twoMonitorDesk(), script: script), clock: clock).disconnect(m34)
    }

    let elapsed = clock.now().timeIntervalSince(start)
    #expect(elapsed >= 3 && elapsed < 4)
}

@Test func connectWorksByRecordedIDDuringFallback() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try bothOff(backend)

    try await operations(backend).connect(lg)

    #expect(backend.topology().onlineIDs == [lg])
}

@Test func connectThrowsIfItNeverComesOnline() async throws {
    let inner = SimulatedDisplayBackend.twoMonitorDesk()
    try inner.setEnabled(m34, false)
    var script = ScriptedBackend.Script()
    script.ignoreEnable = true

    await #expect(throws: DisplayOperationError.didNotReturn(m34)) {
        try await operations(ScriptedBackend(inner, script: script)).connect(m34)
    }
}

// MARK: Modes

@Test func selectModeRefreshOnly() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try await operations(backend).selectMode(lg, resolution: nil, refreshHz: 100, hiDPI: nil)

    #expect(backend.topology().display(lg)?.mode?.matches(mode(2560, 1440, hz: 100)) == true)
}

@Test func selectModeUnknownThrows() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    let error = await #expect(throws: DisplayOperationError.self) {
        try await operations(backend).selectMode(lg, resolution: nil, refreshHz: 77, hiDPI: nil)
    }
    #expect(error == .noSuchMode(lg, "2560x1440 at 77 Hz"))
    #expect(backend.mutations.isEmpty)
    #expect(backend.topology().display(lg)?.mode?.matches(lg120) == true)
}

@Test func selectModeKeepsTheCurrentRateWherePossible() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try await operations(backend).selectMode(lg, resolution: ScreenSize(w: 1920, h: 1080), refreshHz: nil, hiDPI: nil)

    #expect(backend.topology().display(lg)?.mode?.matches(mode(1920, 1080, hz: 120)) == true)
}

@Test func selectModeTakesTheFastestRateWhenTheCurrentOneIsNotOffered() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    // The M34WQ is at 144 Hz, and offers 50, 60 and 120 at this size.
    try await operations(backend).selectMode(m34, resolution: ScreenSize(w: 1920, h: 1080), refreshHz: nil, hiDPI: nil)

    #expect(backend.topology().display(m34)?.mode?.matches(mode(1920, 1080, hz: 120)) == true)
}

@Test func selectModeHonorsHiDPIAndKeepsItWhenUnspecified() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let hiDPI = mode(1280, 720, hz: 120, scale: 2)

    try await operations(backend).selectMode(lg, resolution: ScreenSize(w: 1280, h: 720), refreshHz: nil, hiDPI: true)
    #expect(backend.topology().display(lg)?.mode?.matches(hiDPI) == true)

    // This size is offered both ways, and only the rate changes.
    try await operations(backend).selectMode(lg, resolution: nil, refreshHz: 100, hiDPI: nil)
    #expect(backend.topology().display(lg)?.mode?.matches(mode(1280, 720, hz: 100, scale: 2)) == true)
}

@Test func selectModeNeverChangesAnUnspecifiedResolution() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    // 75 Hz exists on the LG, but only at other sizes.
    await #expect(throws: DisplayOperationError.noSuchMode(lg, "2560x1440 at 75 Hz")) {
        try await operations(backend).selectMode(lg, resolution: nil, refreshHz: 75, hiDPI: nil)
    }
    #expect(backend.mutations.isEmpty)
}

@Test func selectModeThrowsIfTheDisplayIsNotOnline() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    try backend.setEnabled(m34, false)

    await #expect(throws: DisplayOperationError.notOnline(m34)) {
        try await operations(backend).selectMode(m34, resolution: nil, refreshHz: 144, hiDPI: nil)
    }
}

@Test func selectModeThrowsIfTheModeDoesNotTakeHold() async throws {
    var script = ScriptedBackend.Script()
    script.ignoredCommits = .max

    await #expect(throws: DisplayOperationError.modeNotApplied(lg, "2560x1440 at 100 Hz non-HiDPI")) {
        try await operations(ScriptedBackend(.twoMonitorDesk(), script: script))
            .selectMode(lg, resolution: nil, refreshHz: 100, hiDPI: nil)
    }
}

// MARK: Errors

@Test func errorsSayWhatWentWrong() {
    #expect("\(DisplayOperationError.notOnline(4))" == "display 4 is not online")
    #expect("\(DisplayOperationError.stillOnline(4))" == "display 4 is still online 3 seconds after turning it off")
    #expect("\(DisplayOperationError.noSuchMode(4, "1x1 at 60 Hz"))" == "display 4 has no mode 1x1 at 60 Hz")
}
