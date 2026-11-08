import ADFoundation
import Darwin
import Foundation
import Testing

private func isRunning(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// Polls with a real clock, because these tests are about real processes.
private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func temporaryPIDFile() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(component: "BoundedProcessTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(component: "pid", directoryHint: .notDirectory)
}

private func readPID(from file: URL) throws -> Int32 {
    let text = try String(contentsOf: file, encoding: .utf8)
    return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}

@Test func anExitOfZeroSucceeds() throws {
    let outcome = try BoundedProcess.run(path: "/usr/bin/true", arguments: [], limit: 10, atLimit: .leaveRunning)
    #expect(outcome == .succeeded)
}

@Test func anyOtherExitFails() throws {
    let outcome = try BoundedProcess.run(path: "/usr/bin/false", arguments: [], limit: 10, atLimit: .leaveRunning)
    #expect(outcome == .failed)
}

@Test func aProgramKilledBySignalFails() throws {
    let outcome = try BoundedProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "kill -KILL $$"],
        limit: 10,
        atLimit: .leaveRunning
    )
    #expect(outcome == .failed)
}

@Test func aProgramThatCannotStartThrows() {
    #expect(throws: (any Error).self) {
        try BoundedProcess.run(path: "/nonexistent/program", arguments: [], limit: 10, atLimit: .leaveRunning)
    }
}

@Test func argumentsReachTheProgram() throws {
    let outcome = try BoundedProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "test \"$1\" = restore", "sh", "restore"],
        limit: 10,
        atLimit: .leaveRunning
    )
    #expect(outcome == .succeeded)
}

/// How the guardian and the CLI read `adguardian restore`: its exit status, and the names on stdout.
@Test func capturingGivesTheStatusAndWhatWasWrittenToStdout() throws {
    let completion = try BoundedProcess.runCapturingOutput(
        path: "/bin/sh",
        arguments: ["-c", "echo 27GL850; echo; echo M34WQ; echo noise >&2; exit 3"],
        limit: 10,
        atLimit: .stop(killGrace: 5)
    )

    #expect(completion.status == RestoreHelperExit.modesNotRestored)
    #expect(completion.outcome == .failed, "Only exit 0 counts as succeeded, so the guardian retries")
    #expect(completion.outputLines == ["27GL850", "M34WQ"])
}

@Test func capturingReportsNoStatusForASignal() throws {
    let completion = try BoundedProcess.runCapturingOutput(
        path: "/bin/sh",
        arguments: ["-c", "kill -KILL $$"],
        limit: 10,
        atLimit: .stop(killGrace: 5)
    )

    #expect(completion.status == nil)
    #expect(completion.outcome == .failed)
}

/// More than a pipe holds, so a reader that waited for the exit would never see one.
@Test func capturingReadsALongOutputWithoutStalling() throws {
    let completion = try BoundedProcess.runCapturingOutput(
        path: "/bin/sh",
        arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do echo line-$i; i=$((i+1)); done"],
        limit: 10,
        atLimit: .stop(killGrace: 5)
    )

    #expect(completion.status == 0)
    #expect(completion.outputLines.count == 20_000)
}

@Test func leaveRunningReturnsAtTheLimitAndTheProgramGoesOn() throws {
    let file = try temporaryPIDFile()
    let started = Date()

    let outcome = try BoundedProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "sh", file.path],
        limit: 1,
        atLimit: .leaveRunning
    )

    #expect(outcome == .timedOut)
    #expect(Date().timeIntervalSince(started) < 10, "A hung program must not hold up the caller")
    let pid = try readPID(from: file)
    #expect(isRunning(pid))
    kill(pid, SIGKILL)
}

@Test func stopEndsTheProgramWithSIGTERMWithoutWaitingOutTheGrace() async throws {
    let file = try temporaryPIDFile()
    let started = Date()

    let outcome = try BoundedProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "sh", file.path],
        limit: 1,
        atLimit: .stop(killGrace: 20)
    )

    #expect(outcome == .timedOut)
    #expect(Date().timeIntervalSince(started) < 15, "SIGTERM ended it, so the grace wasn't used up")
    let pid = try readPID(from: file)
    #expect(try await waitUntil { !isRunning(pid) })
}

@Test func stopSendsSIGKILLAfterTheGraceToAProgramIgnoringSIGTERM() async throws {
    let file = try temporaryPIDFile()

    let outcome = try BoundedProcess.run(
        path: "/bin/sh",
        arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do /bin/sleep 0.1; done", "sh", file.path],
        limit: 1,
        atLimit: .stop(killGrace: 0.5)
    )

    #expect(outcome == .timedOut)
    let pid = try readPID(from: file)
    #expect(try await waitUntil { !isRunning(pid) })
}
