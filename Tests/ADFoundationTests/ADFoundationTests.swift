import Darwin
import Foundation
import Testing
@testable import ADFoundation

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(component: "ADFoundationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func permissions(of url: URL) -> mode_t {
    var info = stat()
    #expect(stat(url.path, &info) == 0)
    return info.st_mode & 0o777
}

/// Starts a child without Foundation's `Process`, so it stays a zombie until `reap` runs.
private func spawn(_ path: String, _ arguments: String...) throws -> pid_t {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let envp: [UnsafeMutablePointer<CChar>?] = [nil]
    let status = posix_spawn(&pid, path, nil, nil, argv, envp)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    return pid
}

private func spawnSleeper() throws -> pid_t {
    try spawn("/bin/sleep", "60")
}

/// Waits for the child and returns its raw wait status.
@discardableResult
private func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return status
}

private func stopSleeper(_ pid: pid_t) {
    Darwin.kill(pid, SIGKILL)
    reap(pid)
}

// MARK: - ADPaths

@Test func pathsDefaultUnderApplicationSupport() {
    let paths = ADPaths(environment: [:])
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let state = "\(home)/Library/Application Support/PorchLight"

    #expect(paths.stateDirectory.path == state)
    #expect(paths.logsDirectory.path == "\(home)/Library/Logs/PorchLight")
    #expect(paths.ledger.path == "\(state)/safety.json")
    #expect(paths.devices.path == "\(state)/devices.json")
    #expect(paths.presets.path == "\(state)/presets.json")
    #expect(paths.restoreLock.path == "\(state)/restore.lock")
    #expect(paths.appLock.path == "\(state)/app.lock")
    #expect(paths.socketPath == "\(state)/ctl.sock")
    #expect(paths.guardianSocketPath == "\(state)/guardian.sock")
}

@Test func pathsHonorEnvironmentOverrides() {
    let stateOnly = ADPaths(environment: ["AD_STATE_DIR": "/tmp/ad state"])
    #expect(stateOnly.stateDirectory.path == "/tmp/ad state")
    #expect(stateOnly.ledger.path == "/tmp/ad state/safety.json")
    #expect(stateOnly.devices.path == "/tmp/ad state/devices.json")
    #expect(stateOnly.presets.path == "/tmp/ad state/presets.json")
    #expect(stateOnly.restoreLock.path == "/tmp/ad state/restore.lock")
    #expect(stateOnly.appLock.path == "/tmp/ad state/app.lock")
    #expect(stateOnly.socketPath == "/tmp/ad state/ctl.sock")
    #expect(stateOnly.guardianSocketPath == "/tmp/ad state/guardian.sock")

    // The socket override moves the control socket and leaves the guardian's where it is.
    let both = ADPaths(environment: ["AD_STATE_DIR": "/tmp/ad state", "AD_SOCKET_PATH": "/tmp/other.sock"])
    #expect(both.socketPath == "/tmp/other.sock")
    #expect(both.guardianSocketPath == "/tmp/ad state/guardian.sock")
    #expect(both.stateDirectory.path == "/tmp/ad state")
}

/// Size per device: its file beside the presets, and Parsec's log and config, which a dry run can replace.
@Test func clientsAndTheParsecLog() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let defaults = ADPaths(environment: [:])
    #expect(defaults.clients.path == "\(home)/Library/Application Support/PorchLight/clients.json")
    #expect(defaults.parsecLog.path == "\(home)/.parsec/log.txt")
    #expect(defaults.parsecConfig.path == "\(home)/.parsec/config.json")

    let moved = ADPaths(environment: [
        "AD_STATE_DIR": "/tmp/ad state",
        "AD_PARSEC_LOG": "/tmp/fixture log.txt",
        "AD_PARSEC_CONFIG": "/tmp/fixture config.json",
    ])
    #expect(moved.clients.path == "/tmp/ad state/clients.json")
    #expect(moved.parsecLog.path == "/tmp/fixture log.txt")
    #expect(moved.parsecConfig.path == "/tmp/fixture config.json")
    #expect(ADPaths(environment: ["AD_PARSEC_LOG": ""]).parsecLog == defaults.parsecLog)
    #expect(ADPaths(environment: ["AD_PARSEC_CONFIG": ""]).parsecConfig == defaults.parsecConfig)
}

@Test func emptyOverridesCountAsUnset() {
    // An empty AD_STATE_DIR must not become the current directory.
    let paths = ADPaths(environment: ["AD_STATE_DIR": "", "AD_SOCKET_PATH": ""])
    let defaults = ADPaths(environment: [:])
    #expect(paths.stateDirectory == defaults.stateDirectory)
    #expect(paths.socketPath == defaults.socketPath)
}

@Test func longSocketPathFallsBackToTmp() {
    let longDirectory = "/tmp/" + String(repeating: "a", count: 120)
    let paths = ADPaths(environment: ["AD_STATE_DIR": longDirectory, "TMPDIR": "/tmp/ad-tmp/"])
    // The hashes are FNV-1a of each full original path, worked out outside Swift. Literals pin
    // the name across processes, which a per-process seeded hash would fail.
    #expect(paths.socketPath == "/tmp/ad-tmp/PorchLight.46b31829bbcbf948.ctl.sock")
    #expect(paths.guardianSocketPath == "/tmp/ad-tmp/PorchLight.f143e3f4a8909244.guardian.sock")
    // Only the sockets move. The state files have no length limit.
    #expect(paths.ledger.path == "\(longDirectory)/safety.json")
}

@Test func longSocketPathsStayDistinctPerStateDirectory() {
    func paths(_ letter: String) -> ADPaths {
        ADPaths(environment: ["AD_STATE_DIR": "/tmp/" + String(repeating: letter, count: 120), "TMPDIR": "/tmp/ad-tmp"])
    }

    #expect(paths("a").socketPath != paths("b").socketPath)
    #expect(paths("a").guardianSocketPath != paths("b").guardianSocketPath)

    #expect(paths("a").socketPath == paths("a").socketPath)
    #expect(paths("a").guardianSocketPath == paths("a").guardianSocketPath)
}

@Test func guardianSocketIsReachableThroughTheSocketOverride() {
    // The plan's smoke test: the guardian uses AD_STATE_DIR, and the CLI uses
    // AD_SOCKET_PATH=$AD_STATE_DIR/guardian.sock. Both must land on one path, long or short,
    // however the shell spelled the slashes.
    for directory in ["/tmp/short-state", "/tmp/" + String(repeating: "a", count: 120)] {
        for stateSpelling in [directory, directory + "/"] {
            let guardian = ADPaths(environment: ["AD_STATE_DIR": stateSpelling, "TMPDIR": "/tmp/ad-tmp"])
            let client = ADPaths(environment: [
                "AD_STATE_DIR": stateSpelling,
                "AD_SOCKET_PATH": "\(stateSpelling)/guardian.sock",
                "TMPDIR": "/tmp/ad-tmp",
            ])
            #expect(client.socketPath == guardian.guardianSocketPath)
        }
    }
}

@Test func socketPathLimitIsInBytesAndAllows103() {
    func socketPath(for path: String) -> String {
        ADPaths(environment: ["AD_SOCKET_PATH": path, "TMPDIR": "/tmp/ad-tmp"]).socketPath
    }
    func isFallback(_ path: String) -> Bool {
        path.hasPrefix("/tmp/ad-tmp/PorchLight.") && path.hasSuffix(".ctl.sock")
    }

    let at103 = "/" + String(repeating: "a", count: 93) + "/ctl.sock"
    let at104 = "/" + String(repeating: "a", count: 94) + "/ctl.sock"
    #expect(at103.utf8.count == 103)
    #expect(at104.utf8.count == 104)
    #expect(socketPath(for: at103) == at103)
    #expect(isFallback(socketPath(for: at104)))

    // Two bytes per character: short when counted in characters, too long in bytes.
    let multibyte = "/" + String(repeating: "\u{103}", count: 60) + "/ctl.sock"
    #expect(multibyte.count < 103)
    #expect(multibyte.utf8.count > 103)
    #expect(isFallback(socketPath(for: multibyte)))
}

@Test func fallbackSocketPathAlwaysFitsInSunPath() {
    let longDirectory = "/tmp/" + String(repeating: "a", count: 120)
    func fallback(tmp: String, socket: String) -> String {
        ADPaths(environment: ["AD_SOCKET_PATH": socket, "TMPDIR": tmp]).socketPath
    }
    func expectUsable(_ path: String) {
        #expect(path.utf8.count < 104, "\(path.utf8.count) bytes: \(path)")
    }

    // The length macOS really gives TMPDIR, with the longest socket name we use.
    let realisticTmp = "/var/folders/xx/" + String(repeating: "y", count: 32) + "/T/"
    let realistic = fallback(tmp: realisticTmp, socket: "\(longDirectory)/guardian.sock")
    expectUsable(realistic)
    #expect(realistic.hasSuffix(".guardian.sock"))

    // A long file name can't fit, so it gives way. The hash still tells two sockets apart.
    let longNameA = fallback(tmp: realisticTmp, socket: "/tmp/" + String(repeating: "c", count: 200))
    let longNameB = fallback(tmp: realisticTmp, socket: "/tmp/" + String(repeating: "d", count: 200))
    expectUsable(longNameA)
    expectUsable(longNameB)
    #expect(longNameA != longNameB)

    // Nothing fits under a TMPDIR this long, so the path leaves it, and is still distinct.
    let longTmp = "/tmp/" + String(repeating: "e", count: 200)
    let leftTmpA = fallback(tmp: longTmp, socket: "\(longDirectory)/ctl.sock")
    let leftTmpB = fallback(tmp: longTmp, socket: "\(longDirectory)/guardian.sock")
    expectUsable(leftTmpA)
    expectUsable(leftTmpB)
    #expect(leftTmpA != leftTmpB)
}

@Test func ensureStateDirectoryUses0700() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appending(path: "nested/state", directoryHint: .isDirectory)
    let paths = ADPaths(environment: ["AD_STATE_DIR": state.path])

    try paths.ensureStateDirectory()
    #expect(permissions(of: state) == 0o700)

    // An existing directory with a looser mode gets tightened, and running twice is fine.
    #expect(chmod(state.path, 0o755) == 0)
    try paths.ensureStateDirectory()
    #expect(permissions(of: state) == 0o700)
}

@Test func ensureStateDirectoryThrowsWhenAFileIsInTheWay() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(component: "not-a-directory")
    try Data().write(to: file)

    #expect(throws: (any Error).self) {
        try ADPaths(environment: ["AD_STATE_DIR": file.path]).ensureStateDirectory()
    }
}

// MARK: - AtomicFile

@Test func atomicWriteReplacesAndSets0600() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(component: "safety.json")
    try Data("old".utf8).write(to: file)
    #expect(chmod(file.path, 0o644) == 0)

    try AtomicFile.write(Data("new".utf8), to: file)

    #expect(try Data(contentsOf: file) == Data("new".utf8))
    #expect(permissions(of: file) == 0o600)
}

@Test func atomicWriteHonorsModeAndWritesEmptyData() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(component: "with space.json")

    try AtomicFile.write(Data(), to: file, mode: 0o640)

    #expect(try Data(contentsOf: file).isEmpty)
    #expect(permissions(of: file) == 0o640)
}

@Test func atomicWriteLeavesNoTempFileOnSuccess() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(component: "safety.json")

    try AtomicFile.write(Data("one".utf8), to: file)
    try AtomicFile.write(Data("two".utf8), to: file)

    // contentsOfDirectory(atPath:) includes hidden files.
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["safety.json"])
}

@Test func atomicWriteRemovesTempFileOnFailure() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Renaming a file over a directory fails, and by then the temp file exists.
    let destination = root.appending(component: "occupied", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

    #expect(throws: POSIXError.self) {
        try AtomicFile.write(Data("x".utf8), to: destination)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["occupied"])
}

@Test func atomicWriteThrowsWhenDirectoryIsMissing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: POSIXError.self) {
        try AtomicFile.write(Data("x".utf8), to: root.appending(path: "missing/file.json"))
    }
}

@Test func writeAllTreatsAZeroWriteAsAnError() {
    // If the zero isn't caught, the second call ends the loop with EBADF, so a regression
    // fails this test instead of hanging the run.
    var calls = 0
    do {
        try writeAll(Data("x".utf8), to: -1) { _, _, _ in
            calls += 1
            if calls == 1 { return 0 }
            errno = EBADF
            return -1
        }
        Issue.record("expected writeAll to throw")
    } catch {
        #expect(error as? POSIXError == POSIXError(.EIO))
    }
    #expect(calls == 1)
}

@Test func writeAllCarriesOnAfterPartialWritesAndInterruptions() throws {
    var written: [UInt8] = []
    var interrupted = false
    try writeAll(Data("abc".utf8), to: -1) { _, bytes, count in
        if !interrupted {
            interrupted = true
            errno = EINTR
            return -1
        }
        #expect(count == 3 - written.count)
        // One byte per call, so every call after the first is a partial write's follow-up.
        written.append(bytes.load(as: UInt8.self))
        return 1
    }
    #expect(written == Array("abc".utf8))
}

// MARK: - ADLog

@Test func appendLinePrefixesTimestampAndKeepsEarlierLines() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // The logs directory may not exist yet, so appendLine has to make it.
    let log = root.appending(path: "Logs/guardian.log")

    ADLog.appendLine("first", to: log)
    ADLog.appendLine("second", to: log)

    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    let first = #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2}) first/#
    let second = #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2}) second/#
    #expect(lines.first?.wholeMatch(of: first) != nil)
    #expect(lines.last?.wholeMatch(of: second) != nil)
}

@Test func appendLineSwallowsErrors() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(component: "file")
    try Data().write(to: file)

    // A regular file sits where the directory should be. This must return without trapping.
    ADLog.appendLine("lost", to: file.appending(path: "guardian.log"))

    #expect(try Data(contentsOf: file).isEmpty)
}

// MARK: - ADClock

@Test func autoAdvancingClockAdvancesOnSleep() async throws {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let clock = AutoAdvancingClock(start: start)
    #expect(clock.now() == start)

    // A real hour-long sleep would hang the test.
    try await clock.sleep(seconds: 3600)
    #expect(clock.now() == start.addingTimeInterval(3600))

    clock.advance(by: 2.5)
    #expect(clock.now() == start.addingTimeInterval(3602.5))

    // A wait computed from a deadline that already passed must not rewind time.
    try await clock.sleep(seconds: -5)
    #expect(clock.now() == start.addingTimeInterval(3602.5))
}

@Test func autoAdvancingClockThrowsWhenCancelledLikeARealSleep() async throws {
    let clock = AutoAdvancingClock()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await clock.sleep(seconds: 1)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

// MARK: - ProcessRef

@Test func currentProcessRefIsAlive() throws {
    let inspector = LiveProcessInspector()
    let ref = try #require(inspector.reference(forPID: getpid()))
    #expect(ref.pid == getpid())
    #expect(ref.startTime > 0)
    #expect(ref.startTime <= Date().timeIntervalSince1970)
    #expect(inspector.isAlive(ref))
}

@Test func processRefWithDifferentStartTimeIsNotAlive() throws {
    let inspector = LiveProcessInspector()
    let ref = try #require(inspector.reference(forPID: getpid()))
    #expect(!inspector.isAlive(ProcessRef(pid: ref.pid, startTime: ref.startTime + 1)))
}

@Test func processRefSurvivesAJSONRoundTrip() throws {
    // The ledger stores these as JSON, and a start time that shifted would read as a dead process.
    let inspector = LiveProcessInspector()
    let ref = try #require(inspector.reference(forPID: getpid()))
    let decoded = try JSONDecoder().decode(ProcessRef.self, from: JSONEncoder().encode(ref))
    #expect(decoded == ref)
    #expect(inspector.isAlive(decoded))
}

@Test func deadPIDIsNotAlive() throws {
    let inspector = LiveProcessInspector()
    let pid = try spawnSleeper()
    let ref = try #require(inspector.reference(forPID: pid))
    #expect(inspector.isAlive(ref))

    stopSleeper(pid)

    #expect(inspector.reference(forPID: pid) == nil)
    #expect(!inspector.isAlive(ref))
}

@Test func nonPositivePIDsHaveNoReference() {
    // kill(2) reads zero and negative PIDs as process groups, so these must never pass as alive.
    let inspector = LiveProcessInspector()
    #expect(inspector.reference(forPID: 0) == nil)
    #expect(inspector.reference(forPID: -1) == nil)
    #expect(!inspector.isAlive(ProcessRef(pid: 0, startTime: 0)))
    #expect(!inspector.isAlive(ProcessRef(pid: -1, startTime: 0)))
}

@Test func liveKillSendsSIGKILLAndAZombieCountsAsDead() async throws {
    let inspector = LiveProcessInspector()
    let pid = try spawnSleeper()
    let ref = try #require(inspector.reference(forPID: pid))

    inspector.kill(ref)

    // Not reaped yet, so the child is a zombie here. It must still read as dead.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while inspector.isAlive(ref), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!inspector.isAlive(ref))

    let status = reap(pid)
    #expect(status & 0x7f == SIGKILL)
}

@Test func liveKillLeavesAReusedPIDAlone() async throws {
    let inspector = LiveProcessInspector()
    let pid = try spawnSleeper()
    defer { stopSleeper(pid) }
    let ref = try #require(inspector.reference(forPID: pid))

    // Same PID, different start time: a stale reference to whatever used to have this PID.
    inspector.kill(ProcessRef(pid: ref.pid, startTime: ref.startTime + 1))

    try await Task.sleep(for: .milliseconds(100))
    #expect(inspector.isAlive(ref))
}

@Test func fakeInspectorIsSettableAndRecordsKills() {
    let running = ProcessRef(pid: 42, startTime: 100)
    let fake = FakeProcessInspector(alive: [running])

    #expect(fake.reference(forPID: 42) == running)
    #expect(fake.reference(forPID: 43) == nil)
    #expect(fake.isAlive(running))
    // The same PID with another start time is a different process.
    #expect(!fake.isAlive(ProcessRef(pid: 42, startTime: 101)))

    let stale = ProcessRef(pid: 42, startTime: 99)
    fake.kill(stale)
    #expect(fake.killed == [stale])
    #expect(fake.isAlive(running))

    fake.kill(running)
    #expect(fake.killed == [stale, running])
    #expect(!fake.isAlive(running))

    let other = ProcessRef(pid: 7, startTime: 1)
    fake.alive = [other]
    #expect(fake.isAlive(other))
}

// MARK: - BootSession

@Test func bootSessionIsNonEmptyAndStable() {
    let session = BootSession.current()
    #expect(!session.isEmpty)
    #expect(UUID(uuidString: session) != nil)
    #expect(BootSession.current() == session)
}

// MARK: - FileLock

@Test func fileLockExcludesSecondLock() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "restore.lock")
    let first = FileLock(url: url)
    let second = FileLock(url: url)

    try first.lock()
    #expect(!second.tryLock())

    first.unlock()
    #expect(second.tryLock())
    #expect(!first.tryLock())

    second.unlock()
    #expect(first.tryLock())
    first.unlock()
}

@Test func attemptLockTellsContentionFromFailure() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "restore.lock")
    let first = FileLock(url: url)
    let second = FileLock(url: url)

    #expect(first.attemptLock() == .acquired)
    #expect(first.attemptLock() == .acquired, "It already holds it")
    #expect(second.attemptLock() == .heldByOther)
    #expect(!second.tryLock())

    first.unlock()
    #expect(second.attemptLock() == .acquired)
    second.unlock()

    // A regular file where the lock's folder should be, so the lock file can't be created.
    let notAFolder = root.appending(component: "file")
    try Data().write(to: notAFolder)
    let broken = FileLock(url: notAFolder.appending(component: "restore.lock"))
    #expect(broken.attemptLock() == .failed)
    #expect(!broken.tryLock())
}

@Test func fileLockReleasesWhenDeallocated() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "app.lock")

    do {
        let held = FileLock(url: url)
        #expect(held.tryLock())
    }

    let next = FileLock(url: url)
    #expect(next.tryLock())
}

@Test func fileLockDescriptorIsCloseOnExec() throws {
    // A child that inherited the descriptor would keep the lock after this process died.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let viaLock = FileLock(url: root.appending(component: "a.lock"))
    try viaLock.lock()
    #expect(fcntl(viaLock.held, F_GETFD) & FD_CLOEXEC != 0)

    let viaTry = FileLock(url: root.appending(component: "b.lock"))
    #expect(viaTry.tryLock())
    #expect(fcntl(viaTry.held, F_GETFD) & FD_CLOEXEC != 0)
}

@Test func unlockReleasesAtOnceWhileOtherThreadsSpawn() async throws {
    // posix_spawn briefly copies every descriptor into the child, close-on-exec ones included.
    // If unlock only closed its descriptor, the lock would stay held until that copy closed.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "restore.lock")

    let spawners = (0..<4).map { _ in
        Task.detached {
            while !Task.isCancelled {
                if let pid = try? spawn("/usr/bin/true") { reap(pid) }
            }
        }
    }

    var failures = 0
    for _ in 0..<5000 {
        let holder = FileLock(url: url)
        try holder.lock()
        holder.unlock()

        let next = FileLock(url: url)
        if !next.tryLock() { failures += 1 }
        next.unlock()
    }

    spawners.forEach { $0.cancel() }
    for spawner in spawners { await spawner.value }
    #expect(failures == 0)
}

@Test func blockingLockWaitsForRelease() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(component: "restore.lock")
    let first = FileLock(url: url)
    try first.lock()

    let waiter = Task.detached { () throws -> ContinuousClock.Instant in
        let second = FileLock(url: url)
        try second.lock()
        return ContinuousClock.now
    }

    try await Task.sleep(for: .milliseconds(200))
    let released = ContinuousClock.now
    first.unlock()

    let acquired = try await waiter.value
    #expect(acquired >= released)
}

@Test func fileLockCreatesAMissingDirectoryAt0700() throws {
    // On the rescue path a missing folder must not read as contention, and on a fresh
    // install it must not read as another instance holding app.lock.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let viaTry = root.appending(path: "fresh/install/restore.lock")
    let first = FileLock(url: viaTry)
    #expect(first.tryLock())
    #expect(permissions(of: root.appending(path: "fresh")) == 0o700)
    #expect(permissions(of: root.appending(path: "fresh/install")) == 0o700)
    // It's a real lock, not just a created file.
    #expect(!FileLock(url: viaTry).tryLock())
    first.unlock()

    let viaLock = root.appending(path: "other/app.lock")
    let second = FileLock(url: viaLock)
    try second.lock()
    #expect(permissions(of: root.appending(path: "other")) == 0o700)
    #expect(!FileLock(url: viaLock).tryLock())
}

@Test func fileLockFailsWhenAFileIsInTheWay() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(component: "not-a-directory")
    try Data().write(to: file)
    let lock = FileLock(url: file.appending(path: "restore.lock"))

    #expect(throws: POSIXError.self) { try lock.lock() }
    #expect(!lock.tryLock())
}

// MARK: - TestBundleGuard

// Nothing here calls preconditionMutationAllowed: in this process it would crash the test runner.

@Test func testBundleGuardDetectsTestBundle() {
    #expect(TestBundleGuard.isRunningInTestBundle)
}

@Test func testImagePathCheckMatchesOnlyTestImages() {
    // A false positive would crash the app or the guardian at its first live mutation.
    let ordinary = [
        // Loads in real processes. Only the marker's leading slash keeps it from matching.
        "/System/Library/PrivateFrameworks/RecapPerformanceTesting.framework/Versions/A/RecapPerformanceTesting",
        "/System/Library/PrivateFrameworks/XCTestSupport.framework/Versions/A/XCTestSupport",
        "/Applications/PorchLight.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
    ]
    for path in ordinary {
        #expect(!TestBundleGuard.isTestImagePath(path), "\(path)")
    }

    let developer = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    let tests = [
        "/Users/me/repo/.build/arm64-apple-macosx/debug/PorchLightKitPackageTests.xctest/Contents/MacOS/PorchLightKitPackageTests",
        "\(developer)/XCTest.framework/Versions/A/XCTest",
        "\(developer)/Testing.framework/Versions/A/Testing",
    ]
    for path in tests {
        #expect(TestBundleGuard.isTestImagePath(path), "\(path)")
    }
}

@Test func mutationIsBlockedOnlyInATestBundleWithoutHIL() {
    #expect(TestBundleGuard.isMutationAllowed(inTestBundle: false, hil: nil))
    #expect(TestBundleGuard.isMutationAllowed(inTestBundle: false, hil: "0"))
    #expect(TestBundleGuard.isMutationAllowed(inTestBundle: true, hil: "1"))
    #expect(!TestBundleGuard.isMutationAllowed(inTestBundle: true, hil: nil))
    #expect(!TestBundleGuard.isMutationAllowed(inTestBundle: true, hil: "0"))
    #expect(!TestBundleGuard.isMutationAllowed(inTestBundle: true, hil: ""))
    #expect(!TestBundleGuard.isMutationAllowed(inTestBundle: true, hil: "true"))
}
