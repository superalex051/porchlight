import ADFoundation
import ADIPC
import ADModel
import ADSafety
import Foundation

// Wiring only. This file and the seams name no display module, so the watching path can't reach
// CoreGraphics. Everything that touches a display is in `RestoreCommand.swift`.

/// Stays in `runner.run()` for as long as launchd keeps this process alive.
func watch(_ environment: GuardianEnvironment) async -> Never {
    if let refusal = environment.watchRefusal {
        GuardianLog.writeToStandardError(refusal)
        exit(1)
    }

    let paths = ADPaths()
    let log = GuardianLog(environment: environment, paths: paths)
    // In a real run this also creates the logs directory, if launchd somehow started this without it.
    log.write("starting")

    let server = IPCServer(path: paths.guardianSocketPath) { request in
        request.operations == ["ping"] ? .success("pong") : .failure("unknown command")
    }
    let limitedLog = log.repeatLimited()
    let socket = GuardianSocketKeeper(
        start: {
            try paths.ensureStateDirectory()
            try server.start()
            // The server answers busy until this, and a session refuses to start without an answer.
            server.setReady(true)
        },
        // Any answer on this socket is a guardian, because one that's still starting answers busy.
        anotherGuardianAnswers: { await LiveAppPinger(client: IPCClient(path: paths.guardianSocketPath)).ping() },
        clock: SystemClock(),
        log: { limitedLog.write($0) },
        exit: { exit(1) }
    )
    // Waited for, so that two guardians never both start watching.
    if await socket.attempt() == .failed {
        Task { await socket.keepTrying() }
    }

    let runner = GuardianRunner(
        ledger: log.ledgerStore(at: paths.ledger),
        processes: LiveProcessInspector(),
        pinger: LiveAppPinger(client: IPCClient(path: paths.socketPath), ledgerURL: paths.ledger),
        launcher: LiveAppLauncher(environment: environment, log: log),
        restorer: LiveRestoreSpawner(log: log),
        notifier: OSAScriptNotifier(environment: environment, log: log),
        alerter: LiveAlertSpawner(log: log),
        clock: SystemClock(),
        bootSession: BootSession.current(),
        log: { log.write($0) },
        exit: { exit(1) }
    )
    await runner.run()
    server.stop()
    exit(0)
}

let environment = GuardianEnvironment(ProcessInfo.processInfo.environment)
switch Array(CommandLine.arguments.dropFirst()) {
case []:
    await watch(environment)
case ["restore"]:
    // Not awaited: it runs the main thread's run loop itself, until the restore ends.
    exit(RestoreCommand.run(environment))
case let arguments where arguments.first == AlertRequest.subcommand:
    // Not awaited: AppKit runs the main thread's run loop until the window closes.
    exit(AlertCommand.run(arguments))
default:
    GuardianLog.writeToStandardError("usage: porchlight-guardian [restore]")
    exit(2)
}
