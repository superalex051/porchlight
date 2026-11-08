import ADFoundation
import Foundation

/// What the guardian saw on one tick.
public struct GuardianObservation: Sendable {
    public var ledger: SafetyLedger?
    public var currentBoot: String
    /// Whether the ledger's own app reference is running. A ledger with no app reference is not alive.
    public var appAlive: Bool
    /// The result of a ping made on this tick, or nil if none was due.
    public var appPingOK: Bool?
    public var deadOwners: [ProcessRef]
    public var now: Date

    public init(
        ledger: SafetyLedger?,
        currentBoot: String,
        appAlive: Bool,
        appPingOK: Bool?,
        deadOwners: [ProcessRef],
        now: Date
    ) {
        self.ledger = ledger
        self.currentBoot = currentBoot
        self.appAlive = appAlive
        self.appPingOK = appPingOK
        self.deadOwners = deadOwners
        self.now = now
    }
}

/// What the policy has to remember from one tick to the next.
public struct GuardianMemory: Sendable {
    /// Set while a relaunch hasn't produced a healthy app yet.
    public var relaunchedAt: Date?
    /// The start of the current silence. Before the app's first answer, that's when it was first seen.
    public var lastPingOK: Date?
    public var endRequestedAt: Date?
    public var restoreAttempts: Int
    public var lastRestoreAt: Date?
    /// Relaunches and kills of a hung app since the last healthy stretch, in the session that started
    /// at `countedSession`.
    public var relaunches: Int
    public var hungKills: Int
    public var countedSession: Date?
    /// The start of the current unbroken run of answers, tracked only while either count is above 0.
    public var healthySince: Date?
    /// The ledger's app on the last tick, and whether `relaunches` already counts its death, because a
    /// tick saw it dead and relaunched it.
    public var lastApp: ProcessRef?
    public var lastAppRelaunched: Bool

    public init(
        relaunchedAt: Date? = nil,
        lastPingOK: Date? = nil,
        endRequestedAt: Date? = nil,
        restoreAttempts: Int = 0,
        lastRestoreAt: Date? = nil,
        relaunches: Int = 0,
        hungKills: Int = 0,
        countedSession: Date? = nil,
        healthySince: Date? = nil,
        lastApp: ProcessRef? = nil,
        lastAppRelaunched: Bool = false
    ) {
        self.relaunchedAt = relaunchedAt
        self.lastPingOK = lastPingOK
        self.endRequestedAt = endRequestedAt
        self.restoreAttempts = restoreAttempts
        self.lastRestoreAt = lastRestoreAt
        self.relaunches = relaunches
        self.hungKills = hungKills
        self.countedSession = countedSession
        self.healthySince = healthySince
        self.lastApp = lastApp
        self.lastAppRelaunched = lastAppRelaunched
    }

    mutating func forgetSession() {
        self = GuardianMemory()
    }

    /// For when the clock jumped: every wait in progress starts again from now, so a clock set back
    /// can't stretch one by the size of the jump, and a sleep doesn't count as silence.
    mutating func restartWaits(at now: Date) {
        relaunchedAt = relaunchedAt.map { _ in now }
        lastPingOK = lastPingOK.map { _ in now }
        endRequestedAt = endRequestedAt.map { _ in now }
        lastRestoreAt = lastRestoreAt.map { _ in now }
        healthySince = healthySince.map { _ in now }
    }
}

public enum GuardianDecision: Equatable, Sendable {
    case idle, discardLedger, relaunchApp, killApp, askAppToEnd, waitForApp, restore
}

/// The spec's guardian table as a pure function. It changes nothing but `memory`.
public enum GuardianPolicy {
    public static let relaunchWindow: TimeInterval = 10
    public static let hungAfter: TimeInterval = 15
    public static let endWait: TimeInterval = 8
    /// A session gets this many relaunches without a healthy stretch between them, and the next one
    /// that would be needed is a restore. It's a count because a time window lets through any crash or
    /// hang slower than the window: the monitors stay off, a new app dies each time, and nobody is told.
    public static let maxRelaunches = 2
    /// The quick attempts, `restoreSpacing` apart. After these the user is told, and the retries carry on
    /// `restoreRetryInterval` apart for as long as the ledger is live, because someone connected
    /// remotely may have nothing else.
    public static let maxRestores = 3
    public static let restoreSpacing: TimeInterval = 5
    public static let restoreRetryInterval: TimeInterval = 60
    public static let frozenAfter: TimeInterval = 60
    /// This many kills of a hung app also lead to a restore, even with a relaunch to spare. With no
    /// crash first, the second kill comes after only one relaunch, and a third life would hang the same way.
    public static let hungKillsBeforeRestore = 2
    /// An unbroken run of answers longer than this resets both counts.
    public static let healthyStretchResetsBudget: TimeInterval = 300

    /// The longest a healthy app can go without an answer: the 2 second ping interval plus the 1
    /// second timeout. Past this the wait gets reported, though only `hungAfter` acts on it.
    private static let answerExpectedWithin: TimeInterval = 3

    public static func decide(_ o: GuardianObservation, memory: inout GuardianMemory) -> GuardianDecision {
        // Outside a session nothing is ever relaunched or restored, so quitting the app is respected.
        guard let ledger = o.ledger, ledger.state != .rescued else {
            memory.forgetSession()
            return .idle
        }
        if isFromAnotherBoot(ledger, currentBoot: o.currentBoot) {
            memory.forgetSession()
            return .discardLedger
        }

        if memory.countedSession != ledger.startedAt {
            memory.countedSession = ledger.startedAt
            memory.relaunches = 0
            memory.hungKills = 0
            memory.healthySince = nil
            memory.lastApp = nil
            memory.lastAppRelaunched = false
        }
        if noteUncountedTakeover(by: ledger.app, now: o.now, &memory), isOutOfLives(memory) {
            return restoreWhenDue(now: o.now, &memory)
        }
        return o.appAlive
            ? decideWithAppAlive(o, ledger, &memory)
            : decideWithAppDead(o, ledger, &memory)
    }

    /// True for a new app in the ledger that no relaunch of the guardian's brought up. Its predecessor
    /// died and something else started it before any tick saw the death: macOS 27's MenuBarAgent
    /// relaunches a killed status item app within about 50 ms, and the new app names itself in the
    /// ledger about 0.2 s later. Uncounted, a session crashing in a loop never runs out of relaunches,
    /// so it counts as one in full: against the budget, and with the same 10 seconds to answer.
    private static func noteUncountedTakeover(
        by app: ProcessRef?,
        now: Date,
        _ memory: inout GuardianMemory
    ) -> Bool {
        guard let app, app != memory.lastApp else { return false }
        let previous = memory.lastApp
        let alreadyCounted = memory.lastAppRelaunched
        memory.lastApp = app
        memory.lastAppRelaunched = false
        guard previous != nil, !alreadyCounted else { return false }

        memory.relaunches += 1
        memory.relaunchedAt = now
        // The silence clock and the healthy stretch belong to the app that died.
        memory.lastPingOK = nil
        memory.healthySince = nil
        return true
    }

    /// The session has used every life it gets: a third relaunch, or a second kill of a hung app. From
    /// then on a restore is owed until one works or the session changes, whichever app is in the ledger.
    private static func isOutOfLives(_ memory: GuardianMemory) -> Bool {
        memory.relaunches > maxRelaunches || memory.hungKills >= hungKillsBeforeRestore
    }

    /// An empty ID means the boot is unknown (`BootSession.current()` returns it if its sysctl fails),
    /// never another boot. Discarding on it would lose a live session's records.
    public static func isFromAnotherBoot(_ ledger: SafetyLedger, currentBoot: String) -> Bool {
        !currentBoot.isEmpty && !ledger.bootSessionID.isEmpty && ledger.bootSessionID != currentBoot
    }

    /// Whoever runs the restorer moves `updatedAt` at each step, so while this holds, something is
    /// bringing the monitors back and stopping it would only slow that down. The restorer's steps are
    /// time limited, so this can't hold forever. A date in the future shows nothing, so it doesn't count.
    private static func isRestoring(_ ledger: SafetyLedger, now: Date) -> Bool {
        ledger.state == .ending && (0..<endWait).contains(now.timeIntervalSince(ledger.updatedAt))
    }

    /// `starting` and `ending` are short and move `updatedAt` as they go, so one that stops is stuck:
    /// a failed `session end` keeps the ledger, and a relaunched app's resume can fail. The app still
    /// answers, so no other row would ever act. A date far in the future comes from a clock set back,
    /// and it counts too, because waiting for that date could mean dark monitors for as long as the jump.
    private static func isFrozen(_ ledger: SafetyLedger, now: Date) -> Bool {
        (ledger.state == .starting || ledger.state == .ending)
            && abs(now.timeIntervalSince(ledger.updatedAt)) > frozenAfter
    }

    private static func decideWithAppDead(
        _ o: GuardianObservation,
        _ ledger: SafetyLedger,
        _ memory: inout GuardianMemory
    ) -> GuardianDecision {
        // The silence clock belongs to one app process, and this one is gone.
        memory.lastPingOK = nil
        memory.healthySince = nil

        // Once a restore has begun, it keeps going until it works. A relaunched app would turn the
        // monitors off again.
        if memory.restoreAttempts > 0 || !o.deadOwners.isEmpty
            || memory.hungKills >= hungKillsBeforeRestore
        {
            return restoreWhenDue(now: o.now, &memory)
        }

        if let relaunchedAt = memory.relaunchedAt {
            let waited = o.now.timeIntervalSince(relaunchedAt)
            if waited < relaunchWindow || isRestoring(ledger, now: o.now) { return .waitForApp }
            return restoreWhenDue(now: o.now, &memory)
        }

        if memory.relaunches >= maxRelaunches {
            return restoreWhenDue(now: o.now, &memory)
        }
        memory.relaunches += 1
        memory.relaunchedAt = o.now
        memory.lastAppRelaunched = true
        return .relaunchApp
    }

    private static func decideWithAppAlive(
        _ o: GuardianObservation,
        _ ledger: SafetyLedger,
        _ memory: inout GuardianMemory
    ) -> GuardianDecision {
        let ownerDied = !o.deadOwners.isEmpty
        let frozen = isFrozen(ledger, now: o.now)
        let outOfLives = isOutOfLives(memory)

        if o.appPingOK == true {
            memory.lastPingOK = o.now
            // The relaunch is over, so it can't account for any later app.
            memory.relaunchedAt = nil
            memory.lastAppRelaunched = false
            // Only a session with nothing wrong starts over. An answering app would otherwise reset
            // the attempts on every ping, they would never reach three, and nobody would be told.
            if !ownerDied, !frozen, !outOfLives {
                memory.endRequestedAt = nil
                memory.restoreAttempts = 0
                noteHealthyAnswer(now: o.now, &memory)
            }
        } else if o.appPingOK == false {
            memory.healthySince = nil
        }

        // Out of lives, the restore stays owed even while an app answers: macOS can bring up a new one
        // before a restore is due, and that answer would otherwise call the restore off.
        if memory.restoreAttempts > 0 || outOfLives {
            return restoreWhenDue(now: o.now, &memory)
        }

        let silentSince = memory.lastPingOK ?? o.now
        memory.lastPingOK = silentSince
        let silence = o.now.timeIntervalSince(silentSince)
        let restoring = isRestoring(ledger, now: o.now)

        if silence >= hungAfter, !restoring {
            memory.lastPingOK = nil
            memory.healthySince = nil
            memory.hungKills += 1
            return .killApp
        }

        if let relaunchedAt = memory.relaunchedAt,
            o.now.timeIntervalSince(relaunchedAt) >= relaunchWindow,
            !restoring
        {
            return restoreWhenDue(now: o.now, &memory)
        }

        if ownerDied {
            guard let requestedAt = memory.endRequestedAt else {
                memory.endRequestedAt = o.now
                return .askAppToEnd
            }
            if o.now.timeIntervalSince(requestedAt) < endWait || restoring { return .waitForApp }
            return restoreWhenDue(now: o.now, &memory)
        }

        // A relaunched app that hasn't answered yet is the relaunch window's to judge.
        if memory.relaunchedAt != nil { return .waitForApp }
        if frozen { return restoreWhenDue(now: o.now, &memory) }
        return silence >= answerExpectedWithin ? .waitForApp : .idle
    }

    /// Busy counts as an answer for at most 60 seconds in a row, so a resume that hangs can't build up
    /// a stretch long enough to reset its own counts.
    private static func noteHealthyAnswer(now: Date, _ memory: inout GuardianMemory) {
        guard memory.relaunches > 0 || memory.hungKills > 0 else { return }
        let since = memory.healthySince ?? now
        memory.healthySince = since
        if now.timeIntervalSince(since) > healthyStretchResetsBudget {
            memory.relaunches = 0
            memory.hungKills = 0
            memory.healthySince = nil
        }
    }

    private static func restoreWhenDue(now: Date, _ memory: inout GuardianMemory) -> GuardianDecision {
        let spacing = memory.restoreAttempts < maxRestores ? restoreSpacing : restoreRetryInterval
        if let last = memory.lastRestoreAt, now.timeIntervalSince(last) < spacing {
            return .waitForApp
        }
        memory.restoreAttempts += 1
        memory.lastRestoreAt = now
        return .restore
    }
}
