import ADFoundation
import Darwin
import Foundation

public protocol AppPinging: Sendable {
    func ping() async -> Bool
    func askToEnd(reason: String) async -> Bool
}

public protocol AppLaunching: Sendable {
    func launch()
}

public protocol RestoreSpawning: Sendable {
    /// True if the monitors came back. The child writes `rescued` to the ledger itself.
    func restore() async -> Bool
}

public protocol GuardianNotifying: Sendable {
    /// The monitors may be dark and the user needs to act: three restores failed, the ledger was lost with
    /// no copy, or it couldn't be read for 30 seconds.
    func restoreFailed()
}

/// Gathers what the policy needs on each tick and carries out what it decides. It runs one thing at a
/// time: a tick waits for its ping, request or restore, so two restores can't overlap.
public final class GuardianRunner {
    private static let tickInterval: Double = 0.25
    private static let pingInterval: TimeInterval = 2
    /// Ticks are 0.25 seconds apart, so a gap this long means the Mac slept or the clock was changed.
    private static let longestNormalGap: TimeInterval = 5
    /// Longer than a passing fault. Past this, a fresh process may read what this one can't.
    private static let readFailureLimit: TimeInterval = 30
    private static let logRepeatInterval: TimeInterval = 60
    private static let ownerDiedReason = "owner-died"

    /// A session a successful restore brought back, and the app reference the restore saw.
    private struct RestoredSession {
        var startedAt: Date
        var app: ProcessRef?
    }

    private let store: any LedgerStoring
    private let processes: any ProcessInspecting
    private let pinger: any AppPinging
    private let launcher: any AppLaunching
    private let restorer: any RestoreSpawning
    private let notifier: any GuardianNotifying
    private let alerter: any UserAlerting
    private let clock: any ADClock
    private let bootSession: String
    private let log: @Sendable (String) -> Void
    private let exitProcess: @Sendable () -> Void

    private var memory = GuardianMemory()
    /// `startedAt` of the session on the last tick.
    private var watchedSession: Date?
    private var restoredSession: RestoredSession?
    /// An app sent `SIGKILL` stays dead to the guardian, even if the signal hasn't taken effect.
    private var killedApp: ProcessRef?
    private var lastPing: Date?
    private var lastTickEnd: Date?
    private var hasNotifiedRestoreFailure = false

    /// The last ledger read from the file, kept for when the file can't answer.
    private var lastGoodLedger: SafetyLedger?
    /// The file went unreadable while there was a copy, so a missing file doesn't mean it was cleared.
    private var decidingFromCopy = false
    private var noLedgerRestoreDone = false
    private var hasReadLedger = false
    private var readFailingSince: Date?
    private var hasReportedReadFailure = false

    private var lastLogged: String?
    private var lastLoggedAt: [String: Date] = [:]

    public init(
        ledger: any LedgerStoring,
        processes: any ProcessInspecting,
        pinger: any AppPinging,
        launcher: any AppLaunching,
        restorer: any RestoreSpawning,
        notifier: any GuardianNotifying,
        alerter: any UserAlerting,
        clock: any ADClock,
        bootSession: String,
        log: @escaping @Sendable (String) -> Void,
        exit: @escaping @Sendable () -> Void = { Darwin.exit(1) }
    ) {
        self.exitProcess = exit
        self.store = ledger
        self.processes = processes
        self.pinger = pinger
        self.launcher = launcher
        self.restorer = restorer
        self.notifier = notifier
        self.alerter = alerter
        self.clock = clock
        self.bootSession = bootSession
        self.log = log
    }

    /// Returns when the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            await tick()
            do {
                try await clock.sleep(seconds: Self.tickInterval)
            } catch {
                return
            }
        }
    }

    public func tick() async {
        noticeClockJump()
        defer { lastTickEnd = clock.now() }

        let ledger = recordingRestore(await currentLedger())

        if ledger?.startedAt != watchedSession {
            watchedSession = ledger?.startedAt
            memory.forgetSession()
        }

        let appAlive = ledger?.app.map { $0 != killedApp && processes.isAlive($0) } ?? false
        let deadOwners = ledger?.owners.filter { !processes.isAlive($0) } ?? []
        // Only a live session is pinged, and only its own app. A quit app is none of our business.
        let inSession = ledger.map { $0.state != .rescued } ?? false
        let pingResult = inSession && appAlive ? await pingIfDue() : nil

        let observation = GuardianObservation(
            ledger: ledger,
            currentBoot: bootSession,
            appAlive: appAlive,
            appPingOK: pingResult,
            deadOwners: deadOwners,
            now: clock.now()
        )
        let previousApp = memory.lastApp
        let countedBefore = memory.relaunches
        let decision = GuardianPolicy.decide(observation, memory: &memory)
        noteTakeover(from: previousApp, countedBefore: countedBefore, decision: decision)
        await act(on: decision, ledger: ledger, deadOwners: deadOwners)
    }

    /// The policy counted a new app that the guardian didn't launch. Said here, because no other line
    /// would show that the app died and came back. The line doesn't say why it died, because the ledger
    /// can't tell: a replacement after a deliberate kill (the guardian's own `SIGKILL` of a hung app, the
    /// restore child's, a Restart from the menu, a reinstall) also spends the budget. That errs toward
    /// an earlier restore.
    private func noteTakeover(from previous: ProcessRef?, countedBefore: Int, decision: GuardianDecision) {
        guard decision != .relaunchApp, memory.relaunches > countedBefore,
            let previous, let current = memory.lastApp, current != previous
        else { return }
        let budget =
            memory.relaunches <= GuardianPolicy.maxRelaunches
            ? "counting it as relaunch \(memory.relaunches) of \(GuardianPolicy.maxRelaunches)"
            : "and the relaunches are used up"
        note("app \(current.pid) took over from app \(previous.pid), \(budget)")
    }

    /// The ledger to decide from. A failed read and an unreadable file say nothing about the session,
    /// so neither may look like the session being cleared: decisions carry on from the last good copy.
    private func currentLedger() async -> SafetyLedger? {
        let loaded: SafetyLedger?
        do {
            loaded = try store.load()
        } catch {
            note("cannot read the ledger: \(error)")
            reportIfReadsKeepFailing()
            return lastGoodLedger
        }
        hasReadLedger = true
        readFailingSince = nil
        hasReportedReadFailure = false

        // Taken on every load, but a ledger that reads is the truth: another process can set a bad
        // file aside and write a good one between two ticks.
        let setAside = store.takeSetAsideEvent()
        if loaded == nil, setAside {
            if lastGoodLedger == nil {
                await restoreWithoutLedger()
            } else {
                note("the ledger is unreadable, carrying on from the last good copy")
                decidingFromCopy = true
            }
            return lastGoodLedger
        }

        if loaded == nil, decidingFromCopy { return lastGoodLedger }

        lastGoodLedger = loaded
        decidingFromCopy = false
        noLedgerRestoreDone = false
        return loaded
    }

    /// A process whose reads used to work exits, so that launchd starts a fresh guardian, which may read
    /// what this one can't. One whose reads never worked stays up and keeps trying, because a restart
    /// gains nothing, and exiting would only repeat the notification about every 35 seconds.
    private func reportIfReadsKeepFailing() {
        let now = clock.now()
        let since = readFailingSince ?? now
        readFailingSince = since
        guard now.timeIntervalSince(since) >= Self.readFailureLimit, !hasReportedReadFailure else { return }

        hasReportedReadFailure = true
        let limit = Int(Self.readFailureLimit)
        note("cannot read the ledger for \(limit) s, \(hasReadLedger ? "exiting" : "and never could, still trying")")
        notifier.restoreFailed()
        // Before the exit, which this process doesn't come back from.
        showAlert(.ledgerUnreadable)
        if hasReadLedger { exitProcess() }
    }

    /// An unreadable file, and nothing to say what it held. A session may be live with the monitors
    /// off, so this reconnects what the registry knows, once. The child finds no ledger and does that.
    private func restoreWithoutLedger() async {
        guard !noLedgerRestoreDone else { return }
        noLedgerRestoreDone = true

        note("the ledger is unreadable and there is no copy, reconnecting from the registry")
        let restored = await restorer.restore()
        note(restored ? "the reconnect succeeded" : "the reconnect failed")
        notifier.restoreFailed()
        showAlert(.ledgerUnreadable)
    }

    /// Asked for with every notification, because macOS mutes the banner while the display is shared.
    /// One window at a time: while the last one is up, only the notification posts.
    private func showAlert(_ reason: GuardianAlert.Reason) {
        guard !alerter.isShowingAlert else {
            note("the alert window is still up, so only the notification was posted")
            return
        }
        alerter.showAlert(
            title: GuardianAlert.title,
            message: GuardianAlert.message(for: reason),
            timeoutSeconds: GuardianAlert.timeoutSeconds
        )
    }

    /// The restore child writes `rescued` itself. If its write failed, the ledger would still look
    /// live, and the policy would relaunch the app, which would turn the monitors off again. So the
    /// success is recorded here too, and retried each tick until the disk takes it. A different app in
    /// the ledger means the session resumed after the restore: it's live and has to be watched.
    private func recordingRestore(_ current: SafetyLedger?) -> SafetyLedger? {
        guard var ledger = current, ledger.state != .rescued,
            let restored = restoredSession, ledger.startedAt == restored.startedAt
        else {
            return current
        }
        guard ledger.app == restored.app else {
            note("another app took the session over after the restore, watching it")
            restoredSession = nil
            memory.forgetSession()
            return current
        }

        ledger.state = .rescued
        ledger.updatedAt = clock.now()
        lastGoodLedger = ledger
        do {
            try store.save(ledger)
        } catch {
            note("cannot mark the ledger rescued: \(error)")
        }
        return ledger
    }

    private func noticeClockJump() {
        let now = clock.now()
        guard let lastTickEnd else { return }
        let gap = now.timeIntervalSince(lastTickEnd)
        guard gap < 0 || gap > Self.longestNormalGap else { return }

        memory.restartWaits(at: now)
        lastPing = nil
        readFailingSince = readFailingSince.map { _ in now }
        lastLoggedAt = [:]
        note("the clock jumped by \(Int(gap)) s, restarting the timers")
    }

    private func pingIfDue() async -> Bool? {
        let now = clock.now()
        if let lastPing, now.timeIntervalSince(lastPing) < Self.pingInterval { return nil }
        lastPing = now
        return await pinger.ping()
    }

    private func act(on decision: GuardianDecision, ledger: SafetyLedger?, deadOwners: [ProcessRef]) async {
        if memory.restoreAttempts < GuardianPolicy.maxRestores { hasNotifiedRestoreFailure = false }

        switch decision {
        case .idle:
            note("idle")

        case .waitForApp:
            note(memory.restoreAttempts > 0 ? "waiting to retry the restore" : "waiting for the app")

        case .discardLedger:
            note("discarding a ledger from another boot")
            lastGoodLedger = nil
            decidingFromCopy = false
            do {
                try store.clear()
            } catch {
                note("cannot discard the ledger: \(error)")
            }

        case .relaunchApp:
            // The count keeps a second relaunch inside the log's 60 second limit from being dropped.
            note("the app is not running, relaunching it, \(memory.relaunches) of \(GuardianPolicy.maxRelaunches)")
            launcher.launch()

        case .killApp:
            guard let app = ledger?.app else { return }
            note("app \(app.pid) stopped answering, sending SIGKILL")
            killedApp = app
            processes.kill(app)

        case .askAppToEnd:
            let owners = deadOwners.map { String($0.pid) }.joined(separator: ",")
            note("owner \(owners) died, asking the app to end the session")
            // The answer changes nothing: the ledger shows whether it ended, and the policy's timer
            // covers the case where it doesn't.
            let accepted = await pinger.askToEnd(reason: Self.ownerDiedReason)
            note("the app \(accepted ? "accepted" : "did not accept") the request to end")

        case .restore:
            let attempt = "attempt \(memory.restoreAttempts)"
            note("restoring the monitors, \(attempt)")
            let restored = await restorer.restore()
            // The spacing runs from the end of an attempt, because an attempt can take minutes.
            memory.lastRestoreAt = clock.now()
            if restored {
                restoredSession = ledger.map { RestoredSession(startedAt: $0.startedAt, app: $0.app) }
                note("restore succeeded, \(attempt)")
            } else {
                note("restore failed, \(attempt)")
                if memory.restoreAttempts >= GuardianPolicy.maxRestores, !hasNotifiedRestoreFailure {
                    hasNotifiedRestoreFailure = true
                    let retry = Int(GuardianPolicy.restoreRetryInterval)
                    note("\(GuardianPolicy.maxRestores) restores failed, telling the user and retrying every \(retry) s")
                    notifier.restoreFailed()
                    showAlert(.restoresFailed)
                }
            }
        }
    }

    /// Most ticks have nothing new to say, so a line the same as the last one is dropped, and any
    /// other repeat is limited to once every 60 seconds. Two lines taking turns would otherwise write
    /// four lines a second, maybe on a disk that's already full.
    private func note(_ line: String) {
        guard line != lastLogged else { return }
        let now = clock.now()
        if let last = lastLoggedAt[line], now.timeIntervalSince(last) < Self.logRepeatInterval { return }

        lastLoggedAt = lastLoggedAt.filter { now.timeIntervalSince($0.value) < Self.logRepeatInterval }
        lastLoggedAt[line] = now
        lastLogged = line
        log(line)
    }
}
