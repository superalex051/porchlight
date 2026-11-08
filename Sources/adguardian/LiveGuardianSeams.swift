import ADFoundation
import ADIPC
import ADModel
import ADSafety
import Darwin
import Foundation
import Synchronization

/// `guardian.log`. Written directly and not through stderr, because the CLI's rescue also runs
/// `adguardian restore`, and it discards a helper's output. launchd points stdout and stderr at the
/// same file, for whatever the runtime prints in a crash. A test setup writes to stderr instead, so
/// the real log stays real.
struct GuardianLog: Sendable {
    /// Long enough to stop a flood and short enough to show that it's still happening.
    private static let repeatInterval: TimeInterval = 60

    private let file: URL?

    init(environment: GuardianEnvironment, paths: ADPaths) {
        file = environment.isRealRun
            ? paths.logsDirectory.appending(component: "guardian.log", directoryHint: .notDirectory)
            : nil
    }

    /// Creates the logs directory if it has to.
    func write(_ line: String) {
        if let file {
            ADLog.appendLine(line, to: file)
        } else {
            Self.writeToStandardError(line)
        }
    }

    static func writeToStandardError(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(line)\n".utf8))
    }

    func repeatLimited() -> RepeatLimitedLog {
        RepeatLimitedLog(interval: Self.repeatInterval, clock: SystemClock()) { write($0) }
    }

    /// A store logs a line per load while a bad file can't be renamed, and the guardian loads 4 times a
    /// second.
    func ledgerStore(at url: URL) -> FileLedgerStore {
        let limited = repeatLimited()
        return FileLedgerStore(url: url, log: { limited.write($0) })
    }
}

/// Runs `adguardian restore` in a child process, so that a CoreGraphics assertion can't kill the
/// supervisor. The child inherits this environment, so a test setup stays one, and it inherits stderr,
/// so its crash output lands in the log. Its stdout only names displays for the CLI, and the child logs
/// those itself.
///
/// Only exit 0 counts as restored. Exit 3, every display back but one not at its recorded mode, is a
/// failed attempt like any other, so the policy tries again 5 s later with a fresh process.
struct LiveRestoreSpawner: RestoreSpawning {
    /// Longer than the restorer's own worst case, because stopping a working restore is worse than
    /// waiting. A stuck one has to go in the end, or it would hold `restore.lock` for every later one.
    private static let limit = 180.0
    private static let killGrace = 5.0

    let log: GuardianLog

    func restore() async -> Bool {
        guard let path = Self.ownExecutablePath() else {
            log.write("cannot find this program's own path, so the restore can't run")
            return false
        }
        return await withCheckedContinuation { continuation in
            // Its own queue, because the wait blocks a thread for as long as the restore takes.
            DispatchQueue(label: "com.alexluncan.PorchLight.guardian.restore", qos: .userInitiated).async {
                continuation.resume(returning: runChild(at: path))
            }
        }
    }

    private func runChild(at path: String) -> Bool {
        do {
            let completion = try BoundedProcess.runCapturingOutput(
                path: path,
                arguments: ["restore"],
                limit: Self.limit,
                atLimit: .stop(killGrace: Self.killGrace),
                inheritStandardError: true
            )
            if completion.outcome == .timedOut {
                log.write("the restore ran past \(Int(Self.limit)) s and was stopped")
            }
            return completion.status == RestoreHelperExit.restored
        } catch {
            log.write("the restore could not start: \(error)")
            return false
        }
    }

    /// Not `argv[0]`, which is whatever the caller typed.
    static func ownExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

/// Both of these run inside a tick, so a hung program must not hold the guardian up past this.
private let helperWaitLimit = 5.0

struct LiveAppLauncher: AppLaunching {
    let environment: GuardianEnvironment
    let log: GuardianLog

    /// A slow `open` may still start the app, so it's left running, and the policy's timer decides.
    /// By path, because by bundle ID LaunchServices can pick a stale copy in a `build/` folder or a
    /// worktree.
    func launch() {
        // `open` passes no environment, so under a test setup this would start the real app, on the
        // real ledger, with no dry run flag.
        guard environment.isRealRun else {
            log.write("a test setup doesn't start the real app")
            return
        }
        do {
            let outcome = try BoundedProcess.run(
                path: "/usr/bin/open",
                arguments: ["-g", "-a", "/Applications/PorchLight.app"],
                limit: helperWaitLimit,
                atLimit: .leaveRunning
            )
            if outcome != .succeeded { log.write("open did not report success: \(outcome)") }
        } catch {
            log.write("open could not start: \(error)")
        }
    }
}

struct OSAScriptNotifier: GuardianNotifying {
    /// The words are `GuardianAlert`'s, so the notification and the alert window say the same thing.
    private static let script = "display notification \"\(GuardianAlert.notification)\""

    let environment: GuardianEnvironment
    let log: GuardianLog

    /// Waits for `osascript`, because this process may be about to exit, and the wait gives it time to
    /// post. A `Process` child has its own process group, so launchd's group kill wouldn't reach it.
    func restoreFailed() {
        guard environment.isRealRun else {
            log.write("a test setup doesn't post a notification")
            return
        }
        do {
            let outcome = try BoundedProcess.run(
                path: "/usr/bin/osascript",
                arguments: ["-e", Self.script],
                limit: helperWaitLimit,
                atLimit: .leaveRunning
            )
            if outcome != .succeeded { log.write("osascript did not report success: \(outcome)") }
        } catch {
            log.write("osascript could not start: \(error)")
        }
    }
}

/// Runs this program's `alert` subcommand and doesn't wait for it, so no tick waits on a window.
/// `Process` reaps the child when it exits, and until then no second one starts. A `Process` child has
/// its own process group, so a guardian that exits leaves its window up. A test setup shows the window
/// too: it changes nothing, and it's how a dry run checks it.
final class LiveAlertSpawner: UserAlerting {
    private let log: GuardianLog
    private let running = Mutex<Process?>(nil)

    init(log: GuardianLog) {
        self.log = log
    }

    var isShowingAlert: Bool {
        running.withLock { $0 != nil }
    }

    func showAlert(title: String, message: String, timeoutSeconds: Int) {
        guard let path = LiveRestoreSpawner.ownExecutablePath() else {
            log.write("cannot find this program's own path, so the alert window can't show")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = AlertRequest(title: title, message: message, timeoutSeconds: timeoutSeconds).arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // stderr is inherited, so a crash lands in the log.
        process.terminationHandler = { [self] finished in
            running.withLock { if $0 === finished { $0 = nil } }
            if finished.terminationReason != .exit {
                log.write("the alert window was ended by signal \(finished.terminationStatus)")
            } else if finished.terminationStatus != 0 {
                log.write("the alert window exited with status \(finished.terminationStatus)")
            }
        }
        // Held from before the start, so a child that ends at once can't leave it set.
        running.withLock { $0 = process }
        do {
            try process.run()
            log.write("showing the alert window")
        } catch {
            running.withLock { $0 = nil }
            log.write("the alert window could not start: \(error)")
        }
    }
}

final class LiveAppPinger: AppPinging {
    private static let pingTimeout = 1.0
    private static let endTimeout = 10.0
    private static let busyPrefix = "busy"

    private let client: IPCClient
    private let ledgerURL: URL?
    private let clock = SystemClock()
    private let busyLimit = Mutex(BusyPingLimit())

    /// `ledgerURL` tells this which app process is answering, because each one gets its own time to be
    /// busy. Without it, this is a one-off check that something answers.
    init(client: IPCClient, ledgerURL: URL? = nil) {
        self.client = client
        self.ledgerURL = ledgerURL
    }

    /// Not throwing means the app answered. One that's still starting replies `ok: false` and busy, and
    /// taking that for no answer would risk the 15 second kill, but only for so long: a resume that hangs
    /// answers busy for good.
    func ping() async -> Bool {
        let result: CommandResult
        do {
            result = try await client.send(CommandRequest(operations: ["ping"]), timeout: Self.pingTimeout)
        } catch {
            return false
        }
        guard !result.ok, result.reason?.hasPrefix(Self.busyPrefix) == true else {
            busyLimit.withLock { $0.noteAnswered() }
            return true
        }
        let app = ledgerApp()
        let now = clock.now()
        return busyLimit.withLock { $0.noteBusy(from: app, at: now) }
    }

    /// Read here and not through `FileLedgerStore`, which would move a bad file aside and take that news
    /// from the runner. A file that can't be read just means not knowing, for this one ping.
    private func ledgerApp() -> ProcessRef? {
        guard let ledgerURL, let data = try? Data(contentsOf: ledgerURL) else { return nil }
        return (try? JSONDecoder().decode(SafetyLedger.self, from: data))?.app
    }

    func askToEnd(reason: String) async -> Bool {
        let request = CommandRequest(
            operations: ["session", "end"],
            parameters: [CommandParameter(name: "force"), CommandParameter(name: "reason", value: reason)]
        )
        do {
            return try await client.send(request, timeout: Self.endTimeout).ok
        } catch {
            return false
        }
    }
}
