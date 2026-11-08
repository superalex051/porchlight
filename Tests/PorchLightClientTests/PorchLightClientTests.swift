import ADIPC
import ADModel
import Darwin
import Foundation
import Synchronization
import Testing
@testable import PorchLightClient

// The library against a fake app: the real socket server from ADIPC, with a scripted handler. The
// answers are built with ADModel's own `SessionStatus.asJSON`, so these also prove that what the app
// writes is what the library reads.

// MARK: - Helpers

/// A private directory with a short path, because `sun_path` holds 103 bytes and `$TMPDIR` is long here.
private func withSocketPath(_ body: (String) async throws -> Void) async throws {
    var template = Array("/tmp/plclient.XXXXXX".utf8)
    template.append(0)
    let created = template.withUnsafeMutableBytes { bytes in
        mkdtemp(bytes.baseAddress?.assumingMemoryBound(to: CChar.self))
    }
    guard created != nil else { throw POSIXError(.EIO) }
    let directory = String(decoding: template.dropLast(), as: UTF8.self)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try await body("\(directory)/s.sock")
}

/// The fake app's requests, and how many times the library launched it.
private final class Log: Sendable {
    private let state = Mutex((requests: [CommandRequest](), launches: 0))

    func record(_ request: CommandRequest) {
        state.withLock { $0.requests.append(request) }
    }

    func launched() {
        state.withLock { $0.launches += 1 }
    }

    var requests: [CommandRequest] { state.withLock { $0.requests } }
    var launches: Int { state.withLock { $0.launches } }
}

private let screenUUID = "63C872E8-4E48-4D23-9889-F8EE8F82BEEE"

private let ipadSession = SessionStatus(
    state: .active,
    client: "ipad",
    displayID: 77,
    uuid: screenUUID,
    looksLike: ScreenSize(w: 1180, h: 820),
    pixels: ScreenSize(w: 2360, h: 1640),
    hiDPI: true,
    hz: 60,
    ownerPIDs: [ProcessInfo.processInfo.processIdentifier],
    physicalOff: [2, 4]
)

private func answer(_ status: SessionStatus) -> CommandResult {
    .success(status.statusLine, json: status.asJSON)
}

/// A server on a fresh socket, ready unless asked otherwise. Stopped when `body` returns.
private func withApp(
    ready: Bool = true,
    handler: @escaping @Sendable (CommandRequest) async -> CommandResult,
    _ body: (IPCServer, String) async throws -> Void
) async throws {
    try await withSocketPath { path in
        let server = IPCServer(path: path, handler: handler)
        try server.start()
        defer { server.stop() }
        server.setReady(ready)
        try await body(server, path)
    }
}

private func parameter(_ request: CommandRequest, _ name: String) -> [String?] {
    request.parameters.filter { $0.name == name }.map(\.value)
}

// MARK: - Calls

@Test func startSendsTheSessionAndReturnsTheScreenToCapture() async throws {
    let log = Log()
    try await withApp(handler: { request in
        log.record(request)
        return answer(ipadSession)
    }) { _, path in
        let client = PorchLightClient(socketPath: path, launch: nil)

        let status = try await client.start(client: "ipad", looksLike: PorchLightSize(width: 1180, height: 820))

        #expect(status.displayID == 77)
        #expect(status.displayUUID == screenUUID)
        #expect(status.state == .active)
        #expect(status.client == "ipad")
        #expect(status.looksLike == PorchLightSize(width: 1180, height: 820))
        #expect(status.pixels == PorchLightSize(width: 2360, height: 1640))
        #expect(status.hiDPI == true)
        #expect(status.hz == 60)
        #expect(status.ownerPIDs == [ProcessInfo.processInfo.processIdentifier])
        #expect(status.physicalOff == [2, 4])
        #expect(status.apiVersion == 1)
    }
    #expect(log.requests == [
        CommandRequest(
            operations: ["session", "start"],
            parameters: [
                CommandParameter(name: "client", value: "ipad"),
                CommandParameter(name: "lookslike", value: "1180x820"),
                CommandParameter(name: "hiDPI", value: "on"),
                CommandParameter(name: "hz", value: "60"),
                CommandParameter(name: "ownerpid", value: String(ProcessInfo.processInfo.processIdentifier)),
            ]
        ),
    ], "By default the caller owns the session")
}

@Test func startPassesTheShapeAndEveryOwner() async throws {
    let log = Log()
    try await withApp(handler: { request in
        log.record(request)
        return answer(ipadSession)
    }) { _, path in
        let client = PorchLightClient(socketPath: path, launch: nil)

        _ = try await client.start(
            client: "iphone",
            looksLike: PorchLightSize(width: 1311, height: 603),
            hiDPI: false,
            hz: 120,
            ownerPIDs: [11, 22]
        )
    }
    let request = try #require(log.requests.first)
    #expect(parameter(request, "hiDPI") == ["off"])
    #expect(parameter(request, "hz") == ["120"])
    #expect(parameter(request, "ownerpid") == ["11", "22"])
}

@Test func endSendsTheClientAndReturnsIdle() async throws {
    let log = Log()
    try await withApp(handler: { request in
        log.record(request)
        return .success(json: SessionStatus(state: .idle).asJSON)
    }) { _, path in
        let client = PorchLightClient(socketPath: path, launch: nil)

        let status = try await client.end(client: "ipad")

        #expect(status == PorchLightStatus(apiVersion: 1, state: .idle))
        #expect(status.displayID == nil && status.ownerPIDs.isEmpty)
    }
    #expect(log.requests == [
        CommandRequest(operations: ["session", "end"], parameters: [CommandParameter(name: "client", value: "ipad")]),
    ])
}

@Test func statusReadsAStatusWithUnknownValues() async throws {
    let starting = SessionStatus(state: .starting, client: "ipad", hiDPI: true, hz: 60)
    try await withApp(handler: { _ in answer(starting) }) { _, path in
        let status = try await PorchLightClient(socketPath: path, launch: nil).status()

        #expect(status == PorchLightStatus(apiVersion: 1, state: .starting, client: "ipad", hiDPI: true, hz: 60))
    }
}

@Test func aRefusalThrowsItsReason() async throws {
    try await withApp(handler: { _ in .failure("session held by parsec") }) { _, path in
        let client = PorchLightClient(socketPath: path, launch: nil)

        await #expect(throws: PorchLightClientError.failed("session held by parsec")) {
            try await client.start(client: "ipad", looksLike: PorchLightSize(width: 1180, height: 820))
        }
    }
}

@Test(arguments: [
    JSONValue.object(["state": .string("idle"), "apiVersion": .number(2)]),
    .object(["state": .string("idle")]),
    .object(["state": .string("paused"), "apiVersion": .number(1)]),
    .string("state=idle"),
])
func anAnswerOfAnotherVersionOrShapeIsRefused(_ json: JSONValue) async throws {
    try await withApp(handler: { _ in .success("state=idle", json: json) }) { _, path in
        let client = PorchLightClient(socketPath: path, launch: nil)

        let error = await #expect(throws: PorchLightClientError.self) { try await client.status() }
        guard case .unsupportedReply? = error else {
            Issue.record("expected unsupportedReply, got \(String(describing: error))")
            return
        }
    }
}

@Test func aRefusedVersionIsNamed() async throws {
    try await withApp(handler: { _ in .success(json: .object(["state": .string("idle"), "apiVersion": .number(2)])) }) { _, path in
        await #expect(throws: PorchLightClientError.unsupportedReply("API version 2; this library speaks 1")) {
            try await PorchLightClient(socketPath: path, launch: nil).status()
        }
    }
}

@Test func anAnswerWithNoStatusIsRefused() async throws {
    try await withApp(handler: { _ in .success("pong") }) { _, path in
        await #expect(throws: PorchLightClientError.unsupportedReply("the answer has no status")) {
            try await PorchLightClient(socketPath: path, launch: nil).status()
        }
    }
}

@Test func aBusyAppIsWaitedFor() async throws {
    try await withApp(ready: false, handler: { _ in answer(ipadSession) }) { server, path in
        let client = PorchLightClient(socketPath: path, launch: nil)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            server.setReady(true)
        }

        let status = try await client.status()
        #expect(status.displayID == 77)
    }
}

// MARK: - Launching

@Test func withNoAppAndNoLaunchEveryCallThrowsAppNotRunning() async throws {
    try await withSocketPath { path in
        let client = PorchLightClient(socketPath: path, launch: nil)

        await #expect(throws: PorchLightClientError.appNotRunning) {
            try await client.start(client: "ipad", looksLike: PorchLightSize(width: 1180, height: 820))
        }
        await #expect(throws: PorchLightClientError.appNotRunning) { try await client.end(client: "ipad") }
        await #expect(throws: PorchLightClientError.appNotRunning) { try await client.status() }
    }
}

@Test func startAndEndLaunchTheAppButStatusDoesnt() async throws {
    let log = Log()
    try await withSocketPath { path in
        let server = IPCServer(path: path) { request in
            log.record(request)
            return request.operations == ["ping"] ? .success("pong") : answer(ipadSession)
        }
        defer { server.stop() }
        let client = PorchLightClient(socketPath: path) {
            log.launched()
            try server.start()
            server.setReady(true)
        }

        await #expect(throws: PorchLightClientError.appNotRunning) { try await client.status() }
        #expect(log.launches == 0)

        let started = try await client.start(client: "ipad", looksLike: PorchLightSize(width: 1180, height: 820))
        #expect(started.displayID == 77)
        #expect(log.launches == 1)
        #expect(log.requests.map(\.operations) == [["ping"], ["session", "start"]], "It waits for the app to be ready")

        let ended = try await client.end(client: "ipad")
        #expect(ended.displayID == 77)
        #expect(log.launches == 1, "Already running")
    }
}

@Test func aLaunchThatFailsIsAppNotRunning() async throws {
    struct OpenFailed: Error {}
    try await withSocketPath { path in
        let client = PorchLightClient(socketPath: path) { throw OpenFailed() }

        await #expect(throws: PorchLightClientError.appNotRunning) { try await client.end(client: "ipad") }
    }
}

@Test func onlyTheRealSocketWithNoTestOverrideLaunches() {
    #expect(PorchLightClient.launchIsAllowed(socketPath: nil, environment: [:]))
    #expect(!PorchLightClient.launchIsAllowed(socketPath: "/tmp/other.sock", environment: [:]))
    for name in ["AD_SOCKET_PATH", "AD_STATE_DIR", "AD_DRY_RUN"] {
        #expect(!PorchLightClient.launchIsAllowed(socketPath: nil, environment: [name: "1"]), "\(name)")
        #expect(PorchLightClient.launchIsAllowed(socketPath: nil, environment: [name: ""]), "An empty \(name) counts as unset")
    }
    #expect(PorchLightClient(launchesApp: false).launches == false)
    #expect(PorchLightClient(socketPath: "/tmp/other.sock").launches == false)
}

@Test func theLibrarySpeaksTheAppsAPIVersion() {
    #expect(PorchLightClient.apiVersion == SessionAPI.version)
}

// MARK: - Changes

/// A fake app's half of `session watch`: change 0 is idle, change 1 the iPad session, and nothing after.
@Sendable private func watchAnswer(_ request: CommandRequest) async -> CommandResult {
    let after = request.parameters.first { $0.name == "after" }?.value.flatMap { Int($0) }
    let change = after == nil ? 0 : min(after! + 1, 1)
    if after == 1 { try? await Task.sleep(for: .milliseconds(20)) }
    let status = change == 0 ? SessionStatus(state: .idle) : ipadSession
    return .success(
        status.statusLine,
        json: .object([
            "apiVersion": .number(1),
            "instance": .string("run-1"),
            "change": .number(Double(change)),
            "status": status.asJSON,
        ])
    )
}

@Test func changesYieldsTheStatusThenEachChangeAndFinishesWhenTheAppGoes() async throws {
    try await withApp(handler: watchAnswer) { server, path in
        let stream = PorchLightClient(socketPath: path, launch: nil).changes()
        var seen: [PorchLightStatus] = []

        for await status in stream {
            seen.append(status)
            if seen.count == 2 { server.stop() }
        }

        #expect(seen.map(\.state) == [.idle, .active])
        #expect(seen.last?.displayID == 77)
    }
}

@Test func changesWithNoAppFinishesAtOnce() async throws {
    try await withSocketPath { path in
        var count = 0
        for await _ in PorchLightClient(socketPath: path, launch: nil).changes() { count += 1 }
        #expect(count == 0)
    }
}
