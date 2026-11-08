import ADCommand
import ADFoundation
import ADModel
import Foundation
import Testing

@testable import ADEngine

private let active = SessionStatus(state: .active, client: "ipad", displayID: 41, hiDPI: true, hz: 60)
private let resized = SessionStatus(state: .active, client: "ipad", displayID: 42, hiDPI: true, hz: 60)
private let idle = SessionStatus(state: .idle)

@MainActor
@Suite struct SessionChangeFeedTests {
    @Test func changesAreNumberedFromOneAndComeBackInOrder() async {
        let feed = SessionChangeFeed(clock: AutoAdvancingClock())
        #expect(feed.latest == 0)

        feed.record(active)
        feed.record(idle)

        #expect(feed.latest == 2)
        #expect(await feed.change(after: 0, waitingUpTo: 0) == SessionChangeFeed.Change(number: 1, status: active))
        #expect(await feed.change(after: 1, waitingUpTo: 0) == SessionChangeFeed.Change(number: 2, status: idle))
        #expect(await feed.change(after: 2, waitingUpTo: 0) == nil)
    }

    @Test func aWaitEndsAtTheNextChange() async throws {
        let feed = SessionChangeFeed(clock: SystemClock())
        let started = ContinuousClock.now
        let waiting = Task { await feed.change(after: 0, waitingUpTo: 30) }
        try await Task.sleep(for: .milliseconds(50))

        feed.record(active)

        #expect(await waiting.value == SessionChangeFeed.Change(number: 1, status: active))
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func aWaitWithNoChangeEndsAtItsLimit() async {
        let clock = AutoAdvancingClock()
        let feed = SessionChangeFeed(clock: clock)
        feed.record(active)

        #expect(await feed.change(after: 1, waitingUpTo: 15) == nil)
        #expect(clock.now() == Date(timeIntervalSinceReferenceDate: 15))
    }

    @Test func closingEndsEveryWaitAndLaterOnesDontWait() async throws {
        let feed = SessionChangeFeed(clock: SystemClock())
        let waiting = Task { await feed.change(after: 0, waitingUpTo: 30) }
        try await Task.sleep(for: .milliseconds(50))

        feed.close()

        #expect(await waiting.value == nil)
        let started = ContinuousClock.now
        #expect(await feed.change(after: 0, waitingUpTo: 30) == nil)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func onlyTheLatest32AreKept() async {
        let feed = SessionChangeFeed(clock: AutoAdvancingClock())
        for _ in 1...40 { feed.record(active) }

        #expect(feed.latest == 40)
        #expect(await feed.change(after: 0, waitingUpTo: 0)?.number == 9, "A watcher that fell behind gets the oldest one kept")
    }

    @Test func eachFeedIsItsOwnInstance() {
        #expect(SessionChangeFeed(clock: AutoAdvancingClock()).instance != SessionChangeFeed(clock: AutoAdvancingClock()).instance)
    }
}

/// What a `session watch` answer carries.
private struct WatchAnswer {
    var payload: String?
    var instance: String
    var change: Int
    var status: JSONValue
    var apiVersion: JSONValue?

    init(_ result: CommandResult) throws {
        #expect(result.ok, "\(result.reason ?? "")")
        guard case .object(let fields)? = result.json,
            case .string(let instance)? = fields["instance"],
            case .number(let change)? = fields["change"],
            let status = fields["status"]
        else {
            Issue.record("not a watch answer: \(String(describing: result.json))")
            throw CancellationError()
        }
        payload = result.payload
        self.instance = instance
        self.change = Int(change)
        self.status = status
        apiVersion = fields["apiVersion"]
    }
}

@MainActor
@Suite struct SessionWatchCommandTests {
    @Test func theFirstAnswerIsTheStatusNow() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=ipad", "-lookslike=1180x820").ok)

        let answer = try WatchAnswer(try await rig.result("session", "watch"))

        let now = rig.rig.session.status()
        #expect(answer.instance == rig.dispatcher.sessionChanges.instance)
        #expect(answer.change == 0)
        #expect(answer.status == now.asJSON)
        #expect(answer.payload == now.statusLine)
        #expect(answer.apiVersion == .number(1))
    }

    @Test func eachChangeComesBackInOrder() async throws {
        let rig = try DispatcherRig()
        let feed = rig.dispatcher.sessionChanges
        feed.record(active)
        feed.record(resized)
        feed.record(idle)

        var after = 0
        var seen: [JSONValue] = []
        for _ in 0..<3 {
            let answer = try WatchAnswer(
                try await rig.result("session", "watch", "-instance=\(feed.instance)", "-after=\(after)", "-wait=5")
            )
            #expect(answer.change == after + 1)
            after = answer.change
            seen.append(answer.status)
        }

        #expect(seen == [active.asJSON, resized.asJSON, idle.asJSON])
    }

    @Test func noChangeAnswersWithTheSameNumberOnceTheWaitIsOver() async throws {
        let rig = try DispatcherRig()
        let feed = rig.dispatcher.sessionChanges
        feed.record(idle)
        let before = rig.rig.clock.now()

        let answer = try WatchAnswer(
            try await rig.result("session", "watch", "-instance=\(feed.instance)", "-after=1", "-wait=5")
        )

        #expect(answer.change == 1)
        #expect(answer.status == rig.rig.session.status().asJSON)
        #expect(rig.rig.clock.now().timeIntervalSince(before) == 5)
    }

    /// Another run of the app, no run named at all, and a number this run hasn't reached.
    @Test(arguments: [("another-run", "0"), (nil, "0"), ("this run", "7")])
    func aRequestForAnotherRunOrAnUnknownNumberStartsOverAtOnce(_ instance: String?, _ after: String) async throws {
        let rig = try DispatcherRig()
        let feed = rig.dispatcher.sessionChanges
        feed.record(active)
        feed.record(idle)
        let named = instance.map { ["-instance=\($0 == "this run" ? feed.instance : $0)"] } ?? []
        let before = rig.rig.clock.now()

        let answer = try WatchAnswer(try await rig.result(["session", "watch"] + named + ["-after=\(after)", "-wait=5"]))

        #expect(answer.instance == feed.instance)
        #expect(answer.change == 2)
        #expect(answer.status == rig.rig.session.status().asJSON)
        #expect(rig.rig.clock.now() == before, "It didn't wait")
    }

    @Test(arguments: [
        (["-after=soon"], "invalid after: soon"),
        (["-after"], "invalid after: no value"),
        (["-wait=61"], "invalid wait: 61"),
        (["-wait=-1"], "invalid wait: -1"),
        (["-lookslike=1920x1080"], "unknown parameter: lookslike"),
        (["-after=1", "-after=2"], "repeated parameter: after"),
    ])
    func badParametersAreRefused(_ parameters: [String], _ reason: String) async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run(["session", "watch"] + parameters) == .failed(reason))
    }

    @Test func watchIsASessionWord() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "watch", "now") == .failed("unknown session operation: watch now; use start, end, resize, status, watch or presets"))
    }
}
