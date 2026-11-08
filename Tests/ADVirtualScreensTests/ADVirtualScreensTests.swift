import ADDisplays
import ADFoundation
import ADModel
import Foundation
import Synchronization
import Testing
@testable import ADVirtualScreens

private func spec(_ w: Int, _ h: Int, hiDPI: Bool = true, hz: Int = 60, client: String = "parsec") -> VirtualScreenSpec {
    .forClient(client, looksLike: ScreenSize(w: w, h: h), hiDPI: hiDPI, hz: hz)
}

// MARK: - The spec

@Test func serialForParsecIsExact() {
    #expect(spec(1728, 1080).serial == 0xD249_C71D)
}

@Test func serialForDefaultIsExact() {
    #expect(spec(1728, 1080, client: "default").serial == 0x933B_5BDE)
}

@Test func serialIsNeverZero() {
    // This name's FNV-1a hash is exactly 0, found by searching. A virtual screen's serial can't be 0.
    #expect(spec(1728, 1080, client: "akhnp9x").serial == 1)
}

@Test func serialHashesUTF8Bytes() {
    // FNV-1a of the four UTF-8 bytes of "Mäc", worked out separately from the code under test.
    #expect(spec(1728, 1080, client: "M\u{00E4}c").serial == 0x0EE0_E694)
}

@Test func specNameIsExact() {
    #expect(spec(1728, 1080).name == "Porch Light (parsec)")
}

@Test func maxPixelsAtLeastDefaults() {
    for hiDPI in [true, false] {
        let small = spec(1180, 820, hiDPI: hiDPI)
        #expect(small.maxPixelsWide == 4032)
        #expect(small.maxPixelsHigh == 2520)
    }
}

@Test func maxPixelsGrowForLargeSizes() {
    for hiDPI in [true, false] {
        let large = spec(2560, 1600, hiDPI: hiDPI)
        #expect(large.maxPixelsWide == 5120)
        #expect(large.maxPixelsHigh == 3200)
    }
    // Each side grows on its own.
    #expect(spec(2100, 1000).maxPixelsWide == 4200)
    #expect(spec(2100, 1000).maxPixelsHigh == 2520)
    #expect(spec(1000, 1300).maxPixelsWide == 4032)
    #expect(spec(1000, 1300).maxPixelsHigh == 2600)
}

@Test func expectedModeHiDPI() {
    #expect(
        spec(1728, 1080).expectedMode
            == DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 60)
    )
}

@Test func expectedMode1x() {
    #expect(
        spec(2560, 1440, hiDPI: false, hz: 120).expectedMode
            == DisplayMode(pointsWide: 2560, pointsHigh: 1440, pixelsWide: 2560, pixelsHigh: 1440, refreshHz: 120)
    )
}

/// One mode, at the rate asked for, which is what reaches `CGVirtualDisplayMode`. With a second rate
/// listed, macOS could keep the old one after an in-place change.
@Test(arguments: [60, 120])
func declaredModesAreOneModeAtTheAskedRate(hz: Int) {
    let wanted = spec(1728, 1080, hz: hz)

    #expect(wanted.declaredModes == [
        DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: Double(hz)),
    ])
    #expect(wanted.declaredModes == [wanted.expectedMode])
}

@Test func sizeMMWidthIs302AndHeightScales() {
    let size = spec(1728, 1080).sizeMM
    #expect(size.w == 302)
    #expect(size.h == 188.75)
}

// MARK: - The simulated provider

@MainActor
@Test func createAddsOwnVirtualDisplay() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let wanted = spec(1728, 1080)

    let screen = try await provider.create(wanted)

    #expect(screen.spec == wanted)
    let display = try #require(backend.topology().display(screen.displayID))
    #expect(display.kind == .ownVirtual)
    #expect(display.isActive)
    #expect(display.identity.vendor == DisplayClassifier.ownVendor)
    #expect(display.identity.model == DisplayClassifier.ownProduct)
    #expect(display.identity.serial == wanted.serial)
    #expect(display.identity.productName == wanted.name)
    #expect(display.identity.uuid == screen.uuid)
    #expect(display.mode == wanted.expectedMode)
}

@MainActor
@Test func reconfigureInPlaceKeepsID() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let first = try await provider.create(spec(1728, 1080))
    let wanted = spec(1512, 982)

    let second = try await provider.reconfigure(first, to: wanted)

    #expect(second.displayID == first.displayID)
    #expect(second.uuid == first.uuid)
    #expect(second.spec == wanted)
    #expect(backend.topology().display(first.displayID)?.mode == wanted.expectedMode)
    #expect(!backend.mutations.contains { $0.hasPrefix("removeVirtual") })
}

@MainActor
@Test func createAt120HzOffersAndRunsThe120HzMode() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)

    let screen = try await provider.create(spec(1728, 1080, hz: 120))

    #expect(backend.modes(of: screen.displayID).map(\.refreshHz) == [120])
    #expect(backend.topology().display(screen.displayID)?.mode?.refreshHz == 120)
}

/// The status menu's 60/120 Hz choice: same size, same screen, the new rate.
@MainActor
@Test(arguments: [(60, 120), (120, 60)])
func aRateChangeAtTheSameSizeStaysInPlace(from: Int, to: Int) async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let first = try await provider.create(spec(1728, 1080, hz: from))

    let second = try await provider.reconfigure(first, to: spec(1728, 1080, hz: to))

    #expect(second.displayID == first.displayID)
    #expect(second.spec.hz == to)
    #expect(backend.topology().display(first.displayID)?.mode == spec(1728, 1080, hz: to).expectedMode)
    #expect(!backend.mutations.contains { $0.hasPrefix("removeVirtual") })
}

@MainActor
@Test func reconfigurePastMaxRecreatesWithNewIDSameUUID() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let first = try await provider.create(spec(1728, 1080))
    let wanted = spec(2560, 1600)

    let second = try await provider.reconfigure(first, to: wanted)

    #expect(second.displayID != first.displayID)
    #expect(second.uuid.uppercased() == first.uuid.uppercased())
    #expect(second.spec == wanted)
    let topology = backend.topology()
    #expect(topology.display(first.displayID) == nil)
    #expect(topology.display(second.displayID)?.mode == wanted.expectedMode)
    // The old screen goes first, because the new one takes over its identity.
    let removed = try #require(backend.mutations.firstIndex { $0.hasPrefix("removeVirtual") })
    let added = try #require(backend.mutations.lastIndex { $0.hasPrefix("addVirtual") })
    #expect(removed < added)
}

@MainActor
@Test func reconfigureKeepsTheMaxFromCreation() async throws {
    // The max is fixed at creation, so the last spec's max is the wrong number to check against:
    // 1728x1080 alone gives 4032x2520, and this screen can still go back up to 2560x1600.
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    let large = try await provider.create(spec(2560, 1600))
    let small = try await provider.reconfigure(large, to: spec(1728, 1080))

    let back = try await provider.reconfigure(small, to: spec(2560, 1600))

    #expect(small.displayID == large.displayID)
    #expect(back.displayID == large.displayID)
}

@MainActor
@Test func reconfigureChecksThePixelsNot2xFor1x() async throws {
    // 2560x1440 at 1x is 2560x1440 pixels, which fits a screen made with the default max.
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    let first = try await provider.create(spec(1728, 1080))

    let second = try await provider.reconfigure(first, to: spec(2560, 1440, hiDPI: false))

    #expect(second.displayID == first.displayID)
}

@MainActor
@Test func reconfigureExactlyAtMaxStaysInPlace() async throws {
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    let first = try await provider.create(spec(1728, 1080))

    let atMax = try await provider.reconfigure(first, to: spec(2016, 1260))
    let pastMax = try await provider.reconfigure(atMax, to: spec(2017, 1260))

    #expect(atMax.displayID == first.displayID)
    #expect(pastMax.displayID != first.displayID)
}

@MainActor
@Test func reconfigureToAnotherClientRecreates() async throws {
    // A screen's name and serial are fixed at creation too, and its UUID comes from the serial.
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    let first = try await provider.create(spec(1728, 1080))

    let second = try await provider.reconfigure(first, to: spec(1728, 1080, client: "ipad"))

    #expect(second.displayID != first.displayID)
    #expect(second.uuid.uppercased() != first.uuid.uppercased())
}

@MainActor
@Test func reconfigurePastMaxWithMonitorsOffCrossesTheFallback() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let first = try await provider.create(spec(1728, 1080))
    for monitor in backend.topology().online where monitor.kind == .physical {
        try backend.setEnabled(monitor.id, false)
    }
    #expect(backend.fallbackAppearances == 0)

    let second = try await provider.reconfigure(first, to: spec(2560, 1600))

    // The old screen was the last display, so the fallback came up between the two, and went again.
    #expect(backend.fallbackAppearances == 1)
    let topology = backend.topology()
    #expect(topology.display(second.displayID)?.kind == .ownVirtual)
    #expect(!topology.displays.contains { $0.kind == .osFallback })
}

@MainActor
@Test func recreateWaitsForTheOldScreenToGo() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let first = try await provider.create(spec(1728, 1080))
    backend.scriptVirtualLinger(first.displayID, reads: 3)

    let second = try await provider.reconfigure(first, to: spec(2560, 1600))

    let lines = backend.mutations
    let removed = try #require(lines.firstIndex(of: "removeVirtual \(first.displayID)"))
    let gone = try #require(lines.firstIndex(of: "gone \(first.displayID)"))
    let added = try #require(lines.firstIndex { $0.hasPrefix("addVirtual \(second.displayID) ") })
    #expect(removed < gone)
    #expect(gone < added)
}

@MainActor
@Test func recreateGoesAheadIfTheOldScreenStaysListed() async throws {
    // Stopping here would leave no screen at all, so the wait has a limit and create still happens.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let first = try await provider.create(spec(1728, 1080))
    backend.scriptVirtualLinger(first.displayID, reads: .max)
    let wanted = spec(2560, 1600)

    let second = try await provider.reconfigure(first, to: wanted)

    #expect(second.displayID != first.displayID)
    #expect(second.uuid.uppercased() == first.uuid.uppercased())
    let topology = backend.topology()
    #expect(topology.display(second.displayID)?.mode == wanted.expectedMode)
    #expect(topology.display(first.displayID) != nil)
}

@MainActor
@Test func destroyRemoves() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    var reported: [ActiveVirtualScreen] = []
    provider.onScreenTerminated = { reported.append($0) }
    let screen = try await provider.create(spec(1728, 1080))

    provider.destroy(screen)

    #expect(backend.topology().display(screen.displayID) == nil)
    #expect(reported.isEmpty)

    let before = backend.mutations
    provider.destroy(screen)
    #expect(backend.mutations == before)
}

@MainActor
@Test func destroyLeavesOtherVirtualScreensAlone() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let parsecMode = DisplayMode(pointsWide: 1920, pointsHigh: 1080, pixelsWide: 1920, pixelsHigh: 1080, refreshHz: 60)
    let parsec = backend.addVirtual(
        identity: DisplayIdentity(vendor: 1, model: 2, serial: 3, productName: "Parsec Virtual Display"),
        mode: parsecMode,
        modes: [parsecMode]
    )
    let screen = try await provider.create(spec(1728, 1080))
    var notOurs = screen
    notOurs.displayID = parsec

    provider.destroy(notOurs)

    #expect(backend.topology().display(parsec) != nil)
    #expect(backend.topology().display(screen.displayID) != nil)
}

@MainActor
@Test func createFailureThrows() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    provider.failNextCreate = true

    await #expect(throws: VirtualScreenError.self) {
        _ = try await provider.create(spec(1728, 1080))
    }

    #expect(backend.mutations.isEmpty)
    #expect(!backend.topology().displays.contains { $0.kind == .ownVirtual })

    // Only the next one fails.
    let screen = try await provider.create(spec(1728, 1080))
    #expect(backend.topology().display(screen.displayID) != nil)
}

@MainActor
@Test func reconfigureFailureThrowsAndLeavesTheScreen() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let screen = try await provider.create(spec(1728, 1080))
    provider.failNextReconfigure = true

    await #expect(throws: VirtualScreenError.self) {
        _ = try await provider.reconfigure(screen, to: spec(1512, 982))
    }

    #expect(backend.topology().display(screen.displayID)?.mode == spec(1728, 1080).expectedMode)

    // Only the next one fails.
    let second = try await provider.reconfigure(screen, to: spec(1512, 982))
    #expect(second.spec == spec(1512, 982))
}

@MainActor
@Test func failedRecreateLeavesNoScreen() async throws {
    // What the real Mac does: the old screen has to go first, so a failed recreate has neither.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let screen = try await provider.create(spec(1728, 1080))
    provider.failNextCreate = true

    await #expect(throws: VirtualScreenError.self) {
        _ = try await provider.reconfigure(screen, to: spec(2560, 1600))
    }

    #expect(!backend.topology().displays.contains { $0.kind == .ownVirtual })
}

@MainActor
@Test func reconfigureOfAScreenThatIsGoneThrows() async throws {
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    let screen = try await provider.create(spec(1728, 1080))
    provider.destroy(screen)

    await #expect(throws: VirtualScreenError.self) {
        _ = try await provider.reconfigure(screen, to: spec(1512, 982))
    }
}

@MainActor
@Test func reconfigureOfASleepingScreenThrowsAsTheLiveCheckDoes() async throws {
    // The spec's check needs the screen active, and a sleeping one isn't. The real wait takes 5 s.
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    let screen = try await provider.create(spec(1728, 1080))
    backend.setAsleep(screen.displayID, true)

    await #expect(throws: VirtualScreenError.self) {
        _ = try await provider.reconfigure(screen, to: spec(1512, 982))
    }
}

@MainActor
@Test func simulateTerminationRemovesAndReportsTheLatestSpec() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    var reported: [ActiveVirtualScreen] = []
    provider.onScreenTerminated = { reported.append($0) }
    let first = try await provider.create(spec(1728, 1080))
    let resized = try await provider.reconfigure(first, to: spec(1512, 982))

    // Passing the older value still reports what the screen is now.
    provider.simulateTermination(of: first)

    #expect(reported == [resized])
    #expect(backend.topology().display(first.displayID) == nil)

    await #expect(throws: VirtualScreenError.self) {
        _ = try await provider.reconfigure(resized, to: spec(1728, 1080))
    }
}

@MainActor
@Test func simulateTerminationOfAScreenThatIsGoneReportsNothing() async throws {
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    var reported: [ActiveVirtualScreen] = []
    provider.onScreenTerminated = { reported.append($0) }
    let screen = try await provider.create(spec(1728, 1080))
    provider.destroy(screen)

    provider.simulateTermination(of: screen)

    #expect(reported.isEmpty)
}

@MainActor
@Test func terminatedScreenCanBeRecreatedWithTheSameUUID() async throws {
    // The session controller's recovery: a recreated screen has a new ID and the same UUID.
    let provider = SimulatedVirtualScreenProvider(backend: .twoMonitorDesk())
    var reported: [ActiveVirtualScreen] = []
    provider.onScreenTerminated = { reported.append($0) }
    let screen = try await provider.create(spec(1728, 1080))
    provider.simulateTermination(of: screen)

    let again = try await provider.create(try #require(reported.first).spec)

    #expect(again.displayID != screen.displayID)
    #expect(again.uuid.uppercased() == screen.uuid.uppercased())
}

// MARK: - Waiting for the mode

/// A simulator with a virtual screen in the given mode, and the rest of the mode list as given.
private func virtualScreen(
    mode: DisplayMode,
    alsoOffers others: [DisplayMode] = []
) -> (backend: SimulatedDisplayBackend, id: DisplayID) {
    let backend = SimulatedDisplayBackend()
    let id = backend.addVirtual(
        identity: DisplayIdentity(
            vendor: DisplayClassifier.ownVendor,
            model: DisplayClassifier.ownProduct,
            serial: 7,
            productName: "Porch Light (test)"
        ),
        mode: mode,
        modes: [mode] + others
    )
    return (backend, id)
}

private let otherMode = DisplayMode(pointsWide: 1920, pointsHigh: 1080, pixelsWide: 1920, pixelsHigh: 1080, refreshHz: 60)

/// Counts commits and where they ran, and can fail the first few.
private final class WatchedBackend: DisplayBackend {
    private struct State {
        var failuresLeft: Int
        var commitsOnMainThread: [Bool] = []
    }

    private let inner: any DisplayBackend
    private let state: Mutex<State>

    init(_ inner: any DisplayBackend, failingCommits: Int = 0) {
        self.inner = inner
        state = Mutex(State(failuresLeft: failingCommits))
    }

    var commitsOnMainThread: [Bool] {
        state.withLock { $0.commitsOnMainThread }
    }

    func topology() -> Topology { inner.topology() }
    func modes(of id: DisplayID) -> [DisplayMode] { inner.modes(of: id) }
    func setEnabled(_ id: DisplayID, _ enabled: Bool) throws { try inner.setEnabled(id, enabled) }
    func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws { try inner.setEnabled(ids, enabled) }

    func commit(_ changes: [DisplayChange]) throws {
        let onMain = Thread.isMainThread
        let fails = state.withLock { state -> Bool in
            state.commitsOnMainThread.append(onMain)
            guard state.failuresLeft > 0 else { return false }
            state.failuresLeft -= 1
            return true
        }
        if fails { throw DisplayBackendError(code: 1001, message: "scripted") }
        try inner.commit(changes)
    }
}

@MainActor
@Test func settleReturnsAtOnceWhenTheModeIsCurrent() async throws {
    let wanted = spec(1728, 1080).expectedMode
    let (backend, id) = virtualScreen(mode: wanted)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let uuid = try await VirtualScreenSettler(backend: backend, clock: clock).settle(id, to: wanted) { true }

    #expect(uuid == backend.topology().display(id)?.identity.uuid)
    #expect(clock.now() == start)
    #expect(!backend.mutations.contains { $0.hasPrefix("commit") })
}

@MainActor
@Test func settleTakesARoundedRefreshRateAsCurrent() async throws {
    var actual = spec(1728, 1080).expectedMode
    actual.refreshHz = 59.94
    let (backend, id) = virtualScreen(mode: actual)

    _ = try await VirtualScreenSettler(backend: backend, clock: AutoAdvancingClock())
        .settle(id, to: spec(1728, 1080).expectedMode) { true }

    #expect(!backend.mutations.contains { $0.hasPrefix("commit") })
}

@MainActor
@Test func settleSelectsTheModeIfTheScreenComesUpInAnother() async throws {
    let wanted = spec(1728, 1080).expectedMode
    let (backend, id) = virtualScreen(mode: otherMode, alsoOffers: [wanted])
    let clock = AutoAdvancingClock()
    let start = clock.now()

    _ = try await VirtualScreenSettler(backend: backend, clock: clock).settle(id, to: wanted) { true }

    #expect(backend.topology().display(id)?.mode == wanted)
    #expect(backend.mutations.filter { $0.hasPrefix("commit") } == ["commit mode \(id) 1728x1080@60 hiDPI"])
    // A screen normally reaches its mode by itself in about a second, so it gets that long first.
    #expect(clock.now().timeIntervalSince(start) == VirtualScreenSettler.selectAfter)
}

@MainActor
@Test(arguments: [true, false])
func settleSelectsWhenOnlyTheScaleDiffers(wantedHiDPI: Bool) async throws {
    // 1920x1080 at 1x and at HiDPI have the same points and rate, so only the pixels tell them apart.
    let wanted = spec(1920, 1080, hiDPI: wantedHiDPI).expectedMode
    let current = spec(1920, 1080, hiDPI: !wantedHiDPI).expectedMode
    let (backend, id) = virtualScreen(mode: current, alsoOffers: [wanted])

    _ = try await VirtualScreenSettler(backend: backend, clock: AutoAdvancingClock()).settle(id, to: wanted) { true }

    #expect(backend.topology().display(id)?.mode == wanted)
    let scale = wantedHiDPI ? " hiDPI" : ""
    #expect(backend.mutations.filter { $0.hasPrefix("commit") } == ["commit mode \(id) 1920x1080@60\(scale)"])
}

@MainActor
@Test func settleCommitsOffTheMainActor() async throws {
    // A commit can block for about 10 seconds, and the owner's main thread has to keep running.
    let wanted = spec(1728, 1080).expectedMode
    let (inner, id) = virtualScreen(mode: otherMode, alsoOffers: [wanted])
    let backend = WatchedBackend(inner)

    _ = try await VirtualScreenSettler(backend: backend, clock: AutoAdvancingClock()).settle(id, to: wanted) { true }

    #expect(backend.commitsOnMainThread == [false])
}

@MainActor
@Test func settleRetriesAFailedSelect() async throws {
    let wanted = spec(1728, 1080).expectedMode
    let (inner, id) = virtualScreen(mode: otherMode, alsoOffers: [wanted])
    let backend = WatchedBackend(inner, failingCommits: 1)

    _ = try await VirtualScreenSettler(backend: backend, clock: AutoAdvancingClock()).settle(id, to: wanted) { true }

    #expect(backend.commitsOnMainThread.count == 2)
    #expect(inner.topology().display(id)?.mode == wanted)
}

@MainActor
@Test func settleGivesUpAfterFiveSeconds() async throws {
    let wanted = spec(1728, 1080).expectedMode
    let (backend, id) = virtualScreen(mode: otherMode)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let error = await #expect(throws: VirtualScreenError.self) {
        _ = try await VirtualScreenSettler(backend: backend, clock: clock).settle(id, to: wanted) { true }
    }

    #expect(
        error?.reason == "display \(id) was not active in 1728x1080 (3456x2160 pixels) at 60 Hz after 5 seconds"
    )
    #expect(clock.now().timeIntervalSince(start) == 5)
    // The mode isn't on offer, so there was nothing to select.
    #expect(!backend.mutations.contains { $0.hasPrefix("commit") })
}

@MainActor
@Test func settleSaysWhySelectingFailed() async throws {
    let wanted = spec(1728, 1080).expectedMode
    let (inner, id) = virtualScreen(mode: otherMode, alsoOffers: [wanted])
    let backend = WatchedBackend(inner, failingCommits: .max)

    let error = await #expect(throws: VirtualScreenError.self) {
        _ = try await VirtualScreenSettler(backend: backend, clock: AutoAdvancingClock()).settle(id, to: wanted) { true }
    }

    #expect(error?.reason.hasSuffix("selecting it failed: scripted (1001)") == true)
}

@MainActor
@Test func settleStopsWhenTheScreenEnds() async throws {
    let wanted = spec(1728, 1080).expectedMode
    let (backend, id) = virtualScreen(mode: otherMode)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var checks = 0

    let error = await #expect(throws: VirtualScreenError.self) {
        _ = try await VirtualScreenSettler(backend: backend, clock: clock).settle(id, to: wanted) {
            checks += 1
            return checks < 3
        }
    }

    #expect(error?.reason == "display \(id) ended before it was active in 1728x1080 (3456x2160 pixels) at 60 Hz")
    #expect(clock.now().timeIntervalSince(start) < 5)
}

// MARK: - Waiting for a released screen to go

@MainActor
@Test func waitUntilGoneReturnsAtOnceForAScreenAlreadyGone() async throws {
    let (backend, id) = virtualScreen(mode: otherMode)
    backend.removeVirtual(id)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let gone = try await VirtualScreenSettler(backend: backend, clock: clock).waitUntilGone(id)

    #expect(gone)
    #expect(clock.now() == start)
}

@MainActor
@Test func waitUntilGoneWaitsOnlyAsLongAsItTakes() async throws {
    let (backend, id) = virtualScreen(mode: otherMode)
    backend.scriptVirtualLinger(id, reads: 3)
    backend.removeVirtual(id)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let gone = try await VirtualScreenSettler(backend: backend, clock: clock).waitUntilGone(id)

    #expect(gone)
    #expect(clock.now().timeIntervalSince(start) == 3 * VirtualScreenSettler.pollInterval)
}

@MainActor
@Test func waitUntilGoneStopsAtTheBound() async throws {
    let (backend, id) = virtualScreen(mode: otherMode)
    backend.scriptVirtualLinger(id, reads: .max)
    backend.removeVirtual(id)
    let clock = AutoAdvancingClock()
    let start = clock.now()

    let gone = try await VirtualScreenSettler(backend: backend, clock: clock).waitUntilGone(id)

    #expect(!gone)
    #expect(clock.now().timeIntervalSince(start) == VirtualScreenSettler.goneTimeout)
}

@Test func lingeringScreenStaysListedForTheScriptedReadsThenGoes() {
    let (backend, id) = virtualScreen(mode: otherMode)
    backend.scriptVirtualLinger(id, reads: 2)

    backend.removeVirtual(id)

    #expect(backend.topology().display(id) != nil)
    // It's the only display and it still counts, so the fallback waits for it.
    #expect(backend.fallbackAppearances == 0)
    #expect(backend.topology().display(id) != nil)
    #expect(backend.fallbackAppearances == 1)
    #expect(backend.topology().display(id) == nil)
    #expect(backend.mutations.suffix(2) == ["removeVirtual \(id)", "gone \(id)"])
}

// MARK: - Trying again when macOS declines

private let declined = VirtualScreenError(reason: "macOS did not create the virtual screen Porch Light (parsec)")

@MainActor
@Test func createRetriesWhenMacOSDeclinesTwice() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    provider.declinedCreateTries = 2

    let screen = try await provider.create(spec(1728, 1080))

    #expect(provider.declinedCreateTries == 0)
    #expect(backend.topology().display(screen.displayID)?.mode == spec(1728, 1080).expectedMode)
    #expect(backend.mutations.filter { $0.hasPrefix("addVirtual") }.count == 1)
}

@MainActor
@Test func createThrowsWhenMacOSDeclinesPastTheBound() async throws {
    let backend = SimulatedDisplayBackend.twoMonitorDesk()
    let provider = SimulatedVirtualScreenProvider(backend: backend)
    provider.declinedCreateTries = VirtualScreenSettler.createTries

    await #expect(throws: declined) {
        _ = try await provider.create(spec(1728, 1080))
    }

    // It used every try, and a ninth would have worked.
    #expect(provider.declinedCreateTries == 0)
    #expect(backend.mutations.isEmpty)
}

/// A simulator holding a screen with this spec's identity that is on its way out, and another
/// client's screen that stays.
private func dyingScreen(of wanted: VirtualScreenSpec, lingering reads: Int) -> (SimulatedDisplayBackend, DisplayID) {
    let backend = SimulatedDisplayBackend()
    let mode = wanted.expectedMode
    let identity = DisplayIdentity(
        vendor: DisplayClassifier.ownVendor,
        model: DisplayClassifier.ownProduct,
        serial: wanted.serial,
        productName: wanted.name
    )
    let dying = backend.addVirtual(identity: identity, mode: mode, modes: [mode])
    var otherClient = identity
    otherClient.serial += 1
    _ = backend.addVirtual(identity: otherClient, mode: mode, modes: [mode])
    backend.scriptVirtualLinger(dying, reads: reads)
    backend.removeVirtual(dying)
    return (backend, dying)
}

@MainActor
@Test func createRetryingWaitsForTheSameIdentityToGo() async throws {
    let wanted = spec(1728, 1080)
    let (backend, dying) = dyingScreen(of: wanted, lingering: 3)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var sawItGone: [Bool] = []

    let made = try await VirtualScreenSettler(backend: backend, clock: clock).createRetrying(wanted) { () -> Int? in
        sawItGone.append(backend.mutations.contains("gone \(dying)"))
        return sawItGone.count == 2 ? 1 : nil
    }

    #expect(made == 1)
    #expect(sawItGone == [false, true])
    // Three reads while it lingered, then the backoff. The other client's screen didn't hold it up.
    #expect(
        clock.now().timeIntervalSince(start)
            == 3 * VirtualScreenSettler.pollInterval + VirtualScreenSettler.createBackoff
    )
}

@MainActor
@Test func createRetryingStopsAfterEightTries() async throws {
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var tries = 0

    await #expect(throws: declined) {
        _ = try await VirtualScreenSettler(backend: SimulatedDisplayBackend(), clock: clock)
            .createRetrying(spec(1728, 1080)) { () -> Int? in
                tries += 1
                return nil
            }
    }

    #expect(tries == VirtualScreenSettler.createTries)
    #expect(clock.now().timeIntervalSince(start) == 7 * VirtualScreenSettler.createBackoff)
}

@MainActor
@Test func createRetryingStopsAtTheTimeBoundIfTheOldScreenStays() async throws {
    let wanted = spec(1728, 1080)
    let (backend, _) = dyingScreen(of: wanted, lingering: .max)
    let clock = AutoAdvancingClock()
    let start = clock.now()
    var tries = 0

    await #expect(throws: declined) {
        _ = try await VirtualScreenSettler(backend: backend, clock: clock).createRetrying(wanted) { () -> Int? in
            tries += 1
            return nil
        }
    }

    // One wait used the whole 4 s, then the backoff and one last try.
    #expect(tries == 2)
    #expect(
        clock.now().timeIntervalSince(start)
            == VirtualScreenSettler.createTimeout + VirtualScreenSettler.createBackoff
    )
}
