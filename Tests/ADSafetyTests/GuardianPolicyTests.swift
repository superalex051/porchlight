import ADFoundation
import ADSafety
import Foundation
import Testing

/// Walks the policy through time. Each `at` is seconds after the session started, and
/// the memory carries from call to call the way the runner carries it from tick to tick.
private struct Scenario {
    var ledger: SafetyLedger? = makeLedger()
    var boot = testBoot
    var appAlive = true
    var deadOwners: [ProcessRef] = []
    var memory = GuardianMemory()

    mutating func decide(at seconds: Double, ping: Bool? = nil) -> GuardianDecision {
        let observation = GuardianObservation(
            ledger: ledger,
            currentBoot: boot,
            appAlive: appAlive,
            appPingOK: ping,
            deadOwners: deadOwners,
            now: sessionStart.addingTimeInterval(seconds)
        )
        return GuardianPolicy.decide(observation, memory: &memory)
    }

    /// Runs up to the moment a relaunch is under way, with the app not yet back.
    mutating func relaunch(at seconds: Double) {
        appAlive = false
        #expect(decide(at: seconds) == .relaunchApp)
    }

    /// The relaunched app came up and answered.
    mutating func recover(at seconds: Double) {
        appAlive = true
        #expect(decide(at: seconds, ping: true) == .idle)
    }

    /// Answers every 2 seconds, and returns when the next ping is due.
    mutating func answer(from start: Double, for seconds: Double) -> Double {
        for now in stride(from: start, through: start + seconds, by: 2) {
            #expect(decide(at: now, ping: true) == .idle)
        }
        return start + seconds + 2
    }

    /// Stops answering until it's killed, and returns when that was. The app is then dead.
    mutating func hangUntilKilled(from start: Double) -> Double {
        for now in stride(from: start, through: start + 60, by: 2) {
            if decide(at: now, ping: false) == .killApp {
                appAlive = false
                return now
            }
        }
        Issue.record("the app was never killed")
        return start
    }
}

// MARK: - The timings, from the spec

@Test func timingsMatchTheSpec() {
    #expect(GuardianPolicy.relaunchWindow == 10)
    #expect(GuardianPolicy.hungAfter == 15)
    #expect(GuardianPolicy.endWait == 8)
    #expect(GuardianPolicy.maxRelaunches == 2)
    #expect(GuardianPolicy.maxRestores == 3)
    #expect(GuardianPolicy.restoreSpacing == 5)
    #expect(GuardianPolicy.restoreRetryInterval == 60)
    #expect(GuardianPolicy.frozenAfter == 60)
    #expect(GuardianPolicy.hungKillsBeforeRestore == 2)
    #expect(GuardianPolicy.healthyStretchResetsBudget == 300)
}

// MARK: - No ledger, or rescued: nothing

@Test func noLedgerIsIdle() {
    var scenario = Scenario(ledger: nil, appAlive: false)
    #expect(scenario.decide(at: 0) == .idle)
    #expect(scenario.decide(at: 1000) == .idle)
}

@Test func rescuedIsIdle() {
    var scenario = Scenario(ledger: makeLedger(state: .rescued), appAlive: false, deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0) == .idle)
    #expect(scenario.decide(at: 1000) == .idle)
}

@Test(arguments: [nil, LedgerState.rescued])
func neverRelaunchesOrRestoresOutsideASession(state: LedgerState?) {
    for appAlive in [true, false] {
        for ping in [nil, true, false] as [Bool?] {
            var scenario = Scenario(
                ledger: state.map { makeLedger(state: $0) },
                appAlive: appAlive,
                deadOwners: [ownerRef]
            )
            for second in stride(from: 0.0, through: 200, by: 0.25) {
                #expect(scenario.decide(at: second, ping: ping) == .idle)
            }
        }
    }
}

// MARK: - Another boot

@Test func staleBootDiscards() {
    var scenario = Scenario(ledger: makeLedger(boot: otherBoot), appAlive: false)
    #expect(scenario.decide(at: 0) == .discardLedger)
}

@Test func staleBootDiscardsEvenWithADeadOwner() {
    var scenario = Scenario(ledger: makeLedger(boot: otherBoot), appAlive: false, deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0) == .discardLedger)
}

/// `BootSession.current()` returns "" if its sysctl fails. Discarding on that would throw away a
/// live session's records and leave the monitors dark.
@Test func emptyCurrentBootDoesNotDiscard() {
    var healthy = Scenario(boot: "")
    #expect(healthy.decide(at: 0, ping: true) == .idle)

    var appDead = Scenario(boot: "", appAlive: false)
    #expect(appDead.decide(at: 0) == .relaunchApp)
}

@Test func emptyLedgerBootDoesNotDiscard() {
    var healthy = Scenario(ledger: makeLedger(boot: ""))
    #expect(healthy.decide(at: 0, ping: true) == .idle)

    var appDead = Scenario(ledger: makeLedger(boot: ""), appAlive: false)
    #expect(appDead.decide(at: 0) == .relaunchApp)

    var bothUnknown = Scenario(ledger: makeLedger(boot: ""), boot: "")
    #expect(bothUnknown.decide(at: 0, ping: true) == .idle)
}

// MARK: - App healthy

@Test(arguments: [LedgerState.starting, .active, .ending])
func healthyIsIdle(state: LedgerState) {
    var scenario = Scenario(ledger: makeLedger(state: state))
    #expect(scenario.decide(at: 0, ping: true) == .idle)
    // Between pings there's no new answer, and the app is still healthy.
    #expect(scenario.decide(at: 0.25) == .idle)
    #expect(scenario.decide(at: 1.75) == .idle)
    #expect(scenario.decide(at: 2, ping: true) == .idle)
}

// MARK: - App healthy, an owner died

@Test(arguments: [LedgerState.starting, .active, .ending])
func ownerDiedAsksAppToEnd(state: LedgerState) {
    var scenario = Scenario(ledger: makeLedger(state: state), deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)
    // Asked once, not on every tick.
    #expect(scenario.decide(at: 0.25) == .waitForApp)
    #expect(scenario.decide(at: 2, ping: true) == .waitForApp)
}

@Test func ownerDiedEndTimesOutRestores() {
    var scenario = Scenario(deadOwners: [ownerRef])
    #expect(scenario.decide(at: 100, ping: true) == .askAppToEnd)
    #expect(scenario.decide(at: 107.75) == .waitForApp)
    #expect(scenario.decide(at: 108) == .restore)
}

@Test func endingWithAdvancingUpdatedAtKeepsWaiting() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)

    // Long past the 8 seconds, but the restorer keeps moving `updatedAt`.
    for second in stride(from: 8.0, through: 40, by: 1) {
        scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(second - 1))
        #expect(scenario.decide(at: second, ping: true) == .waitForApp)
    }

    // Then it stops. Exactly 8 seconds after its last move is too long.
    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(40))
    #expect(scenario.decide(at: 47.75, ping: true) == .waitForApp)
    #expect(scenario.decide(at: 48, ping: true) == .restore)
}

@Test func endingWithAStaleUpdatedAtRestoresOnTime() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), deadOwners: [ownerRef])
    #expect(scenario.decide(at: 100, ping: true) == .askAppToEnd)
    #expect(scenario.decide(at: 108, ping: true) == .restore)
}

@Test func movingUpdatedAtOnlyHoldsOffARestoreWhileEnding() {
    var scenario = Scenario(deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)
    scenario.ledger = makeLedger(state: .active, updatedAt: sessionStart.addingTimeInterval(7))
    #expect(scenario.decide(at: 8, ping: true) == .restore)
}

@Test func updatedAtFromTheFutureDoesNotHoldOffARestore() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)
    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(3600))
    #expect(scenario.decide(at: 8, ping: true) == .restore)
}

/// An end request is about the owner that died. If that owner leaves the ledger, the next death
/// gets its own request and its own 8 seconds, not an instant restore.
@Test func anEndRequestEndsWhenNoOwnerIsDead() {
    var scenario = Scenario(deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)

    scenario.deadOwners = []
    #expect(scenario.decide(at: 2, ping: true) == .idle)
    #expect(scenario.memory.endRequestedAt == nil)

    scenario.deadOwners = [ownerRef]
    #expect(scenario.decide(at: 100, ping: true) == .askAppToEnd)
    #expect(scenario.decide(at: 107.75) == .waitForApp)
}

@Test func ownerDiedWithASilentAppStillAsksAndThenRestores() {
    var scenario = Scenario(deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: false) == .askAppToEnd)
    #expect(scenario.decide(at: 4, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 8, ping: false) == .restore)
}

// MARK: - App dead

@Test(arguments: [LedgerState.starting, .active, .ending])
func appDeadOwnerDeadRestores(state: LedgerState) {
    var scenario = Scenario(ledger: makeLedger(state: state), appAlive: false, deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0) == .restore)
}

@Test(arguments: [LedgerState.starting, .active, .ending])
func appDeadRelaunches(state: LedgerState) {
    var scenario = Scenario(ledger: makeLedger(state: state), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)
    // One relaunch, then a wait for it to work.
    #expect(scenario.decide(at: 0.25) == .waitForApp)
    #expect(scenario.decide(at: 9.75) == .waitForApp)
}

@Test func missingAppReferenceIsADeadApp() {
    // The runner reports a ledger with no app as not alive. A ledger like this still relaunches.
    var scenario = Scenario(ledger: makeLedger(app: nil), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)
}

/// "Healthy" needs the ledger's process alive too. A stray answer on the socket doesn't count.
@Test func anAnswerFromADeadReferenceIsNotHealthy() {
    var scenario = Scenario(appAlive: false)
    #expect(scenario.decide(at: 0, ping: true) == .relaunchApp)
    #expect(scenario.decide(at: 5, ping: true) == .waitForApp)
    #expect(scenario.decide(at: 10, ping: true) == .restore)
}

// MARK: - Relaunched, not healthy within 10 seconds

@Test(arguments: [LedgerState.starting, .active, .ending])
func relaunchNotHealthyIn10sRestores(state: LedgerState) {
    var scenario = Scenario(ledger: makeLedger(state: state), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)
    #expect(scenario.decide(at: 9.75) == .waitForApp)
    #expect(scenario.decide(at: 10) == .restore)
}

@Test func relaunchedAliveButSilentRestoresAt10s() {
    var scenario = Scenario(appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)

    // The new app has written its reference to the ledger, and doesn't answer.
    scenario.appAlive = true
    #expect(scenario.decide(at: 2, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 9.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 10, ping: false) == .restore)
}

@Test func relaunchedAppThatAnswersIsHealthy() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.appAlive = true
    #expect(scenario.decide(at: 3, ping: true) == .idle)
    // The window is over, so 10 seconds passing means nothing now.
    #expect(scenario.decide(at: 30, ping: true) == .idle)
}

@Test func relaunchedAppFinishingAnEndIsLeftToFinishWhileItProgresses() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)

    // The window has passed, but something is moving `updatedAt`: the new app, running the end sequence.
    for second in stride(from: 10.0, through: 30, by: 1) {
        scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(second - 1))
        #expect(scenario.decide(at: second) == .waitForApp)
    }

    // It stops moving, so the restore goes ahead.
    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(30))
    #expect(scenario.decide(at: 37.75) == .waitForApp)
    #expect(scenario.decide(at: 38) == .restore)
}

@Test func relaunchedAppThatIsAliveAndFinishingAnEndIsAlsoLeftToFinish() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)

    // The same, with the new app's reference in the ledger. Its socket says busy until it's done.
    scenario.appAlive = true
    for second in stride(from: 10.0, through: 30, by: 1) {
        scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(second - 1))
        #expect(scenario.decide(at: second, ping: false) == .waitForApp)
    }

    // It stops moving and it's silent, so it's killed, and the expired window then means a restore.
    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(30))
    #expect(scenario.decide(at: 37.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 38, ping: false) == .killApp)
    scenario.appAlive = false
    #expect(scenario.decide(at: 38.25) == .restore)
}

// MARK: - The relaunch budget

/// Counted, not timed: these are far apart, and a time window would let through any crash slower
/// than its length.
@Test func aThirdRelaunchWithoutAHealthyStretchRestores() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.appAlive = true
    var now = scenario.answer(from: 1, for: 200)

    scenario.relaunch(at: now)
    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 200)

    scenario.appAlive = false
    #expect(scenario.decide(at: now) == .restore)
    #expect(scenario.memory.relaunches == 2)
}

@Test func relaunchBudgetResetsAfterAHealthyStretch() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    scenario.relaunch(at: 30)
    scenario.recover(at: 31)

    // With the budget spent, dying now would be a restore. The stretch below is what changes that.
    var withoutTheStretch = scenario
    withoutTheStretch.appAlive = false
    #expect(withoutTheStretch.decide(at: 32) == .restore)

    let now = scenario.answer(from: 33, for: 302)
    #expect(scenario.memory.relaunches == 0)

    scenario.appAlive = false
    #expect(scenario.decide(at: now) == .relaunchApp)
}

/// The next life after each crash answers until it dies by itself, so it's never a hung kill. A 60
/// second window caught only the fastest of these, and relaunched the others forever.
@Test(arguments: [25.0, 35.0, 40.0, 59.0, 70.0, 299.0])
func aResumeThatKeepsCrashingGetsTwoRelaunchesThenRestores(lifetime: Double) {
    let acted = stepResume(for: 1800, answersFor: .infinity, diesAfter: lifetime)

    #expect(acted.prefix(3).map(\.decision) == [.relaunchApp, .relaunchApp, .restore])
    #expect(acted.dropFirst(2).allSatisfy { $0.decision == .restore })
}

/// A session that stays up for minutes between crashes is working, and it keeps getting relaunched.
@Test func aCrashAfterMoreThan5HealthyMinutesGetsANewBudget() {
    let acted = stepResume(for: 3600, answersFor: .infinity, diesAfter: 400)

    #expect(acted.count > 3)
    #expect(acted.allSatisfy { $0.decision == .relaunchApp })
}

@Test(arguments: [LedgerState.starting, .ending])
func budgetAppliesInEveryLiveState(state: LedgerState) {
    var scenario = Scenario(ledger: makeLedger(state: state))
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    scenario.relaunch(at: 20)
    scenario.recover(at: 21)

    scenario.appAlive = false
    #expect(scenario.decide(at: 40) == .restore)
}

// MARK: - A new app the guardian didn't launch

/// Apps that took the session over one after another, each started by something other than the guardian.
private let replacements = (1...4).map { ProcessRef(pid: 600 + Int32($0), startTime: 2000 + Double($0)) }

/// macOS 27's MenuBarAgent relaunches a killed status item app within about 50 ms, and the new app
/// writes itself into the ledger about 0.2 s later. No tick may fall between, so all the guardian sees
/// is a new app in the ledger. In hardware test 6B, three kills got three relaunches and no restore.
@Test func aNewAppAfterADeathNoTickSawCountsAsARelaunch() {
    var scenario = Scenario()
    let now = scenario.answer(from: 0, for: 6)

    scenario.ledger = makeLedger(app: replacements[0])
    #expect(scenario.decide(at: now, ping: true) == .idle)
    #expect(scenario.memory.relaunches == 1)
}

@Test func threeNewAppsNoTickSawDieRestoresOnTheThird() {
    var scenario = Scenario()
    var now = scenario.answer(from: 0, for: 6)

    for app in replacements.prefix(2) {
        scenario.ledger = makeLedger(app: app)
        now = scenario.answer(from: now, for: 6)
    }
    #expect(scenario.memory.relaunches == 2)

    scenario.ledger = makeLedger(app: replacements[2])
    #expect(scenario.decide(at: now, ping: true) == .restore)
}

/// Test 6B as it ran: kill 1 replaced before any tick, then kills 2 and 3 seen. The third death is the
/// third relaunch the session needed.
@Test func aMissedDeathThenTwoSeenOnesRestoresOnTheThird() {
    var scenario = Scenario()
    var now = scenario.answer(from: 0, for: 10)

    scenario.ledger = makeLedger(app: replacements[0])
    now = scenario.answer(from: now, for: 6)

    scenario.relaunch(at: now)
    scenario.ledger = makeLedger(app: replacements[1])
    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 6)
    #expect(scenario.memory.relaunches == 2)

    scenario.appAlive = false
    #expect(scenario.decide(at: now) == .restore)
}

/// The app a relaunch brings up is that relaunch, whoever started it first.
@Test func theAppAGuardianRelaunchBringsUpIsCountedOnce() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.ledger = makeLedger(app: replacements[0])
    scenario.recover(at: 1)
    #expect(scenario.memory.relaunches == 1)
}

/// A relaunched app that dies before it ever answers, replaced before any tick saw it dead.
@Test func aReplacementDuringTheRelaunchWindowCountsToo() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.ledger = makeLedger(app: replacements[0])
    scenario.appAlive = true
    #expect(scenario.decide(at: 0.5) == .waitForApp)

    scenario.ledger = makeLedger(app: replacements[1])
    #expect(scenario.decide(at: 1, ping: true) == .idle)
    #expect(scenario.memory.relaunches == 2)
}

/// Treated as a relaunch in full, so it gets the same 10 seconds to answer.
@Test func aNewAppThatNeverAnswersRestoresAfterTheRelaunchWindow() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    scenario.ledger = makeLedger(app: replacements[0])
    #expect(scenario.decide(at: 2, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 11.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 12, ping: false) == .restore)
}

@Test func aNewAppAfterAHealthyStretchStartsAFreshBudget() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    let now = scenario.answer(from: 3, for: 302)
    #expect(scenario.memory.relaunches == 0)

    scenario.ledger = makeLedger(app: replacements[0])
    #expect(scenario.decide(at: now, ping: true) == .idle)
    #expect(scenario.memory.relaunches == 1)
}

/// A ledger the app hasn't named itself in yet, then one it has, is the same app arriving.
@Test func aFirstAppReferenceIsNotANewApp() {
    var scenario = Scenario(ledger: makeLedger(state: .starting, app: nil), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)
    scenario.ledger = makeLedger(state: .starting, app: replacements[0])
    scenario.appAlive = true
    #expect(scenario.decide(at: 1, ping: true) == .idle)
    #expect(scenario.memory.relaunches == 1)
}

@Test func aNewSessionIsNotANewApp() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    scenario.ledger = makeLedger(app: replacements[0], startedAt: sessionStart.addingTimeInterval(60))
    #expect(scenario.decide(at: 61, ping: true) == .idle)
    #expect(scenario.memory.relaunches == 0)
}

/// The app rewrites its own ledger as the session goes on. Only a different app is a takeover.
@Test func theSameAppRewritingTheLedgerIsNotANewApp() {
    var scenario = Scenario(ledger: makeLedger(state: .starting))
    var now = scenario.answer(from: 0, for: 4)

    for state in [LedgerState.active, .active, .ending] {
        scenario.ledger = makeLedger(state: state, updatedAt: sessionStart.addingTimeInterval(now))
        now = scenario.answer(from: now, for: 4)
    }
    #expect(scenario.memory.relaunches == 0)
}

// MARK: - App alive, no answer for 15 seconds

@Test func hungPing15sKills() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    for second in stride(from: 2.0, to: 15, by: 2) {
        #expect(scenario.decide(at: second, ping: false) != .killApp)
    }
    #expect(scenario.decide(at: 14.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 15, ping: false) == .killApp)

    // Then it's treated as dead.
    scenario.appAlive = false
    #expect(scenario.decide(at: 15.25) == .relaunchApp)
}

@Test func anAnswerRestartsTheHungClock() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)
    #expect(scenario.decide(at: 14, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 14.5, ping: true) == .idle)
    #expect(scenario.decide(at: 29.25, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 29.5, ping: false) == .killApp)
}

/// The guardian can start mid-session, when launchd restarts it. It has never heard from the app,
/// so the 15 seconds run from when it first saw it.
@Test func hungClockStartsAtFirstSight() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 100, ping: false) == .idle)
    #expect(scenario.decide(at: 114.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 115, ping: false) == .killApp)
}

@Test func theHungClockBelongsToOneAppProcess() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    // The app dies 12 seconds after its last answer, and its replacement is still starting at 15.
    // On the old app's clock, that would be a kill.
    scenario.appAlive = false
    #expect(scenario.decide(at: 12) == .relaunchApp)
    scenario.appAlive = true
    #expect(scenario.decide(at: 13, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 15, ping: false) == .waitForApp)

    // Once it answers, it gets the full 15 seconds of its own.
    #expect(scenario.decide(at: 16, ping: true) == .idle)
    #expect(scenario.decide(at: 30.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 31, ping: false) == .killApp)
}

/// A process that outlives its `SIGKILL`, or a replacement already in the ledger, must not be killed
/// again on the very next tick on the old clock.
@Test func aKillRestartsTheHungClock() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)
    #expect(scenario.decide(at: 15, ping: false) == .killApp)

    #expect(scenario.decide(at: 15.25, ping: false) != .killApp)
    #expect(scenario.decide(at: 30, ping: false) != .killApp)
    #expect(scenario.decide(at: 30.25, ping: false) == .killApp)
}

@Test func hungAppOverBudgetRestoresInsteadOfRelaunching() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    scenario.relaunch(at: 2)
    scenario.recover(at: 3)

    #expect(scenario.decide(at: 18, ping: false) == .killApp)
    scenario.appAlive = false
    #expect(scenario.decide(at: 18.25) == .restore)
}

@Test func silentAppMakingEndProgressIsNotKilledUntilItStops() {
    var scenario = Scenario(ledger: makeLedger(state: .ending))
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    for second in stride(from: 15.0, through: 40, by: 1) {
        scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(second - 1))
        #expect(scenario.decide(at: second, ping: false) == .waitForApp)
    }

    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(40))
    #expect(scenario.decide(at: 47.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 48, ping: false) == .killApp)
}

// MARK: - A resume that keeps hanging

/// Steps the real cycle tick by tick, with the clock. Each relaunched app comes up after a second and
/// answers for `answersFor` seconds, then goes silent, and dies by itself after `diesAfter` if given.
/// Returns what the guardian did and when.
private func stepResume(
    for seconds: Double,
    answersFor: Double,
    diesAfter: Double? = nil
) -> [(at: Double, decision: GuardianDecision)] {
    var scenario = Scenario(appAlive: false)
    var acted: [(at: Double, decision: GuardianDecision)] = []
    var upAt: Double?

    for now in stride(from: 0.0, through: seconds, by: 0.25) {
        if let started = upAt, let diesAfter, now >= started + diesAfter { upAt = nil }
        scenario.appAlive = upAt.map { now >= $0 } ?? false
        var ping: Bool?
        if let upAt, now >= upAt, now.truncatingRemainder(dividingBy: 2) == 0 {
            ping = now - upAt <= answersFor
        }

        let decision = scenario.decide(at: now, ping: ping)
        switch decision {
        case .idle, .waitForApp: continue
        case .relaunchApp: upAt = now + 1
        case .killApp: upAt = nil
        case .discardLedger, .askAppToEnd, .restore: break
        }
        acted.append((now, decision))
    }
    return acted
}

/// Busy counts as an answer for 60 seconds, so these kills come about 76 seconds apart. A budget that
/// only looked back 60 seconds never tripped: the monitors stayed off, a new app died every 76 seconds,
/// and nobody was told.
@Test func aResumeThatKeepsHangingRestoresOnTheSecondKill() {
    let acted = stepResume(for: 1000, answersFor: BusyPingLimit.seconds)

    #expect(acted.prefix(5).map(\.decision) == [.relaunchApp, .killApp, .relaunchApp, .killApp, .restore])
    #expect(acted[2].at - acted[0].at > 60)
    #expect(acted[4].at - acted[3].at == 0.25)

    // Only restores from there, and no third relaunch however long it runs.
    #expect(acted.dropFirst(4).allSatisfy { $0.decision == .restore })
    #expect(acted.count > 8)
}

/// Counting relaunches alone wouldn't catch this. With no crash first, the second kill comes after only
/// one relaunch, and the budget would allow a third life, which would hang the same way.
@Test func aSecondHungKillDoesNotNeedAThirdLife() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)

    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 2)

    now = scenario.hangUntilKilled(from: now) + 0.25
    #expect(scenario.memory.relaunches == 1)
    #expect(scenario.decide(at: now) == .restore)
}

/// macOS 27's MenuBarAgent can bring up a killed app's replacement before the next tick sees the
/// death. After the second hung kill, that replacement is the third life the test above rules out.
@Test func aTakeoverAfterTheSecondHungKillRestores() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    scenario.ledger = makeLedger(app: replacements[0])
    scenario.appAlive = true
    now = scenario.answer(from: now, for: 2)

    now = scenario.hangUntilKilled(from: now) + 0.25
    scenario.ledger = makeLedger(app: replacements[1])
    scenario.appAlive = true
    #expect(scenario.decide(at: now) == .restore)
    #expect(scenario.memory.hungKills == 2)
    #expect(scenario.memory.relaunches == 2)
}

@Test func aKillFollowedBy6HealthyMinutesRelaunchesOnceMore() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)

    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 2)

    // The same hang with no healthy stretch first would restore. The 6 minutes are what change that.
    var withoutTheStretch = scenario
    let killedAt = withoutTheStretch.hangUntilKilled(from: now) + 0.25
    #expect(withoutTheStretch.decide(at: killedAt) == .restore)

    now = scenario.answer(from: now, for: 360)
    #expect(scenario.memory.hungKills == 0)
    #expect(scenario.memory.relaunches == 0)

    now = scenario.hangUntilKilled(from: now) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)
}

@Test func exactly5HealthyMinutesDoNotClearAKill() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)

    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 300)

    now = scenario.hangUntilKilled(from: now) + 0.25
    #expect(scenario.decide(at: now) == .restore)
}

/// The stretch has to be unbroken, and a failed ping breaks it. Keeping a kill too long only brings
/// a restore sooner, which is the safe direction.
@Test func aBrokenHealthyStretchDoesNotClearAKill() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)

    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 200)
    #expect(scenario.decide(at: now, ping: false) == .idle)
    now = scenario.answer(from: now + 2, for: 200)

    now = scenario.hangUntilKilled(from: now) + 0.25
    #expect(scenario.decide(at: now) == .restore)
}

@Test func aNewSessionStartsTheHungKillCountOver() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)

    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 2)

    // In the same session, the next kill would restore.
    var sameSession = scenario
    let killedAt = sameSession.hangUntilKilled(from: now) + 0.25
    #expect(sameSession.decide(at: killedAt) == .restore)

    // A new session replaces the ledger, with no tick seeing it empty.
    scenario.ledger = makeLedger(startedAt: sessionStart.addingTimeInterval(1000))
    now = scenario.answer(from: now, for: 2)

    now = scenario.hangUntilKilled(from: now) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)
}

@Test func aNewSessionResetsTheRelaunchBudget() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    scenario.relaunch(at: 2)
    scenario.recover(at: 3)

    // In the same session, dying now would restore.
    var sameSession = scenario
    sameSession.appAlive = false
    #expect(sameSession.decide(at: 4) == .restore)

    scenario.ledger = makeLedger(startedAt: sessionStart.addingTimeInterval(1000))
    scenario.appAlive = false
    #expect(scenario.decide(at: 4) == .relaunchApp)
}

// MARK: - App healthy, `starting` or `ending`, and `updatedAt` frozen

/// A failed `session end` keeps the ledger and the app stays healthy, so nothing else would ever
/// bring the monitors back.
@Test func frozenEndingWithHealthyAppRestoresAfter60s() {
    var scenario = Scenario(ledger: makeLedger(state: .ending))
    #expect(scenario.decide(at: 0, ping: true) == .idle)
    #expect(scenario.decide(at: 60, ping: true) == .idle)
    #expect(scenario.decide(at: 60.25, ping: true) == .restore)
}

@Test func frozenStartingWithHealthyAppRestoresAfter60s() {
    var scenario = Scenario(ledger: makeLedger(state: .starting))
    #expect(scenario.decide(at: 0, ping: true) == .idle)
    #expect(scenario.decide(at: 60, ping: true) == .idle)
    #expect(scenario.decide(at: 60.25, ping: true) == .restore)
}

@Test func endingWithAdvancingUpdatedAtKeepsWaitingPast60s() {
    var scenario = Scenario(ledger: makeLedger(state: .ending))
    for second in stride(from: 0.0, through: 200, by: 10) {
        scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(second))
        #expect(scenario.decide(at: second, ping: true) == .idle)
        #expect(scenario.decide(at: second + 9.75, ping: true) == .idle)
    }

    // It stops moving at 200.
    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(200))
    #expect(scenario.decide(at: 260, ping: true) == .idle)
    #expect(scenario.decide(at: 260.25, ping: true) == .restore)
}

/// `active` is meant to sit still for hours.
@Test func anActiveLedgerIsNeverFrozen() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)
    #expect(scenario.decide(at: 36000, ping: true) == .idle)
}

@Test func relaunchedAppWhoseResumeFailedRestores() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)

    scenario.appAlive = true
    #expect(scenario.decide(at: 2, ping: true) == .idle)
    #expect(scenario.decide(at: 60, ping: true) == .idle)
    #expect(scenario.decide(at: 60.25, ping: true) == .restore)
}

/// A relaunched app hasn't said anything yet, so the relaunch window decides, however old the ledger.
@Test func aFrozenLedgerWaitsOutTheRelaunchWindow() {
    var scenario = Scenario(ledger: makeLedger(state: .ending), appAlive: false)
    #expect(scenario.decide(at: 100) == .relaunchApp)

    scenario.appAlive = true
    #expect(scenario.decide(at: 101, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 109.75, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 110, ping: false) == .restore)
}

/// A spawn failure leaves the app up and answering. That must not reset the attempts, or they would
/// never reach three and nobody would be told.
@Test func aFrozenLedgerKeepsCountingRestoresWhileTheAppAnswers() {
    var scenario = Scenario(ledger: makeLedger(state: .ending))
    #expect(scenario.decide(at: 60.25, ping: true) == .restore)
    #expect(scenario.decide(at: 65.25, ping: true) == .restore)
    #expect(scenario.decide(at: 70.25, ping: true) == .restore)
    #expect(scenario.memory.restoreAttempts == 3)
    #expect(scenario.decide(at: 75.25, ping: true) == .waitForApp)
    #expect(scenario.decide(at: 130.25, ping: true) == .restore)
}

@Test func aLedgerThatMovesAgainIsNoLongerFrozen() {
    var scenario = Scenario(ledger: makeLedger(state: .ending))
    #expect(scenario.decide(at: 60.25, ping: true) == .restore)

    scenario.ledger = makeLedger(state: .ending, updatedAt: sessionStart.addingTimeInterval(62))
    #expect(scenario.decide(at: 63, ping: true) == .idle)
    #expect(scenario.memory.restoreAttempts == 0)
}

/// A clock set back makes `updatedAt` look like the future. Waiting for that date to arrive could
/// keep the monitors dark for as long as the jump.
@Test func updatedAtFarInTheFutureCountsAsFrozen() {
    let future = sessionStart.addingTimeInterval(3600)
    var scenario = Scenario(ledger: makeLedger(state: .ending, updatedAt: future))
    #expect(scenario.decide(at: 0, ping: true) == .restore)
}

// MARK: - Restore retries

@Test func restoreRetriesThreeTimesThenEveryMinute() {
    var scenario = Scenario(appAlive: false, deadOwners: [ownerRef])

    #expect(scenario.decide(at: 0) == .restore)
    #expect(scenario.decide(at: 4.75) == .waitForApp)
    #expect(scenario.decide(at: 5) == .restore)
    #expect(scenario.decide(at: 9.75) == .waitForApp)
    #expect(scenario.decide(at: 10) == .restore)
    #expect(scenario.memory.restoreAttempts == 3)

    // Slower now, but it never stops while the ledger is live. A remote user may have nothing else.
    #expect(scenario.decide(at: 15) == .waitForApp)
    #expect(scenario.decide(at: 69.75) == .waitForApp)
    #expect(scenario.decide(at: 70) == .restore)
    #expect(scenario.decide(at: 129.75) == .waitForApp)
    #expect(scenario.decide(at: 130) == .restore)
    #expect(scenario.decide(at: 5000) == .restore)
    #expect(scenario.memory.restoreAttempts == 6)
}

/// A relaunched app would turn the monitors back off, so nothing relaunches once a restore has begun.
@Test func aFailedRestoreIsRetriedNeverFollowedByARelaunch() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    #expect(scenario.decide(at: 10) == .restore)

    // The relaunch window is long over, and there's a relaunch left in the budget.
    #expect(scenario.decide(at: 15) == .restore)
    #expect(scenario.decide(at: 70) == .restore)
    #expect(scenario.decide(at: 130) == .restore)
}

@Test func relaunchBudgetRestoreIsAlsoRetried() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    scenario.relaunch(at: 2)
    scenario.recover(at: 3)

    scenario.appAlive = false
    #expect(scenario.decide(at: 4) == .restore)
    #expect(scenario.decide(at: 9) == .restore)
    #expect(scenario.decide(at: 14) == .restore)
    #expect(scenario.decide(at: 14.25) == .waitForApp)
    #expect(scenario.decide(at: 74) == .restore)
}

/// A frozen ledger restores with the relaunch budget untouched. If that restore fails and the app then
/// dies, a relaunch would turn the monitors back off.
@Test func aFailedRestoreWithBudgetLeftIsNotFollowedByARelaunch() {
    var scenario = Scenario(ledger: makeLedger(state: .ending))
    #expect(scenario.decide(at: 60.25, ping: true) == .restore)

    scenario.appAlive = false
    #expect(scenario.memory.relaunches == 0)
    #expect(scenario.decide(at: 65.25) == .restore)
}

/// With a healthy app and a dead owner, a spawn failure can leave the app answering. That must not
/// reset the attempts, or they would never reach three and nobody would be told.
@Test func aHealthyAppWithADeadOwnerDoesNotResetTheRestoreBudget() {
    var scenario = Scenario(deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)
    #expect(scenario.decide(at: 8, ping: true) == .restore)
    #expect(scenario.decide(at: 13, ping: true) == .restore)
    #expect(scenario.decide(at: 18, ping: true) == .restore)
    #expect(scenario.decide(at: 18.25, ping: true) == .waitForApp)
    #expect(scenario.decide(at: 78, ping: true) == .restore)
    #expect(scenario.memory.restoreAttempts == 4)
}

@Test func aFailedRestoreWithASilentAppIsRetriedWithoutAKill() {
    var scenario = Scenario(appAlive: false)
    #expect(scenario.decide(at: 0) == .relaunchApp)
    scenario.appAlive = true
    #expect(scenario.decide(at: 10, ping: false) == .restore)
    // The app is alive, so the restore child kills it. Nothing else should.
    #expect(scenario.decide(at: 15, ping: false) == .restore)
    #expect(scenario.decide(at: 20, ping: false) == .restore)
    #expect(scenario.decide(at: 25, ping: false) == .waitForApp)
    #expect(scenario.decide(at: 80, ping: false) == .restore)
}

/// The restore child kills the app, and macOS can bring up another within the 5 second spacing. That
/// one answers, but the session has no lives left, so the restore is still owed.
@Test func anOverBudgetRestoreWaitingOnItsSpacingIsNotForgotten() {
    var scenario = Scenario()
    var now = scenario.answer(from: 0, for: 6)
    for app in replacements.prefix(2) {
        scenario.ledger = makeLedger(app: app)
        now = scenario.answer(from: now, for: 6)
    }
    scenario.ledger = makeLedger(app: replacements[2])
    #expect(scenario.decide(at: now, ping: true) == .restore)

    scenario.ledger = makeLedger(app: replacements[3])
    #expect(scenario.decide(at: now + 1, ping: true) == .waitForApp)
    #expect(scenario.decide(at: now + 3, ping: true) == .waitForApp)
    #expect(scenario.decide(at: now + 5, ping: true) == .restore)
}

/// The same after two hung kills: a replacement that answers doesn't call the restore off, although
/// the relaunch count alone would allow it.
@Test func aRestoreOwedForTwoHungKillsIsNotCalledOffByAnAnswer() {
    var scenario = Scenario()
    #expect(scenario.decide(at: 0, ping: true) == .idle)

    var now = scenario.hangUntilKilled(from: 2) + 0.25
    #expect(scenario.decide(at: now) == .relaunchApp)
    scenario.appAlive = true
    now = scenario.answer(from: now + 1, for: 2)

    now = scenario.hangUntilKilled(from: now) + 0.25
    #expect(scenario.decide(at: now) == .restore)

    scenario.ledger = makeLedger(app: replacements[0])
    scenario.appAlive = true
    #expect(scenario.decide(at: now + 1, ping: true) == .waitForApp)
    #expect(scenario.decide(at: now + 3, ping: true) == .waitForApp)
    #expect(scenario.memory.relaunches == 2)
    #expect(scenario.decide(at: now + 5, ping: true) == .restore)
}

/// The user can start the app by hand after a failed rescue, and that session is healthy. Row 3 applies.
@Test func aHealthyAppStopsTheRetriesAndStartsOverIfItDiesLater() {
    var scenario = Scenario(appAlive: false, deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0) == .restore)
    #expect(scenario.decide(at: 5) == .restore)
    #expect(scenario.decide(at: 10) == .restore)
    #expect(scenario.decide(at: 11) == .waitForApp)

    scenario.deadOwners = []
    scenario.appAlive = true
    #expect(scenario.decide(at: 300, ping: true) == .idle)
    #expect(scenario.memory.restoreAttempts == 0)

    scenario.appAlive = false
    #expect(scenario.decide(at: 400) == .relaunchApp)
}

// MARK: - Memory across sessions

@Test func endingASessionClearsItsMemory() {
    var scenario = Scenario(appAlive: false, deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0) == .restore)
    #expect(scenario.decide(at: 5) == .restore)
    #expect(scenario.decide(at: 10) == .restore)
    #expect(scenario.decide(at: 11) == .waitForApp)

    // Rescued by hand, then a new session whose app dies with a dead owner: three new attempts.
    scenario.ledger = makeLedger(state: .rescued)
    #expect(scenario.decide(at: 12) == .idle)
    #expect(scenario.memory.restoreAttempts == 0)
    #expect(scenario.memory.lastRestoreAt == nil)
    #expect(scenario.memory.endRequestedAt == nil)
    #expect(scenario.memory.lastPingOK == nil)
    #expect(scenario.memory.relaunchedAt == nil)

    scenario.ledger = makeLedger()
    #expect(scenario.decide(at: 13) == .restore)
}

@Test func anEndRequestDoesNotLeakIntoTheNextSession() {
    var scenario = Scenario(deadOwners: [ownerRef])
    #expect(scenario.decide(at: 0, ping: true) == .askAppToEnd)

    scenario.ledger = nil
    #expect(scenario.decide(at: 1) == .idle)

    scenario.ledger = makeLedger()
    #expect(scenario.decide(at: 50, ping: true) == .askAppToEnd)
}

@Test func theEndOfASessionResetsTheRelaunchBudget() {
    var scenario = Scenario()
    scenario.relaunch(at: 0)
    scenario.recover(at: 1)
    scenario.relaunch(at: 2)
    scenario.recover(at: 3)

    scenario.ledger = nil
    #expect(scenario.decide(at: 4) == .idle)
    #expect(scenario.memory.relaunches == 0)

    scenario.ledger = makeLedger()
    scenario.appAlive = false
    #expect(scenario.decide(at: 5) == .relaunchApp)
}

// MARK: - Purity

@Test func theSameInputGivesTheSameDecision() {
    func run() -> [GuardianDecision] {
        var scenario = Scenario(appAlive: false)
        return stride(from: 0.0, through: 40, by: 0.25).map { scenario.decide(at: $0) }
    }
    #expect(run() == run())
}
