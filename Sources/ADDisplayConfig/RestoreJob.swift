import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Synchronization

/// What `adguardian restore` runs: stop the app, bring the monitors back, and say so in the ledger.
public struct RestoreJob: Sendable {
    /// How a run ended.
    public enum Outcome: Sendable, Equatable {
        /// `rescued` is written, and every display that came back is at its recorded mode.
        case restored
        /// `rescued` is written, but these came back without their recorded mode.
        case restoredWithoutModes([PhysicalRecord])
        /// The arrangement verified, but these aren't at their recorded mode, so `rescued` isn't
        /// written. Only with `insistOnRecordedModes`.
        case modesNotRestored([PhysicalRecord])
        case failed

        public var wroteRescued: Bool {
            switch self {
            case .restored, .restoredWithoutModes: true
            case .modesNotRestored, .failed: false
            }
        }
    }

    private enum Seconds {
        /// The same as the restorer's own wait, which this one replaces.
        static let lockLimit = 60.0
        static let lockPoll = 0.1
        /// MenuBarAgent relaunches a killed app within 20 to 50 ms, and the new app reads the ledger
        /// about 0.2 to 0.3 seconds after that, so this covers a few rounds of kill and relaunch.
        static let watchFor = 1.5
        static let watchPoll = 0.1
    }

    /// Each kill can bring another relaunch, so this many and no more.
    static let resumerKillLimit = 3

    private static let log = ADLog.logger("restorer")

    private let ledger: any LedgerStoring
    private let registryURL: URL
    private let backend: any DisplayBackend
    private let processes: any ProcessInspecting
    private let clock: any ADClock
    private let power: any PowerAsserting
    private let lockURL: URL
    private let bootSession: String
    private let onReport: @Sendable (RestoreReport) -> Void
    private let insistOnRecordedModes: Bool

    /// The registry comes as a URL, because a `DeviceRegistry` caches its file when it's made, and
    /// this has to see what's on disk when it runs. `onReport` gets the restorer's report, for the log.
    /// A reconnect has no report, because it only says whether a monitor is on.
    ///
    /// `adguardian restore` sets `insistOnRecordedModes`. A process that started while a monitor was off
    /// may never see that monitor's modes, as the hardware run of 2026-11-07 found, and a fresh process
    /// can. So the first run that verifies with a mode not offered leaves `rescued` unwritten for the
    /// next child, and marks the ledger. A run that finds the mark and the mode missing again takes the
    /// mode to be gone, so the guardian doesn't retry forever.
    public init(
        ledger: any LedgerStoring,
        registryURL: URL,
        backend: any DisplayBackend,
        processes: any ProcessInspecting,
        clock: any ADClock,
        power: any PowerAsserting,
        lockURL: URL,
        bootSession: String,
        onReport: @escaping @Sendable (RestoreReport) -> Void = { _ in },
        insistOnRecordedModes: Bool = false
    ) {
        self.ledger = ledger
        self.registryURL = registryURL
        self.backend = backend
        self.processes = processes
        self.clock = clock
        self.power = power
        self.lockURL = lockURL
        self.bootSession = bootSession
        self.onReport = onReport
        self.insistOnRecordedModes = insistOnRecordedModes
    }

    /// True only if a physical display is online afterward, because the OS fallback display doesn't
    /// count, and only then is `rescued` written, because that stops the guardian trying. With recorded
    /// displays, the arrangement has to be verified too. The app is killed first so that it can't turn
    /// the monitors back off.
    ///
    /// Before that, the ledger is written as `ending`. Killing the app can get it relaunched, and with
    /// the ledger still `active`, that app would resume the session and turn the monitors off again.
    /// Now it finishes the end instead, even if this restore fails. A failed write only gets logged,
    /// because restoring comes first.
    ///
    /// The whole run holds `restore.lock`, taken before the ledger is read, so an app launched meanwhile
    /// sees a restore running and leaves the displays to it. An app that read `active` before the lock
    /// was taken can still resume, so after the kill this watches the ledger for one (`stopResumers`).
    ///
    /// A ledger that recorded nothing is from a session that kept every monitor on, and restoring nothing
    /// would say nothing about them. One may have been turned off by hand since, so this reconnects from
    /// the registry, the same as with no usable ledger.
    ///
    /// True exactly when `rescued` is written, so false for `.modesNotRestored` too.
    @concurrent public func run() async -> Bool {
        await runWithOutcome().wroteRescued
    }

    @concurrent public func runWithOutcome() async -> Outcome {
        let lockWaitStarted = clock.now()
        let lock = FileLock(url: lockURL)
        defer { lock.unlock() }
        guard await takeLock(lock) else {
            Self.log.error("Another restore held the lock for too long, so this one gave up")
            return .failed
        }

        guard let session = usableLedger() else {
            return await reconnectFromRegistry(restorer(since: lockWaitStarted)) ? .restored : .failed
        }

        let marker = LedgerMarker(store: ledger, clock: clock, session: session)
        let replaced = marker.markEnding()

        if let app = session.app, processes.isAlive(app) {
            Self.log.notice("Killing app process \(app.pid) before the restore")
            processes.kill(app)
        }
        await stopResumers(of: session, firstSeen: replaced, marker: marker)

        let outcome: Outcome
        if session.physical.isEmpty {
            let restorer = restorer(since: lockWaitStarted, onProgress: { marker.beat() })
            outcome = await reconnectFromRegistry(restorer) ? .restored : .failed
        } else {
            let report = await restorer(since: lockWaitStarted, onProgress: { marker.beat() }).restore(session.physical)
            onReport(report)
            let succeeded = report.verified && report.anyReturned
                && backend.topology().online.contains { $0.kind == .physical }
            outcome = succeeded ? judge(report.modeNotOffered, missedBefore: session.restoreMissedModes == true) : .failed
        }
        marker.finish(outcome)
        return outcome
    }

    private func judge(_ notAtRecordedMode: [PhysicalRecord], missedBefore: Bool) -> Outcome {
        guard !notAtRecordedMode.isEmpty else { return .restored }
        guard insistOnRecordedModes else { return .restoredWithoutModes(notAtRecordedMode) }
        guard missedBefore else { return .modesNotRestored(notAtRecordedMode) }
        Self.log.notice("A second fresh process found a recorded mode missing too, so it's taken to be gone")
        return .restoredWithoutModes(notAtRecordedMode)
    }

    private func reconnectFromRegistry(_ restorer: PhysicalRestorer) async -> Bool {
        let entries = DeviceRegistry(url: registryURL, bootSession: bootSession).currentBootEntries()
        return await restorer.reconnect(entries.filter { $0.kind == .physical })
    }

    // MARK: The lock and the relaunched app

    /// Polls, because a blocking `flock` would hold a thread for as long as the other holder takes. A
    /// lock that can't be created at all says nothing about anyone else restoring, and dark monitors are
    /// worse than two restorers, so that goes ahead without it, as the restorer does. False if another
    /// holder kept it for the whole limit, or if the task was cancelled.
    ///
    /// The holder can be the app, stuck in its own restore with the lock taken, and only killing it
    /// frees the lock. So a busy lock gets the `ending` write and the kill the run starts with, from the
    /// ledger read without the lock, and then the wait. The run does both again under the lock, where
    /// they change nothing unless a relaunched app came in between.
    private func takeLock(_ lock: FileLock) async -> Bool {
        let deadline = clock.now().addingTimeInterval(Seconds.lockLimit)
        var hasStoppedTheApp = false
        while true {
            switch lock.attemptLock() {
            case .acquired:
                return true
            case .failed:
                Self.log.error("The restore lock can't be taken, so this restore runs without it")
                return true
            case .heldByOther:
                if !hasStoppedTheApp {
                    hasStoppedTheApp = true
                    stopTheAppBeforeWaiting()
                }
                guard clock.now() < deadline else { return false }
                do {
                    try await clock.sleep(seconds: Seconds.lockPoll)
                } catch {
                    return false
                }
            }
        }
    }

    private func stopTheAppBeforeWaiting() {
        guard let found = try? ledger.load(), !GuardianPolicy.isFromAnotherBoot(found, currentBoot: bootSession) else {
            return
        }
        LedgerMarker(store: ledger, clock: clock, session: found).markEnding()
        if let app = found.app, processes.isAlive(app) {
            Self.log.notice("The restore lock is busy and app process \(app.pid) may hold it, so it's killed before the wait")
            processes.kill(app)
        }
    }

    /// MenuBarAgent relaunches a killed app within 20 to 50 ms. One that read `active` before the
    /// `ending` write landed resumes the session, and turns the monitors off while this turns them on.
    /// So for a short while this reads the ledger, starting with what the `ending` write found. A live
    /// app named in this session's ledger, other than `session.app` and any already killed, is resuming
    /// if the ledger reads `active`: it gets `ending` written again, so that its own relaunch finishes
    /// the end, and it's killed. An app that reads `ending` is finishing the end, which helps, so it's
    /// left alone.
    private func stopResumers(of session: SafetyLedger, firstSeen: SafetyLedger?, marker: LedgerMarker) async {
        var killed = Set([session.app].compactMap { $0 })
        var kills = 0
        var seen = firstSeen
        let deadline = clock.now().addingTimeInterval(Seconds.watchFor)
        while true {
            if let seen, seen.startedAt == session.startedAt, seen.state == .active,
                let app = seen.app, !killed.contains(app), processes.isAlive(app)
            {
                guard kills < Self.resumerKillLimit else {
                    Self.log.error("App process \(app.pid) resumed the session after \(kills) kills, so the restore goes on and leaves it")
                    return
                }
                kills += 1
                killed.insert(app)
                marker.markEnding()
                Self.log.notice("App process \(app.pid) resumed the session during the restore, so ending is written again and it's killed, \(kills) of \(Self.resumerKillLimit)")
                processes.kill(app)
            }
            guard clock.now() < deadline else { return }
            do {
                try await clock.sleep(seconds: Seconds.watchPoll)
            } catch {
                return
            }
            seen = try? ledger.load()
        }
    }

    /// A ledger that can't be read, or one from another boot whose IDs mean nothing now, is no use.
    /// An unknown boot isn't another boot, by the same rule the guardian goes by.
    private func usableLedger() -> SafetyLedger? {
        let found: SafetyLedger?
        do {
            found = try ledger.load()
        } catch {
            Self.log.error("The ledger can't be read, so this reconnects from the registry: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let found, !GuardianPolicy.isFromAnotherBoot(found, currentBoot: bootSession) else { return nil }
        return found
    }

    /// Works under the job's hold on `restore.lock`, so it doesn't take the lock again.
    private func restorer(since lockWaitStarted: Date, onProgress: @escaping @Sendable () -> Void = {}) -> PhysicalRestorer {
        PhysicalRestorer(
            backend: backend,
            clock: clock,
            power: power,
            lockURL: lockURL,
            lockHeldByCallerSince: lockWaitStarted,
            onProgress: onProgress
        )
    }
}

/// The job's writes to the ledger. Each reads the file first, and leaves it alone if it no longer
/// describes the session this job saw, going by `startedAt` alone: a session started since stays live
/// and watched. A relaunched app that named itself in is still this session, and the restore wins it.
private final class LedgerMarker: Sendable {
    private struct State {
        var isFinished = false
        var hasLoggedFailure = false
    }

    private static let log = ADLog.logger("restorer")

    private let store: any LedgerStoring
    private let clock: any ADClock
    private let session: SafetyLedger
    /// `beat` can come from a timer thread, and one of its writes must not land after `finish`.
    private let state = Mutex(State())

    init(store: any LedgerStoring, clock: any ADClock, session: SafetyLedger) {
        self.store = store
        self.clock = clock
        self.session = session
    }

    /// Keeps a `rescued` ledger as it is: the guardian leaves that one alone, and `ending` would have it
    /// relaunch the app. Returns this session's ledger as it read just before the write, even if the
    /// write failed, so the caller can see which app it went over.
    @discardableResult
    func markEnding() -> SafetyLedger? {
        state.withLock { _ in
            var found: SafetyLedger?
            do {
                try update { ledger in
                    found = ledger
                    if ledger.state != .rescued { ledger.state = .ending }
                }
            } catch {
                Self.log.error("Writing ending to the ledger failed, so the restore goes on without it: \(error.localizedDescription, privacy: .public)")
            }
            return found
        }
    }

    /// Moves `updatedAt`, so a watcher can see the restore is alive. A failure here doesn't touch the
    /// restore, so it's logged once and the next beat tries again.
    func beat() {
        state.withLock { state in
            guard !state.isFinished else { return }
            do {
                try update { _ in }
            } catch {
                guard !state.hasLoggedFailure else { return }
                state.hasLoggedFailure = true
                Self.log.error("Writing the ledger's heartbeat failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends the heartbeat, and writes what the outcome calls for: `rescued`, or the mark that a mode was
    /// missing. A failure leaves any earlier mark, because it says nothing about the modes. A failed
    /// write doesn't change the answer: the guardian handles a ledger that still looks live.
    func finish(_ outcome: RestoreJob.Outcome) {
        state.withLock { state in
            state.isFinished = true
            do {
                switch outcome {
                case .restored, .restoredWithoutModes:
                    try update { $0.state = .rescued }
                case .modesNotRestored:
                    try update { $0.restoreMissedModes = true }
                case .failed:
                    return
                }
            } catch {
                Self.log.error("Writing the restore's end to the ledger failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func update(_ change: (inout SafetyLedger) -> Void) throws {
        guard var current = try store.load(), current.startedAt == session.startedAt else { return }
        change(&current)
        current.updatedAt = clock.now()
        try store.save(current)
    }
}
