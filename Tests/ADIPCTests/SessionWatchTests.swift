import ADModel
import Foundation
import Synchronization
import Testing
@testable import ADIPC

// The client half of `session watch`. The app's half is tested in ADEngineTests.

private let idle: JSONValue = .object(["state": .string("idle"), "apiVersion": .number(1)])
private let active: JSONValue = .object(["state": .string("active"), "apiVersion": .number(1), "displayID": .number(41)])
private let recreated: JSONValue = .object(["state": .string("active"), "apiVersion": .number(1), "displayID": .number(42)])

/// An answer to `session watch` as the app sends it.
private func answer(_ instance: String, _ change: Int, _ status: JSONValue, line: String = "line") -> CommandResult {
    .success(
        line,
        json: .object([
            "apiVersion": .number(1),
            "instance": .string(instance),
            "change": .number(Double(change)),
            "status": status,
        ])
    )
}

/// What the app would print for `session status`.
private func shown(_ status: JSONValue, line: String = "line") -> CommandResult {
    .success(line, json: status)
}

private func parameters(_ request: CommandRequest) -> [String: String?] {
    Dictionary(uniqueKeysWithValues: request.parameters.map { ($0.name, $0.value) })
}

/// Answers each request with the next scripted result, and records what it was asked.
private final class ScriptedApp: Sendable {
    private let state: Mutex<(script: [Result<CommandResult, IPCError>], asked: [(CommandRequest, Double)])>

    init(_ script: [Result<CommandResult, IPCError>]) {
        state = Mutex((script, []))
    }

    var asked: [(request: CommandRequest, timeout: Double)] {
        state.withLock { $0.asked }
    }

    func send(_ request: CommandRequest, timeout: Double) throws -> CommandResult {
        let next = state.withLock { state in
            state.asked.append((request, timeout))
            return state.script.isEmpty ? .failure(.notRunning) : state.script.removeFirst()
        }
        return try next.get()
    }
}

private final class Collected: Sendable {
    private let values = Mutex<[CommandResult]>([])

    func append(_ value: CommandResult) {
        values.withLock { $0.append(value) }
    }

    var all: [CommandResult] {
        values.withLock { $0 }
    }
}

// MARK: - One answer at a time

@Test func theFirstRequestAsksForTheStatusNow() {
    #expect(SessionWatch().request == CommandRequest(operations: ["session", "watch"]))
}

@Test func theFirstAnswerIsShownAndTheNextRequestWaitsAfterIt() throws {
    var watch = SessionWatch()

    #expect(try watch.take(answer("run-1", 3, active, line: "state=active")) == shown(active, line: "state=active"))

    #expect(watch.request.operations == ["session", "watch"])
    #expect(parameters(watch.request) == ["instance": "run-1", "after": "3", "wait": "15"])
}

@Test func anAnswerWithNoNewChangeShowsNothing() throws {
    var watch = SessionWatch()
    _ = try watch.take(answer("run-1", 3, active))

    #expect(try watch.take(answer("run-1", 3, recreated)) == nil)
    #expect(parameters(watch.request)["after"] == "3")
}

@Test func aChangeThatLeavesTheStatusAsShownShowsNothingButMovesOn() throws {
    var watch = SessionWatch()
    _ = try watch.take(answer("run-1", 3, active))

    #expect(try watch.take(answer("run-1", 4, active)) == nil)
    #expect(parameters(watch.request)["after"] == "4")
    #expect(try watch.take(answer("run-1", 5, recreated)) == shown(recreated))
}

@Test func anotherRunOfTheAppIsShownEvenWithALowerNumber() throws {
    var watch = SessionWatch()
    _ = try watch.take(answer("run-1", 9, active))

    #expect(try watch.take(answer("run-2", 0, recreated)) == shown(recreated))
    #expect(parameters(watch.request) == ["instance": "run-2", "after": "0", "wait": "15"])
}

@Test func aFailedAnswerStopsTheWatch() {
    var watch = SessionWatch()

    #expect(throws: SessionWatchError(reason: "unknown session operation: watch")) {
        try watch.take(.failure("unknown session operation: watch"))
    }
    #expect(throws: SessionWatchError(reason: "session watch failed")) { try watch.take(.failure()) }
}

@Test(arguments: [
    CommandResult.success("line"),
    .success("line", json: idle),
    .success("line", json: .object(["instance": .string("i"), "change": .number(1.5), "status": idle])),
    .success("line", json: .object(["instance": .string("i"), "change": .number(1)])),
])
func anAnswerThatIsntAWatchAnswerStopsTheWatch(_ reply: CommandResult) {
    var watch = SessionWatch()

    #expect(throws: SessionWatchError(reason: "the app's answer to session watch could not be read")) {
        try watch.take(reply)
    }
}

// MARK: - Following

@Test func followShowsEachChangeUntilTheAppIsGone() async {
    let app = ScriptedApp([
        .success(answer("run-1", 0, idle)),
        .success(answer("run-1", 0, idle)),
        .success(answer("run-1", 1, active)),
        .success(answer("run-1", 2, idle)),
        .failure(.notRunning),
    ])
    let seen = Collected()
    var watch = SessionWatch()

    let ending = await watch.follow(send: { try app.send($0, timeout: $1) }) { seen.append($0) }

    #expect(ending == .appGone)
    #expect(seen.all == [shown(idle), shown(active), shown(idle)])
    #expect(app.asked.map { parameters($0.request)["after"] ?? nil } == [nil, "0", "0", "1", "2"])
    #expect(app.asked.allSatisfy { $0.timeout == SessionWatch.requestTimeout })
    #expect(SessionWatch.requestTimeout == 25)
}

@Test func followAsksAgainWhileTheAppIsBusyOrTheConnectionDrops() async {
    let app = ScriptedApp([
        .success(answer("run-1", 0, active)),
        .success(CommandResult(ok: false, reason: IPCClient.busyReason)),
        .failure(.timedOut),
        .failure(.protocolError("connection closed before a reply")),
        .success(answer("run-2", 0, recreated)),
        .failure(.notRunning),
    ])
    let seen = Collected()
    var watch = SessionWatch()

    let ending = await watch.follow(send: { try app.send($0, timeout: $1) }) { seen.append($0) }

    #expect(ending == .appGone)
    #expect(seen.all == [shown(active), shown(recreated)])
    #expect(app.asked.count == 6)
}

@Test func followStopsAtAFailedAnswer() async {
    let app = ScriptedApp([.success(answer("run-1", 0, active)), .success(.failure("app is quitting"))])
    let seen = Collected()
    var watch = SessionWatch()

    let ending = await watch.follow(send: { try app.send($0, timeout: $1) }) { seen.append($0) }

    #expect(ending == .failed("app is quitting"))
    #expect(seen.all == [shown(active)])
}

@Test func followStopsWhenItsTaskIsCancelled() async {
    let app = ScriptedApp(Array(repeating: .success(answer("run-1", 0, active)), count: 10_000))
    let task = Task {
        var watch = SessionWatch()
        return await watch.follow(send: { request, timeout in
            try await Task.sleep(for: .milliseconds(5))
            return try app.send(request, timeout: timeout)
        }) { _ in }
    }
    try? await Task.sleep(for: .milliseconds(50))

    task.cancel()

    #expect(await task.value == .cancelled)
}

@Test func busyReasonIsWhatABusyServerAnswers() {
    #expect(IPCReply.busy(id: "x").result.reason == IPCClient.busyReason)
}
