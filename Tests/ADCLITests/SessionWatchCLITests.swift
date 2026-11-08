import ADCommand
import ADIPC
import ADModel
import Foundation
import Synchronization
import Testing
@testable import adcli

// `porchlight session watch`: the first answer comes through the usual path, which can start the app,
// and every one after through single attempts, so a quitting app ends the watch at once.

private let idle: JSONValue = .object(["state": .string("idle"), "apiVersion": .number(1)])
private let active: JSONValue = .object(["state": .string("active"), "apiVersion": .number(1), "displayID": .number(41)])
private let idleLine = "state=idle"
private let activeLine = "state=active client=ipad displayID=41"

private func answer(_ instance: String, _ change: Int, _ status: JSONValue, _ line: String) -> Result<CommandResult, IPCError> {
    .success(.success(
        line,
        json: .object([
            "apiVersion": .number(1),
            "instance": .string(instance),
            "change": .number(Double(change)),
            "status": status,
        ])
    ))
}

/// Answers from a script, in order, and then as if the app had quit. Records which path each request took.
private final class WatchedMac: CLITransport, CLIAppLaunching, RescueRunning {
    private struct State {
        var script: [Result<CommandResult, IPCError>]
        var sent: [CommandRequest] = []
        var sentOnce: [CommandRequest] = []
        var launches = 0
    }

    private let state: Mutex<State>
    let helperProblem: String? = nil

    init(_ script: [Result<CommandResult, IPCError>]) {
        state = Mutex(State(script: script))
    }

    var sent: [CommandRequest] { state.withLock { $0.sent } }
    var sentOnce: [CommandRequest] { state.withLock { $0.sentOnce } }
    var launches: Int { state.withLock { $0.launches } }

    func send(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        try next { $0.sent.append(request) }
    }

    func sendOnce(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        try next { $0.sentOnce.append(request) }
    }

    private func next(recording: (inout State) -> Void) throws -> CommandResult {
        try state.withLock { state in
            recording(&state)
            return state.script.isEmpty ? .failure(IPCError.notRunning) : state.script.removeFirst()
        }.get()
    }

    func ping(timeout: Double) async -> Bool { true }

    func launch() throws {
        state.withLock { $0.launches += 1 }
    }

    func runRestoreHelper() async -> HelperOutcome { .failed }
}

private final class Printed: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] { lines.withLock { $0 } }
}

private func watch(_ mac: WatchedMac, _ argv: String...) async -> (output: RenderedOutput, printed: [String]) {
    let printed = Printed()
    let runner = CLIRunner(transport: mac, launcher: mac, rescue: mac, environment: [:], write: { printed.append($0) })
    let output = await runner.run(argv)
    return (output, printed.all)
}

private let exitedQuietly = RenderedOutput(stdout: "", stderr: "", exitCode: 0)

@Test func watchPrintsTheStatusThenEachChangeAndExits0WhenTheAppGoes() async {
    let mac = WatchedMac([
        answer("run-1", 0, idle, idleLine),
        answer("run-1", 1, active, activeLine),
        answer("run-1", 1, active, activeLine),
        answer("run-1", 2, idle, idleLine),
    ])

    let (output, printed) = await watch(mac, "session", "watch")

    #expect(output == exitedQuietly)
    #expect(printed == ["\(idleLine)\n", "\(activeLine)\n", "\(idleLine)\n"])
    #expect(mac.sent == [CommandRequest(operations: ["session", "watch"])], "Only the first can start the app")
    #expect(mac.sentOnce.count == 4)
    #expect(mac.sentOnce.first?.parameters == [
        CommandParameter(name: "instance", value: "run-1"),
        CommandParameter(name: "after", value: "0"),
        CommandParameter(name: "wait", value: "15"),
    ])
}

@Test func watchWithJSONPrintsTheStatusEnvelopeOnEachLine() async {
    let mac = WatchedMac([answer("run-1", 0, idle, idleLine), answer("run-1", 1, active, activeLine)])

    let (output, printed) = await watch(mac, "session", "watch", "--json")

    #expect(output == exitedQuietly)
    #expect(printed == [
        #"{"ok":true,"payload":"state=idle","reason":null,"warning":null,"json":{"apiVersion":1,"state":"idle"}}"# + "\n",
        #"{"ok":true,"payload":"state=active client=ipad displayID=41","reason":null,"warning":null,"json":{"apiVersion":1,"displayID":41,"state":"active"}}"# + "\n",
    ])
}

@Test func watchWithNoAppAndNoLaunchFailsAndPrintsNothing() async {
    let mac = WatchedMac([.failure(.notRunning)])

    let (output, printed) = await watch(mac, "session", "watch", "--no-launch")

    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. app not running\n", exitCode: 1))
    #expect(printed.isEmpty)
    #expect(mac.launches == 0)
}

@Test func watchStartsTheAppLikeStatusDoes() async {
    let mac = WatchedMac([.failure(.notRunning), answer("run-1", 0, idle, idleLine)])

    let (output, printed) = await watch(mac, "session", "watch")

    #expect(output == exitedQuietly)
    #expect(printed == ["\(idleLine)\n"])
    #expect(mac.launches == 1)
}

@Test func watchAgainstAnAppThatDoesntKnowItFails() async {
    let reason = "unknown session operation: watch; use start, end, resize, status or presets"
    let mac = WatchedMac([.success(.failure(reason))])

    let (output, printed) = await watch(mac, "session", "watch", "--json")

    #expect(output == RenderedOutput(
        stdout: #"{"ok":false,"payload":null,"reason":"\#(reason)","warning":null,"json":null}"# + "\n",
        stderr: "",
        exitCode: 1
    ))
    #expect(printed.isEmpty)
}

@Test func aFailureLaterStopsTheWatchWithExit1() async {
    let mac = WatchedMac([answer("run-1", 0, idle, idleLine), .success(.failure("app is quitting"))])

    let (output, printed) = await watch(mac, "session", "watch")

    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. app is quitting\n", exitCode: 1))
    #expect(printed == ["\(idleLine)\n"])
}

@Test func watchTakesNoParameters() async {
    let mac = WatchedMac([])

    let (output, printed) = await watch(mac, "session", "watch", "-client=ipad")

    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. unknown parameter: client\n", exitCode: 1))
    #expect(printed.isEmpty)
    #expect(mac.sent.isEmpty && mac.sentOnce.isEmpty)
}

@Test func watchHelpIsTheHelp() async {
    let mac = WatchedMac([])

    let (output, _) = await watch(mac, "session", "watch", "--help")

    #expect(output == RenderedOutput(stdout: CommandHelp.text + "\n", stderr: "", exitCode: 0))
    #expect(mac.sent.isEmpty && mac.sentOnce.isEmpty)
}

/// A busy app (starting or quitting) answers the real transport's single attempt with busy at once,
/// where `send` would wait for it to be ready. The watch asks again itself, and ends once the socket is gone.
@Test func theRealTransportsSingleAttemptDoesntWaitOutABusyApp() async throws {
    var template = Array("/tmp/plcli.XXXXXX".utf8)
    template.append(0)
    let created = template.withUnsafeMutableBytes { mkdtemp($0.baseAddress?.assumingMemoryBound(to: CChar.self)) }
    try #require(created != nil)
    let directory = String(decoding: template.dropLast(), as: UTF8.self)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let server = IPCServer(path: "\(directory)/s.sock") { _ in .success("pong") }
    try server.start()
    let transport = IPCTransport(client: IPCClient(path: "\(directory)/s.sock"))
    let started = ContinuousClock.now

    let busy = try await transport.sendOnce(CommandRequest(operations: ["ping"]), timeout: 5)

    #expect(busy == CommandResult(ok: false, reason: IPCClient.busyReason))
    #expect(started.duration(to: .now) < .seconds(2))
    server.stop()
    await #expect(throws: IPCError.notRunning) { try await transport.sendOnce(CommandRequest(operations: ["ping"]), timeout: 5) }
}
