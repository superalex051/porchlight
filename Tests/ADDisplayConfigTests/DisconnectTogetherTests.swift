import ADDisplays
import ADFoundation
import ADModel
import Testing

@testable import ADDisplayConfig

// `DisplayOperations.disconnect` with a list: one backend transaction, then the same wait as for one.

@Test func disconnectingAListIsOneBackendCall() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let screen = addScreen(backend)

    let seconds = try await DisplayOperations(backend: backend, clock: AutoAdvancingClock()).disconnect([m34, lg])

    #expect(backend.topology().onlineIDs == [screen])
    #expect(backend.switchTransactions == ["disable 4 2"])
    #expect(seconds == 0)
}

@Test func disconnectingAListReturnsHowLongTheBackendCallTook() async throws {
    let clock = AutoAdvancingClock()
    var script = ScriptedBackend.Script()
    script.beforeCall = { clock.advance(by: 10) }
    let simulated = SimulatedDisplayBackend.twoMonitorDesk()
    _ = addScreen(simulated)

    let seconds = try await DisplayOperations(backend: ScriptedBackend(simulated, script: script), clock: clock)
        .disconnect([m34, lg])

    #expect(seconds == 10)
}

@Test func disconnectingAListNamesTheFirstStillOnlineAfter3s() async throws {
    var script = ScriptedBackend.Script()
    script.ignoreDisable = true
    let clock = AutoAdvancingClock()
    let start = clock.now()
    let operations = DisplayOperations(backend: ScriptedBackend(.twoMonitorDesk(), script: script), clock: clock)

    await #expect(throws: DisplayOperationError.stillOnline(lg)) {
        try await operations.disconnect([lg, m34])
    }

    let elapsed = clock.now().timeIntervalSince(start)
    #expect(elapsed >= 3 && elapsed < 4)
}

@Test func disconnectingAListNamesTheOneStillOnline() async throws {
    let simulated = SimulatedDisplayBackend.twoMonitorDesk()
    _ = addScreen(simulated)
    var script = ScriptedBackend.Script()
    // The LG goes off, and the M34WQ keeps reading online.
    script.rewrite = { topology in
        for index in topology.displays.indices where topology.displays[index].id == m34 {
            topology.displays[index].isOnline = true
        }
    }
    let operations = DisplayOperations(backend: ScriptedBackend(simulated, script: script), clock: AutoAdvancingClock())

    await #expect(throws: DisplayOperationError.stillOnline(m34)) {
        try await operations.disconnect([lg, m34])
    }
    #expect(!simulated.topology().onlineIDs.contains(lg))
}

@Test func disconnectingAnEmptyListDoesNothing() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    try await DisplayOperations(backend: backend, clock: AutoAdvancingClock()).disconnect([])

    #expect(backend.mutations.isEmpty)
    #expect(backend.switchTransactions.isEmpty)
}

@Test func aFailedListLeavesEveryMonitorOn() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()

    await #expect(throws: DisplayBackendError.self) {
        try await DisplayOperations(backend: backend, clock: AutoAdvancingClock()).disconnect([m34, 77])
    }

    #expect(backend.topology().onlineIDs == [lg, m34])
}
