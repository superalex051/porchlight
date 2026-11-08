import ADModel
import Darwin
import Foundation
import Synchronization
import Testing
@testable import ADIPC

// MARK: - Helpers

/// A private directory with a short path, because `sun_path` holds 103 bytes and `$TMPDIR` is long here.
private func withSocketPath(_ body: (String) async throws -> Void) async throws {
    var template = Array("/tmp/adipc.XXXXXX".utf8)
    template.append(0)
    let created = template.withUnsafeMutableBytes { bytes in
        mkdtemp(bytes.baseAddress?.assumingMemoryBound(to: CChar.self))
    }
    guard created != nil else { throw POSIXError(.EIO) }
    let directory = String(decoding: template.dropLast(), as: UTF8.self)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try await body("\(directory)/s.sock")
}

private func withServer(
    ready: Bool = true,
    handler: @escaping @Sendable (CommandRequest) async -> CommandResult = { _ in .success("ok") },
    _ body: (IPCServer, IPCClient, String) async throws -> Void
) async throws {
    try await withSocketPath { path in
        let server = IPCServer(path: path, handler: handler)
        try server.start()
        defer { server.stop() }
        server.setReady(ready)
        try await body(server, IPCClient(path: path), path)
    }
}

private let getRequest = CommandRequest(operations: ["get"])

/// A literal request line, so these tests pin the wire format instead of the encoder.
private func requestLine(id: String = "r1", version: Int = 1, operation: String = "get") -> String {
    #"{"v":\#(version),"id":"\#(id)","operations":["\#(operation)"],"parameters":[],"client":"test"}"# + "\n"
}

private final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}

/// Tracks how many handlers overlap.
private final class OverlapGauge: Sendable {
    private let counts = Mutex((current: 0, peak: 0))

    func enter() {
        counts.withLock {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
        }
    }

    func leave() {
        counts.withLock { $0.current -= 1 }
    }

    var peak: Int {
        counts.withLock { $0.peak }
    }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

/// Runs blocking socket calls away from the cooperative pool, which the handlers under test need.
private func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

private func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, size) }
    }
}

/// Leaves a socket file behind that nobody listens on, as a crash does.
private func makeStaleSocketFile(at path: String) throws {
    let file = socket(AF_UNIX, SOCK_STREAM, 0)
    guard file >= 0 else { throw POSIXError(.EIO) }
    defer { close(file) }
    guard withAddress(path, { bind(file, $0, $1) }) == 0 else { throw POSIXError(.EADDRINUSE) }
}

/// A client that speaks raw bytes, for what `IPCClient` would never send. Reads and writes give up
/// after 5 s, so a server that stops responding fails the test instead of hanging it.
private struct RawClient: Sendable {
    let file: Int32

    init(path: String) throws {
        file = socket(AF_UNIX, SOCK_STREAM, 0)
        guard file >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(file, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(file, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(file, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard withAddress(path, { connect(file, $0, $1) }) == 0 else {
            close(file)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    /// Returns false once the server has stopped taking bytes.
    @discardableResult
    func send(_ bytes: [UInt8]) async -> Bool {
        await offPool { [file] in
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    @discardableResult
    func send(_ text: String) async -> Bool {
        await send(Array(text.utf8))
    }

    /// Nil at end of stream, and after the read timeout.
    func readLine() async -> String? {
        await offPool { [file] in
            var line: [UInt8] = []
            var byte: UInt8 = 0
            while read(file, &byte, 1) == 1 {
                if byte == 0x0A { return String(bytes: line, encoding: .utf8) }
                line.append(byte)
            }
            return nil
        }
    }

    /// True if the stream ended, false if the read timed out first.
    func readReachesEnd() async -> Bool {
        await offPool { [file] in
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(file, &chunk, chunk.count)
                if count <= 0 { return count == 0 }
            }
        }
    }

    func hangUp() {
        close(file)
    }
}

private func object(_ line: String?) throws -> [String: Any] {
    let text = try #require(line)
    return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// Accepts one connection, reads a line, optionally answers with `reply`, and hangs up.
/// `$ID` in the reply becomes the request's ID, so a bad reply fails for its own reason.
private func withFakeServer(reply: String?, _ body: (IPCClient) async throws -> Void) async throws {
    try await withSocketPath { path in
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        defer { close(listener) }
        guard withAddress(path, { bind(listener, $0, $1) }) == 0, listen(listener, 1) == 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        DispatchQueue.global().async {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var line: [UInt8] = []
            var byte: UInt8 = 0
            while read(connection, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            let request = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            let id = request?["id"] as? String ?? ""
            if let text = reply?.replacingOccurrences(of: "$ID", with: id) {
                _ = text.withCString { write(connection, $0, strlen($0)) }
            }
        }
        try await body(IPCClient(path: path))
    }
}

private func expectProtocolError(_ error: IPCError?, sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .protocolError = error else {
        Issue.record("expected protocolError, got \(String(describing: error))", sourceLocation: sourceLocation)
        return
    }
}

// MARK: - Round trips

@Test func roundTripPreservesParameterOrder() async throws {
    let received = Recorder<CommandRequest>()
    let request = CommandRequest(
        operations: ["set", "get"],
        parameters: [
            CommandParameter(name: "z", value: "1"),
            CommandParameter(name: "connected", value: nil),
            CommandParameter(name: "a", value: "2"),
            CommandParameter(name: "z", value: "3"),
        ]
    )
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        received.append($0)
        return .success("on")
    }
    try await withServer(handler: handler) { _, client, _ in
        let result = try await client.send(request, timeout: 5)
        #expect(result == .success("on"))
    }
    #expect(received.all == [request])
}

@Test func everyResultFieldRoundTrips() async throws {
    let expected = CommandResult(
        ok: false,
        payload: "two\nlines, one é",
        reason: "why",
        warning: "careful",
        json: .object(["list": .array([.number(1.5), .bool(true), .null, .string("x")])])
    )
    try await withServer(handler: { _ in expected }) { _, client, _ in
        let result = try await client.send(getRequest, timeout: 5)
        #expect(result == expected)
    }
}

@Test func largePayloadRoundTrips() async throws {
    let large = String(repeating: "x", count: 1_048_576)
    let request = CommandRequest(operations: ["set"], parameters: [CommandParameter(name: "big", value: large)])
    try await withServer(handler: { .success($0.parameters.first?.value) }) { _, client, _ in
        let result = try await client.send(request, timeout: 30)
        #expect(result.payload == large)
    }
}

@Test func concurrentClientsAllAnswered() async throws {
    let gauge = OverlapGauge()
    let handler: @Sendable (CommandRequest) async -> CommandResult = { request in
        gauge.enter()
        defer { gauge.leave() }
        try? await Task.sleep(for: .milliseconds(100))
        return .success(request.operations.first)
    }
    try await withServer(handler: handler) { _, client, _ in
        let answers = try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for index in 0..<20 {
                group.addTask {
                    let result = try await client.send(CommandRequest(operations: ["op\(index)"]), timeout: 30)
                    return ("op\(index)", result.payload)
                }
            }
            return try await group.reduce(into: [(String, String?)]()) { $0.append($1) }
        }
        #expect(answers.count == 20)
        #expect(answers.allSatisfy { $0.0 == $0.1 })
    }
    // Answered one at a time, these 20 would never overlap.
    #expect(gauge.peak > 1)
}

@MainActor private func mainActorAnswer() -> CommandResult {
    MainActor.preconditionIsolated()
    return .success("main")
}

/// The engine's handler runs on the main actor, while the server's threads don't.
@Test func mainActorHandlerAnswers() async throws {
    try await withServer(handler: { @MainActor _ in mainActorAnswer() }) { _, client, _ in
        let result = try await client.send(getRequest, timeout: 10)
        #expect(result.payload == "main")
    }
}

// MARK: - Wire format

@Test func requestEncodesAsTheSpecifiedLine() throws {
    let message = IPCRequest(
        id: "abc",
        command: CommandRequest(
            operations: ["set"],
            parameters: [CommandParameter(name: "UUID", value: "x"), CommandParameter(name: "connected", value: nil)]
        ),
        client: "cli"
    )
    let line = try encodeLine(message)
    #expect(line.last == 0x0A)
    #expect(line.dropLast().contains(0x0A) == false)

    let decoded = try object(String(data: line, encoding: .utf8))
    #expect(Set(decoded.keys) == ["v", "id", "operations", "parameters", "client"])
    #expect(decoded["v"] as? Int == 1)
    #expect(decoded["id"] as? String == "abc")
    #expect(decoded["operations"] as? [String] == ["set"])
    #expect(decoded["client"] as? String == "cli")
    let parameters = try #require(decoded["parameters"] as? [[Any]])
    #expect(parameters.count == 2)
    #expect(parameters[0] as? [String] == ["UUID", "x"])
    #expect(parameters[1].first as? String == "connected")
    #expect(parameters[1].count == 2)
    #expect(parameters[1].last is NSNull)
}

@Test func literalRequestGetsTheSpecifiedReply() async throws {
    let received = Recorder<CommandRequest>()
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        received.append($0)
        return CommandResult(ok: true, payload: "on", warning: "w", json: .bool(true))
    }
    try await withServer(handler: handler) { _, _, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        await raw.send(
            #"{"v":1,"id":"abc","operations":["set"],"parameters":[["UUID","x"],["connected",null],["UUID","y"]],"client":"cli"}"#
                + "\n"
        )
        let reply = try object(await raw.readLine())
        #expect(reply["v"] as? Int == 1)
        #expect(reply["id"] as? String == "abc")
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["payload"] as? String == "on")
        #expect(reply["warning"] as? String == "w")
        #expect(reply["json"] as? Bool == true)
        #expect(reply["busy"] == nil)
    }
    #expect(
        received.all == [
            CommandRequest(
                operations: ["set"],
                parameters: [
                    CommandParameter(name: "UUID", value: "x"),
                    CommandParameter(name: "connected", value: nil),
                    CommandParameter(name: "UUID", value: "y"),
                ]
            )
        ]
    )
}

@Test func malformedLineGetsError() async throws {
    let handled = Recorder<CommandRequest>()
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        handled.append($0)
        return .success("fine")
    }
    let badLines: [[UInt8]] = [
        Array("not json\n".utf8),
        Array("\n".utf8),
        Array("[]\n".utf8),
        Array(#"{"v":1}"#.utf8) + [0x0A],
        // Not UTF-8.
        [0xFF, 0xFE, 0x0A],
        // A parameter has to be exactly [name, value|null].
        Array(#"{"v":1,"id":"x","operations":[],"parameters":[["a"]],"client":"t"}"#.utf8) + [0x0A],
        Array(#"{"v":1,"id":"x","operations":[],"parameters":[["a","b","c"]],"client":"t"}"#.utf8) + [0x0A],
        Array(#"{"v":1,"id":"x","operations":[],"parameters":[[1,"b"]],"client":"t"}"#.utf8) + [0x0A],
        Array(requestLine(version: 2).utf8),
    ]
    try await withServer(handler: handler) { _, _, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        for bad in badLines {
            await raw.send(bad)
            let reply = try object(await raw.readLine())
            #expect(reply["ok"] as? Bool == false)
            #expect(reply["reason"] is String)
            #expect(reply["busy"] == nil)
        }
        #expect(handled.all.isEmpty)

        await raw.send(requestLine(id: "after"))
        let reply = try object(await raw.readLine())
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["id"] as? String == "after")
        #expect(reply["payload"] as? String == "fine")
    }
    #expect(handled.all.count == 1)
}

@Test func linesOnOneConnectionAreAnsweredInOrder() async throws {
    let handler: @Sendable (CommandRequest) async -> CommandResult = { request in
        // The first line takes longest, so later answers would overtake it if handled out of order.
        if request.operations == ["op0"] { try? await Task.sleep(for: .milliseconds(100)) }
        return .success(request.operations.first)
    }
    try await withServer(handler: handler) { _, _, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        await raw.send((0..<3).map { requestLine(id: "r\($0)", operation: "op\($0)") }.joined())
        for index in 0..<3 {
            let reply = try object(await raw.readLine())
            #expect(reply["id"] as? String == "r\(index)")
            #expect(reply["payload"] as? String == "op\(index)")
        }
    }
}

@Test func oversizedLineIsRefusedAndTheConnectionCloses() async throws {
    let handled = Recorder<CommandRequest>()
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        handled.append($0)
        return .success()
    }
    try await withServer(handler: handler) { _, client, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        // No newline, so the server has to give up without seeing the end of the line.
        await raw.send([UInt8](repeating: 0x78, count: IPCServer.maxRequestBytes + 1_048_576))
        let reply = try object(await raw.readLine())
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["reason"] is String)
        #expect(await raw.readReachesEnd())
        #expect(handled.all.isEmpty)

        // Other clients aren't affected.
        #expect(try await client.send(getRequest, timeout: 5).ok)
    }
}

@Test func unencodableResultGetsError() async throws {
    let handler: @Sendable (CommandRequest) async -> CommandResult = { request in
        // JSON has no infinity.
        request.operations == ["bad"] ? .success(json: .number(.infinity)) : .success("fine")
    }
    try await withServer(handler: handler) { _, _, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        await raw.send(requestLine(id: "r1", operation: "bad"))
        let bad = try object(await raw.readLine())
        #expect(bad["ok"] as? Bool == false)
        #expect(bad["id"] as? String == "r1")
        #expect(bad["reason"] is String)

        await raw.send(requestLine(id: "r2", operation: "good"))
        let good = try object(await raw.readLine())
        #expect(good["payload"] as? String == "fine")
    }
}

// MARK: - The socket file

@Test func socketFileIsMode0600() async throws {
    try await withServer { _, _, path in
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
    }
}

@Test func staleSocketFileIsReplaced() async throws {
    try await withSocketPath { path in
        try makeStaleSocketFile(at: path)
        let server = IPCServer(path: path, handler: { _ in .success("new") })
        try server.start()
        defer { server.stop() }
        server.setReady(true)
        #expect(try await IPCClient(path: path).send(getRequest, timeout: 5).payload == "new")
    }
}

@Test func liveSocketIsNotReplaced() async throws {
    try await withServer(handler: { _ in .success("first") }) { _, client, path in
        let second = IPCServer(path: path, handler: { _ in .success("second") })
        second.setReady(true)
        #expect(throws: IPCError.self) { try second.start() }
        second.stop()
        let result = try await client.send(getRequest, timeout: 5)
        #expect(result.payload == "first")
    }
}

@Test func fileThatIsNotASocketIsLeftAlone() async throws {
    try await withSocketPath { path in
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let server = IPCServer(path: path, handler: { _ in .success() })
        #expect(throws: IPCError.self) { try server.start() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("keep".utf8))
        await #expect(throws: IPCError.notRunning) {
            try await IPCClient(path: path).send(getRequest, timeout: 5)
        }
    }
}

@Test func stopRemovesTheSocketFile() async throws {
    try await withServer { server, client, path in
        server.stop()
        #expect(access(path, F_OK) != 0)
        await #expect(throws: IPCError.notRunning) { try await client.send(getRequest, timeout: 5) }
    }
}

@Test func stopLeavesAReplacementSocketAlone() async throws {
    try await withServer(handler: { _ in .success("old") }) { old, client, path in
        unlink(path)
        let replacement = IPCServer(path: path, handler: { _ in .success("new") })
        try replacement.start()
        defer { replacement.stop() }
        replacement.setReady(true)

        old.stop()
        #expect(try await client.send(getRequest, timeout: 5).payload == "new")
    }
}

@Test func serverRestartsAfterStopAndIsBusyAgain() async throws {
    try await withServer { server, client, _ in
        #expect(try await client.send(getRequest, timeout: 5).ok)
        server.stop()
        try server.start()
        #expect(try await client.send(getRequest, timeout: 5).reason == "busy: starting")
        server.setReady(true)
        #expect(try await client.send(getRequest, timeout: 5).ok)
    }
}

@Test func startingTwiceThrows() async throws {
    try await withServer { server, client, _ in
        #expect(throws: IPCError.self) { try server.start() }
        let result = try await client.send(getRequest, timeout: 5)
        #expect(result.ok)
    }
}

@Test func longestBindablePathWorksAndOneByteMoreIsRefused() async throws {
    try await withSocketPath { path in
        let directory = (path as NSString).deletingLastPathComponent
        let longest = directory + "/" + String(repeating: "s", count: 103 - directory.utf8.count - 1)
        #expect(longest.utf8.count == 103)
        let server = IPCServer(path: longest, handler: { _ in .success("fits") })
        try server.start()
        defer { server.stop() }
        server.setReady(true)
        #expect(try await IPCClient(path: longest).send(getRequest, timeout: 5).payload == "fits")

        // Truncating this one would bind or reach the 103-byte socket above.
        let tooLong = longest + "s"
        let refused = IPCServer(path: tooLong, handler: { _ in .success("no") })
        #expect(throws: IPCError.self) { try refused.start() }
        let error = await #expect(throws: IPCError.self) {
            try await IPCClient(path: tooLong).send(getRequest, timeout: 5)
        }
        expectProtocolError(error)
    }
}

@Test func socketsAreSetUpToSurviveChildrenAndHangUps() throws {
    let file = try IPCSocket.make()
    defer { close(file) }
    #expect(fcntl(file, F_GETFD) & FD_CLOEXEC != 0)
    #expect(fcntl(file, F_GETFL) & O_NONBLOCK != 0)
    var noSigpipe: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    #expect(getsockopt(file, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, &size) == 0)
    #expect(noSigpipe != 0)
}

/// `FD_CLOEXEC` belongs to the descriptor, so an accepted socket can't get it from the listener. A
/// child that inherited one would keep the connection open after the server closed it.
@Test func acceptedSocketsAreNotInheritedByChildren() async throws {
    try await withServer { server, _, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        await raw.send(requestLine())
        #expect(await raw.readLine() != nil)

        let accepted = server.openConnections
        #expect(accepted.count == 1)
        for file in accepted {
            #expect(fcntl(file, F_GETFD) & FD_CLOEXEC != 0)
        }
    }
}

// MARK: - Readiness

@Test func busyUntilReady() async throws {
    let handled = Recorder<CommandRequest>()
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        handled.append($0)
        return .success("ready")
    }
    try await withServer(ready: false, handler: handler) { server, client, _ in
        // A plain send gets the busy answer back, without retrying.
        let busy = try await client.send(getRequest, timeout: 5)
        #expect(!busy.ok)
        #expect(busy.reason == "busy: starting")
        #expect(handled.all.isEmpty)

        let start = ContinuousClock.now
        let flip = Task {
            try await Task.sleep(for: .milliseconds(350))
            server.setReady(true)
        }
        let result = try await client.sendWaitingForReady(getRequest, timeout: 10)
        try await flip.value
        #expect(result == .success("ready"))
        #expect(seconds(since: start) >= 0.3)

        server.setReady(false)
        let busyAgain = try await client.send(getRequest, timeout: 5)
        #expect(busyAgain.reason == "busy: starting")
    }
    #expect(handled.all == [getRequest])
}

@Test func busyReplyIsTheSpecifiedLine() async throws {
    try await withServer(ready: false) { _, _, path in
        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        await raw.send(requestLine(id: "r9"))
        let reply = try object(await raw.readLine())
        #expect(reply["v"] as? Int == 1)
        #expect(reply["id"] as? String == "r9")
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["busy"] as? String == "starting")
    }
}

@Test func waitingGivesUpWithTimedOutWhileStillBusy() async throws {
    try await withServer(ready: false) { _, client, _ in
        let start = ContinuousClock.now
        await #expect(throws: IPCError.timedOut) {
            try await client.sendWaitingForReady(getRequest, timeout: 0.3)
        }
        #expect(seconds(since: start) >= 0.29)
        #expect(seconds(since: start) < 3)
    }
}

@Test func missingSocketThrowsNotRunning() async throws {
    try await withSocketPath { path in
        await #expect(throws: IPCError.notRunning) {
            try await IPCClient(path: path).send(getRequest, timeout: 5)
        }
    }
}

@Test func staleSocketFileThrowsNotRunning() async throws {
    try await withSocketPath { path in
        try makeStaleSocketFile(at: path)
        await #expect(throws: IPCError.notRunning) {
            try await IPCClient(path: path).send(getRequest, timeout: 5)
        }
    }
}

@Test func waitingGivesUpWithNotRunningWhenTheSocketNeverAppears() async throws {
    try await withSocketPath { path in
        let start = ContinuousClock.now
        await #expect(throws: IPCError.notRunning) {
            try await IPCClient(path: path).sendWaitingForReady(getRequest, timeout: 0.3)
        }
        #expect(seconds(since: start) >= 0.29)
        #expect(seconds(since: start) < 3)
    }
}

@Test func waitingFindsASocketThatAppearsLater() async throws {
    try await withSocketPath { path in
        let server = IPCServer(path: path, handler: { _ in .success("up") })
        defer { server.stop() }
        server.setReady(true)
        let late = Task {
            try await Task.sleep(for: .milliseconds(300))
            try server.start()
        }
        let result = try await IPCClient(path: path).sendWaitingForReady(getRequest, timeout: 10)
        try await late.value
        #expect(result.payload == "up")
    }
}

// MARK: - Timeouts and misbehaving peers

@Test func timeoutThrowsTimedOut() async throws {
    let handler: @Sendable (CommandRequest) async -> CommandResult = { _ in
        try? await Task.sleep(for: .seconds(2))
        return .success()
    }
    try await withServer(handler: handler) { _, client, _ in
        let start = ContinuousClock.now
        await #expect(throws: IPCError.timedOut) { try await client.send(getRequest, timeout: 0.2) }
        #expect(seconds(since: start) < 1.5)
    }
}

@Test func unusableTimeoutsThrowTimedOutWithoutSending() async throws {
    let handled = Recorder<CommandRequest>()
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        handled.append($0)
        return .success("ok")
    }
    try await withServer(handler: handler) { _, client, path in
        for timeout in [0, -1, Double.nan] {
            await #expect(throws: IPCError.timedOut) { try await client.send(getRequest, timeout: timeout) }
        }
        // Nothing is attempted, so a missing socket doesn't even get noticed.
        await #expect(throws: IPCError.timedOut) {
            try await IPCClient(path: path + ".missing").send(getRequest, timeout: 0)
        }
        let sent = try await client.send(getRequest, timeout: .infinity)
        #expect(sent.ok)
        let waited = try await client.sendWaitingForReady(getRequest, timeout: .infinity)
        #expect(waited.ok)
        // Checked after these round trips, so an expired send has had time to reach the handler.
        #expect(handled.all.count == 2)
    }
}

@Test func peerWithDifferentUIDIsRejected() async throws {
    let handled = Recorder<CommandRequest>()
    let handler: @Sendable (CommandRequest) async -> CommandResult = {
        handled.append($0)
        return .success()
    }
    try await withSocketPath { path in
        let server = IPCServer(path: path, allowedUID: geteuid() + 1, handler: handler)
        try server.start()
        defer { server.stop() }
        server.setReady(true)

        let error = await #expect(throws: IPCError.self) {
            try await IPCClient(path: path).send(getRequest, timeout: 5)
        }
        expectProtocolError(error)

        let raw = try RawClient(path: path)
        defer { raw.hangUp() }
        await raw.send(requestLine())
        #expect(await raw.readLine() == nil)
    }
    #expect(handled.all.isEmpty)
}

private let sigpipeCount = Atomic<Int>(0)

/// Writing to a departed client must not raise SIGPIPE, whose default action kills the process.
/// The signal is counted because a test runner that ignores it would hide the bug.
@Test func clientThatHangsUpDoesNotKillTheServer() async throws {
    let previous = signal(SIGPIPE) { _ in sigpipeCount.add(1, ordering: .relaxed) }
    defer { signal(SIGPIPE, previous) }
    let handler: @Sendable (CommandRequest) async -> CommandResult = { _ in
        try? await Task.sleep(for: .milliseconds(100))
        return .success("still here")
    }
    try await withServer(handler: handler) { _, client, path in
        let raw = try RawClient(path: path)
        await raw.send(requestLine())
        raw.hangUp()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await client.send(getRequest, timeout: 5).payload == "still here")
    }
    #expect(sigpipeCount.load(ordering: .relaxed) == 0)
}

@Test func stalledClientDoesNotBlockOthersAndStopReleasesIt() async throws {
    let large = String(repeating: "x", count: 8 * 1_048_576)
    let handler: @Sendable (CommandRequest) async -> CommandResult = { request in
        request.operations == ["large"] ? .success(large) : .success("small")
    }
    try await withServer(handler: handler) { server, client, path in
        let stalled = try RawClient(path: path)
        defer { stalled.hangUp() }
        // It never reads, so the server's write fills the socket buffer and stays there.
        await stalled.send(requestLine(operation: "large"))
        try await Task.sleep(for: .milliseconds(100))

        #expect(try await client.send(getRequest, timeout: 5).payload == "small")

        server.stop()
        #expect(await stalled.readReachesEnd())
    }
}

@Test func connectionsAreClosedWhenClientsLeave() async throws {
    try await withServer { server, client, path in
        for _ in 0..<5 {
            _ = try await client.send(getRequest, timeout: 5)
        }
        let raw = try RawClient(path: path)
        raw.hangUp()

        let start = ContinuousClock.now
        while !server.openConnections.isEmpty, seconds(since: start) < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.openConnections.isEmpty)
    }
}

@Test func stopReleasesAnIdleConnection() async throws {
    try await withServer { server, _, path in
        let idle = try RawClient(path: path)
        defer { idle.hangUp() }
        await idle.send(requestLine())
        #expect(await idle.readLine() != nil)
        server.stop()
        #expect(await idle.readReachesEnd())
    }
}

@Test(arguments: [
    "garbage\n",
    #"{"v":1,"id":"not-the-request","ok":true}"# + "\n",
    #"{"v":2,"id":"$ID","ok":true}"# + "\n",
    #"{"v":1,"id":"$ID"}"# + "\n",
])
func unusableReplyThrowsProtocolError(reply: String) async throws {
    try await withFakeServer(reply: reply) { client in
        let error = await #expect(throws: IPCError.self) { try await client.send(getRequest, timeout: 5) }
        expectProtocolError(error)
    }
}

/// The control for the test above: this reply differs only in being valid.
@Test func validReplyFromTheFakeServerIsAccepted() async throws {
    try await withFakeServer(reply: #"{"v":1,"id":"$ID","ok":true,"payload":"fake"}"# + "\n") { client in
        let result = try await client.send(getRequest, timeout: 5)
        #expect(result == .success("fake"))
    }
}

/// The request may have run, so a waiting client must not send it again.
@Test func connectionClosedBeforeTheReplyIsNotRetried() async throws {
    try await withFakeServer(reply: nil) { client in
        let error = await #expect(throws: IPCError.self) {
            try await client.sendWaitingForReady(getRequest, timeout: 5)
        }
        expectProtocolError(error)
    }
}
