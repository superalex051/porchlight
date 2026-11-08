import ADModel
import Darwin
import Foundation

/// Sends one request per connection. Each call does its socket work on its own dispatch queue,
/// so a slow server can't tie up a thread in the cooperative pool.
public struct IPCClient: Sendable {
    /// The reason `send` gives for a server that isn't taking requests yet, or any more. It didn't
    /// run the request.
    public static let busyReason = "busy: \(IPCWire.busyStarting)"
    private static let retryInterval = 0.1

    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// One attempt. A server that's still starting comes back as `ok: false` with the reason
    /// `busy: starting`, so not throwing means the server answered.
    public func send(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        try await exchange(request, deadline: monotonicSeconds() + timeout).result
    }

    /// Retries every 100 ms while the server is busy or the socket is missing, since in both cases
    /// the request didn't run. At the timeout it throws `notRunning` if the last attempt found no
    /// server, and `timedOut` otherwise. A connection lost after sending isn't retried, because
    /// the request may have run.
    public func sendWaitingForReady(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        let deadline = monotonicSeconds() + timeout
        var lastFailure: IPCError
        repeat {
            do {
                let reply = try await exchange(request, deadline: deadline)
                guard reply.busy != nil else { return reply.result }
                lastFailure = .timedOut
            } catch IPCError.notRunning {
                lastFailure = .notRunning
            }
            try await Task.sleep(for: .seconds(min(Self.retryInterval, deadline - monotonicSeconds())))
        } while monotonicSeconds() < deadline
        throw lastFailure
    }

    private func exchange(_ request: CommandRequest, deadline: Double) async throws -> IPCReply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "com.alexluncan.PorchLight.ipc.client", qos: .userInitiated).async { [path] in
                continuation.resume(with: Result {
                    try Self.blockingExchange(request, path: path, deadline: deadline)
                })
            }
        }
    }

    private static func blockingExchange(_ request: CommandRequest, path: String, deadline: Double) throws -> IPCReply {
        // A write and a connect don't wait, so without this an expired deadline would still send.
        guard deadline > monotonicSeconds() else { throw IPCError.timedOut }

        let message = IPCRequest(
            id: UUID().uuidString,
            command: request,
            client: ProcessInfo.processInfo.processName
        )
        let line = try encodeLine(message)

        let file = try IPCSocket.connected(to: IPCSocketAddress(path: path))
        defer { close(file) }

        var stream = IPCStream(file: file)
        try stream.write(line, deadline: deadline)
        guard let replyLine = try stream.readLine(deadline: deadline) else {
            throw IPCError.protocolError("connection closed before a reply")
        }
        guard let reply = try? JSONDecoder().decode(IPCReply.self, from: replyLine) else {
            throw IPCError.protocolError("malformed reply")
        }
        guard reply.v == IPCWire.version else {
            throw IPCError.protocolError("unsupported protocol version \(reply.v)")
        }
        guard reply.id == message.id else {
            throw IPCError.protocolError("reply is for a different request")
        }
        return reply
    }
}
