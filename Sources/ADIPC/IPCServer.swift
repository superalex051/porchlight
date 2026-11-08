import ADFoundation
import ADModel
import Darwin
import Foundation
import Synchronization
import os

private let log = ADLog.logger("ipc")

/// Serves newline-delimited JSON on a Unix socket. Each connection has its own dispatch queue, and
/// its lines are answered one at a time, in order. Stays alive until `stop`.
public final class IPCServer: Sendable {
    /// Far beyond any real command. A longer line closes the connection, so a client that never
    /// sends a newline can't grow the buffer until the process holding the monitors runs out of memory.
    static let maxRequestBytes = 16 * 1_048_576

    private struct SocketFileID: Equatable {
        var device: dev_t
        var inode: ino_t

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private struct Listener {
        var source: DispatchSourceRead
        var socketFile: SocketFileID?
    }

    private struct State {
        var ready = false
        var listener: Listener?
        var connections: Set<Int32> = []
    }

    private let path: String
    private let allowedUID: uid_t
    private let handler: @Sendable (CommandRequest) async -> CommandResult
    private let state = Mutex(State())
    private let acceptQueue = DispatchQueue(label: "com.alexluncan.PorchLight.ipc.accept", qos: .userInitiated)

    public convenience init(path: String, handler: @escaping @Sendable (CommandRequest) async -> CommandResult) {
        self.init(path: path, allowedUID: geteuid(), handler: handler)
    }

    init(path: String, allowedUID: uid_t, handler: @escaping @Sendable (CommandRequest) async -> CommandResult) {
        self.path = path
        self.allowedUID = allowedUID
        self.handler = handler
    }

    /// Listens right away, answering busy until `setReady(true)`. Throws `IPCError.protocolError` if the
    /// socket can't be set up, or if another server is already listening at the path.
    public func start() throws {
        try state.withLock { state in
            guard state.listener == nil else { throw IPCError.protocolError("server already started") }
            state.listener = try openListener()
        }
    }

    /// Closes the socket and ends open connections. Doesn't wait for running handlers, since one may
    /// need the actor calling this. Their replies go nowhere.
    public func stop() {
        state.withLock { state in
            state.ready = false
            guard let listener = state.listener else { return }
            state.listener = nil
            listener.source.cancel()
            // A newer server may have taken over the path.
            if let socketFile = listener.socketFile, SocketFileID(path: path) == socketFile {
                unlink(path)
            }
            // Wakes each connection's queue, which then closes its own descriptor.
            for file in state.connections {
                shutdown(file, SHUT_RDWR)
            }
        }
    }

    public func setReady(_ ready: Bool) {
        state.withLock { $0.ready = ready }
    }

    /// Connections not yet closed. The guardian pings every 2 seconds on a new one, so a leak adds up fast.
    var openConnections: Set<Int32> {
        state.withLock { $0.connections }
    }

    // MARK: - Listening

    private func openListener() throws -> Listener {
        let address = try IPCSocketAddress(path: path)
        try removeStaleSocket(at: address)

        let file = try IPCSocket.make()
        guard address.call({ bind(file, $0, $1) }) == 0 else {
            let failure = IPCSocket.failure("bind \(path)")
            close(file)
            throw failure
        }
        // In this order: nobody can connect before `listen`, so the mode is never wider than 0600 for a client.
        guard chmod(path, 0o600) == 0, listen(file, SOMAXCONN) == 0 else {
            let failure = IPCSocket.failure("listen \(path)")
            close(file)
            unlink(path)
            throw failure
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: file, queue: acceptQueue)
        source.setEventHandler { [self] in acceptPending(on: file) }
        source.setCancelHandler { close(file) }
        source.activate()
        return Listener(source: source, socketFile: SocketFileID(path: path))
    }

    /// Only a socket nobody listens on is stale. A live one is left alone, because replacing it would
    /// cut off a running server without telling it. Anything that isn't a socket isn't ours to delete.
    private func removeStaleSocket(at address: IPCSocketAddress) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            guard errno == ENOENT else { throw IPCSocket.failure("lstat \(path)") }
            return
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw IPCError.protocolError("\(path) exists and is not a socket")
        }
        if let live = try? IPCSocket.connected(to: address) {
            close(live)
            throw IPCError.protocolError("another server is listening at \(path)")
        }
        guard unlink(path) == 0 else { throw IPCSocket.failure("unlink \(path)") }
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let file = accept(listener, nil, nil)
            if file >= 0 {
                admit(file)
            } else if errno != EINTR, errno != ECONNABORTED {
                // Normally EAGAIN, meaning all caught up. The source fires again for anything new.
                return
            }
        }
    }

    private func admit(_ file: Int32) {
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(file, &peerUID, &peerGID) == 0, peerUID == allowedUID else {
            // `getpeereid` also fails for a client that has already gone, leaving the UID unset.
            log.error("Rejected a connection: peer UID unknown or not ours (\(peerUID, privacy: .public))")
            close(file)
            return
        }
        guard (try? IPCSocket.prepare(file)) != nil else {
            log.error("Dropped a connection whose socket options could not be set")
            close(file)
            return
        }
        // Inside the lock, so a connection accepted during `stop` isn't missed by it.
        let admitted = state.withLock { state in
            guard state.listener != nil else { return false }
            state.connections.insert(file)
            return true
        }
        guard admitted else {
            close(file)
            return
        }
        DispatchQueue(label: "com.alexluncan.PorchLight.ipc.connection", qos: .userInitiated).async { [self] in
            serve(file)
        }
    }

    // MARK: - One connection

    private func serve(_ file: Int32) {
        // Inside the lock, so `stop` can't shut down a descriptor number the system has already reused.
        defer {
            state.withLock { state in
                state.connections.remove(file)
                close(file)
            }
        }

        var stream = IPCStream(file: file)
        do {
            while let line = try stream.readLine(maxBytes: Self.maxRequestBytes) {
                let reply = reply(to: line)
                // Only a non-finite number in `json` can't be encoded.
                let fallback = IPCReply.failure(id: reply.id, reason: "could not encode the reply")
                guard let encoded = (try? encodeLine(reply)) ?? (try? encodeLine(fallback)) else { return }
                try stream.write(encoded)
            }
        } catch is IPCLineTooLong {
            if let refusal = try? encodeLine(IPCReply.failure(id: nil, reason: "request line too long")) {
                try? stream.write(refusal)
            }
        } catch {
            // The client went away, or `stop` shut the socket. Either way this connection is done.
        }
    }

    private func reply(to line: Data) -> IPCReply {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
            return .failure(id: nil, reason: "malformed request")
        }
        guard request.v == IPCWire.version else {
            return .failure(id: request.id, reason: "unsupported protocol version \(request.v)")
        }
        guard state.withLock({ $0.ready }) else { return .busy(id: request.id) }
        log.debug("Request from \(request.client, privacy: .public)")
        return IPCReply(id: request.id, result: runHandler(request.command))
    }

    /// Waits on the connection's queue, whose thread isn't in the cooperative pool, so this can't
    /// starve the handler. Waiting here also keeps this connection's answers in order.
    private func runHandler(_ command: CommandRequest) -> CommandResult {
        let outcome = HandlerOutcome()
        Task { [handler] in
            outcome.finish(await handler(command))
        }
        return outcome.wait()
    }
}

/// Carries a handler's result from its task back to the connection's queue.
private final class HandlerOutcome: Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let result = Mutex<CommandResult?>(nil)

    func finish(_ value: CommandResult) {
        result.withLock { $0 = value }
        done.signal()
    }

    func wait() -> CommandResult {
        done.wait()
        return result.withLock { $0 } ?? .failure()
    }
}
