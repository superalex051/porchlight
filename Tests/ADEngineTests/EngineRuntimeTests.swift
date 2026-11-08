import ADCommand
import ADDisplays
import ADFoundation
import ADIPC
import ADIntegrations
import ADModel
import ADSPI
import ADSafety
import ADVirtualScreens
import Foundation
import Synchronization
import Testing

@testable import ADEngine

/// An `AutoAdvancingClock` that can hold sleeps of an exact length until a test lets them go, so a test
/// can see the shutdown's 10 second limit being reached, and can pause the startup poll, whose ticks
/// otherwise fly by.
private final class RuntimeTestClock: ADClock {
    private struct Held {
        var seconds: Set<Double> = []
        var waiting: [Double: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let inner = AutoAdvancingClock()
    private let held = Mutex(Held())
    private let sleeps = Recorder<Double>()

    func now() -> Date { inner.now() }

    func advance(by seconds: Double) {
        inner.advance(by: seconds)
    }

    func sleep(seconds: Double) async throws {
        sleeps.append(seconds)
        await withCheckedContinuation { continuation in
            let keep: CheckedContinuation<Void, Never>? = held.withLock { held in
                guard held.seconds.contains(seconds) else { return continuation }
                held.waiting[seconds, default: []].append(continuation)
                return nil
            }
            keep?.resume()
        }
        try await inner.sleep(seconds: seconds)
    }

    func hold(_ seconds: Double) {
        held.withLock { _ = $0.seconds.insert(seconds) }
    }

    func heldCount(_ seconds: Double) -> Int {
        held.withLock { $0.waiting[seconds]?.count ?? 0 }
    }

    func release(_ seconds: Double) {
        let waiting = held.withLock { held in
            held.seconds.remove(seconds)
            return held.waiting.removeValue(forKey: seconds) ?? []
        }
        for continuation in waiting { continuation.resume() }
    }

    func sleepCount(_ seconds: Double) -> Int {
        sleeps.values.filter { $0 == seconds }.count
    }
}

/// `FakeLifecycleNotifier`, plus a hook that runs at the moment `launched` is posted.
private final class HookedNotifier: LifecycleNotifying {
    let inner = FakeLifecycleNotifier()
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    func onLaunched(_ action: @escaping @Sendable () -> Void) {
        hook.withLock { $0 = action }
    }

    var events: [LifecycleEvent] { inner.events }

    func launched() {
        hook.withLock { $0 }?()
        inner.launched()
    }

    func terminated() { inner.terminated() }
    func sessionChanged() { inner.sessionChanged() }
}

/// An in-memory ledger with a hook that runs before the next read, once.
private final class HookedLedger: LedgerStoring {
    let inner = InMemoryLedgerStore()
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    func beforeNextLoad(_ action: @escaping @Sendable () -> Void) {
        hook.withLock { $0 = action }
    }

    func load() throws -> SafetyLedger? {
        let action = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        action?()
        return try inner.load()
    }

    func save(_ ledger: SafetyLedger) throws { try inner.save(ledger) }
    func clear() throws { try inner.clear() }
    func takeSetAsideEvent() -> Bool { inner.takeSetAsideEvent() }
}

/// A guardian check that sleeps on the rig's clock, so a test can hold a start at its very beginning,
/// before it has written anything, while there's still no session to see.
private final class HoldableGuardian: GuardianProbing {
    static let seconds = 55.0

    private let clock: RuntimeTestClock

    init(clock: RuntimeTestClock) {
        self.clock = clock
    }

    func isAlive() async -> Bool {
        try? await clock.sleep(seconds: Self.seconds)
        return true
    }
}

/// Holds a display switch on the thread that's making it, until `release`.
private final class SwitchHold: Sendable {
    private let reached = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    var isReached: Bool {
        reached.withLock { $0 }
    }

    func arrive() {
        reached.withLock { $0 = true }
        gate.wait()
    }

    func release() {
        gate.signal()
    }
}

/// What the socket answers.
private enum Answer: Equatable, Sendable {
    case busy, pong, other, timedOut, notRunning
}

private func answer(from client: IPCClient, timeout: Double = 5) async -> Answer {
    do {
        let result = try await client.send(CommandRequest(operations: ["ping"]), timeout: timeout)
        if result.ok { return result.payload == "pong" ? .pong : .other }
        return result.reason?.hasPrefix("busy") == true ? .busy : .other
    } catch IPCError.timedOut {
        return .timedOut
    } catch IPCError.notRunning {
        return .notRunning
    } catch {
        return .other
    }
}

/// The socket's answer, for a hook that holds the main thread. A server still in busy mode answers
/// without the main actor. One that's ready needs the main actor for the command, so while the main
/// thread is held here it can't answer, and this reads as `timedOut`.
private func answerHoldingThisThread(from client: IPCClient) -> Answer {
    let seen = Recorder<Answer>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        seen.append(await answer(from: client, timeout: 0.3))
        done.signal()
    }
    done.wait()
    return seen.values.first ?? .other
}

/// The test desk in memory, with a runtime built on it from seams.
@MainActor
private final class RuntimeRig {
    let simulated = SimulatedDisplayBackend.twoMonitorDesk()
    let backend: ScriptedBackend
    let provider: SimulatedVirtualScreenProvider
    let screens: ScriptedScreens
    let ledger = HookedLedger()
    let processes = FakeProcessInspector(alive: [appRef, ownerRef])
    let clock = RuntimeTestClock()
    let events = ManualTopologyEvents()
    let notifier = HookedNotifier()
    let power: FakePowerAssertions
    let folder: URL
    let environment: [String: String]
    let paths: ADPaths
    let client: IPCClient

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(component: "ADRuntime-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        environment = [
            "AD_STATE_DIR": folder.path,
            "AD_SOCKET_PATH": folder.appending(component: "ctl.sock").path,
        ]
        paths = ADPaths(environment: environment)
        client = IPCClient(path: paths.socketPath)

        let simulated = simulated
        backend = ScriptedBackend(simulated)
        provider = SimulatedVirtualScreenProvider(backend: simulated)
        screens = ScriptedScreens(inner: provider)
        power = FakePowerAssertions(onDeclare: { simulated.wakeAll() })
    }

    /// More than one can be built on a rig, as two instances of the app on one Mac.
    func makeRuntime(safeMode: Bool = false, dryRunPlan: Bool = true) -> EngineRuntime {
        let simulated = simulated
        var plan: (@MainActor () -> [String])?
        if dryRunPlan { plan = { simulated.mutations } }
        return EngineRuntime(
            environment: environment,
            safeMode: safeMode,
            seams: EngineSeams(
                backend: backend,
                screens: screens,
                ledger: ledger,
                power: power,
                guardian: HoldableGuardian(clock: clock),
                processes: processes,
                clock: clock,
                events: events,
                notifier: notifier,
                launchAtLogin: FakeLaunchAtLogin(),
                capabilities: SPICapabilities(
                    displayList: true,
                    infoDictionary: true,
                    enableDisable: true,
                    virtualDisplay: true,
                    missing: []
                ),
                bootSession: boot,
                selfRef: appRef,
                sessionLogURL: folder.appending(component: "session.log"),
                dryRunPlan: plan
            )
        )
    }

    /// A session as a dead app left it: this ledger, and no screen. The monitors happen to be back on,
    /// so the resume has to turn them off again.
    func seedSessionFromADeadApp() throws {
        let records = simulated.topology().online.filter { $0.kind == .physical }.map { display in
            PhysicalRecord(
                id: display.id,
                identity: display.identity,
                origin: display.origin,
                mode: display.mode ?? mode(1, 1, hz: 0),
                wasMain: display.isMain
            )
        }
        let past = clock.now().addingTimeInterval(-100)
        try ledger.inner.save(
            SafetyLedger(
                state: .active,
                client: "parsec",
                looksLike: defaultSize,
                hiDPI: true,
                hz: 60,
                physical: records,
                owners: [ownerRef],
                app: ProcessRef(pid: 1, startTime: 1),
                bootSessionID: boot,
                startedAt: past,
                updatedAt: past
            )
        )
    }

    /// Holds the next display switch in this direction until `letGo`.
    func holdSwitch(enabling: Bool) -> SwitchHold {
        let hold = SwitchHold()
        backend.update { script in
            script.beforeSetEnabled = { _, enabled in
                if enabled == enabling { hold.arrive() }
            }
        }
        return hold
    }

    func letGo(_ hold: SwitchHold) {
        backend.update { $0.beforeSetEnabled = nil }
        hold.release()
    }

    /// Sends a command the way the CLI does: real parser, real socket.
    func send(_ argv: String...) async throws -> CommandResult {
        let (request, _) = try CommandParser.parse(argv)
        return try await client.send(request, timeout: 5)
    }

    func count(_ line: String) -> Int {
        simulated.mutations.filter { $0 == line }.count
    }

    var log: String {
        (try? String(contentsOf: folder.appending(component: "session.log"), encoding: .utf8)) ?? ""
    }

    func registryKnows(uuid: String) -> Bool {
        DeviceRegistry(url: paths.devices, bootSession: boot).entry(uuid: uuid) != nil
    }

    /// Waits for the startup poll's ticks to run out, and for the last one's turn, so that from here on
    /// only a topology event can start enforcement.
    func letTheStartupPollFinish(_ runtime: EngineRuntime) async throws {
        let clock = clock
        try await eventually { clock.sleepCount(1) >= 15 }
        clock.advance(by: 100)
        try await runtime.session.inTurn {}
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Waits in real time for something another task or thread does. A failure names the caller's line.
@MainActor
private func eventually(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The condition never held", sourceLocation: sourceLocation)
    throw CancellationError()
}

private func temporaryFolder(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(component: "\(prefix)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
}

@MainActor
@Suite struct EngineRuntimeTests {
    // MARK: Start

    @Test func startGoesBusyThenReady() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        #expect(await answer(from: rig.client) == .notRunning, "Nothing listens before the start")

        let client = rig.client
        let duringResume = Recorder<Answer>()
        rig.ledger.beforeNextLoad { duringResume.append(answerHoldingThisThread(from: client)) }

        try await runtime.start()

        #expect(duringResume.values == [.busy])
        #expect(await answer(from: rig.client) == .pong)
        await runtime.shutdown()
    }

    @Test func secondInstanceThrowsAlreadyRunning() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let first = rig.makeRuntime()
        try await first.start()
        let second = rig.makeRuntime()

        await #expect(throws: EngineRuntimeError.alreadyRunning) {
            try await second.start()
        }

        #expect(await answer(from: rig.client) == .pong, "The first instance's socket is untouched")
        #expect(rig.notifier.events == [.launched], "Only the first instance announced itself")
        await first.shutdown()
    }

    @Test func resumeRunsBeforeReady() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        try rig.seedSessionFromADeadApp()
        let client = rig.client
        var duringResume: Answer?
        rig.screens.beforeCreate = { duringResume = answerHoldingThisThread(from: client) }
        let runtime = rig.makeRuntime()

        try await runtime.start()

        #expect(duringResume == .busy)
        #expect(runtime.session.status().state == .active)
        #expect(runtime.session.status().displayID != nil)
        #expect(rig.count("disable \(lg)") == 1)
        #expect(rig.count("disable \(m34)") == 1)
        #expect(rig.notifier.events == [.sessionChanged, .launched], "The resume's change comes before readiness")
        await runtime.shutdown()
    }

    @Test func safeModeEndsTheSessionItFinds() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        try rig.seedSessionFromADeadApp()
        let runtime = rig.makeRuntime(safeMode: true)

        try await runtime.start()

        #expect(runtime.session.status().state == .idle)
        #expect(try rig.ledger.load() == nil)
        #expect(!rig.simulated.mutations.contains { $0.hasPrefix("addVirtual") })
        await runtime.shutdown()
    }

    @Test func savedScreensComeBackUnlessInSafeMode() async throws {
        for safeMode in [false, true] {
            let rig = try RuntimeRig()
            defer { rig.cleanUp() }
            try VirtualScreenStore(directory: rig.folder, log: { _ in }).save([VirtualScreenDefinition(name: "Saved")])
            let runtime = rig.makeRuntime(safeMode: safeMode)

            try await runtime.start()

            let created = rig.simulated.mutations.filter { $0.hasPrefix("addVirtual") }
            #expect(created.count == (safeMode ? 0 : 1))
            await runtime.shutdown()
        }
    }

    /// A quit during the resume ends what the resume found, and brings up nothing more.
    @Test func quitDuringResumeRestoresNoSavedScreens() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        try rig.seedSessionFromADeadApp()
        try VirtualScreenStore(directory: rig.folder, log: { _ in }).save([VirtualScreenDefinition(name: "Saved")])
        rig.clock.hold(10)
        let hold = rig.holdSwitch(enabling: false)
        let runtime = rig.makeRuntime()

        let starting = Task { try await runtime.start() }
        try await eventually { hold.isReached }
        let stopping = Task { await runtime.shutdown() }
        try await eventually { rig.clock.heldCount(10) == 1 }

        rig.letGo(hold)
        try await starting.value
        await stopping.value
        rig.clock.release(10)

        #expect(rig.simulated.mutations.filter { $0.hasPrefix("addVirtual") }.count == 1, "Only the resume's screen")
        #expect(!rig.notifier.events.contains(.launched))
        #expect(rig.notifier.events.last == .terminated)
        #expect(try rig.ledger.load() == nil)
    }

    @Test func launchedPostedAfterReady() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        let client = rig.client
        let atLaunched = Recorder<Answer>()
        rig.notifier.onLaunched { atLaunched.append(answerHoldingThisThread(from: client)) }

        try await runtime.start()

        #expect(atLaunched.values == [.timedOut], "Only a server that's ready waits for the main actor")
        #expect(rig.notifier.events == [.launched])
        await runtime.shutdown()
    }

    // MARK: Topology

    @Test func topologyEventReachesEnforcement() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        _ = try await runtime.session.start(parsec())
        try await rig.letTheStartupPollFinish(runtime)
        #expect(rig.count("disable \(lg)") == 1, "Only the start's so far")

        rig.simulated.simulateWake(reconnecting: [lg])
        rig.events.fire()

        try await eventually { rig.count("disable \(lg)") == 2 }
        await runtime.shutdown()
    }

    @Test func startupPollEnforcesWithNoEvent() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        rig.clock.hold(1)
        _ = try await runtime.session.start(parsec())
        try await eventually { rig.clock.heldCount(1) == 1 }
        rig.simulated.simulateWake(reconnecting: [lg])
        #expect(rig.count("disable \(lg)") == 1, "Only the start's so far")

        rig.clock.release(1)

        try await eventually { rig.count("disable \(lg)") == 2 }
        await runtime.shutdown()
    }

    /// A relaunched app takes the session back with its monitors just turned off again, the same
    /// moment a start has, so the poll runs here too.
    @Test func startupPollRunsOnAResumedSession() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        try rig.seedSessionFromADeadApp()
        rig.clock.hold(1)
        let runtime = rig.makeRuntime()

        try await runtime.start()
        try await eventually { rig.clock.heldCount(1) == 1 }
        rig.simulated.simulateWake(reconnecting: [lg])
        #expect(rig.count("disable \(lg)") == 1, "Only the resume's so far")

        rig.clock.release(1)

        try await eventually { rig.count("disable \(lg)") == 2 }
        await runtime.shutdown()
    }

    /// With the end still hung, so it's the shutdown that has to stop them. The clock moves past the
    /// poll's window so that a tick wouldn't wait for a turn, and would go straight on to the next one.
    @Test func startupPollStopsAtShutdown() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        rig.clock.hold(1)
        rig.clock.hold(10)
        _ = try await runtime.session.start(parsec())
        try await eventually { rig.clock.heldCount(1) == 1 }
        let hold = rig.holdSwitch(enabling: true)

        let stopping = Task { await runtime.shutdown() }
        try await eventually { rig.clock.heldCount(10) == 1 }
        rig.clock.release(10)
        await stopping.value

        rig.clock.advance(by: 100)
        rig.clock.release(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.clock.sleepCount(1) == 1, "The tick that was waiting was the last")

        rig.letGo(hold)
        try await runtime.session.inTurn {}
    }

    /// The window starts over for a new session, and one tick per second is all it takes.
    @Test func startupPollStopsAfter15TicksAndRunsAgainForTheNextSession() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()

        #expect(rig.clock.sleepCount(1) == 0, "No session, no ticks")

        _ = try await runtime.session.start(parsec())
        try await rig.letTheStartupPollFinish(runtime)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.clock.sleepCount(1) == 15)

        _ = try await runtime.session.end(client: "parsec", force: false, reason: "test")
        let afterEnd = rig.clock.sleepCount(1)
        _ = try await runtime.session.start(parsec())

        let clock = rig.clock
        try await eventually { clock.sleepCount(1) >= afterEnd + 15 }
        await runtime.shutdown()
    }

    @Test func registryUpdatedOnTopologyEvent() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        #expect(rig.registryKnows(uuid: lgUUID), "A launch records what's there")

        let id = rig.simulated.addVirtual(
            identity: DisplayIdentity(vendor: 1, model: 2, serial: 3, productName: "New"),
            mode: mode(1280, 720, hz: 60),
            modes: []
        )
        let uuid = try #require(rig.simulated.topology().display(id)?.identity.uuid)
        #expect(!rig.registryKnows(uuid: uuid))

        rig.events.fire()

        try await eventually { rig.registryKnows(uuid: uuid) }
        await runtime.shutdown()
    }

    @Test func registryWriteFailureOnlyLogs() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        // A folder in the file's place reads as a registry that can't be read, so every write fails.
        try FileManager.default.createDirectory(at: rig.paths.devices, withIntermediateDirectories: true)
        let runtime = rig.makeRuntime()

        try await runtime.start()
        rig.events.fire()

        try await eventually { rig.log.contains("The display registry can't be written") }
        #expect(await answer(from: rig.client) == .pong)
        #expect(rig.notifier.events == [.launched])
        await runtime.shutdown()
    }

    // MARK: Session changes

    @Test func sessionChangePostsNotification() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        #expect(rig.notifier.events == [.launched])

        _ = try await runtime.session.start(parsec())

        #expect(rig.notifier.events == [.launched, .sessionChanged])
        await runtime.shutdown()
    }

    @Test func sessionChangeTellsTheApp() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        var changes = 0
        runtime.onSessionChange = { changes += 1 }
        try await runtime.start()
        #expect(changes == 0)

        _ = try await runtime.session.start(parsec())

        #expect(changes == 1)
        await runtime.shutdown()
    }

    @Test func sessionChangesReachTheWatchFeedAndShutdownClosesIt() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        let feed = runtime.dispatcher.sessionChanges

        _ = try await runtime.session.start(parsec())

        #expect(feed.latest == 1)
        #expect(await feed.change(after: 0, waitingUpTo: 0)?.status == runtime.session.status())

        // The shutdown's 10 second limit would otherwise pass at once on this clock.
        rig.clock.hold(10)
        await runtime.shutdown()
        rig.clock.release(10)

        #expect(feed.latest == 2, "The quit's end is a change too")
        #expect(await feed.change(after: 1, waitingUpTo: 0)?.status.state == .idle)
        rig.clock.hold(30)
        #expect(await feed.change(after: 2, waitingUpTo: 30) == nil, "A closed feed doesn't wait")
        #expect(rig.clock.heldCount(30) == 0)
        rig.clock.release(30)
    }

    @Test func aWatchOverTheSocketAnswersWhenTheSessionChanges() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        let first = try await rig.send("session", "watch")
        guard case .object(let fields)? = first.json, case .string(let instance)? = fields["instance"] else {
            Issue.record("not a watch answer: \(String(describing: first.json))")
            return
        }
        #expect(fields["change"] == .number(0))
        #expect(fields["status"] == .object(["state": .string("idle"), "apiVersion": .number(1)]))

        rig.clock.hold(7)
        let client = rig.client
        let waiting = Task.detached {
            try await client.send(
                CommandRequest(
                    operations: ["session", "watch"],
                    parameters: [
                        CommandParameter(name: "instance", value: instance),
                        CommandParameter(name: "after", value: "0"),
                        CommandParameter(name: "wait", value: "7"),
                    ]
                ),
                timeout: 10
            )
        }
        let clock = rig.clock
        try await eventually { clock.heldCount(7) == 1 }

        _ = try await runtime.session.start(parsec())

        let answer = try await waiting.value
        guard case .object(let changed)? = answer.json, case .object(let status)? = changed["status"] else {
            Issue.record("not a watch answer: \(String(describing: answer.json))")
            return
        }
        #expect(changed["change"] == .number(1))
        #expect(status["state"] == .string("active"))
        #expect(status["displayID"] == .number(Double(try #require(runtime.session.status().displayID))))
        #expect(answer.payload == runtime.session.status().statusLine)
        rig.clock.release(7)
        await runtime.shutdown()
    }

    // MARK: What the status menu reads

    @Test func thePresetsAreTheOnesTheCommandsUse() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()

        #expect(runtime.presets == Presets.builtIn)
    }

    /// The presets window saves where the menu reads, and the save goes to `session.log`.
    @Test func thePresetsWindowSavesWhatTheMenuShows() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        let mine = Preset(name: "Mine", lookslike: "1600x1000", hidpi: true, hz: 120)

        #expect(try runtime.presetLibrary.save([mine], renaming: []) == [])

        #expect(runtime.presets == [mine])
        #expect(runtime.presetLibrary.savedPresets() == SavedPresets(presets: [mine]))
        let log = try String(contentsOf: rig.folder.appending(component: "session.log"), encoding: .utf8)
        #expect(log.contains("Presets saved from the window: 1 preset\n"))
    }

    @Test func launchAtLoginReadsTheSameSwitchTheCommandSets() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        #expect(runtime.launchAtLoginIsEnabled == false)

        let result = await runtime.dispatcher.handle(
            CommandRequest(operations: ["set"], parameters: [CommandParameter(name: "launchAtLogin", value: "on")])
        )

        #expect(result.ok)
        #expect(runtime.launchAtLoginIsEnabled)
    }

    // MARK: Shutdown

    @Test func shutdownEndsSessionFirst() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        _ = try await runtime.session.start(parsec())
        rig.clock.hold(10)

        // What a caller and a listener would find while the monitors are coming back.
        let client = rig.client
        let notifier = rig.notifier
        let duringEnd = Recorder<Answer>()
        let eventsDuringEnd = Recorder<[LifecycleEvent]>()
        rig.backend.update { script in
            script.beforeSetEnabled = { _, enabled in
                guard enabled, duringEnd.values.isEmpty else { return }
                eventsDuringEnd.append(notifier.events)
                duringEnd.append(answerHoldingThisThread(from: client))
            }
        }

        await runtime.shutdown()
        rig.clock.release(10)

        #expect(duringEnd.values == [.busy], "A session start can't sneak in during the end")
        #expect(eventsDuringEnd.values.first?.contains(.terminated) == false)
        #expect(runtime.session.status().state == .idle)
        #expect(try rig.ledger.load() == nil)
        let topology = rig.simulated.topology()
        #expect(topology.main?.id == lg)
        #expect(topology.display(lg)?.mode?.matches(lg120) == true)
        #expect(topology.online.allSatisfy { $0.kind != .ownVirtual })
        #expect(rig.notifier.events.last == .terminated)
        #expect(await answer(from: rig.client) == .notRunning, "The socket is gone")
        #expect(!FileManager.default.fileExists(atPath: rig.paths.socketPath))

        let next = rig.makeRuntime()
        try await next.start()
        #expect(await answer(from: rig.client) == .pong, "The lock was let go")
        await next.shutdown()
    }

    @Test func shutdownGivesUpAfter10s() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        _ = try await runtime.session.start(parsec())
        rig.clock.hold(10)
        let hold = rig.holdSwitch(enabling: true)

        let shutdown = Task { await runtime.shutdown() }
        try await eventually { rig.clock.heldCount(10) == 1 }
        await Task.yield()
        #expect(!rig.notifier.events.contains(.terminated), "It's still waiting for the end")

        rig.clock.release(10)
        await shutdown.value

        #expect(rig.notifier.events.last == .terminated)
        #expect(await answer(from: rig.client) == .notRunning)
        #expect(try rig.ledger.load()?.state == .ending, "The next launch or the guardian finishes it")

        rig.letGo(hold)
        try await runtime.session.inTurn {}
    }

    /// Past the socket's check, and waiting its turn when the quit begins.
    @Test func aStartThatGotPastTheSocketFailsOnceQuitting() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        let session = runtime.session
        let clock = rig.clock
        clock.hold(77)
        clock.hold(10)
        let inTheWay = Task { try await session.inTurn { try? await clock.sleep(seconds: 77) } }
        try await eventually { clock.heldCount(77) == 1 }

        let reply = Task { try await rig.send("session", "start", "-client=parsec") }
        try await eventually { session.turnsWaiting == 1 }
        let stopping = Task { await runtime.shutdown() }
        try await eventually { clock.heldCount(10) == 1 }

        clock.release(77)
        try await inTheWay.value
        let answer = try await reply.value
        await stopping.value
        clock.release(10)

        #expect(!answer.ok)
        #expect(answer.reason == "app is quitting")
        #expect(rig.simulated.mutations.isEmpty)
        #expect(try rig.ledger.load() == nil)
        #expect(rig.notifier.events == [.launched, .terminated])
    }

    /// A start this early has written nothing, so the session reads idle, and a shutdown that took that
    /// at its word would quit with the monitors about to go off. It waits, and ends what the start made.
    @Test func shutdownWaitsForARunningStart() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        let session = runtime.session
        rig.clock.hold(HoldableGuardian.seconds)
        rig.clock.hold(10)

        let starting = Task { try await session.start(parsec()) }
        try await eventually { rig.clock.heldCount(HoldableGuardian.seconds) == 1 }
        #expect(session.status().state == .idle)

        let stopping = Task { await runtime.shutdown() }
        try await eventually { rig.clock.heldCount(10) == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!rig.notifier.events.contains(.terminated), "It's waiting for the start")

        rig.clock.release(HoldableGuardian.seconds)
        _ = try await starting.value
        await stopping.value
        rig.clock.release(10)

        #expect(rig.count("disable \(lg)") == 1)
        #expect(rig.count("enable \(lg)") == 1)
        #expect(session.status().state == .idle)
        #expect(try rig.ledger.load() == nil)
        #expect(rig.notifier.events.last == .terminated)
    }

    @Test func shutdownGivesUpOnAHungStartAfter10s() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        let session = runtime.session
        rig.clock.hold(HoldableGuardian.seconds)
        rig.clock.hold(10)
        let starting = Task { try await session.start(parsec()) }
        try await eventually { rig.clock.heldCount(HoldableGuardian.seconds) == 1 }

        let stopping = Task { await runtime.shutdown() }
        try await eventually { rig.clock.heldCount(10) == 1 }
        rig.clock.release(10)
        await stopping.value

        #expect(rig.notifier.events.last == .terminated)

        rig.clock.release(HoldableGuardian.seconds)
        _ = try await starting.value
        try await session.inTurn {}
    }

    @Test func shutdownWaitsForARunningEnd() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        let session = runtime.session
        _ = try await session.start(parsec())
        rig.clock.hold(10)
        let hold = rig.holdSwitch(enabling: true)

        let ending = Task { try await session.end(client: "parsec", force: false, reason: "test") }
        try await eventually { hold.isReached }
        let stopping = Task { await runtime.shutdown() }
        try await eventually { rig.clock.heldCount(10) == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!rig.notifier.events.contains(.terminated), "It's waiting for the end")

        rig.letGo(hold)
        _ = try await ending.value
        await stopping.value
        rig.clock.release(10)

        #expect(try rig.ledger.load() == nil)
        #expect(rig.notifier.events.last == .terminated)
    }

    @Test func shutdownWithNoSessionIsQuick() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        rig.clock.hold(10)

        await runtime.shutdown()
        rig.clock.release(10)

        #expect(rig.notifier.events == [.launched, .terminated])
        #expect(rig.simulated.mutations.isEmpty)
    }

    @Test func pingAnswersDuringASlowEnd() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()
        _ = try await runtime.session.start(parsec())

        let hold = rig.holdSwitch(enabling: true)
        let session = runtime.session
        let ending = Task { try await session.end(client: "parsec", force: false, reason: "test") }
        try await eventually { hold.isReached }

        #expect(await answer(from: rig.client) == .pong, "The guardian's ping waits for no turn")

        rig.letGo(hold)
        _ = try await ending.value
        await runtime.shutdown()
    }

    // MARK: End to end

    @Test func endToEndOverSocket() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime()
        try await runtime.start()

        let started = try await rig.send(
            "session", "start", "-client=parsec", "-lookslike=1728x1080", "-ownerpid=\(ownerRef.pid)"
        )
        #expect(started.ok, "\(started.reason ?? "")")
        let line = try #require(started.payload)
        #expect(line.hasPrefix("state=active client=parsec displayID="))
        #expect(line.hasSuffix("lookslike=1728x1080 pixels=3456x2160 hz=60 off=\(lg),\(m34)"))
        #expect(rig.count("disable \(m34)") == 1)
        #expect(rig.count("disable \(lg)") == 1)

        let status = try await rig.send("session", "status")
        #expect(status.payload == line)

        let resized = try await rig.send("session", "resize", "-lookslike=1512x945")
        #expect(resized.payload?.contains("lookslike=1512x945 pixels=3024x1890") == true)
        #expect(resized.payload?.hasSuffix("off=\(lg),\(m34)") == true)

        let ended = try await rig.send("session", "end", "-client=parsec")
        #expect(ended.ok, "\(ended.reason ?? "")")
        #expect(rig.count("enable \(lg)") >= 1)
        #expect(rig.count("enable \(m34)") >= 1)

        let idle = try await rig.send("session", "status")
        #expect(idle.payload == "state=idle")

        let plan = try await rig.send("get", "-dryRunPlan")
        #expect(plan.payload == rig.simulated.mutations.joined(separator: "\n"))

        await runtime.shutdown()
        #expect(rig.notifier.events == [.launched, .sessionChanged, .sessionChanged, .sessionChanged, .terminated])
    }

    // MARK: Dry run

    @Test func dryRunUsesSimulatedBackend() async throws {
        let folder = temporaryFolder("ADDryRun")
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = [
            "AD_DRY_RUN": "1",
            "AD_STATE_DIR": folder.path,
            "AD_SOCKET_PATH": folder.appending(component: "ctl.sock").path,
        ]

        let runtime = EngineRuntime(environment: environment, safeMode: false)

        #expect(runtime.isDryRun)
        #expect(runtime.dispatcher.backend is SimulatedDisplayBackend)
        #expect(runtime.dispatcher.screens is SimulatedVirtualScreenProvider)
        #expect(runtime.session.power is FakePowerAssertions)
        #expect(runtime.seams.guardian is FakeGuardianProbe)
        #expect(runtime.seams.notifier is FakeLifecycleNotifier, "A dry run posts nothing to other processes")
        #expect(runtime.seams.events is ManualTopologyEvents, "Real display events aren't about the copy")
        #expect(!(runtime.dispatcher.launchAtLogin is SMAppServiceLaunchAtLogin))
        #expect(runtime.seams.sessionLogURL.path.hasPrefix(folder.path), "The real log stays out of it")

        try await runtime.start()
        #expect(runtime.dryRunPlan.isEmpty)

        let (request, _) = try CommandParser.parse(["session", "start", "-client=parsec"])
        let started = await runtime.dispatcher.handle(request)
        #expect(started.ok, "\(started.reason ?? "")")
        #expect(runtime.dryRunPlan.contains { $0.hasPrefix("addVirtual") })

        let (planRequest, _) = try CommandParser.parse(["get", "-dryRunPlan"])
        let plan = await runtime.dispatcher.handle(planRequest)
        #expect(plan.payload == runtime.dryRunPlan.joined(separator: "\n"))

        await runtime.shutdown()
        #expect(runtime.session.status().state == .idle)
    }

    @Test func dryRunPlanIsAnUnknownKeyOtherwise() async throws {
        let rig = try RuntimeRig()
        defer { rig.cleanUp() }
        let runtime = rig.makeRuntime(dryRunPlan: false)
        let (request, _) = try CommandParser.parse(["get", "-dryRunPlan"])

        #expect(await runtime.dispatcher.handle(request).ok == false)
        #expect(runtime.dryRunPlan.isEmpty)
    }

    // MARK: Choosing the seams

    /// `dryRunUsesSimulatedBackend` covers what `.dryRun` builds, and building `.live` in a test crashes.
    @Test func noOverrideMeansTheRealMac() {
        #expect(EngineConfiguration.choose(for: [:]) == .live)
        #expect(EngineConfiguration.choose(for: ["HOME": "/Users/someone"]) == .live)
    }

    @Test(arguments: ["AD_DRY_RUN", "AD_STATE_DIR", "AD_SOCKET_PATH"])
    func anyOverrideMeansTheSimulator(name: String) {
        #expect(EngineConfiguration.choose(for: [name: "1"]) == .dryRun)
        #expect(EngineConfiguration.choose(for: [name: ""]) == .live, "Empty counts as unset, as in ADPaths")
    }

    /// The app leaves its hotkeys, Restart and notifications to the real app in any test setup, including
    /// one that refuses to start, because its engine isn't running but the app around it is.
    @Test func anyOverrideIsATestSetup() {
        #expect(!EngineRuntime.isTestSetup([:]))
        #expect(!EngineRuntime.isTestSetup(["HOME": "/Users/someone", "AD_HIL": "1"]))
        #expect(EngineRuntime.isTestSetup(Self.good))
        for name in ["AD_DRY_RUN", "AD_STATE_DIR", "AD_SOCKET_PATH"] {
            #expect(EngineRuntime.isTestSetup([name: "/tmp/x"]), "\(name)")
            #expect(!EngineRuntime.isTestSetup([name: ""]), "\(name): empty counts as unset")
        }
    }

    // MARK: Refusals

    private static let good = ["AD_DRY_RUN": "1", "AD_STATE_DIR": "/tmp/ad-state", "AD_SOCKET_PATH": "/tmp/ad-ctl.sock"]

    private static func goodExcept(_ name: String, _ value: String) -> [String: String] {
        var environment = good
        environment[name] = value
        return environment
    }

    /// The links lead to where the real paths are, which may not exist yet, so neither may their targets.
    @Test func dryRunRefusesTheRealPathsThroughASymlink() throws {
        let manager = FileManager.default
        let real = ADPaths(environment: [:])
        let folder = temporaryFolder("ADLink")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }

        func link(_ name: String, to target: String) throws -> String {
            let path = folder.appending(component: name).path
            try manager.createSymbolicLink(atPath: path, withDestinationPath: target)
            return path
        }
        let toState = try link("state", to: real.stateDirectory.path)
        let toItsFolder = try link("support", to: real.stateDirectory.deletingLastPathComponent().path)
        let toSocket = try link("sock", to: real.socketPath)
        let chained = try link("chain", to: "state")
        let underItsFolder = "\(toItsFolder)/\(real.stateDirectory.lastPathComponent)"

        for path in [toState, underItsFolder, chained, real.stateDirectory.path.uppercased()] {
            #expect(EngineRuntime.dryRunRefusal(in: Self.goodExcept("AD_STATE_DIR", path)) != nil, "\(path)")
        }
        #expect(EngineRuntime.dryRunRefusal(in: Self.goodExcept("AD_SOCKET_PATH", toSocket)) != nil)
    }

    @Test func dryRunAcceptsASymlinkToSomewhereElse() throws {
        let manager = FileManager.default
        let folder = temporaryFolder("ADLink")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let path = folder.appending(component: "state").path
        try manager.createSymbolicLink(atPath: path, withDestinationPath: folder.appending(component: "elsewhere").path)

        #expect(EngineRuntime.dryRunRefusal(in: Self.goodExcept("AD_STATE_DIR", path)) == nil)
    }

    @Test func hostAcceptsOnlyACompleteDryRun() {
        #expect(EngineRuntime.dryRunRefusal(in: Self.good) == nil)

        func without(_ name: String) -> [String: String] {
            var environment = Self.good
            environment[name] = nil
            return environment
        }
        func with(_ name: String, _ value: String) -> [String: String] {
            var environment = Self.good
            environment[name] = value
            return environment
        }

        let refused: [[String: String]] = [
            [:],
            without("AD_DRY_RUN"), with("AD_DRY_RUN", "true"), with("AD_DRY_RUN", ""),
            without("AD_STATE_DIR"), with("AD_STATE_DIR", ""),
            without("AD_SOCKET_PATH"), with("AD_SOCKET_PATH", ""),
        ]
        for environment in refused {
            #expect(EngineRuntime.dryRunRefusal(in: environment) != nil, "\(environment)")
        }
    }

    /// A dry run on the real paths would take the real app's lock and read its ledger.
    @Test func dryRunRefusesTheRealPaths() {
        let real = ADPaths(environment: [:])

        var state = Self.good
        state["AD_STATE_DIR"] = real.stateDirectory.path
        var stateWithSlash = Self.good
        stateWithSlash["AD_STATE_DIR"] = real.stateDirectory.path + "/"
        var socket = Self.good
        socket["AD_SOCKET_PATH"] = real.socketPath

        for environment in [state, stateWithSlash, socket] {
            #expect(EngineRuntime.dryRunRefusal(in: environment) != nil, "\(environment)")
        }
    }

    @Test func aRealRunIsAnEnvironmentWithNoOverrides() {
        #expect(EngineRuntime.refusal(in: [:]) == nil)
        #expect(EngineRuntime.refusal(in: ["AD_DRY_RUN": ""]) == nil, "Empty counts as unset, as in ADPaths")
        #expect(EngineRuntime.refusal(in: Self.good) == nil)
        #expect(EngineRuntime.refusal(in: ["AD_STATE_DIR": "/tmp/ad-state"]) != nil)
        #expect(EngineRuntime.refusal(in: ["AD_SOCKET_PATH": "/tmp/ad-ctl.sock"]) != nil)
        #expect(EngineRuntime.refusal(in: ["AD_DRY_RUN": "true"]) != nil)
    }

    /// With overrides but no valid flag, nothing live is built, and the start refuses.
    @Test func startRefusesAnIncompleteTestSetup() async throws {
        let folder = temporaryFolder("ADRefused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = [
            "AD_DRY_RUN": "true",
            "AD_STATE_DIR": folder.path,
            "AD_SOCKET_PATH": folder.appending(component: "ctl.sock").path,
        ]

        let runtime = EngineRuntime(environment: environment, safeMode: false)

        #expect(!runtime.isDryRun)
        #expect(runtime.dispatcher.backend is SimulatedDisplayBackend)
        await #expect(throws: EngineRuntimeError.self) {
            try await runtime.start()
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "It stopped before touching anything")
    }
}
