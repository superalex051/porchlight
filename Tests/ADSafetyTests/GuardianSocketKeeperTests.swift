import ADFoundation
import ADSafety
import Foundation
import Synchronization
import Testing

private struct SocketFailure: Error, CustomStringConvertible {
    var description: String { "no space left on device" }
}

/// Stands in for the socket, the other guardian and the process.
private final class World: Sendable {
    private struct State {
        var startResults: [Bool] = []
        var startCount = 0
        var startTimes: [Date] = []
        var pingAnswers: [Bool] = []
        var pingCount = 0
        var exitCount = 0
        var lines: [String] = []
    }

    private let state = Mutex(State())
    let clock = AutoAdvancingClock()

    /// `starts` and `answers` are used in order, and the last one repeats.
    init(starts: [Bool], answers: [Bool] = [false]) {
        state.withLock {
            $0.startResults = starts
            $0.pingAnswers = answers
        }
    }

    var startCount: Int { state.withLock { $0.startCount } }
    var startTimes: [Date] { state.withLock { $0.startTimes } }
    var pingCount: Int { state.withLock { $0.pingCount } }
    var exitCount: Int { state.withLock { $0.exitCount } }
    var lines: [String] { state.withLock { $0.lines } }

    func keeper() -> GuardianSocketKeeper {
        GuardianSocketKeeper(
            start: { [self] in try start() },
            anotherGuardianAnswers: { [self] in answer() },
            clock: clock,
            log: { [self] line in state.withLock { $0.lines.append(line) } },
            exit: { [self] in state.withLock { $0.exitCount += 1 } }
        )
    }

    private func start() throws {
        let now = clock.now()
        let succeeds = state.withLock { state in
            let result = state.startResults[min(state.startCount, state.startResults.count - 1)]
            state.startCount += 1
            state.startTimes.append(now)
            return result
        }
        if !succeeds { throw SocketFailure() }
    }

    private func answer() -> Bool {
        state.withLock { state in
            let result = state.pingAnswers[min(state.pingCount, state.pingAnswers.count - 1)]
            state.pingCount += 1
            return result
        }
    }
}

@Test func aSocketThatOpensNeedsNoPingAndDoesNotExit() async {
    let world = World(starts: [true])

    let outcome = await world.keeper().attempt()

    #expect(outcome == .listening)
    #expect(world.pingCount == 0)
    #expect(world.exitCount == 0)
    #expect(world.lines.isEmpty)
}

@Test func anotherGuardianAnsweringExits() async {
    let world = World(starts: [false], answers: [true])

    let outcome = await world.keeper().attempt()

    #expect(outcome == .anotherGuardianIsListening)
    #expect(world.exitCount == 1, "Two guardians would both act on the same ledger")
    #expect(world.lines.contains { $0.contains("another guardian") })
}

/// A full disk or a stray file at the socket path, say. A live session still needs watching.
@Test func anyOtherFailureDoesNotExit() async {
    let world = World(starts: [false], answers: [false])

    let outcome = await world.keeper().attempt()

    #expect(outcome == .failed)
    #expect(world.startCount == 1, "It returns at once, so the watching loop can start")
    #expect(world.exitCount == 0)
    #expect(world.lines.count == 1)
    #expect(world.lines.first?.contains("no space left on device") == true, "The log says why")
}

@Test func keepTryingEndsOnceTheSocketOpens() async {
    let world = World(starts: [false, false, true])

    await world.keeper().keepTrying()

    #expect(world.startCount == 3)
    #expect(world.exitCount == 0)
    #expect(world.lines.last == "the guardian socket is up")
}

@Test func keepTryingWaitsBetweenTries() async throws {
    let world = World(starts: [false, false, true])

    await world.keeper().keepTrying()

    let times = world.startTimes
    #expect(times.count == 3)
    for (earlier, later) in zip(times, times.dropFirst()) {
        #expect(later.timeIntervalSince(earlier) == GuardianSocketKeeper.retryInterval)
    }
    #expect(GuardianSocketKeeper.retryInterval == 5)
}

@Test func keepTryingExitsIfAnotherGuardianTurnsUp() async {
    let world = World(starts: [false], answers: [false, false, true])

    await world.keeper().keepTrying()

    #expect(world.startCount == 3)
    #expect(world.exitCount == 1)
}

@Test func keepTryingStopsWhenCancelled() async {
    let world = World(starts: [false])
    let keeper = world.keeper()

    let task = Task { await keeper.keepTrying() }
    task.cancel()
    await task.value

    #expect(world.exitCount == 0)
}
