import ADDisplayConfig
import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import CoreGraphics
import Foundation
import Synchronization

/// `adguardian restore`, the one part of this program that touches a display. The guardian runs it as
/// a child process, and so does the CLI's rescue. SIGTERM keeps its default action here, because the
/// guardian's spawner relies on it to stop a stuck restore.
enum RestoreCommand {
    /// A guardian that dies takes its 180 s limit with it, and launchd's kill doesn't reach this child,
    /// which has its own process group. A display call hung for good would then hold `restore.lock`
    /// forever, and every later restore would fail. This is past the guardian's and the CLI's limits
    /// and their 5 s grace, so while either is alive, it stops the child first.
    private static let ownLimitSeconds: UInt32 = 190

    /// The process's exit status, one of `RestoreHelperExit`'s. Call it on the main thread.
    static func run(_ environment: GuardianEnvironment) -> Int32 {
        // The default action ends the process, which releases the lock. Set explicitly, because a
        // parent that ignored SIGALRM would pass that on.
        signal(SIGALRM, SIG_DFL)
        alarm(ownLimitSeconds)

        let paths = ADPaths()
        let log = GuardianLog(environment: environment, paths: paths)

        let job: @Sendable () async -> RestoreJob.Outcome
        switch environment.restoreMode {
        case .refused(let why):
            GuardianLog.writeToStandardError(why)
            return RestoreHelperExit.failed
        case .live:
            log.write("restore starting")
            job = { await live(paths: paths, log: log) }
        case .dryRun:
            log.write("dry run: restore starting")
            job = { await dryRun(paths: paths, log: log) }
        }
        return finish(runServicingMainRunLoop(job), log: log)
    }

    /// The exit status, with the name of each display not at its recorded mode on stdout, one a line,
    /// for the guardian and the CLI.
    private static func finish(_ outcome: RestoreJob.Outcome, log: GuardianLog) -> Int32 {
        switch outcome {
        case .restored:
            log.write("restore succeeded")
            return RestoreHelperExit.restored
        case .restoredWithoutModes(let records):
            printNames(of: records)
            log.write("restore succeeded, without the recorded mode of \(names(of: records))")
            return RestoreHelperExit.restored
        case .modesNotRestored(let records):
            printNames(of: records)
            log.write(
                "restore put every display back, but not \(names(of: records)) at its recorded mode, "
                    + "so rescued isn't written and a fresh process can try"
            )
            return RestoreHelperExit.modesNotRestored
        case .failed:
            log.write("restore failed")
            return RestoreHelperExit.failed
        }
    }

    private static func printNames(of records: [PhysicalRecord]) {
        let lines = records.map { "\($0.identity.productName ?? "display \($0.id)")\n" }.joined()
        try? FileHandle.standardOutput.write(contentsOf: Data(lines.utf8))
    }

    private static func names(of records: [PhysicalRecord]) -> String {
        records.map(name(of:)).joined(separator: ", ")
    }

    /// CoreGraphics updates this process's copy of the displays, mode lists included, from display
    /// notifications delivered on the main run loop. In the hardware run of 2026-11-07, a restore child
    /// kept a returned monitor as a 1x1 stub with no modes. So CoreGraphics starts here, a callback gives
    /// it a reason to listen for display changes, and the main thread runs its run loop until the job ends.
    private static func runServicingMainRunLoop(
        _ job: @escaping @Sendable () async -> RestoreJob.Outcome
    ) -> RestoreJob.Outcome {
        _ = CGMainDisplayID()
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in }, nil)

        let result = JobResult()
        Task.detached {
            result.set(await job())
            CFRunLoopStop(CFRunLoopGetMain())
        }
        // Something to wait on, without which a run returns at once. Runs are short, so a stop that
        // came before one started is noticed within half a second.
        RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .default)
        while true {
            if let outcome = result.value { return outcome }
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }
    }

    private static func live(paths: ADPaths, log: GuardianLog) async -> RestoreJob.Outcome {
        // A failure here must not stop a rescue. The lock and the ledger create what they need anyway.
        try? paths.ensureStateDirectory()

        return await RestoreJob(
            ledger: log.ledgerStore(at: paths.ledger),
            registryURL: paths.devices,
            backend: LiveDisplayBackend(),
            processes: LiveProcessInspector(),
            clock: SystemClock(),
            power: LivePowerAssertions(),
            lockURL: paths.restoreLock,
            bootSession: BootSession.current(),
            onReport: { write($0, to: log) },
            insistOnRecordedModes: true
        ).runWithOutcome()
    }

    /// Reads the real Mac and changes nothing, wherever the state directory is: no display call that
    /// changes anything, no wake, no signal to the ledger's app, no ledger write, and no holding the
    /// real lock, which would make a real restore wait. The guardian records a child's success in its
    /// own ledger, so a dry-run guardian still sees the session rescued. The copy starts with the
    /// ledger's monitors off, as a crash leaves them, and the plan leaves out the steps that did that.
    private static func dryRun(paths: ADPaths, log: GuardianLog) async -> RestoreJob.Outcome {
        let backend = SimulatedDisplayBackend.seededFromLive()
        let scratch = FileManager.default.temporaryDirectory
            .appending(component: "PorchLight-dry-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = readOnlyLedger(at: paths.ledger)
        let actedOut = DryRunSessionState.actOut(session, on: backend, currentBoot: BootSession.current())
        if actedOut > 0 {
            let monitors = actedOut == 1 ? "monitor" : "monitors"
            log.write("dry run: the copy starts with the session's \(actedOut) \(monitors) off, as after a crash")
        }

        let outcome = await RestoreJob(
            ledger: InMemoryLedgerStore(ledger: session),
            registryURL: paths.devices,
            backend: backend,
            processes: FakeProcessInspector(),
            clock: SystemClock(),
            power: FakePowerAssertions(onDeclare: { backend.wakeAll() }),
            lockURL: scratch.appending(component: "restore.lock", directoryHint: .notDirectory),
            bootSession: BootSession.current(),
            onReport: { write($0, to: log) },
            insistOnRecordedModes: true
        ).runWithOutcome()

        for mutation in backend.mutations.dropFirst(actedOut) {
            log.write("dry run: \(mutation)")
        }
        return outcome
    }

    /// `FileLedgerStore` would rename a bad file aside, so a dry run reads the file itself. A bad file
    /// counts as no ledger, the same as a store's answer.
    private static func readOnlyLedger(at url: URL) -> SafetyLedger? {
        guard let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(SafetyLedger.self, from: data),
            ledger.schemaVersion == SafetyLedger.currentSchemaVersion
        else { return nil }
        return ledger
    }

    private static func write(_ report: RestoreReport, to log: GuardianLog) {
        log.write(
            "restore report: \(report.restored.count) back, \(report.missing.count) missing, "
                + "\(report.stillDark.count) still dark, \(report.attempts) attempts, verified \(report.verified)"
        )
        for record in report.missing {
            log.write("not on the display list, maybe unplugged: \(name(of: record))")
        }
        for record in report.stillDark {
            log.write("still dark: \(name(of: record))")
        }
        for record in report.modeNotOffered {
            log.write("back, but not at its recorded mode: \(name(of: record))")
        }
    }

    private static func name(of record: PhysicalRecord) -> String {
        "\(record.identity.productName ?? "display") (\(record.id))"
    }
}

/// The job's answer, handed from its task to the main thread.
private final class JobResult: Sendable {
    private let stored = Mutex<RestoreJob.Outcome?>(nil)

    var value: RestoreJob.Outcome? {
        stored.withLock { $0 }
    }

    func set(_ outcome: RestoreJob.Outcome) {
        stored.withLock { $0 = outcome }
    }
}
