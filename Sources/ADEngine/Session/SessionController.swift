import ADDisplayConfig
import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import ADVirtualScreens
import Foundation

/// The only code that runs a session: start, resize, enforcement, end and crash resume. It follows the
/// spec's Session and App launch sections, whose step numbers its comments use. The order is the point,
/// because a wrong one can leave someone with dark monitors.
///
/// **One operation runs at a time.** Every call waits its turn, and once one has begun it runs to the
/// end even if its caller goes away, because a sequence stopped halfway is what leaves monitors dark.
/// Display calls happen off the main actor, so hotkeys and display events keep arriving meanwhile.
@MainActor
public final class SessionController {
    private enum Seconds {
        static let afterDestroy = 1.0
        static let goneLimit = 2.0
        static let poll = 0.25
        /// How long a start waits for a read that shows no display, or for a just-woken display to
        /// report its mode, before it gives up.
        static let readLimit = 5.0
    }

    /// What `session end` means with no `-client`, the same as `session start`.
    private static let defaultClient = "default"
    private static let startHold = "Porch Light is starting a session"
    private static let endHold = "Porch Light is ending a session"
    private static let resumeHold = "Porch Light is resuming a session"

    /// A session this process is running or finishing.
    private struct LiveSession {
        /// As last written, or as last meant to be if a write failed on the way to restoring.
        var ledger: SafetyLedger
        /// Nil before a create, after a destroy, and while finishing a session this process didn't start.
        var screen: ActiveVirtualScreen?
        var phase: SessionState

        var spec: VirtualScreenSpec {
            Self.spec(of: ledger)
        }

        static func spec(of ledger: SafetyLedger) -> VirtualScreenSpec {
            VirtualScreenSpec.forClient(ledger.client, looksLike: ledger.looksLike, hiDPI: ledger.hiDPI, hz: ledger.hz)
        }

        var isRunning: Bool {
            phase == .active || phase == .degraded
        }
    }

    private let backend: any DisplayBackend
    private let screens: any VirtualScreenProviding
    private let writer: SessionLedgerWriter
    private let registry: DeviceRegistry
    /// The dispatcher wakes the displays with this before a plain `set -connected=on`.
    let power: any PowerAsserting
    private let guardian: any GuardianProbing
    private let processes: any ProcessInspecting
    private let clock: any ADClock
    private let operations: DisplayOperations
    private let restorer: PhysicalRestorer
    private let bootSession: String
    private let selfRef: ProcessRef
    private let onChange: @MainActor () -> Void
    private let log: SessionLog

    private let turn = SessionTurn()
    private var live: LiveSession?
    private var enforcer = SessionEnforcer()
    private var topologyEvents = 0
    private var endIsRunning = false
    private var endWaiters: [CheckedContinuation<EndOutcome, any Error>] = []
    private var pendingRecovery: Task<Void, Never>?
    private var isClosing = false

    /// `restorer` gets the closure the restorer must call as its `onProgress`. That closure moves the
    /// ledger's `updatedAt`, so this class has to supply it, and it's safe to call from any thread.
    public init(
        backend: any DisplayBackend,
        screens: any VirtualScreenProviding,
        ledger: any LedgerStoring,
        registry: DeviceRegistry,
        power: any PowerAsserting,
        guardian: any GuardianProbing,
        processes: any ProcessInspecting,
        clock: any ADClock,
        operations: DisplayOperations,
        restorer: (@escaping @Sendable () -> Void) -> PhysicalRestorer,
        bootSession: String,
        selfRef: ProcessRef,
        onChange: @escaping @MainActor () -> Void,
        log: SessionLog
    ) {
        let writer = SessionLedgerWriter(store: ledger, clock: clock, log: { log.append($0) })
        self.backend = backend
        self.screens = screens
        self.writer = writer
        self.registry = registry
        self.power = power
        self.guardian = guardian
        self.processes = processes
        self.clock = clock
        self.operations = operations
        self.restorer = restorer({ writer.beat() })
        self.bootSession = bootSession
        self.selfRef = selfRef
        self.onChange = onChange
        self.log = log

        screens.onScreenTerminated = { [weak self] ended in
            self?.screenEnded(ended)
        }
    }

    // MARK: Status

    public func status() -> SessionStatus {
        guard let live else { return SessionStatus(state: .idle) }
        let topology = backend.topology()
        let mode = live.spec.expectedMode
        // A caller captures this display, so one that has gone must not be named. An empty online list
        // is a bad read and says nothing about it, because a working Mac always lists the fallback.
        let screen = live.screen.flatMap { topology.online.isEmpty || SessionEnforcer.isOnline($0, in: topology) ? $0 : nil }
        return SessionStatus(
            state: live.phase,
            client: live.ledger.client,
            displayID: screen?.displayID,
            uuid: screen?.uuid,
            looksLike: live.ledger.looksLike,
            pixels: ScreenSize(w: mode.pixelsWide, h: mode.pixelsHigh),
            hiDPI: live.ledger.hiDPI,
            hz: live.ledger.hz,
            ownerPIDs: live.ledger.owners.map(\.pid),
            physicalOff: live.ledger.physical.filter { $0.onlineDisplay(in: topology) == nil }.map(\.id).sorted()
        )
    }

    /// The screen as a test or a caller in this module needs it.
    var activeScreen: ActiveVirtualScreen? {
        live?.screen
    }

    var endWaiterCount: Int {
        endWaiters.count
    }

    /// Calls waiting for the one that's running to finish.
    var turnsWaiting: Int {
        turn.waitingCount
    }

    /// Returns once the latest report of a screen ending has been dealt with.
    func recoveryFinished() async {
        await pendingRecovery?.value
    }

    // MARK: Start

    /// From the same client while a session runs, this adds the owners and keeps the current size, so
    /// a second guest connecting doesn't undo a size the user picked.
    public func start(_ request: SessionRequest) async throws -> SessionStatus {
        try await inTurn { [self] in try await runStart(request) }
    }

    /// The app is quitting, so from here on a start fails, even one that's already waiting its turn. A
    /// start that's already running finishes, and the quit's end, which waits behind it, ends it.
    public func refuseNewSessions() {
        isClosing = true
    }

    private func runStart(_ request: SessionRequest) async throws -> SessionStatus {
        if isClosing { throw SessionError.appIsQuitting }

        // Step 1. Nothing has changed until the first ledger write has succeeded, except that monitors
        // come back if the OS fallback display is up. That has no ledger to protect it, and needs none.
        if let reason = SessionLimits.validate(looksLike: request.looksLike, hz: request.hz) {
            throw SessionError(reason: reason)
        }
        let owners = try request.ownerPIDs.map { pid in
            guard let owner = processes.reference(forPID: pid) else { throw SessionError.ownerNotRunning(pid) }
            return owner
        }

        if let live {
            guard live.ledger.client == request.client else { throw SessionError.heldBy(live.ledger.client) }
            // Its own last session failed to end, and a guest can't start over that. Saying so points at
            // the way out, where "held by" names the very client that's asking.
            if live.phase == .ending { throw SessionError.lastEndUnfinished }
            guard live.isRunning else { throw SessionError.heldBy(live.ledger.client) }
            return try addOwners(owners)
        }
        try refuseIfALedgerIsLive()

        guard await guardian.isAlive() else { throw SessionError.guardianNotRunning }

        try await leaveFallbackIfUp()

        let now = clock.now()
        var ledger = SafetyLedger(
            state: .starting,
            client: request.client,
            looksLike: request.looksLike,
            hiDPI: request.hiDPI,
            hz: request.hz,
            keepOn: request.keepOn,
            owners: Self.unique(owners),
            app: selfRef,
            bootSessionID: bootSession,
            startedAt: now,
            updatedAt: now
        )
        do {
            ledger = try writer.save(ledger)
        } catch {
            log.append("Start refused, the ledger can't be written: \(error.localizedDescription)")
            throw SessionError.cannotWriteState
        }

        // Step 2.
        power.declareUserActivity()
        let hold = power.holdNoDisplaySleep(reason: Self.startHold)
        defer { hold.release() }

        // Step 3. Up to here no display has changed, so a failure is a plain refusal.
        do {
            ledger.physical = try await recordDisplays(keepOn: request.keepOn)
            ledger = try writer.save(ledger)
        } catch {
            log.append("Start refused: \(error.sessionReason)")
            try? writer.clear()
            throw error as? SessionError ?? SessionError.cannotWriteState
        }

        let starting = LiveSession(ledger: ledger, screen: nil, phase: .starting)
        live = starting
        log.append("Starting a session for \(request.client), \(request.looksLike)")
        do {
            // Steps 4 and 5.
            let screen = try await screens.create(starting.spec)
            live?.screen = screen
            writer.touch()

            try await operations.setMain(screen.displayID)
            writer.touch()

            try NeverZeroRule.check(
                topology: backend.topology(),
                disconnecting: Set(ledger.physical.map(\.id)),
                inProtectedSession: true
            ).get()

            let order = SessionEnforcer.disconnectOrder(ledger.physical).map(\.id)
            for id in try await disconnectTogether(order) {
                try await operations.disconnect(id)
                writer.touch()
            }
            writer.touch()

            // Step 6.
            ledger.state = .active
            do {
                live?.ledger = try writer.save(ledger)
            } catch {
                throw SessionError.cannotWriteState
            }
        } catch {
            throw await rollBackStart(after: error)
        }

        live?.phase = .active
        enforcer.sessionBecameActive(at: clock.now())
        hold.release()
        log.append("The session is active")
        onChange()
        return status()
    }

    /// Returns what the start should throw: its own reason, plus the rollback's if that failed too.
    private func rollBackStart(after error: any Error) async -> SessionError {
        let reason = error.sessionReason
        log.append("The start failed, rolling back: \(reason)")
        do {
            _ = try await runEndSequence(why: "the start failed")
            return SessionError(reason: reason)
        } catch {
            return SessionError(reason: "\(reason); \(error.sessionReason)")
        }
    }

    private func addOwners(_ owners: [ProcessRef]) throws -> SessionStatus {
        guard var ledger = live?.ledger else { return status() }
        let new = Self.unique(owners).filter { !ledger.owners.contains($0) }
        guard !new.isEmpty else { return status() }

        ledger.owners += new
        do {
            live?.ledger = try writer.save(ledger)
        } catch {
            log.append("Adding an owner failed, the ledger can't be written: \(error.localizedDescription)")
            throw SessionError.cannotWriteState
        }
        return status()
    }

    /// A ledger this process doesn't know about may be a session's only record of monitors it turned
    /// off, so writing over it could lose them for good. A file that can't be read might be just that.
    private func refuseIfALedgerIsLive() throws {
        let found: SafetyLedger?
        do {
            found = try writer.load()
        } catch {
            log.append("Start refused, the ledger can't be read: \(error.localizedDescription)")
            throw SessionError.cannotWriteState
        }
        guard let found, isLive(found) else { return }
        throw SessionError.heldBy(found.client)
    }

    private func isLive(_ ledger: SafetyLedger) -> Bool {
        ledger.state != .rescued && !GuardianPolicy.isFromAnotherBoot(ledger, currentBoot: bootSession)
    }

    /// With the OS fallback display up no monitor is listed, so a record made now would hold nothing,
    /// and the session's end would report success over dark monitors. So they come back first, and
    /// with none to come back there's nothing for an end to return to. This changes nothing else.
    private func leaveFallbackIfUp() async throws {
        guard backend.topology().online.contains(where: { $0.kind == .osFallback }) else { return }
        log.append("The OS fallback display is up, so this reconnects from the registry before starting")
        guard await reconnectFromRegistry() else {
            log.append("Start refused: \(SessionError.noPhysicalDisplay.reason)")
            throw SessionError.noPhysicalDisplay
        }
    }

    /// Every online physical display not kept on, sleeping ones included. A read can come back empty,
    /// and a display that has only just been told to wake may not report its mode yet, so this gives
    /// them a moment. Going ahead on an empty read would record nothing and leave the monitors on.
    private func recordDisplays(keepOn: [String]) async throws -> [PhysicalRecord] {
        let kept = Set(keepOn.map { $0.uppercased() })
        func targets(_ topology: Topology) -> [DisplaySnapshot] {
            topology.online.filter { display in
                display.kind == .physical && !(display.identity.uuid.map { kept.contains($0.uppercased()) } ?? false)
            }
        }
        func isReadable(_ topology: Topology) -> Bool {
            !topology.online.isEmpty && !targets(topology).contains { $0.mode == nil }
        }

        var topology = backend.topology()
        let deadline = clock.now().addingTimeInterval(Seconds.readLimit)
        while !isReadable(topology), clock.now() < deadline {
            try await clock.sleep(seconds: Seconds.poll)
            topology = backend.topology()
        }
        guard !topology.online.isEmpty else { throw SessionError.noDisplaysFound }
        // With only another virtual display up there's nothing to record, and an end would report
        // success over dark monitors. This also catches the fallback if an empty read hid it earlier.
        guard topology.online.contains(where: { $0.kind == .physical }) else {
            throw SessionError.noPhysicalDisplay
        }

        // The way back if the ledger is lost, so a session doesn't begin without it.
        do {
            try registry.update(from: topology)
        } catch {
            log.append("The display registry can't be written: \(String(describing: error))")
            throw SessionError.cannotWriteState
        }

        return try targets(topology).map { display in
            guard let mode = display.mode else {
                throw SessionError.cannotRead(display.identity.productName ?? "\(display.id)")
            }
            return PhysicalRecord(
                id: display.id,
                identity: display.identity,
                origin: display.origin,
                mode: recordedMode(of: display, current: mode),
                wasMain: display.isMain
            )
        }
    }

    /// A pinned rate goes in place of the current one, so a restore never reproduces a bad rate.
    private func recordedMode(of display: DisplaySnapshot, current: DisplayMode) -> DisplayMode {
        guard let uuid = display.identity.uuid, let pin = registry.entry(uuid: uuid)?.pinnedRefreshHz else {
            return current
        }
        var wanted = current
        wanted.refreshHz = Double(pin)
        return backend.modes(of: display.id).first { $0.matches(wanted) } ?? wanted
    }

    // MARK: End

    /// `client` nil means the default client. An `end` while another is running gets that one's result
    /// instead of starting a second.
    public func end(client: String?, force: Bool, reason: String) async throws -> EndOutcome {
        if endIsRunning {
            if !force, let holder = live?.ledger.client, holder != client ?? Self.defaultClient {
                throw SessionError.heldBy(holder)
            }
            return try await withCheckedThrowingContinuation { endWaiters.append($0) }
        }
        return try await inTurn { [self] in try await runEnd(client: client, force: force, reason: reason) }
    }

    private func runEnd(client: String?, force: Bool, reason: String) async throws -> EndOutcome {
        let onDisk: SafetyLedger?
        do {
            onDisk = try writer.load()
        } catch {
            // Memory still has the records, so a running session can still end. Without one, this
            // can't say whether a session exists.
            log.append("The ledger can't be read: \(error.localizedDescription)")
            guard live != nil else { throw SessionError.cannotWriteState }
            onDisk = nil
        }

        // The guardian brought the monitors back already, so all that's left is to tidy up.
        if onDisk?.state == .rescued {
            if let screen = live?.screen {
                screens.destroy(screen)
                live?.screen = nil
            }
            return try finishRescued()
        }

        if live == nil {
            guard let onDisk else { return EndOutcome() }
            if GuardianPolicy.isFromAnotherBoot(onDisk, currentBoot: bootSession) {
                log.append("Discarding a ledger from another boot")
                try clearLedger()
                return EndOutcome()
            }
            try checkHolder(onDisk.client, client: client, force: force)
            var adopted = onDisk
            adopted.app = selfRef
            live = LiveSession(ledger: adopted, screen: nil, phase: .ending)
        } else if let holder = live?.ledger.client {
            try checkHolder(holder, client: client, force: force)
        }

        log.append("Ending the session: \(reason)")
        return try await runEndSequence(why: reason)
    }

    private func checkHolder(_ holder: String, client: String?, force: Bool) throws {
        guard force || holder == client ?? Self.defaultClient else { throw SessionError.heldBy(holder) }
    }

    /// Force-ends any session, then reconnects every display this boot's registry knows, and it fails if
    /// no physical display is online afterward. It goes ahead of every call that's waiting, because
    /// someone may be sitting in front of dark monitors, but it doesn't interrupt the one that's running.
    /// So it must not be called from inside a turn.
    public func rescue() async throws -> EndOutcome {
        try await inTurn(first: true) { [self] in try await runRescue() }
    }

    private func runRescue() async throws -> EndOutcome {
        let found: SafetyLedger?
        do {
            found = try writer.load()
        } catch {
            // That says nothing about a session, and reconnecting is safe either way.
            log.append("The ledger can't be read during a rescue: \(error.localizedDescription)")
            found = nil
        }

        if live != nil || found.map(isLive) == true {
            // The end only brings back what it recorded. A monitor that was off before the session, or
            // kept on and then turned off by hand, needs this too, and needs it even if the end failed.
            let outcome: EndOutcome
            do {
                outcome = try await runEnd(client: nil, force: true, reason: "rescue")
            } catch {
                _ = await reconnectFromRegistry()
                throw error
            }
            guard await reconnectFromRegistry() else { throw SessionError.couldNotRestore }
            return outcome
        }

        if found != nil {
            log.append("Clearing a ledger with no session left in it")
            try? writer.clear()
        }
        log.append("Rescue with no session, so this reconnects from the registry")
        let reconnected = await reconnectFromRegistry()
        onChange()
        guard reconnected else { throw SessionError.couldNotRestore }
        return EndOutcome()
    }

    private func finishRescued() throws -> EndOutcome {
        try clearLedger()
        let hadSession = live != nil
        live = nil
        enforcer.sessionEnded()
        if hadSession { onChange() }
        return EndOutcome()
    }

    private func clearLedger() throws {
        do {
            try writer.clear()
        } catch {
            log.append("The ledger can't be cleared: \(error.localizedDescription)")
            throw SessionError.cannotWriteState
        }
    }

    /// The spec's end sequence, for every path that needs it. Whoever called `end` while this runs gets
    /// the same result. On a failure the ledger stays and `updatedAt` stops moving, so the guardian's
    /// frozen-state row takes over, and another `end` may try again.
    private func runEndSequence(why: String) async throws -> EndOutcome {
        endIsRunning = true
        let result: Result<EndOutcome, any Error>
        do {
            result = .success(try await performEndSequence(why: why))
        } catch {
            result = .failure(error)
        }
        endIsRunning = false

        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters { waiter.resume(with: result) }

        if case .failure(let error) = result {
            log.append("The end failed: \(error.sessionReason)")
            onChange()
        }
        return try result.get()
    }

    private func performEndSequence(why: String) async throws -> EndOutcome {
        guard var session = live else { return EndOutcome() }

        // Step 1. Unlike every other step, this one goes ahead if the write fails. What's on disk still
        // records every monitor, this only moves toward that record, and refusing would leave them dark.
        session.ledger.state = .ending
        session.phase = .ending
        do {
            session.ledger = try writer.save(session.ledger)
        } catch {
            log.append("Writing ending failed, restoring anyway: \(error.localizedDescription)")
        }
        live = session

        power.declareUserActivity()
        let hold = power.holdNoDisplaySleep(reason: Self.endHold)
        defer { hold.release() }
        writer.setBeating(true)
        defer { writer.setBeating(false) }

        // Step 2, with the screen still alive so there's always something showing.
        let records = session.ledger.physical
        var report = await restorer.restore(records)
        try check(report)

        // Step 3. Every monitor could have been kept on and since gone off or been unplugged, and then a
        // restore that did its job has still left only the screen. So the screen stays, and so does the
        // ledger. The rule's own protection for the screen doesn't apply, because this is it going away.
        if let screen = session.screen {
            if case .failure = NeverZeroRule.check(
                topology: backend.topology(),
                disconnecting: [screen.displayID],
                inProtectedSession: false
            ) {
                log.append("Nothing else is showing, so the screen stays")
                throw SessionError.didNotComeBack
            }
            screens.destroy(screen)
            live?.screen = nil
            await waitUntilGone(screen.displayID)
            try? await clock.sleep(seconds: Seconds.afterDestroy)

            let holds = SessionEnforcer.arrangementHolds(
                records,
                missing: report.missing,
                modeNotOffered: report.modeNotOffered,
                in: backend.topology()
            )
            if !holds {
                log.append("macOS moved something when the screen went, so this fixes it once")
                report = await restorer.restore(records)
                try check(report)
            }
        }

        // Step 4.
        try clearLedger()
        live = nil
        enforcer.sessionEnded()

        let outcome = EndOutcome(
            missing: report.missing.map(\.displayName),
            notAtRecordedMode: report.modeNotOffered.map(\.displayName)
        )
        log.append("The session ended: \(why)" + (outcome.warning.map { ", \($0)" } ?? ""))
        onChange()
        return outcome
    }

    private func check(_ report: RestoreReport) throws {
        guard report.anyReturned else { throw SessionError.couldNotRestore }
        guard report.verified else { throw SessionError.didNotComeBack }
    }

    /// A released screen leaves the list some time later, and a new screen with the same identity must
    /// not race that. Going ahead at the limit is better than holding up the end for good.
    private func waitUntilGone(_ id: DisplayID) async {
        let deadline = clock.now().addingTimeInterval(Seconds.goneLimit)
        while backend.topology().display(id) != nil {
            guard clock.now() < deadline else {
                log.append("Display \(id) is still listed \(Int(Seconds.goneLimit)) seconds after its release")
                return
            }
            do {
                try await clock.sleep(seconds: Seconds.poll)
            } catch {
                return
            }
        }
    }

    // MARK: Resize

    /// The new size goes to the ledger first, so a crash recovery comes back at the size the user picked.
    /// Never touches the physical monitors. A nil `looksLike`, `hiDPI` or `hz` stays as the session has
    /// it when this gets its turn, which may be after another resize has changed it.
    public func resize(looksLike: ScreenSize?, hiDPI: Bool?, hz: Int?) async throws -> SessionStatus {
        try await inTurn { [self] in try await runResize(looksLike: looksLike, hiDPI: hiDPI, hz: hz) }
    }

    private func runResize(looksLike: ScreenSize?, hiDPI: Bool?, hz: Int?) async throws -> SessionStatus {
        guard var session = live, session.isRunning, let screen = session.screen else {
            throw SessionError.noSession
        }
        let looksLike = looksLike ?? session.ledger.looksLike
        let hiDPI = hiDPI ?? session.ledger.hiDPI
        let hz = hz ?? session.ledger.hz
        if let reason = SessionLimits.validate(looksLike: looksLike, hz: hz) {
            throw SessionError(reason: reason)
        }
        let previous = session.ledger

        session.ledger.looksLike = looksLike
        session.ledger.hiDPI = hiDPI
        session.ledger.hz = hz
        do {
            session.ledger = try writer.save(session.ledger)
        } catch {
            log.append("Resize refused, the ledger can't be written: \(error.localizedDescription)")
            throw SessionError.cannotWriteState
        }
        live = session

        // The mode check needs the screen active.
        power.declareUserActivity()
        do {
            let resized = try await screens.reconfigure(screen, to: session.spec)
            live?.screen = resized
            await makeMainIfNeeded(resized.displayID)
            log.append("Resized to \(looksLike) at \(hz) Hz")
            onChange()
            return status()
        } catch {
            let reason = error.sessionReason
            log.append("The resize to \(looksLike) at \(hz) Hz failed: \(reason)")
            let consequence = await revertResize(of: screen, to: previous)
            throw SessionError(reason: consequence.map { "\(reason); \($0)" } ?? reason)
        }
    }

    /// Nil if the screen went back. If it couldn't, the session has to end, because no screen with the
    /// monitors off would leave nothing showing, and this returns the words for how that went.
    private func revertResize(of screen: ActiveVirtualScreen, to previous: SafetyLedger) async -> String? {
        do {
            live?.ledger = try writer.save(previous)
        } catch {
            live?.ledger = previous
            log.append("Writing the previous size failed: \(error.localizedDescription)")
        }
        let spec = LiveSession.spec(of: previous)

        // After a failed recreate the old screen has gone, and nothing is left to reconfigure.
        var restored: ActiveVirtualScreen?
        if SessionEnforcer.isOnline(screen, in: backend.topology()) {
            do {
                restored = try await screens.reconfigure(screen, to: spec)
            } catch {
                log.append("Going back in place failed: \(error.sessionReason)")
            }
        }
        if restored == nil {
            screens.destroy(screen)
            await waitUntilGone(screen.displayID)
            do {
                restored = try await screens.create(spec)
            } catch {
                log.append("Making the previous size again failed: \(error.sessionReason)")
            }
        }

        guard let restored else {
            live?.screen = nil
            let cause = "the previous size could not be restored"
            do {
                _ = try await runEndSequence(why: cause)
                return "\(cause), so the session ended"
            } catch {
                return "\(cause), and ending the session failed: \(error.sessionReason)"
            }
        }
        live?.screen = restored
        await makeMainIfNeeded(restored.displayID)
        if restored.displayID != screen.displayID { onChange() }
        return nil
    }

    // MARK: Enforcement

    /// Call this for every topology event, without waiting for one call before making the next. A
    /// burst acts once, 1 second after the last event of it.
    public func topologyChanged() async {
        topologyEvents += 1
        let event = topologyEvents
        guard live != nil else { return }
        do {
            try await clock.sleep(seconds: SessionEnforcer.debounceSeconds)
        } catch {
            return
        }
        guard event == topologyEvents else { return }
        try? await inTurn { [self] in await enforce() }
    }

    /// Call this once a second. It does nothing outside the first 15 seconds of a session, and that
    /// window starts over when a relaunched app takes a session back.
    public func startupPollTick() async {
        guard enforcer.isPolling(at: clock.now()) else { return }
        try? await inTurn { [self] in await enforce() }
    }

    /// In this order, because a monitor must not go off while nothing else is showing.
    private func enforce() async {
        guard let session = live, session.isRunning, let screen = session.screen else { return }
        let topology = backend.topology()
        guard !topology.listReadFailed else {
            log.append("The display list can't be read, so enforcement skips this pass")
            return
        }

        if !SessionEnforcer.isOnline(screen, in: topology) {
            log.append("Screen \(screen.displayID) has gone")
            guard await recreateWithinBudget() else { return }
        }

        // Degraded means it stopped trying to hold the monitors off and keep main. Keeping a screen
        // isn't part of that, as long as its own budget lasts.
        guard live?.phase == .active, let id = live?.screen?.displayID else { return }
        guard await retakeMainWithinBudget(id) else { return }
        await disconnectWhatReturned()
    }

    /// Past the budget, this stops enforcing. That leaves the session with no screen, which is fine
    /// with a monitor still on. With none it would leave nothing showing, so the session ends instead,
    /// the same as for a screen that can't be recreated. False if there's no new screen.
    private func recreateWithinBudget() async -> Bool {
        guard enforcer.spend([.screen], at: clock.now()) else {
            stopEnforcing(because: "The screen keeps going away")
            let topology = backend.topology()
            if case .failure = NeverZeroRule.check(topology: topology, disconnecting: [], inProtectedSession: true) {
                log.append("Nothing else is showing, so this ends the session")
                _ = try? await runEndSequence(why: "the screen keeps going away")
            }
            return false
        }
        return await recreateScreen()
    }

    /// False if it has stopped enforcing. A screen that's main already spends nothing.
    private func retakeMainWithinBudget(_ id: DisplayID) async -> Bool {
        let topology = backend.topology()
        if topology.main?.id == id, topology.display(id)?.origin == DisplayOrigin(x: 0, y: 0) { return true }

        guard enforcer.spend([.main], at: clock.now()) else {
            stopEnforcing(because: "Something keeps taking main")
            return false
        }
        await makeMainIfNeeded(id)
        return true
    }

    /// Only the first time says so, so a pass made after this adds nothing.
    private func stopEnforcing(because why: String) {
        guard live?.phase == .active else { return }
        live?.phase = .degraded
        let limit = "\(SessionEnforcer.actionsPerWindow) times in \(Int(SessionEnforcer.windowSeconds)) seconds"
        log.append("\(why), \(limit), so this stopped enforcing. The session still works")
        onChange()
    }

    private func disconnectWhatReturned() async {
        guard let session = live else { return }
        let topology = backend.topology()
        let returned = SessionEnforcer.returned(session.ledger, in: topology)
        guard !returned.isEmpty else { return }

        if case .failure(let refusal) = NeverZeroRule.check(
            topology: topology,
            disconnecting: Set(returned.map(\.display.id)),
            inProtectedSession: true
        ) {
            log.append("Not turning a monitor back off: \(refusal.reason)")
            return
        }

        guard enforcer.spend(returned.map { .monitor($0.record.id) }, at: clock.now()) else {
            stopEnforcing(because: "A monitor keeps coming back")
            return
        }

        let left: [DisplayID]
        do {
            left = try await disconnectTogether(returned.map(\.display.id))
        } catch {
            // Only one came back, so there was nothing to fall back to.
            log.append("Turning display \(returned[0].display.id) off again failed: \(error.sessionReason)")
            return
        }
        for item in returned {
            if !left.contains(item.display.id) {
                log.append("Display \(item.display.id) came back on and was turned off again")
                continue
            }
            do {
                try await operations.disconnect(item.display.id)
                log.append("Display \(item.display.id) came back on and was turned off again")
            } catch {
                log.append("Turning display \(item.display.id) off again failed: \(error.sessionReason)")
            }
        }
    }

    /// A display transaction longer than this is the stall of spec section 4.3.
    private static let slowTransactionSeconds = 5.0

    /// Spec section 4.3: every monitor in one display transaction, because turning the last one off in
    /// a transaction of its own sometimes stalled for 10 seconds. Returns the monitors the caller still
    /// has to turn off one at a time, as before: none if the transaction worked, and if it failed, the
    /// ones that still read online, which this logs. With only one monitor, one at a time would repeat
    /// the same call, so its error goes straight to the caller.
    private func disconnectTogether(_ ids: [DisplayID]) async throws -> [DisplayID] {
        guard !ids.isEmpty else { return [] }
        do {
            // The macOS call alone, because that's where the stall is.
            let callSeconds = try await operations.disconnect(ids)
            let seconds = String(format: "%.1f", callSeconds)
            let monitors = ids.count == 1 ? "1 monitor" : "\(ids.count) monitors"
            let slow = callSeconds > Self.slowTransactionSeconds ? " (macOS took over 5 s to confirm)" : ""
            log.append("turned off \(monitors) in \(seconds) s\(slow)")
            return []
        } catch {
            guard ids.count > 1 else { throw error }
            log.append("turning the monitors off together failed (\(error.sessionReason)), so they go one at a time")
            return stillOnline(ids)
        }
    }

    /// Those a fresh read shows online, in the order given, so a monitor the failed transaction did turn
    /// off isn't switched again. A read with nothing online is a bad read, because the session's screen
    /// is up, so then it's all of them.
    private func stillOnline(_ ids: [DisplayID]) -> [DisplayID] {
        let online = backend.topology().onlineIDs
        guard !online.isEmpty else { return ids }
        return ids.filter { online.contains($0) }
    }

    private func makeMainIfNeeded(_ id: DisplayID) async {
        do {
            // This returns at once if the screen is main already.
            try await operations.setMain(id)
        } catch {
            log.append("Making screen \(id) main failed: \(error.sessionReason)")
        }
    }

    /// False if it couldn't, in which case the session has ended: with the monitors off, no screen
    /// means nothing is showing.
    private func recreateScreen() async -> Bool {
        guard let session = live else { return false }
        if let old = session.screen {
            screens.destroy(old)
            await waitUntilGone(old.displayID)
        }
        power.declareUserActivity()
        do {
            let screen = try await screens.create(session.spec)
            live?.screen = screen
            await makeMainIfNeeded(screen.displayID)
            log.append("Screen recreated as \(screen.displayID)")
            onChange()
            return true
        } catch {
            log.append("Recreating the screen failed: \(error.sessionReason)")
            live?.screen = nil
            _ = try? await runEndSequence(why: "the screen could not be recreated")
            return false
        }
    }

    /// The system ended the screen. A screen ending during a resize also makes that call throw, and the
    /// resize deals with it. By the time this report gets its turn the ID no longer matches, so there's
    /// never a second recreate.
    private func screenEnded(_ ended: ActiveVirtualScreen) {
        log.append("The system ended screen \(ended.displayID)")
        pendingRecovery = Task { [self] in
            try? await inTurn { [self] in
                guard let session = live, session.isRunning, session.screen?.displayID == ended.displayID else {
                    return
                }
                _ = await recreateWithinBudget()
            }
        }
    }

    // MARK: Launch

    /// A restore stops itself within 190 seconds, so a `restore.lock` held for longer isn't a restore's.
    private static let restoreWaitLimit = 200.0

    /// Call this before the socket stops answering busy.
    public func resumeAtLaunch(safeMode: Bool) async {
        try? await inTurn { [self] in await runResume(safeMode: safeMode) }
    }

    /// The ledger a launch goes on with, or nil once whatever can't be resumed is dealt with: no ledger,
    /// one set aside, one from another boot, or one already rescued.
    private func ledgerToResume() async -> SafetyLedger? {
        let found: SafetyLedger?
        do {
            found = try writer.load()
        } catch {
            // It may read fine in a moment. The guardian carries on from its last good copy.
            log.append("The ledger can't be read at launch: \(error.localizedDescription)")
            return nil
        }

        // Taken on every load, but a ledger that reads is the truth.
        let setAside = writer.takeSetAsideEvent()
        guard let ledger = found else {
            if setAside {
                log.append("The ledger was unreadable and was set aside, so this reconnects from the registry")
                _ = await reconnectFromRegistry()
                onChange()
            }
            return nil
        }

        if GuardianPolicy.isFromAnotherBoot(ledger, currentBoot: bootSession) {
            log.append("Discarding a ledger from another boot")
            try? writer.clear()
            return nil
        }
        if ledger.state == .rescued {
            log.append("Clearing a rescued ledger")
            try? writer.clear()
            return nil
        }
        return ledger
    }

    private func runResume(safeMode: Bool) async {
        guard var ledger = await ledgerToResume() else { return }
        // Before this process names itself in the ledger, because that write would put `active` back
        // over a restore's `ending`.
        if ledger.state == .active, await waitedForARestore() {
            guard let reread = await ledgerToResume() else { return }
            ledger = reread
        }

        // First, before any display step, so that a restore can always find and kill this process. If
        // it can't be written, the guardian is going by the old process, so hands stay off the displays.
        ledger.app = selfRef
        do {
            ledger = try writer.save(ledger)
        } catch {
            log.append("Resume stopped, the ledger can't be written: \(error.localizedDescription)")
            return
        }
        live = LiveSession(ledger: ledger, screen: nil, phase: .starting)

        let ownerDied = ledger.owners.contains { !processes.isAlive($0) }
        if safeMode || ledger.state != .active || ownerDied {
            let why = safeMode ? "safe mode" : ownerDied ? "an owner died" : "finishing a \(ledger.state.rawValue) session"
            log.append("Resuming by ending the session: \(why)")
            _ = try? await runEndSequence(why: why)
            return
        }
        await resumeActive(ledger)
    }

    /// A restore holds `restore.lock` for its whole run, and an app that resumed under it would turn the
    /// monitors off while the restore turns them on. So while another holds the lock, this waits, and
    /// then the ledger has to be read again: the restore may have rescued the session, or left it
    /// `ending`. The lock is let go at once, because resuming must not hold it, and a lock that can't be
    /// opened says nothing about a restore. True if it waited.
    private func waitedForARestore() async -> Bool {
        let lock = FileLock(url: restorer.lockURL)
        defer { lock.unlock() }
        guard lock.attemptLock() == .heldByOther else { return false }

        log.append("a restore is running, so this app leaves the displays to it")
        let deadline = clock.now().addingTimeInterval(Self.restoreWaitLimit)
        while lock.attemptLock() == .heldByOther {
            guard clock.now() < deadline else {
                log.append("restore.lock is still held after \(Int(Self.restoreWaitLimit)) seconds, so this app goes on")
                return true
            }
            do {
                try await clock.sleep(seconds: Seconds.poll)
            } catch {
                return true
            }
        }
        log.append("The restore is over, so this app reads the ledger again")
        return true
    }

    /// A failure at any step ends the session. If that fails too, the ledger says `ending`, which the
    /// guardian's frozen-state row can act on.
    private func resumeActive(_ ledger: SafetyLedger) async {
        log.append("Resuming the session for \(ledger.client) at \(ledger.looksLike)")
        power.declareUserActivity()
        let hold = power.holdNoDisplaySleep(reason: Self.resumeHold)
        defer { hold.release() }

        do {
            guard let spec = live?.spec else { return }
            let screen = try await screens.create(spec)
            live?.screen = screen
            try await operations.setMain(screen.displayID)

            let topology = backend.topology()
            let returned = SessionEnforcer.returned(ledger, in: topology)
            try NeverZeroRule.check(
                topology: topology,
                disconnecting: Set(returned.map(\.display.id)),
                inProtectedSession: true
            ).get()

            for id in try await disconnectTogether(returned.map(\.display.id)) {
                try await operations.disconnect(id)
            }
        } catch {
            log.append("The resume failed: \(error.sessionReason)")
            _ = try? await runEndSequence(why: "the resume failed")
            return
        }

        writer.touch()
        live?.phase = .active
        enforcer.sessionBecameActive(at: clock.now())
        log.append("The session is active again on screen \(live?.screen?.displayID ?? 0)")
        onChange()
    }

    /// With no usable ledger: the restorer turns on every display this boot's registry knows and any
    /// other that's listed as off, under `restore.lock`, and it arranges nothing, because only a ledger
    /// says where things went. True if a physical display is online afterward, because the OS fallback
    /// display doesn't count. Only for use inside a turn.
    private func reconnectFromRegistry() async -> Bool {
        let entries = registry.currentBootEntries().filter { $0.kind == .physical }
        let reconnected = await restorer.reconnect(entries)
        log.append(
            reconnected
                ? "The reconnect finished with a physical display online"
                : "The reconnect finished with no physical display online"
        )
        return reconnected
    }

    // MARK: Turns

    /// Runs `work` when every earlier call has finished. It's a task of its own so that a cancelled
    /// caller can't stop it partway. Display sequences have to run to their end. The dispatcher runs its
    /// plain display commands through this too, so a check can't go stale before the change it allows.
    func inTurn<Value: Sendable>(
        first: Bool = false,
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let turn = turn
        return try await Task {
            await turn.begin(first: first)
            defer { turn.end() }
            return try await work()
        }.value
    }

    private static func unique<Element: Hashable>(_ items: [Element]) -> [Element] {
        var seen = Set<Element>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// Lets one async operation run at a time, first come, first served, except that a rescue goes to the
/// front of the line. An actor isn't enough, because it lets another call in at every suspension.
private final class SessionTurn {
    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int {
        waiting.count
    }

    func begin(first: Bool) async {
        guard isTaken else {
            isTaken = true
            return
        }
        await withCheckedContinuation { continuation in
            if first {
                waiting.insert(continuation, at: 0)
            } else {
                waiting.append(continuation)
            }
        }
    }

    /// The turn passes straight to the next in line, and is free only when nobody's waiting.
    func end() {
        guard !waiting.isEmpty else {
            isTaken = false
            return
        }
        waiting.removeFirst().resume()
    }
}
