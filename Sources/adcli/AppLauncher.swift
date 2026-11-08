import Foundation

struct AppLauncher: CLIAppLaunching {
    struct OpenFailed: Error {}

    static let executable = "/usr/bin/open"
    /// By path, because by bundle ID LaunchServices can pick a stale copy in a `build/` folder or a
    /// worktree.
    static let arguments = ["-g", "-a", "/Applications/PorchLight.app"]
    /// So a hung `open` can't hold up the CLI, the same limit as the guardian's.
    private static let waitLimit = 5.0

    /// Throws only if `open` couldn't run or reported a failure. A slow one may still start the app,
    /// so it's left running, and the runner's wait for readiness decides.
    func launch() throws {
        let outcome = try ChildProcess.run(
            path: Self.executable,
            arguments: Self.arguments,
            limit: Self.waitLimit,
            terminateAtLimit: false
        )
        if outcome == .failed { throw OpenFailed() }
    }
}

enum ChildProcess {
    enum Outcome: Equatable {
        case succeeded
        case failed
        case timedOut
    }

    /// Runs a program and blocks until it exits or `limit` seconds pass. Its streams go nowhere:
    /// stdout and stderr are the CLI's contract with its caller, and a child that kept them open
    /// after the CLI exited would hang a script reading them through `$(...)`.
    ///
    /// With `terminateAtLimit`, a child past the limit gets SIGTERM, then SIGKILL if it's still
    /// there `killGrace` seconds later. Otherwise it's left running.
    static func run(
        path: String,
        arguments: [String],
        limit: Double,
        terminateAtLimit: Bool,
        killGrace: Double = 5
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        guard exited.wait(timeout: .now() + limit) == .success else {
            if terminateAtLimit {
                process.terminate()
                if exited.wait(timeout: .now() + killGrace) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            return .timedOut
        }
        return process.terminationReason == .exit && process.terminationStatus == 0 ? .succeeded : .failed
    }
}
