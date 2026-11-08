import ADCommand
import ADIPC
import ADModel
import Foundation

protocol CLITransport: Sendable {
    /// Throws `IPCError.notRunning` only if nothing was sent, so sending again after a launch is safe.
    func send(_ request: CommandRequest, timeout: Double) async throws -> CommandResult
    /// One attempt, which doesn't wait out a busy app: that comes back as `IPCClient.busyReason`.
    func sendOnce(_ request: CommandRequest, timeout: Double) async throws -> CommandResult
    /// True if the app is ready and answers within the timeout.
    func ping(timeout: Double) async -> Bool
}

extension CLITransport {
    func sendOnce(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        try await send(request, timeout: timeout)
    }
}

protocol CLIAppLaunching: Sendable {
    func launch() throws
}

protocol RescueRunning: Sendable {
    /// Why the helper can't run at all, naming where it should be. Nil if it's there.
    var helperProblem: String? { get }
    func runRestoreHelper() async -> HelperOutcome
}

/// One command line, start to finish. `main` writes the output and exits with its code.
struct CLIRunner {
    private static let defaultTimeout = 15.0
    private static let sessionTimeout = 60.0
    private static let minimumTimeout = 0.01
    private static let rescuePingTimeout = 1.0
    private static let rescueTimeout = 60.0

    private static let appNotRunning = "app not running"
    private static let sessionTimedOut = "timed out; the session change may still complete, check session status"

    private static let helperRefused = "refusing the restore helper under test overrides without AD_DRY_RUN=1"

    private let transport: CLITransport
    private let launcher: CLIAppLaunching
    private let rescue: RescueRunning
    /// `open` passes no environment, so under a test setup a launch would start the real app with
    /// no dry run flag, on the real ledger.
    private let environmentAllowsLaunch: Bool
    /// The helper inherits this environment, and only `AD_DRY_RUN=1` keeps it off the real displays.
    /// Under a test setup without that, it would restore for real, killing a live app first.
    private let environmentAllowsHelper: Bool
    /// Where `session watch` prints each line as it comes. Everything else is in the returned output.
    private let write: @Sendable (String) -> Void

    init(
        transport: CLITransport,
        launcher: CLIAppLaunching,
        rescue: RescueRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        write: @escaping @Sendable (String) -> Void = { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) }
    ) {
        self.transport = transport
        self.launcher = launcher
        self.rescue = rescue
        self.write = write
        // An empty variable counts as unset, the same as in `ADPaths`.
        func isSet(_ name: String) -> Bool { environment[name]?.isEmpty == false }
        let overridden = isSet("AD_SOCKET_PATH") || isSet("AD_STATE_DIR")
        environmentAllowsLaunch = !overridden && !isSet("AD_DRY_RUN")
        environmentAllowsHelper = !overridden || environment["AD_DRY_RUN"] == "1"
    }

    func run(_ argv: [String]) async -> RenderedOutput {
        let request: CommandRequest
        let options: CLIOptions
        do {
            (request, options) = try CommandParser.parse(argv)
        } catch let error as CommandParseError {
            return OutputFormatter.render(.failure(error.reason), options: error.options)
        } catch {
            return OutputFormatter.render(.failure(String(describing: error)), options: CLIOptions())
        }

        let result: CommandResult
        switch request.operations.first {
        case _ where CommandHelp.isRequested(request):
            // Answered here, so asking for help never starts the app, or runs `rescue --help`.
            result = .success(CommandHelp.text)
        case nil:
            // Checked here so that a bare `porchlight` doesn't start the app just to refuse.
            result = .failure("no operation given; run porchlight help")
        case "rescue":
            result = await runRescue(request)
        case "session" where request.operations == ["session", "watch"]:
            return await runWatch(request, options: options)
        default:
            result = await runCommand(request, options: options)
        }
        return OutputFormatter.render(result, options: options)
    }

    /// Prints the status, then a line for each change, until the app goes away, which exits 0. The first
    /// answer comes the usual way, so it can start the app. Later ones are single attempts, so a quitting
    /// app ends the watch as soon as its socket is gone, not at the end of a wait for it to be ready.
    private func runWatch(_ request: CommandRequest, options: CLIOptions) async -> RenderedOutput {
        if let parameter = request.parameters.first {
            return OutputFormatter.render(.failure("unknown parameter: \(parameter.name)"), options: options)
        }
        let show: (CommandResult) -> Void = { write(OutputFormatter.render($0, options: options).stdout) }

        var watch = SessionWatch()
        do {
            if let status = try watch.take(await runCommand(watch.request, options: options)) { show(status) }
        } catch {
            return OutputFormatter.render(.failure(error.reason), options: options)
        }
        let ending = await watch.follow(send: { try await transport.sendOnce($0, timeout: $1) }) { show($0) }
        guard case .failed(let reason) = ending else { return RenderedOutput(stdout: "", stderr: "", exitCode: 0) }
        return OutputFormatter.render(.failure(reason), options: options)
    }

    /// The timeout covers the whole command, including any launch.
    private func runCommand(_ request: CommandRequest, options: CLIOptions) async -> CommandResult {
        let timeout = max(
            options.timeout ?? (request.operations.first == "session" ? Self.sessionTimeout : Self.defaultTimeout),
            Self.minimumTimeout
        )
        let deadline = monotonicSeconds() + timeout
        func remaining() -> Double {
            max(deadline - monotonicSeconds(), Self.minimumTimeout)
        }

        do {
            return try await transport.send(request, timeout: timeout)
        } catch IPCError.notRunning {
            // Starting the app only to stop it would do nothing useful.
            guard !options.noLaunch, environmentAllowsLaunch, request.operations.first != "quit" else {
                return .failure(Self.appNotRunning)
            }
        } catch {
            return .failure(reason(for: error, in: request))
        }

        do {
            try launcher.launch()
        } catch {
            return .failure(Self.appNotRunning)
        }
        guard await transport.ping(timeout: remaining()) else { return .failure(Self.appNotRunning) }
        do {
            return try await transport.send(request, timeout: remaining())
        } catch {
            return .failure(reason(for: error, in: request))
        }
    }

    /// Never launches the app, because a restore must not race a fresh one. `--timeout` doesn't apply:
    /// a short one would turn a force-end that's still working into a helper run, which kills the app.
    private func runRescue(_ request: CommandRequest) async -> CommandResult {
        let appAnswered = await transport.ping(timeout: Self.rescuePingTimeout)
        var appResult = CommandResult.failure(Self.appNotRunning)
        if appAnswered {
            do {
                appResult = try await transport.send(request, timeout: Self.rescueTimeout)
            } catch {
                appResult = .failure(reason(for: error, in: request))
            }
            if appResult.ok { return appResult }
        }

        guard environmentAllowsHelper else { return .failure(Self.helperRefused) }

        let problem = appResult.reason ?? "no reason given"
        if let helperProblem = rescue.helperProblem {
            return .failure("\(problem), and \(helperProblem)")
        }
        guard case .restored(let notAtRecordedMode) = await rescue.runRestoreHelper() else {
            return .failure("\(problem), and the restore helper failed")
        }
        let warnings = (appAnswered ? ["the app failed (\(problem)), so the restore helper ran"] : [])
            + notAtRecordedMode.map { "\($0) came back but not at its recorded mode" }
        return .success(warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }

    private func reason(for error: any Error, in request: CommandRequest) -> String {
        switch error as? IPCError {
        case .notRunning:
            Self.appNotRunning
        case .timedOut:
            // The server still runs a request whose client gave up.
            request.operations.first == "session" ? Self.sessionTimedOut : "timed out"
        case .protocolError(let reason):
            reason
        case nil:
            String(describing: error)
        }
    }
}

/// The app's control socket.
struct IPCTransport: CLITransport {
    /// What `IPCClient.send` answers for a server that hasn't started taking requests. It didn't run the request.
    private static let busyStarting = "busy: starting"
    private static let pingRequest = CommandRequest(operations: ["ping"])

    let client: IPCClient

    /// One plain attempt first, because `sendWaitingForReady` would wait out the whole timeout on a
    /// missing socket, and the runner wants to launch right away. Only a starting server is worth waiting for.
    func send(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        let deadline = monotonicSeconds() + timeout
        let result = try await client.send(request, timeout: timeout)
        guard result.reason == Self.busyStarting else { return result }
        return try await client.sendWaitingForReady(request, timeout: deadline - monotonicSeconds())
    }

    func sendOnce(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        try await client.send(request, timeout: timeout)
    }

    func ping(timeout: Double) async -> Bool {
        let result = try? await client.sendWaitingForReady(Self.pingRequest, timeout: timeout)
        return result?.ok == true
    }
}

/// Doesn't jump when the wall clock is set.
private func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
}
