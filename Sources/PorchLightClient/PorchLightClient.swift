import ADFoundation
import ADIPC
import ADModel
import Foundation

public enum PorchLightClientError: Error, Equatable, Sendable {
    /// Porch Light isn't running, and this call doesn't start it, or starting it didn't work.
    case appNotRunning
    /// No answer in time. A start or end Porch Light already began carries on, so ask for the status.
    case timedOut
    /// Porch Light refused or failed, with its reason, such as `session held by parsec`.
    case failed(String)
    /// The answer isn't API version 1's, such as one from a newer Porch Light.
    case unsupportedReply(String)
}

/// Starts and ends Porch Light sessions, and follows them, over the app's control socket. The contract
/// is `docs/session-api.md`. Every call is safe from any task.
public struct PorchLightClient: Sendable {
    /// The session API version this library speaks. It refuses answers of any other.
    public static let apiVersion = 1

    static let appPath = "/Applications/PorchLight.app"
    private static let sessionTimeout = 60.0
    private static let statusTimeout = 15.0
    private static let openLimit = 5.0
    private static let minimumTimeout = 0.01
    private static let testOverrides = ["AD_SOCKET_PATH", "AD_STATE_DIR", "AD_DRY_RUN"]

    private let ipc: IPCClient
    private let launch: (@Sendable () async throws -> Void)?

    /// With no `socketPath`, Porch Light's own socket. `start` and `end` start the app if it isn't
    /// running, as the CLI does, unless `launchesApp` is false, a `socketPath` is given, or this process
    /// runs under a test override (`AD_SOCKET_PATH`, `AD_STATE_DIR` or `AD_DRY_RUN`).
    public init(socketPath: String? = nil, launchesApp: Bool = true) {
        let environment = ProcessInfo.processInfo.environment
        let allowed = launchesApp && Self.launchIsAllowed(socketPath: socketPath, environment: environment)
        self.init(
            socketPath: socketPath ?? ADPaths(environment: environment).socketPath,
            launch: allowed ? Self.openApp : nil
        )
    }

    init(socketPath: String, launch: (@Sendable () async throws -> Void)?) {
        ipc = IPCClient(path: socketPath)
        self.launch = launch
    }

    /// Whether `start` and `end` may start the app.
    var launches: Bool {
        launch != nil
    }

    /// A launch by `open` would start the real app with none of this process's environment, so a test
    /// setup, or any socket but the real one, must never launch.
    static func launchIsAllowed(socketPath: String?, environment: [String: String]) -> Bool {
        socketPath == nil && !testOverrides.contains { environment[$0]?.isEmpty == false }
    }

    // MARK: Calls

    /// Starts a session, or from the client that holds one, adds the owners and keeps its size. Returns
    /// once the screen is up and main and the monitors are off, with the screen's `displayID` to capture.
    /// By default the calling process owns the session, so it ends if this process exits.
    public func start(
        client: String,
        looksLike: PorchLightSize,
        hiDPI: Bool = true,
        hz: Int = 60,
        ownerPIDs: [Int32] = [ProcessInfo.processInfo.processIdentifier]
    ) async throws(PorchLightClientError) -> PorchLightStatus {
        let request = CommandRequest(
            operations: ["session", "start"],
            parameters: [
                CommandParameter(name: "client", value: client),
                CommandParameter(name: "lookslike", value: "\(looksLike.width)x\(looksLike.height)"),
                CommandParameter(name: "hiDPI", value: hiDPI ? "on" : "off"),
                CommandParameter(name: "hz", value: String(hz)),
            ] + ownerPIDs.map { CommandParameter(name: "ownerpid", value: String($0)) }
        )
        return try Self.status(from: await run(request, timeout: Self.sessionTimeout, launching: true))
    }

    /// Ends `client`'s session and brings the monitors back. With no session it does nothing and
    /// succeeds. Returns the status after the end, normally idle.
    public func end(client: String) async throws(PorchLightClientError) -> PorchLightStatus {
        let request = CommandRequest(
            operations: ["session", "end"],
            parameters: [CommandParameter(name: "client", value: client)]
        )
        return try Self.status(from: await run(request, timeout: Self.sessionTimeout, launching: true))
    }

    /// The status now. Never starts the app.
    public func status() async throws(PorchLightClientError) -> PorchLightStatus {
        let request = CommandRequest(operations: ["session", "status"])
        return try Self.status(from: await run(request, timeout: Self.statusTimeout, launching: false))
    }

    /// The status now, then the status after each change, the same as `porchlight session watch`. The
    /// stream finishes when the app goes away, and right away if it isn't running, which this never
    /// starts. Stop reading and it stops within one long poll.
    public func changes() -> AsyncStream<PorchLightStatus> {
        let ipc = ipc
        return AsyncStream { continuation in
            let task = Task {
                var watch = SessionWatch()
                _ = await watch.follow(send: { try await ipc.send($0, timeout: $1) }) { shown in
                    continuation.yield(try PorchLightStatus(json: shown.json ?? .null))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Sending

    /// The timeout covers the whole call, including a launch. Only a call that found no app at all is
    /// sent again after the launch, because nothing was sent the first time.
    private func run(
        _ request: CommandRequest,
        timeout: Double,
        launching: Bool
    ) async throws(PorchLightClientError) -> CommandResult {
        let deadline = Self.now() + timeout
        func remaining() -> Double { max(deadline - Self.now(), Self.minimumTimeout) }
        do {
            do {
                return try await answer(request, timeout: remaining())
            } catch IPCError.notRunning {
                guard launching, let launch else { throw IPCError.notRunning }
                do {
                    try await launch()
                } catch {
                    throw IPCError.notRunning
                }
                let ping = try await ipc.sendWaitingForReady(CommandRequest(operations: ["ping"]), timeout: remaining())
                guard ping.ok else { throw IPCError.notRunning }
                return try await answer(request, timeout: remaining())
            }
        } catch let error as IPCError {
            switch error {
            case .notRunning: throw .appNotRunning
            case .timedOut: throw .timedOut
            case .protocolError(let reason): throw .failed(reason)
            }
        } catch {
            throw .failed(String(describing: error))
        }
    }

    /// A busy app (starting up) didn't run the request, so it's worth waiting for.
    private func answer(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        let deadline = Self.now() + timeout
        let result = try await ipc.send(request, timeout: timeout)
        guard !result.ok, result.reason == IPCClient.busyReason else { return result }
        return try await ipc.sendWaitingForReady(request, timeout: max(deadline - Self.now(), Self.minimumTimeout))
    }

    private static func status(from result: CommandResult) throws(PorchLightClientError) -> PorchLightStatus {
        guard result.ok else { throw .failed(result.reason ?? "Porch Light refused without a reason") }
        guard let json = result.json else { throw .unsupportedReply("the answer has no status") }
        return try PorchLightStatus(json: json)
    }

    /// The same launch as the CLI's: by path, in the background. A slow `open` may still start the app,
    /// so only a failure it reports throws, and the wait for the app to be ready decides.
    @Sendable private static func openApp() async throws {
        struct OpenFailed: Error {}
        let succeeded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-g", "-a", appPath]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                guard exited.wait(timeout: .now() + openLimit) == .success else {
                    continuation.resume(returning: true)
                    return
                }
                continuation.resume(returning: process.terminationReason == .exit && process.terminationStatus == 0)
            }
        }
        if !succeeded { throw OpenFailed() }
    }

    /// Doesn't jump when the wall clock is set.
    private static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
