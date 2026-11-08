import ADCommand
import ADIPC
import ADModel
import Darwin
import Foundation
import Synchronization
import Testing
@testable import adcli

// MARK: - Fakes

private struct FakeLaunchFailure: Error {}

/// The socket, `open` and the restore helper in one place, so launching can change what the socket
/// does. A launched app only starts answering once something waits for it with a ping, which is how
/// these tests prove the runner waits for readiness before sending.
private final class FakeMac: CLITransport, CLIAppLaunching, RescueRunning {
    private struct State {
        var appReady: Bool
        var launched = false
        var sent: [(request: CommandRequest, timeout: Double)] = []
        var pings: [Double] = []
        var launches = 0
        var helperRuns = 0
    }

    private let state: Mutex<State>
    private let reply: Result<CommandResult, IPCError>
    private let launchStartsApp: Bool
    private let launchThrows: Bool
    private let helperWorks: Bool
    private let helperNotAtRecordedMode: [String]
    private let pingDelay: Duration
    let helperProblem: String?

    init(
        appReady: Bool = true,
        reply: Result<CommandResult, IPCError> = .success(.success()),
        launchStartsApp: Bool = true,
        launchThrows: Bool = false,
        helperWorks: Bool = true,
        helperNotAtRecordedMode: [String] = [],
        pingDelay: Duration = .zero,
        helperProblem: String? = nil
    ) {
        state = Mutex(State(appReady: appReady))
        self.reply = reply
        self.launchStartsApp = launchStartsApp
        self.launchThrows = launchThrows
        self.helperWorks = helperWorks
        self.helperNotAtRecordedMode = helperNotAtRecordedMode
        self.pingDelay = pingDelay
        self.helperProblem = helperProblem
    }

    /// Requests that reached a ready app, with the timeout each one was given.
    var sent: [(request: CommandRequest, timeout: Double)] { state.withLock { $0.sent } }
    var pings: [Double] { state.withLock { $0.pings } }
    var launches: Int { state.withLock { $0.launches } }
    var helperRuns: Int { state.withLock { $0.helperRuns } }

    func send(_ request: CommandRequest, timeout: Double) async throws -> CommandResult {
        let ready = state.withLock { state in
            if state.appReady { state.sent.append((request, timeout)) }
            return state.appReady
        }
        guard ready else { throw IPCError.notRunning }
        return try reply.get()
    }

    func ping(timeout: Double) async -> Bool {
        try? await Task.sleep(for: pingDelay)
        return state.withLock { state in
            state.pings.append(timeout)
            if state.launched, launchStartsApp { state.appReady = true }
            return state.appReady
        }
    }

    func launch() throws {
        state.withLock { state in
            state.launches += 1
            state.launched = !launchThrows
        }
        if launchThrows { throw FakeLaunchFailure() }
    }

    func runRestoreHelper() async -> HelperOutcome {
        state.withLock { $0.helperRuns += 1 }
        return helperWorks ? .restored(notAtRecordedMode: helperNotAtRecordedMode) : .failed
    }
}

/// The environment is explicit, so an `AD_` variable around the test run can't change what these prove.
private func run(_ mac: FakeMac, environment: [String: String] = [:], _ argv: String...) async -> RenderedOutput {
    await CLIRunner(transport: mac, launcher: mac, rescue: mac, environment: environment).run(argv)
}

private let notRunningOutput = RenderedOutput(stdout: "", stderr: "Failed. app not running\n", exitCode: 1)

// MARK: - Output

@Test func getPrintsPayload() async {
    let mac = FakeMac(reply: .success(.success("on")))
    let output = await run(mac, "get", "-UUID=abc", "-connected")
    #expect(output == RenderedOutput(stdout: "on\n", stderr: "", exitCode: 0))
    #expect(mac.sent.map(\.request) == [
        CommandRequest(
            operations: ["get"],
            parameters: [CommandParameter(name: "UUID", value: "abc"), CommandParameter(name: "connected")]
        ),
    ])
    #expect(mac.launches == 0)
}

@Test func pingPrintsItsPayload() async {
    let mac = FakeMac(reply: .success(.success("pong")))
    let output = await run(mac, "ping", "--no-launch")
    #expect(output == RenderedOutput(stdout: "pong\n", stderr: "", exitCode: 0))
}

@Test func failurePrintsFailedAndExit1() async {
    let mac = FakeMac(reply: .success(.failure("session held by parsec")))
    let output = await run(mac, "session", "end")
    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. session held by parsec\n", exitCode: 1))
}

@Test func jsonFlagRendersEnvelope() async {
    let mac = FakeMac(reply: .success(.success("on")))
    let output = await run(mac, "get", "--json")
    #expect(output == RenderedOutput(
        stdout: #"{"ok":true,"payload":"on","reason":null,"warning":null,"json":null}"# + "\n",
        stderr: "",
        exitCode: 0
    ))
}

@Test func jsonFlagRendersAFailureFromTheCLIItself() async {
    let mac = FakeMac(appReady: false)
    let output = await run(mac, "get", "--json", "--no-launch")
    #expect(output == RenderedOutput(
        stdout: #"{"ok":false,"payload":null,"reason":"app not running","warning":null,"json":null}"# + "\n",
        stderr: "",
        exitCode: 1
    ))
}

@Test func parseErrorRendersWithItsOptionsAndSendsNothing() async {
    let mac = FakeMac()
    let output = await run(mac, "get", "--timeout=soon", "--json")
    #expect(output.exitCode == 1)
    #expect(output.stdout.hasPrefix(#"{"ok":false,"payload":null,"reason":"--timeout needs"#))
    #expect(output.stderr.isEmpty)
    #expect(mac.sent.isEmpty && mac.launches == 0 && mac.helperRuns == 0)
}

@Test func noOperationFailsWithoutLaunching() async {
    let mac = FakeMac(appReady: false)
    let output = await run(mac, "--json")
    #expect(output.exitCode == 1)
    #expect(output.stdout.contains(#""reason":"no operation given; run porchlight help""#))
    #expect(mac.pings.isEmpty && mac.launches == 0 && mac.helperRuns == 0)
}

/// Someone who has forgotten the syntax is pointed at the help.
@Test func noOperationPointsAtHelp() async {
    let output = await run(FakeMac(appReady: false))
    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. no operation given; run porchlight help\n", exitCode: 1))
}

// MARK: - Help

/// Help comes from the CLI itself, so asking for it never starts the app, and works with the app down.
@Test(arguments: [["help"], ["--help"], ["-help"], ["-h"], ["-H"], ["session", "help"], ["--HELP"]])
func helpIsPrintedWithoutTheApp(argv: [String]) async {
    let mac = FakeMac(appReady: false)
    let output = await CLIRunner(transport: mac, launcher: mac, rescue: mac, environment: [:]).run(argv)
    #expect(output == RenderedOutput(stdout: CommandHelp.text + "\n", stderr: "", exitCode: 0), "\(argv)")
    #expect(mac.sent.isEmpty && mac.pings.isEmpty && mac.launches == 0 && mac.helperRuns == 0, "\(argv)")
}

/// `--help` after a command explains it and doesn't run it. `rescue` ignores its parameters, so without
/// this, `rescue --help` would end a session to answer a question.
@Test(arguments: [
    ["rescue", "--help"],
    ["session", "start", "-client=parsec", "--help"],
    ["set", "-UUID=abc", "-connected=off", "-h"],
    ["quit", "--help"],
])
func helpAfterACommandDoesntRunIt(argv: [String]) async {
    let mac = FakeMac()
    let output = await CLIRunner(transport: mac, launcher: mac, rescue: mac, environment: [:]).run(argv)
    #expect(output.stdout == CommandHelp.text + "\n" && output.exitCode == 0, "\(argv)")
    #expect(mac.sent.isEmpty && mac.pings.isEmpty && mac.launches == 0 && mac.helperRuns == 0, "\(argv)")
}

@Test func helpWithJSONIsAnEnvelope() async {
    let output = await run(FakeMac(appReady: false), "help", "--json")
    #expect(output.exitCode == 0 && output.stderr.isEmpty)
    #expect(output.stdout.hasPrefix(#"{"ok":true,"payload":"porchlight: "#))
}

/// A malformed argument still says what's wrong with it, rather than printing the help over it.
@Test func aParseErrorWinsOverHelp() async {
    let output = await run(FakeMac(), "--help", "--timeout=soon")
    #expect(output.exitCode == 1)
    #expect(output.stderr.hasPrefix("Failed. --timeout needs"))
}

// MARK: - Timeouts

@Test func sessionDefaultTimeoutIs60() async {
    let mac = FakeMac()
    _ = await run(mac, "session", "status")
    #expect(mac.sent.map(\.timeout) == [60])
}

@Test func otherDefaultTimeoutIs15() async {
    let mac = FakeMac()
    _ = await run(mac, "get", "-connected")
    #expect(mac.sent.map(\.timeout) == [15])
}

@Test func timeoutFlagWins() async {
    let session = FakeMac()
    _ = await run(session, "session", "status", "--timeout=7")
    #expect(session.sent.map(\.timeout) == [7])

    let other = FakeMac()
    _ = await run(other, "get", "--timeout=120.5")
    #expect(other.sent.map(\.timeout) == [120.5])
}

@Test func extremelySmallTimeoutIsRaisedToTheFloor() async {
    let mac = FakeMac()
    _ = await run(mac, "get", "--timeout=5e-324")
    #expect(mac.sent.map(\.timeout) == [0.01])
}

@Test func sessionTimeoutSaysTheChangeMayStillComplete() async {
    let mac = FakeMac(reply: .failure(.timedOut))
    let output = await run(mac, "session", "start", "--timeout=1")
    #expect(output == RenderedOutput(
        stdout: "",
        stderr: "Failed. timed out; the session change may still complete, check session status\n",
        exitCode: 1
    ))
}

@Test func otherTimeoutJustSaysTimedOut() async {
    let mac = FakeMac(reply: .failure(.timedOut))
    let output = await run(mac, "get")
    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. timed out\n", exitCode: 1))
}

@Test func protocolErrorPrintsItsReasonWithoutLaunching() async {
    let mac = FakeMac(reply: .failure(.protocolError("connection closed before a reply")))
    let output = await run(mac, "get")
    #expect(output == RenderedOutput(stdout: "", stderr: "Failed. connection closed before a reply\n", exitCode: 1))
    #expect(mac.launches == 0)
    #expect(mac.sent.count == 1)
}

// MARK: - Launching

@Test func launchesWhenNotRunning() async {
    let mac = FakeMac(appReady: false, reply: .success(.success("on")))
    let output = await run(mac, "get")
    #expect(output == RenderedOutput(stdout: "on\n", stderr: "", exitCode: 0))
    #expect(mac.launches == 1)
    #expect(mac.sent.count == 1)
}

@Test func waitingForTheLaunchCountsAgainstTheTimeout() async {
    let mac = FakeMac(appReady: false, pingDelay: .milliseconds(50))
    _ = await run(mac, "get", "--timeout=10")
    #expect(mac.pings.count == 1 && mac.pings[0] <= 10 && mac.pings[0] > 9)
    #expect(mac.sent.count == 1 && mac.sent[0].timeout <= 9.95 && mac.sent[0].timeout > 0)
}

@Test func noLaunchFailsWithoutLaunching() async {
    let mac = FakeMac(appReady: false)
    #expect(await run(mac, "get", "--no-launch") == notRunningOutput)
    #expect(mac.launches == 0)
}

/// Starting the app only to stop it would do nothing useful, and an install relies on this.
@Test func quitNeverLaunches() async {
    let mac = FakeMac(appReady: false)
    #expect(await run(mac, "quit") == notRunningOutput)
    #expect(mac.launches == 0)
}

@Test func unreachableAfterLaunchFails() async {
    let mac = FakeMac(appReady: false, launchStartsApp: false)
    #expect(await run(mac, "get") == notRunningOutput)
    #expect(mac.launches == 1)
    #expect(mac.sent.isEmpty)
}

/// `open` passes no environment, so a launch here would start the real app with no dry run flag.
@Test(arguments: ["AD_SOCKET_PATH", "AD_STATE_DIR", "AD_DRY_RUN"])
func overrideVariableMeansNoLaunch(variable: String) async {
    let mac = FakeMac(appReady: false)
    #expect(await run(mac, environment: [variable: "1"], "get") == notRunningOutput)
    #expect(mac.launches == 0)
    #expect(mac.pings.isEmpty)
}

@Test func overrideVariableDoesNotStopASendToALiveServer() async {
    let mac = FakeMac(reply: .success(.success("pong")))
    let output = await run(mac, environment: ["AD_SOCKET_PATH": "/tmp/s.sock"], "ping")
    #expect(output == RenderedOutput(stdout: "pong\n", stderr: "", exitCode: 0))
}

@Test func emptyOverrideVariablesStillLaunch() async {
    let mac = FakeMac(appReady: false)
    let environment = ["AD_SOCKET_PATH": "", "AD_STATE_DIR": "", "AD_DRY_RUN": ""]
    #expect(await run(mac, environment: environment, "get").exitCode == 0)
    #expect(mac.launches == 1)
}

@Test func failedLaunchFailsWithoutWaiting() async {
    let mac = FakeMac(appReady: false, launchThrows: true)
    #expect(await run(mac, "get") == notRunningOutput)
    #expect(mac.pings.isEmpty)
}

// MARK: - Rescue

@Test func rescueWithLiveAppSendsRescueOperation() async {
    let mac = FakeMac(reply: .success(.success("state=idle")))
    let output = await run(mac, "rescue")
    #expect(output == RenderedOutput(stdout: "state=idle\n", stderr: "", exitCode: 0))
    #expect(mac.pings == [1])
    #expect(mac.sent.map(\.request) == [CommandRequest(operations: ["rescue"])])
    #expect(mac.sent.map(\.timeout) == [60])
    #expect(mac.helperRuns == 0 && mac.launches == 0)
}

@Test func rescueKeepsItsTimeoutWhateverTheFlagSays() async {
    let mac = FakeMac()
    _ = await run(mac, "rescue", "--timeout=1")
    #expect(mac.sent.map(\.timeout) == [60])
    #expect(mac.helperRuns == 0)
}

@Test func rescueWithDeadAppRunsHelper() async {
    let mac = FakeMac(appReady: false)
    let output = await run(mac, "rescue")
    #expect(output == RenderedOutput(stdout: "", stderr: "", exitCode: 0))
    #expect(mac.pings == [1])
    #expect(mac.sent.isEmpty)
    #expect(mac.helperRuns == 1 && mac.launches == 0)
}

@Test func rescueWhenAppFailsRunsHelper() async {
    let mac = FakeMac(reply: .success(.failure("restore failed")))
    let output = await run(mac, "rescue")
    #expect(output.exitCode == 0)
    #expect(output.stderr == "warning: the app failed (restore failed), so the restore helper ran\n")
    #expect(mac.helperRuns == 1 && mac.launches == 0)
}

@Test func rescueWhenAppTimesOutRunsHelper() async {
    let mac = FakeMac(reply: .failure(.timedOut))
    let output = await run(mac, "rescue")
    #expect(output.exitCode == 0)
    #expect(output.stderr == "warning: the app failed (timed out), so the restore helper ran\n")
    #expect(mac.helperRuns == 1)
}

/// The monitors are on, so this is a success, but the user has to know a rate or resolution is off.
@Test func rescueWarnsForADisplayNotAtItsRecordedMode() async {
    let dead = FakeMac(appReady: false, helperNotAtRecordedMode: ["M34WQ"])
    #expect(await run(dead, "rescue") == RenderedOutput(
        stdout: "",
        stderr: "warning: M34WQ came back but not at its recorded mode\n",
        exitCode: 0
    ))

    let failing = FakeMac(reply: .success(.failure("restore failed")), helperNotAtRecordedMode: ["27GL850", "M34WQ"])
    #expect(await run(failing, "rescue").stderr == "warning: the app failed (restore failed), so the restore helper ran; "
        + "27GL850 came back but not at its recorded mode; M34WQ came back but not at its recorded mode\n")
}

@Test func rescueBothFailExit1() async {
    let failing = FakeMac(reply: .success(.failure("restore failed")), helperWorks: false)
    #expect(await run(failing, "rescue") == RenderedOutput(
        stdout: "",
        stderr: "Failed. restore failed, and the restore helper failed\n",
        exitCode: 1
    ))
    #expect(failing.helperRuns == 1)

    let dead = FakeMac(appReady: false, helperWorks: false)
    #expect(await run(dead, "rescue") == RenderedOutput(
        stdout: "",
        stderr: "Failed. app not running, and the restore helper failed\n",
        exitCode: 1
    ))
    #expect(dead.helperRuns == 1 && dead.launches == 0)
}

@Test func rescueWithMissingHelperSaysSoInsteadOfRunningIt() async {
    let mac = FakeMac(appReady: false, helperProblem: "the restore helper is missing: /Helpers/porchlight-guardian")
    #expect(await run(mac, "rescue") == RenderedOutput(
        stdout: "",
        stderr: "Failed. app not running, and the restore helper is missing: /Helpers/porchlight-guardian\n",
        exitCode: 1
    ))
    #expect(mac.helperRuns == 0)
}

private let helperRefusedOutput = RenderedOutput(
    stdout: "",
    stderr: "Failed. refusing the restore helper under test overrides without AD_DRY_RUN=1\n",
    exitCode: 1
)

/// The real helper reads the real ledger and kills a live app, so a test setup must not reach it.
@Test(arguments: [
    ["AD_SOCKET_PATH": "/tmp/s.sock"],
    ["AD_STATE_DIR": "/tmp/state"],
    ["AD_SOCKET_PATH": "/tmp/s.sock", "AD_STATE_DIR": "/tmp/state"],
    ["AD_SOCKET_PATH": "/tmp/s.sock", "AD_DRY_RUN": "0"],
    ["AD_STATE_DIR": "/tmp/state", "AD_DRY_RUN": ""],
])
func rescueRefusesTheHelperUnderOverrides(environment: [String: String]) async {
    let mac = FakeMac(appReady: false)
    #expect(await run(mac, environment: environment, "rescue") == helperRefusedOutput)
    #expect(mac.helperRuns == 0 && mac.launches == 0)
}

@Test func rescueRefusesTheHelperWhenTheAppFailsUnderAnOverride() async {
    let mac = FakeMac(reply: .success(.failure("restore failed")))
    #expect(await run(mac, environment: ["AD_SOCKET_PATH": "/tmp/s.sock"], "rescue") == helperRefusedOutput)
    #expect(mac.sent.count == 1)
    #expect(mac.helperRuns == 0)
}

@Test func rescueRefusalComesBeforeAMissingHelper() async {
    let mac = FakeMac(appReady: false, helperProblem: "the restore helper is missing: /Helpers/porchlight-guardian")
    #expect(await run(mac, environment: ["AD_STATE_DIR": "/tmp/state"], "rescue") == helperRefusedOutput)
}

@Test func rescueUnderAnOverrideStillAsksALiveApp() async {
    let mac = FakeMac(reply: .success(.success()))
    let output = await run(mac, environment: ["AD_SOCKET_PATH": "/tmp/s.sock"], "rescue")
    #expect(output == RenderedOutput(stdout: "", stderr: "", exitCode: 0))
    #expect(mac.sent.map(\.request) == [CommandRequest(operations: ["rescue"])])
    #expect(mac.helperRuns == 0)
}

@Test(arguments: [
    ["AD_SOCKET_PATH": "/tmp/s.sock", "AD_DRY_RUN": "1"],
    ["AD_STATE_DIR": "/tmp/state", "AD_DRY_RUN": "1"],
    ["AD_SOCKET_PATH": "/tmp/s.sock", "AD_STATE_DIR": "/tmp/state", "AD_DRY_RUN": "1"],
    ["AD_DRY_RUN": "1"],
    ["AD_SOCKET_PATH": "", "AD_STATE_DIR": ""],
])
func rescueRunsTheHelperOtherwise(environment: [String: String]) async {
    let mac = FakeMac(appReady: false)
    let output = await run(mac, environment: environment, "rescue")
    #expect(output == RenderedOutput(stdout: "", stderr: "", exitCode: 0))
    #expect(mac.helperRuns == 1 && mac.launches == 0)
}

// MARK: - The real socket transport, against a server in this process

/// A private directory with a short path, because `sun_path` holds 103 bytes and `$TMPDIR` is long here.
private func withSocketPath(_ body: (String) async throws -> Void) async throws {
    var template = Array("/tmp/adcli.XXXXXX".utf8)
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
    handler: @escaping @Sendable (CommandRequest) async -> CommandResult = { _ in .success("pong") },
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

private let getRequest = CommandRequest(operations: ["get"])

/// With no socket, the runner launches at once instead of waiting out a 60 second timeout first.
@Test func transportFailsAtOnceWithNoSocket() async throws {
    try await withSocketPath { path in
        let transport = IPCTransport(client: IPCClient(path: path))
        let started = ContinuousClock.now
        await #expect(throws: IPCError.notRunning) {
            try await transport.send(getRequest, timeout: 60)
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }
}

@Test func transportWaitsOutAStartingServer() async throws {
    try await withServer(ready: false, handler: { _ in .success("on") }) { server, path in
        let transport = IPCTransport(client: IPCClient(path: path))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            server.setReady(true)
        }
        let result = try await transport.send(getRequest, timeout: 30)
        #expect(result == .success("on"))
    }
}

@Test func transportReportsAServerThatNeverFinishesStarting() async throws {
    try await withServer(ready: false) { _, path in
        let transport = IPCTransport(client: IPCClient(path: path))
        await #expect(throws: IPCError.timedOut) {
            try await transport.send(getRequest, timeout: 0.3)
        }
    }
}

@Test func transportPassesAFailureThrough() async throws {
    try await withServer(handler: { _ in .failure("no such display") }) { _, path in
        let transport = IPCTransport(client: IPCClient(path: path))
        let result = try await transport.send(getRequest, timeout: 5)
        #expect(result == .failure("no such display"))
    }
}

@Test func transportPingAnswersOnlyForAReadyServer() async throws {
    try await withSocketPath { path in
        #expect(await IPCTransport(client: IPCClient(path: path)).ping(timeout: 0.2) == false)
    }
    try await withServer(ready: false) { _, path in
        #expect(await IPCTransport(client: IPCClient(path: path)).ping(timeout: 0.2) == false)
    }
    try await withServer { _, path in
        #expect(await IPCTransport(client: IPCClient(path: path)).ping(timeout: 5))
    }
    try await withServer(handler: { _ in .failure("broken") }) { _, path in
        #expect(await IPCTransport(client: IPCClient(path: path)).ping(timeout: 5) == false)
    }
}

@Test func transportPingWaitsForAStartingServer() async throws {
    try await withServer(ready: false) { server, path in
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            server.setReady(true)
        }
        #expect(await IPCTransport(client: IPCClient(path: path)).ping(timeout: 30))
    }
}

// MARK: - The launcher and helper commands. `open` and the real helper are never run here.

@Test func launcherCommandIsExact() {
    #expect(AppLauncher.executable == "/usr/bin/open")
    #expect(AppLauncher.arguments == ["-g", "-a", "/Applications/PorchLight.app"])
}

@Test func helperOverrideWins() {
    let path = RescueRunner.helperPath(
        environment: ["AD_GUARDIAN_PATH": "/somewhere/else/porchlight-guardian"],
        executablePath: "/usr/bin/true"
    )
    #expect(path == "/somewhere/else/porchlight-guardian")
}

@Test func helperIsTheSiblingOfTheResolvedExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appending(component: "adcli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let helpers = root.appending(component: "Helpers")
    let bin = root.appending(component: "bin")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let binary = helpers.appending(component: "porchlight")
    try Data().write(to: binary)
    let link = bin.appending(component: "porchlight")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

    // An empty override counts as unset, the same as in `ADPaths`.
    let path = RescueRunner.helperPath(environment: ["AD_GUARDIAN_PATH": ""], executablePath: link.path)
    #expect(path?.hasSuffix("/\(root.lastPathComponent)/Helpers/porchlight-guardian") == true)
}

@Test func helperIsNilWhenTheExecutableCannotBeFound() {
    #expect(RescueRunner.helperPath(environment: [:], executablePath: nil) == nil)
    #expect(RescueRunner.helperPath(environment: [:], executablePath: "/no/such/porchlight") == nil)
}

/// With stand-ins for the helper, all named by `AD_GUARDIAN_PATH`.
@Test func helperResultFollowsItsExitStatus() async {
    let restored = HelperOutcome.restored(notAtRecordedMode: [])
    #expect(await RescueRunner(environment: ["AD_GUARDIAN_PATH": "/usr/bin/true"]).runRestoreHelper() == restored)
    #expect(await RescueRunner(environment: ["AD_GUARDIAN_PATH": "/usr/bin/false"]).runRestoreHelper() == .failed)
    #expect(await RescueRunner(environment: ["AD_GUARDIAN_PATH": "/no/such/porchlight-guardian"]).runRestoreHelper() == .failed)
}

/// A stand-in for `porchlight-guardian restore` that answers from a script, one run per entry: an exit
/// status and what it prints. It keeps a count beside itself, and the last entry repeats.
private func scriptedHelper(_ runs: [(status: Int32, stdout: [String])]) throws -> (path: String, runs: () -> Int) {
    let folder = FileManager.default.temporaryDirectory
        .appending(component: "ADCLITests-helper-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cases = runs.enumerated().map { index, run in
        let prints = run.stdout.map { "echo '\($0)'" }.joined(separator: "; ")
        let pattern = index == runs.count - 1 ? "*" : "\(index + 1)"
        return "\(pattern)) \(prints.isEmpty ? ":" : prints); exit \(run.status) ;;"
    }
    let script = """
        #!/bin/sh
        test "$1" = restore || exit 64
        count="$(dirname "$0")/count"
        n=$(( $(cat "$count" 2>/dev/null || echo 0) + 1 ))
        echo $n > "$count"
        case $n in
        \(cases.joined(separator: "\n"))
        esac
        """
    let path = folder.appending(component: "porchlight-guardian").path
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    let countFile = folder.appending(component: "count").path
    return (path, { Int((try? String(contentsOfFile: countFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 })
}

private func rescueRunner(_ path: String) -> RescueRunner {
    RescueRunner(environment: ["AD_GUARDIAN_PATH": path], retryDelay: 0.05)
}

/// Exit 3: every display is back, but one isn't at its recorded mode, and a fresh process may see it.
@Test func helperExit3IsRunOnceMoreAndASecondSuccessIsClean() async throws {
    let helper = try scriptedHelper([(3, ["M34WQ"]), (0, [])])

    #expect(await rescueRunner(helper.path).runRestoreHelper() == .restored(notAtRecordedMode: []))
    #expect(helper.runs() == 2)
}

/// The second child is the second fresh process in a row, so it accepts the mode as gone and exits 0,
/// still naming the display.
@Test func helperSecondRunAcceptingTheMissingModeIsASuccessWithItsName() async throws {
    let helper = try scriptedHelper([(3, ["M34WQ"]), (0, ["M34WQ"])])

    #expect(await rescueRunner(helper.path).runRestoreHelper() == .restored(notAtRecordedMode: ["M34WQ"]))
}

/// The monitors are on either way, so this exits 0 with the warning, and doesn't try a third time.
@Test func helperExit3TwiceIsStillASuccessWithTheNames() async throws {
    let helper = try scriptedHelper([(3, ["M34WQ"]), (3, ["M34WQ"])])

    #expect(await rescueRunner(helper.path).runRestoreHelper() == .restored(notAtRecordedMode: ["M34WQ"]))
    #expect(helper.runs() == 2)
}

/// The first run put every display back, and a second that fails takes nothing away from that.
@Test func helperFailingOnTheSecondRunKeepsTheFirstRunsNames() async throws {
    let helper = try scriptedHelper([(3, ["M34WQ"]), (1, [])])

    #expect(await rescueRunner(helper.path).runRestoreHelper() == .restored(notAtRecordedMode: ["M34WQ"]))
}

@Test func helperOtherFailuresAreNotRunAgain() async throws {
    let helper = try scriptedHelper([(1, []), (0, [])])

    #expect(await rescueRunner(helper.path).runRestoreHelper() == .failed)
    #expect(helper.runs() == 1)
}

@Test func helperSecondRunWaitsASecondByDefault() async throws {
    let helper = try scriptedHelper([(3, ["M34WQ"]), (0, [])])
    let started = Date()

    _ = await RescueRunner(environment: ["AD_GUARDIAN_PATH": helper.path]).runRestoreHelper()

    #expect(Date().timeIntervalSince(started) >= 1)
}

@Test func helperProblemNamesAMissingPath() {
    let missing = RescueRunner(environment: ["AD_GUARDIAN_PATH": "/no/such/porchlight-guardian"])
    #expect(missing.helperProblem == "the restore helper is missing: /no/such/porchlight-guardian")
    #expect(RescueRunner(environment: ["AD_GUARDIAN_PATH": "/usr/bin/true"]).helperProblem == nil)
    #expect(
        RescueRunner(environment: [:], executablePath: nil).helperProblem
            == "the restore helper can't be found, set AD_GUARDIAN_PATH"
    )
}

// MARK: - Waiting on a child process, with harmless programs

@Test func childExitStatusDecidesTheOutcome() throws {
    #expect(try ChildProcess.run(path: "/usr/bin/true", arguments: [], limit: 30, terminateAtLimit: true) == .succeeded)
    #expect(try ChildProcess.run(path: "/usr/bin/false", arguments: [], limit: 30, terminateAtLimit: true) == .failed)
    #expect(
        try ChildProcess.run(path: "/bin/sh", arguments: ["-c", "kill -9 $$"], limit: 30, terminateAtLimit: true)
            == .failed
    )
}

@Test func missingChildThrows() {
    #expect(throws: (any Error).self) {
        try ChildProcess.run(path: "/no/such/program", arguments: [], limit: 30, terminateAtLimit: true)
    }
}

/// `main` calls the launcher on the main actor, so the wait can't depend on the main thread.
@MainActor @Test func childWaitWorksOnTheMainActor() throws {
    #expect(try ChildProcess.run(path: "/usr/bin/true", arguments: [], limit: 30, terminateAtLimit: true) == .succeeded)
}

@Test func stuckChildIsTerminatedAtTheLimit() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(component: "adcli-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let outcome = try ChildProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "echo $$ > \"$0\"; exec sleep 30", pidFile.path],
        limit: 1,
        terminateAtLimit: true
    )
    #expect(outcome == .timedOut)
    #expect(try await exits(pidFile: pidFile))
}

/// `exec` keeps the ignored SIGTERM, so only SIGKILL can end this one before its 30 seconds are up.
@Test func childIgnoringTerminateIsKilledAfterTheGrace() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(component: "adcli-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let outcome = try ChildProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "trap '' TERM; echo $$ > \"$0\"; exec sleep 30", pidFile.path],
        limit: 1,
        terminateAtLimit: true,
        killGrace: 0.2
    )
    #expect(outcome == .timedOut)
    #expect(try await exits(pidFile: pidFile))
}

/// True if the process named in the file is gone within 5 seconds.
private func exits(pidFile: URL) async throws -> Bool {
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    for _ in 0..<100 {
        if kill(pid, 0) != 0 { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

// MARK: - The built binary. Only `otool` and `ping --no-launch`, which can't launch or restore anything.

private let builtBinary: URL? = {
    let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: ".build/debug/porchlight")
    return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
}()

private func capture(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String]? = nil
) async throws -> (stdout: String, status: Int32) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // On another thread, so an in-process server can still answer while this waits.
    let data = await withCheckedContinuation { continuation in
        DispatchQueue(label: "com.alexluncan.PorchLight.test.capture").async {
            continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
        }
    }
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

@Test(.enabled(if: builtBinary != nil, "porchlight isn't built at .build/debug"))
func binaryLinksNoAppKit() async throws {
    let binary = try #require(builtBinary)
    let (libraries, status) = try await capture(URL(fileURLWithPath: "/usr/bin/otool"), ["-L", binary.path])
    #expect(status == 0)
    #expect(libraries.contains("Foundation"))
    #expect(!libraries.contains("AppKit"))
}

@Test(.enabled(if: builtBinary != nil, "porchlight isn't built at .build/debug"))
func binaryPingsTheSocketInADSocketPath() async throws {
    let binary = try #require(builtBinary)
    try await withServer(handler: { request in
        request.operations == ["ping"] ? .success("pong") : .failure("unexpected request")
    }) { _, path in
        var environment = ProcessInfo.processInfo.environment
        environment["AD_SOCKET_PATH"] = path
        let (stdout, status) = try await capture(binary, ["ping", "--no-launch"], environment: environment)
        #expect(stdout == "pong\n")
        #expect(status == 0)
    }
}
