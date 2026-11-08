import ADDisplayConfig
import ADDisplays
import ADFoundation
import ADIPC
import ADIntegrations
import ADModel
import ADSPI
import ADSafety
import ADVirtualScreens
import Foundation

public enum EngineRuntimeError: Error, Equatable {
    /// Another instance holds `app.lock`.
    case alreadyRunning
    /// `app.lock` can't be opened or locked, so nothing says this is the only instance.
    case cannotLock
    /// The environment is a test setup that isn't a complete dry run. The text says why.
    case refused(String)
}

/// What a runtime with no injected seams is built on.
nonisolated enum EngineConfiguration: Equatable {
    case live, dryRun

    /// No override at all means the real Mac. Any override means a test setup, as for the guardian, and
    /// that only ever gets the simulator. An empty variable counts as unset, the same as in `ADPaths`.
    static func choose(for environment: [String: String]) -> EngineConfiguration {
        let overrides = ["AD_DRY_RUN", "AD_STATE_DIR", "AD_SOCKET_PATH"]
        return overrides.contains { environment[$0]?.isEmpty == false } ? .dryRun : .live
    }
}

/// Everything the engine reaches outside itself with. The app gets `live` and a dry run gets `dryRun`,
/// and those are the only two places that choose what a process can touch. A test passes its own.
public struct EngineSeams {
    public var backend: any DisplayBackend
    public var screens: any VirtualScreenProviding
    public var ledger: any LedgerStoring
    public var power: any PowerAsserting
    public var guardian: any GuardianProbing
    public var processes: any ProcessInspecting
    public var clock: any ADClock
    public var events: any TopologyEventSource
    public var notifier: any LifecycleNotifying
    public var launchAtLogin: any LaunchAtLoginControlling
    public var capabilities: SPICapabilities
    public var bootSession: String
    public var selfRef: ProcessRef
    public var sessionLogURL: URL
    public var dryRunPlan: (@MainActor () -> [String])?

    public init(
        backend: any DisplayBackend,
        screens: any VirtualScreenProviding,
        ledger: any LedgerStoring,
        power: any PowerAsserting,
        guardian: any GuardianProbing,
        processes: any ProcessInspecting,
        clock: any ADClock,
        events: any TopologyEventSource,
        notifier: any LifecycleNotifying,
        launchAtLogin: any LaunchAtLoginControlling,
        capabilities: SPICapabilities,
        bootSession: String,
        selfRef: ProcessRef,
        sessionLogURL: URL,
        dryRunPlan: (@MainActor () -> [String])? = nil
    ) {
        self.backend = backend
        self.screens = screens
        self.ledger = ledger
        self.power = power
        self.guardian = guardian
        self.processes = processes
        self.clock = clock
        self.events = events
        self.notifier = notifier
        self.launchAtLogin = launchAtLogin
        self.capabilities = capabilities
        self.bootSession = bootSession
        self.selfRef = selfRef
        self.sessionLogURL = sessionLogURL
        self.dryRunPlan = dryRunPlan
    }

    static func make(_ configuration: EngineConfiguration, paths: ADPaths) -> EngineSeams {
        switch configuration {
        case .live: live(paths: paths)
        case .dryRun: dryRun(paths: paths)
        }
    }

    /// The real Mac. Only the app's own launch comes here, in the attended run.
    static func live(paths: ADPaths) -> EngineSeams {
        TestBundleGuard.preconditionMutationAllowed()
        let backend = LiveDisplayBackend()
        let clock = SystemClock()
        let processes = LiveProcessInspector()
        return EngineSeams(
            backend: backend,
            screens: LiveVirtualScreenProvider(backend: backend, clock: clock),
            ledger: FileLedgerStore(url: paths.ledger),
            power: LivePowerAssertions(),
            guardian: IPCGuardianProbe(socketPath: paths.guardianSocketPath),
            processes: processes,
            clock: clock,
            events: LiveTopologyEvents(),
            notifier: DistributedLifecycleNotifier(),
            launchAtLogin: SMAppServiceLaunchAtLogin(),
            capabilities: .probe(),
            bootSession: BootSession.current(),
            selfRef: currentProcess(processes),
            sessionLogURL: paths.logsDirectory.appending(component: "session.log", directoryHint: .notDirectory)
        )
    }

    /// A copy of the real Mac in memory. The real one is only read, once, to make the copy. Nothing
    /// here changes a display or wakes one, signals a process, posts to other processes, or writes
    /// outside the state directory. Its clock is the real one, so the flow keeps its real timing.
    static func dryRun(paths: ADPaths) -> EngineSeams {
        let backend = SimulatedDisplayBackend.seededFromLive()
        let processes = ReadOnlyProcesses()
        return EngineSeams(
            backend: backend,
            screens: SimulatedVirtualScreenProvider(backend: backend),
            ledger: FileLedgerStore(url: paths.ledger),
            power: FakePowerAssertions(onDeclare: { backend.wakeAll() }),
            guardian: FakeGuardianProbe(alive: true),
            processes: processes,
            clock: SystemClock(),
            events: ManualTopologyEvents(),
            notifier: FakeLifecycleNotifier(),
            launchAtLogin: InMemoryLaunchAtLogin(),
            capabilities: .probe(),
            bootSession: BootSession.current(),
            selfRef: currentProcess(processes),
            sessionLogURL: paths.stateDirectory.appending(component: "session.log", directoryHint: .notDirectory),
            dryRunPlan: { backend.mutations }
        )
    }

    /// A reference with no start time reads as a dead process, so if the lookup ever failed, the guardian
    /// would take over from this process. That's the safe way to be wrong.
    private static func currentProcess(_ processes: any ProcessInspecting) -> ProcessRef {
        processes.reference(forPID: getpid()) ?? ProcessRef(pid: getpid(), startTime: 0)
    }
}

/// Real answers about who's alive, because a dry run's `-ownerpid` is a real process. No signal is sent.
nonisolated private struct ReadOnlyProcesses: ProcessInspecting {
    private let live = LiveProcessInspector()

    func reference(forPID pid: Int32) -> ProcessRef? {
        live.reference(forPID: pid)
    }

    func isAlive(_ ref: ProcessRef) -> Bool {
        live.isAlive(ref)
    }

    func kill(_ ref: ProcessRef) {}
}

/// A dry run's login item, which goes no further than this object.
private final class InMemoryLaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled = false

    func setEnabled(_ on: Bool) {
        isEnabled = on
    }
}

/// Puts everything together, and runs the app's life from launch to quit. Start it once `NSApplication`
/// is running, because display events and a screen's mode list need the run loop.
@MainActor
public final class EngineRuntime {
    private static let startupPollSeconds = 1.0
    private static let startupPollTicks = 15
    private static let shutdownLimitSeconds = 10.0

    private enum Phase {
        case idle, running, stopped
    }

    public let dispatcher: CommandDispatcher
    public let session: SessionController
    public let isDryRun: Bool

    let seams: EngineSeams

    private let startRefusal: String?
    private let safeMode: Bool
    private let paths: ADPaths
    private let registry: DeviceRegistry
    private let log: SessionLog
    private let appLock: FileLock
    private let server: IPCServer

    private var phase = Phase.idle
    private var topologyWatcher: Task<Void, Never>?
    private var startupPoll: Task<Void, Never>?
    private var wasActive = false

    /// What `get -dryRunPlan` prints, one line each. Empty outside a dry run.
    public var dryRunPlan: [String] {
        seams.dryRunPlan?() ?? []
    }

    /// Called after each session state change, for the status menu.
    public var onSessionChange: (() -> Void)?

    /// The saved sizes, read at each call, so an edit to the file shows the next time the menu opens.
    public var presets: [Preset] {
        dispatcher.presets.presets()
    }

    /// What the presets window reads and saves through: the files the commands and the menu read, and
    /// `session.log`.
    public var presetLibrary: PresetLibraryStore {
        PresetLibraryStore(presets: dispatcher.presets, clients: dispatcher.sizer.clients, log: { [log] in log.append($0) })
    }

    public var launchAtLoginIsEnabled: Bool {
        seams.launchAtLogin.isEnabled
    }

    /// With `seams`, a test has chosen what can be touched. Without them the environment chooses, and
    /// `start` refuses a test setup unless it's a complete dry run.
    public init(environment: [String: String], safeMode: Bool, seams injected: EngineSeams? = nil) {
        let paths = ADPaths(environment: environment)
        let seams = injected ?? .make(.choose(for: environment), paths: paths)
        let log = SessionLog(url: seams.sessionLogURL)
        let registry = DeviceRegistry(url: paths.devices, bootSession: seams.bootSession)
        let operations = DisplayOperations(backend: seams.backend, clock: seams.clock)
        let relay = SessionChangeRelay()
        let session = SessionController(
            backend: seams.backend,
            screens: seams.screens,
            ledger: seams.ledger,
            registry: registry,
            power: seams.power,
            guardian: seams.guardian,
            processes: seams.processes,
            clock: seams.clock,
            operations: operations,
            restorer: { onProgress in
                PhysicalRestorer(
                    backend: seams.backend,
                    clock: seams.clock,
                    power: seams.power,
                    lockURL: paths.restoreLock,
                    onProgress: onProgress
                )
            },
            bootSession: seams.bootSession,
            selfRef: seams.selfRef,
            onChange: { relay.sessionChanged?() },
            log: log
        )
        let presets = PresetStore(url: paths.presets, log: { log.append($0) })
        let dispatcher = CommandDispatcher(
            backend: seams.backend,
            registry: registry,
            session: session,
            presets: presets,
            sizer: DeviceSizer(
                clients: ClientStore(url: paths.clients, log: { log.append($0) }),
                presets: presets,
                parsecLog: paths.parsecLog,
                parsecConfig: paths.parsecConfig,
                clock: seams.clock,
                log: { log.append($0) }
            ),
            operations: operations,
            screens: seams.screens,
            virtualStore: VirtualScreenStore(directory: paths.stateDirectory, log: { log.append($0) }),
            launchAtLogin: seams.launchAtLogin,
            capabilities: seams.capabilities,
            clock: seams.clock,
            dryRunPlan: seams.dryRunPlan
        )

        self.dispatcher = dispatcher
        self.session = session
        self.seams = seams
        self.safeMode = safeMode
        self.paths = paths
        self.registry = registry
        self.log = log
        isDryRun = environment["AD_DRY_RUN"] == "1"
        startRefusal = injected == nil ? Self.refusal(in: environment) : nil
        appLock = FileLock(url: paths.appLock)
        // The guardian's ping comes through here too, and the dispatcher answers it without waiting for
        // a turn, so a slow end can't look like a hung app.
        server = IPCServer(path: paths.socketPath) { request in
            await dispatcher.handle(request)
        }
        relay.sessionChanged = { [weak self] in self?.sessionDidChange() }
    }

    // MARK: Environment

    /// Why this environment can't run a dry run, or nil if it can. Without its own state directory a dry
    /// run would take the real app's lock and read its ledger, and without its own socket it would
    /// answer the real CLI. `addevhost` asks this before it builds anything.
    nonisolated public static func dryRunRefusal(in environment: [String: String]) -> String? {
        guard environment["AD_DRY_RUN"] == "1" else {
            return "AD_DRY_RUN=1 is required"
        }
        guard environment["AD_STATE_DIR"]?.isEmpty == false, environment["AD_SOCKET_PATH"]?.isEmpty == false else {
            return "a dry run needs its own AD_STATE_DIR and AD_SOCKET_PATH"
        }
        let real = ADPaths(environment: [:])
        let asked = ADPaths(environment: environment)
        if isSamePlace(asked.stateDirectory.path, real.stateDirectory.path)
            || isSamePlace(asked.socketPath, real.socketPath)
        {
            return "a dry run can't use the real state directory or the real socket"
        }
        return nil
    }

    /// Why the engine can't start in this environment, or nil if it can. A test setup must never reach
    /// the real displays, so it has to be a complete dry run.
    nonisolated public static func refusal(in environment: [String: String]) -> String? {
        isTestSetup(environment) ? dryRunRefusal(in: environment) : nil
    }

    /// True if any override is set, so this is a dry run or a setup that refuses to start. A copy like
    /// that leaves everything with an effect beyond itself to the real app: the emergency hotkeys, which
    /// would otherwise go to it once the real app lets go of them, opening a new copy, which would get
    /// none of this environment and so be the real app, and notifications, which would read as the real
    /// app's.
    nonisolated public static func isTestSetup(_ environment: [String: String]) -> Bool {
        EngineConfiguration.choose(for: environment) == .dryRun
    }

    /// With symlinks followed and case ignored, because this file system ignores it. On one that doesn't,
    /// this could only refuse a dry run it needn't, which is the safe way to be wrong.
    nonisolated private static func isSamePlace(_ first: String, _ second: String) -> Bool {
        func canonical(_ path: String) -> String {
            followingSymlinks(URL(fileURLWithPath: path).standardizedFileURL, hops: 0).path.lowercased()
        }
        return canonical(first) == canonical(second)
    }

    /// One level at a time, from the top. `resolvingSymlinksInPath` gives up on any path that doesn't
    /// exist yet, and the real state directory may not. The limit is for a cycle of links.
    nonisolated private static func followingSymlinks(_ url: URL, hops: Int) -> URL {
        guard url.path != "/", hops < 32 else { return url }
        let parent = followingSymlinks(url.deletingLastPathComponent(), hops: hops)
        let candidate = parent.appending(component: url.lastPathComponent)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) else {
            return candidate
        }
        let base = URL(fileURLWithPath: parent.path, isDirectory: true)
        return followingSymlinks(URL(fileURLWithPath: target, relativeTo: base).standardizedFileURL, hops: hops + 1)
    }

    // MARK: Start

    /// In the spec's order: the lock, the socket answering busy, the session found at launch, and only
    /// then ready. Throws `alreadyRunning` if another instance holds the lock.
    public func start() async throws {
        guard phase == .idle else { return }
        if let startRefusal { throw EngineRuntimeError.refused(startRefusal) }

        try paths.ensureStateDirectory()
        switch appLock.attemptLock() {
        case .acquired: break
        case .heldByOther: throw EngineRuntimeError.alreadyRunning
        case .failed: throw EngineRuntimeError.cannotLock
        }
        do {
            try server.start()
        } catch {
            appLock.unlock()
            throw error
        }
        phase = .running

        // A quit can come in during either of these. It has already told the socket to stay busy, and
        // it's ending what the resume found, so there's nothing more to bring up.
        await session.resumeAtLaunch(safeMode: safeMode)
        guard phase == .running else { return }
        if !safeMode { await dispatcher.reconnectSavedScreens() }
        guard phase == .running else { return }

        watchTopology()
        // No event may come for a long time, and a rescue with no ledger goes by what the registry knows.
        updateRegistry()
        server.setReady(true)
        seams.notifier.launched()
    }

    // MARK: Topology

    /// `topologyChanged` debounces inside, so each event gets its own call, with no waiting for the last.
    private func watchTopology() {
        let events = seams.events.events()
        let session = session
        topologyWatcher = Task { [weak self] in
            for await _ in events {
                self?.updateRegistry()
                Task { await session.topologyChanged() }
            }
        }
    }

    /// A failed write is logged and nothing more. The only thing that depends on it, a plain disconnect,
    /// makes a write of its own and refuses if that one fails.
    private func updateRegistry() {
        do {
            try registry.update(from: seams.backend.topology())
        } catch {
            log.append("The display registry can't be written: \(error.sessionReason)")
        }
    }

    // MARK: Session changes

    private func sessionDidChange() {
        seams.notifier.sessionChanged()
        let status = session.status()
        dispatcher.sessionChanges.record(status)
        let isActive = status.state == .active
        if isActive, !wasActive { runStartupPoll() }
        if !isActive {
            startupPoll?.cancel()
            startupPoll = nil
        }
        wasActive = isActive
        onSessionChange?()
    }

    /// Catches a monitor that comes back in the first seconds of a session with no event to say so.
    private func runStartupPoll() {
        let session = session
        let clock = seams.clock
        startupPoll = Task {
            for _ in 0..<Self.startupPollTicks {
                do {
                    try await clock.sleep(seconds: Self.startupPollSeconds)
                } catch {
                    return
                }
                await session.startupPollTick()
            }
        }
    }

    // MARK: Shutdown

    /// An orderly quit. Busy first, so a `session start` can't sneak in during the wait, and the socket
    /// goes last, so a caller gets told busy until then. Busy only stops what hasn't reached the socket's
    /// check yet, so the controller also refuses a start that has. A start or an end that's running
    /// counts even with no session yet, because the end below waits its turn behind it.
    public func shutdown() async {
        guard phase == .running else { return }
        phase = .stopped
        session.refuseNewSessions()
        server.setReady(false)

        let finished = await endSession()
        // After the end, so a watcher gets its last change. Its next request finds the socket busy, then gone.
        dispatcher.sessionChanges.close()

        topologyWatcher?.cancel()
        startupPoll?.cancel()
        server.stop()
        seams.notifier.terminated()
        // An end still running keeps the lock until this process exits, so nothing can start beside it.
        if finished { appLock.unlock() }
    }

    /// False if the limit came first. The end carries on until the process exits, and the ledger says
    /// `ending`, which the next launch finishes, as does the guardian if there isn't one.
    private func endSession() async -> Bool {
        let race = FirstToFinish()
        let session = session
        let log = log
        let clock = seams.clock
        Task {
            do {
                _ = try await session.end(client: nil, force: true, reason: "the app is quitting")
            } catch {
                log.append("Ending the session at quit failed: \(error.sessionReason)")
            }
            race.finish(with: true)
        }
        let limit = Task {
            try? await clock.sleep(seconds: Self.shutdownLimitSeconds)
            race.finish(with: false)
        }
        let finished = await race.result()
        limit.cancel()
        if !finished {
            log.append("The session hadn't ended after \(Int(Self.shutdownLimitSeconds)) seconds, so the app is quitting anyway")
        }
        return finished
    }
}

/// Lets the session controller, which has to exist before the runtime does, call back into the runtime.
private final class SessionChangeRelay {
    var sessionChanged: (() -> Void)?
}

/// Whichever `finish` comes first is the `result`.
private final class FirstToFinish {
    private var value: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func finish(with value: Bool) {
        guard self.value == nil else { return }
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func result() async -> Bool {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}
