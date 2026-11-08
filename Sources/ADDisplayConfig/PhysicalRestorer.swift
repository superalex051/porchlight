import ADDisplays
import ADFoundation
import ADModel
import Foundation

public struct RestoreReport: Sendable, Equatable {
    /// The current ID of each recorded display that's online, the old main first.
    public var restored: [DisplayID]
    /// The recorded displays listed neither under their recorded ID nor at their recorded location, as
    /// after an unplug or a move to another port. After a lock timeout nothing was tried, so this and
    /// `stillDark` are only what the last read showed, and `attempts` is 0.
    public var missing: [PhysicalRecord]
    /// The recorded displays that aren't online and aren't known to be gone: listed offline under their
    /// recorded ID or at their recorded location, or hidden because the OS fallback display is up or the
    /// list couldn't be read.
    public var stillDark: [PhysicalRecord]
    /// How many times steps 4 to 6 ran.
    public var attempts: Int
    /// The arrangement read back as recorded for every display that came back, and none was still
    /// dark. A caller may treat this as final, so it's false for a monitor that's plugged in and dark.
    /// Also false if the lock never came free, if nothing came back or if the run was cancelled.
    public var verified: Bool
    /// True if a recorded display is online, or if nothing was recorded, so nothing had to return.
    public var anyReturned: Bool
    /// Displays that came back but didn't list their recorded mode for 10 seconds of being online, so
    /// they got only their origin.
    public var modeNotOffered: [PhysicalRecord]

    public init(
        restored: [DisplayID],
        missing: [PhysicalRecord],
        stillDark: [PhysicalRecord] = [],
        attempts: Int,
        verified: Bool,
        anyReturned: Bool,
        modeNotOffered: [PhysicalRecord] = []
    ) {
        self.restored = restored
        self.missing = missing
        self.stillDark = stillDark
        self.attempts = attempts
        self.verified = verified
        self.anyReturned = anyReturned
        self.modeNotOffered = modeNotOffered
    }
}

/// The heartbeat while one `setEnabled` or `commit` is blocked, in real seconds, because the blocked
/// thread is what moves a test clock. A live call can block for about 10 seconds. One still blocked at
/// `limit` is taken to be hung, and the beats stop, so a watcher sees a frozen restorer and steps in.
public struct BlockedCallHeartbeat: Sendable {
    public var interval: Double
    public var limit: Double

    public init(interval: Double = 1, limit: Double = 30) {
        self.interval = interval
        self.limit = limit
    }
}

/// Brings recorded monitors back. This is the spec's Restorer section, the algorithm that worked in
/// the spike, and the app and the guardian share it. Its comments use the spec's step numbers.
///
/// Whether a recorded display is back is read from the online list, and never from a per-ID online
/// call, which says true for a dark monitor while the OS fallback display is up.
public struct PhysicalRestorer: Sendable {
    private static let log = ADLog.logger("restorer")

    private let backend: any DisplayBackend
    private let clock: any ADClock
    private let power: any PowerAsserting
    /// `restore.lock`, which each call takes for itself unless the caller holds it. The app reads it to
    /// find out whether a restore is running.
    public let lockURL: URL
    private let lockHeldByCallerSince: Date?
    private let blockedCallHeartbeat: BlockedCallHeartbeat
    private let onProgress: @Sendable () -> Void

    /// `onProgress` runs at least every 2 seconds of clock time, from any thread, so a watcher can
    /// tell this run from a dead one. The one exception is a display call hung past
    /// `blockedCallHeartbeat.limit`, which is a dead run.
    ///
    /// `lockHeldByCallerSince` is for a caller that took `restore.lock` itself and holds it across these
    /// calls, as `RestoreJob` does. The calls then don't take it again: `flock` on a second descriptor of
    /// the same file conflicts even within one process, so each would wait out its limit and give up.
    /// The date is when the caller began waiting for the lock, and the whole-run limit counts from it, as
    /// it counts a call's own wait. Nil, the default, has each call take the lock.
    public init(
        backend: any DisplayBackend,
        clock: any ADClock,
        power: any PowerAsserting,
        lockURL: URL,
        lockHeldByCallerSince: Date? = nil,
        blockedCallHeartbeat: BlockedCallHeartbeat = BlockedCallHeartbeat(),
        onProgress: @escaping @Sendable () -> Void = {}
    ) {
        self.backend = backend
        self.clock = clock
        self.power = power
        self.lockURL = lockURL
        self.lockHeldByCallerSince = lockHeldByCallerSince
        self.blockedCallHeartbeat = blockedCallHeartbeat
        self.onProgress = onProgress
    }

    @concurrent public func restore(_ records: [PhysicalRecord]) async -> RestoreReport {
        // A session that kept every monitor on, say. There's nothing to wait for.
        guard !records.isEmpty else {
            return RestoreReport(restored: [], missing: [], attempts: 0, verified: true, anyReturned: true)
        }

        let run = makeRun(records: records.filter(\.wasMain) + records.filter { !$0.wasMain })
        let lock = FileLock(url: lockURL)
        defer { lock.unlock() }
        do {
            if try await mayGoOn(run, holding: lock) {
                try await run.restoreRecords()
            } else {
                Self.log.error("Another restore held the lock for too long, so this one gave up")
            }
        } catch {
            Self.log.error("The restore stopped early: \(error.localizedDescription, privacy: .public)")
        }
        return run.report()
    }

    /// For a rescue with no usable ledger: turns on every display it can find, and arranges nothing.
    /// True only if a physical display is online afterward, because the OS fallback display doesn't
    /// count. False if another holder kept the lock, because then this run did nothing.
    @concurrent public func reconnect(_ entries: [RegistryEntry]) async -> Bool {
        let run = makeRun(records: [])
        let lock = FileLock(url: lockURL)
        defer { lock.unlock() }
        do {
            guard try await mayGoOn(run, holding: lock) else {
                Self.log.error("Another restore held the lock for too long, so this one gave up")
                return false
            }
            return try await run.reconnect(entries)
        } catch {
            Self.log.error("The reconnect stopped early: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// True if the caller holds the lock already, or if this call took it.
    private func mayGoOn(_ run: RestoreRun, holding lock: FileLock) async throws -> Bool {
        guard lockHeldByCallerSince == nil else { return true }
        return try await run.takeLock(lock)
    }

    private func makeRun(records: [PhysicalRecord]) -> RestoreRun {
        RestoreRun(
            records: records,
            backend: backend,
            clock: clock,
            power: power,
            blockedCallHeartbeat: blockedCallHeartbeat,
            startedAt: lockHeldByCallerSince,
            onProgress: onProgress
        )
    }
}

/// A recorded display that's online right now, under any ID.
private struct PresentDisplay {
    var index: Int
    var record: PhysicalRecord
    var display: DisplaySnapshot
}

/// One run of the restorer. It stays inside the call that made it, so it needs no locking.
private final class RestoreRun {
    private enum Seconds {
        static let lockLimit = 60.0
        static let lockPoll = 0.1
        static let wakeLimit = 5.0
        static let afterEnable = 0.5
        static let enableRetry = 1.0
        static let allOnlineLimit = 15.0
        static let afterTierTwoAndThree = 3.0
        static let stableFor = 1.5
        static let stableLimit = 30.0
        /// How long a recorded display can be offline in steps 4 to 6 before it gets another enable.
        static let reenableAfter = 5.0
        /// How long a recorded mode has to be off a display's list before the display goes without it.
        static let modeAbsentLimit = 10.0
        static let readBack = 0.8
        static let poll = 0.25
        /// A slice of any wait is at most this long, and a beat is due after this long, so the gap
        /// between beats stays under 2 seconds.
        static let beat = 1.0
        /// The spec's limits add up to more than the guardian's 180 second limit on a whole restore,
        /// so past this no new attempt starts. It leaves room for one commit to block for 10 seconds.
        static let wholeRunLimit = 165.0
    }

    private static let enableAttempts = 3
    private static let arrangeAttempts = 8
    private static let holdReason = "Porch Light is restoring displays"
    private static let log = ADLog.logger("restorer")

    private let records: [PhysicalRecord]
    private let backend: any DisplayBackend
    private let clock: any ADClock
    private let power: any PowerAsserting
    private let blockedCallHeartbeat: BlockedCallHeartbeat
    private let onProgress: @Sendable () -> Void
    private let wholeRunDeadline: Date
    private var lastBeat: Date

    /// Indexes of the records step 4 waits for: the ones read online at any time in this run, minus
    /// any offline at the end of a whole step 4. A display that comes back later joins again. This
    /// only decides what to wait for. Whether a display is missing is for `readBackMatches`.
    private var present = Set<Int>()
    /// Since when each record has been offline in steps 4 to 6, or since its last enable.
    private var offlineSince: [Int: Date] = [:]
    /// Where each online record's wait for its mode starts: when the display came online, or when its
    /// list last had the mode. Going offline starts it over.
    private var modeAbsentSince: [Int: Date] = [:]
    /// Indexes of the records that go without their mode, as of the latest commit.
    private var modeNotOffered = Set<Int>()
    /// Indexes of the records whose mode went into the latest commit on an empty list, which says
    /// nothing about the mode. Only the commit can say it isn't there.
    private var modeAskedBlind = Set<Int>()
    private var attempts = 0
    private var verified = false

    init(
        records: [PhysicalRecord],
        backend: any DisplayBackend,
        clock: any ADClock,
        power: any PowerAsserting,
        blockedCallHeartbeat: BlockedCallHeartbeat,
        startedAt: Date?,
        onProgress: @escaping @Sendable () -> Void
    ) {
        self.records = records
        self.backend = backend
        self.clock = clock
        self.power = power
        self.blockedCallHeartbeat = blockedCallHeartbeat
        self.onProgress = onProgress
        let now = clock.now()
        // A caller that took the lock began its wait earlier, and that counts, as this run's own does.
        wholeRunDeadline = (startedAt ?? now).addingTimeInterval(Seconds.wholeRunLimit)
        lastBeat = now
        onProgress()
    }

    // MARK: Lock and wake

    /// Polls, because a blocking `flock` would freeze whichever thread waited on it. False if another
    /// holder kept it for too long. A lock that can't be created at all says nothing about anyone else
    /// restoring, and dark monitors are worse than two restorers, so that goes ahead without it.
    func takeLock(_ lock: FileLock) async throws -> Bool {
        let deadline = clock.now().addingTimeInterval(Seconds.lockLimit)
        while true {
            switch lock.attemptLock() {
            case .acquired:
                return true
            case .failed:
                Self.log.error("The restore lock can't be taken, so this restore runs without it")
                return true
            case .heldByOther:
                guard clock.now() < deadline else { return false }
                try await pass(Seconds.lockPoll)
            }
        }
    }

    /// The caller has to keep the token.
    private func wakeDisplays() async throws -> PowerAssertionToken {
        power.declareUserActivity()
        let hold = power.holdNoDisplaySleep(reason: Self.holdReason)
        _ = try await wait(upTo: Seconds.wakeLimit) { topology in
            topology.displays.contains(where: \.isActive)
        }
        return hold
    }

    // MARK: The restore

    func restoreRecords() async throws {
        let hold = try await wakeDisplays()
        defer { hold.release() }

        try await enableRecordedDisplays()
        let allOnline = try await wait(upTo: Seconds.allOnlineLimit) { topology in
            records.allSatisfy { $0.onlineDisplay(in: topology) != nil }
        }
        if !allOnline {
            try await enableByIdentityAndEverythingOffline()
        }
        try await arrange()
    }

    /// Step 1. By recorded ID, because while the OS fallback display is up no list shows the monitors
    /// and enabling one by ID is the thing that still works.
    private func enableRecordedDisplays() async throws {
        for record in records where record.onlineDisplay(in: read()) == nil {
            try await enable(record.id)
            try await pass(Seconds.afterEnable)
        }
    }

    /// Step 3.
    private func enableByIdentityAndEverythingOffline() async throws {
        let topology = read()
        var tried = Set<DisplayID>()
        for record in records where record.onlineDisplay(in: topology) == nil {
            if let listed = record.offlineListing(in: topology), tried.insert(listed.id).inserted {
                try await enable(listed.id)
            }
        }
        _ = try await enableEveryOfflineDisplay(except: tried)
        try await pass(Seconds.afterTierTwoAndThree)
    }

    /// Steps 4 to 6. A target that's offline fails the whole transaction, so a commit only ever names
    /// displays that have just been read as stable.
    private func arrange() async throws {
        _ = read()
        while attempts < Self.arrangeAttempts, !present.isEmpty, clock.now() < wholeRunDeadline {
            attempts += 1
            guard let stable = try await waitForStableDisplays() else {
                Self.log.notice("Attempt \(self.attempts): nothing stayed online, so nothing was committed")
                continue
            }
            let changes = changes(for: stable)
            do {
                try blockingCall { try backend.commit(changes) }
                restartBlindModeWaits(in: stable, except: [])
            } catch let error as DisplayBackendError where !error.modesNotApplied.isEmpty {
                // The rest went through. For a mode asked for on an empty list, this is the first word
                // that it isn't there, so its wait goes on, and past the limit the display goes without it.
                restartBlindModeWaits(in: stable, except: Set(error.modesNotApplied))
                Self.log.notice("Attempt \(self.attempts): \(error.message, privacy: .public), so the rest was applied without it")
                continue
            } catch {
                restartBlindModeWaits(in: stable, except: [])
                Self.log.error("Attempt \(self.attempts): the commit failed:\(String(describing: error), privacy: .public)")
                power.declareUserActivity()
                continue
            }
            try await pass(Seconds.readBack)
            verified = readBackMatches(stable)
            if verified { return }
            Self.log.notice("Attempt \(self.attempts): not verified, because the arrangement differs or a monitor is dark")
        }
    }

    /// Step 4. Returns once everything it's waiting for has stayed online for long enough, however
    /// long that took. At the limit, it stops waiting for whatever is offline, and the displays that
    /// were stable go ahead without it, so one bad monitor can't hold up the others. That monitor can
    /// still fail the read-back.
    private func waitForStableDisplays() async throws -> [PresentDisplay]? {
        let deadline = min(clock.now().addingTimeInterval(Seconds.stableLimit), wholeRunDeadline)
        var onlineSince: [Int: Date] = [:]
        while true {
            let now = clock.now()
            let topology = read()
            let online = presentDisplays(in: topology)
            let onlineIndexes = Set(online.map(\.index))
            onlineSince = onlineSince.filter { onlineIndexes.contains($0.key) }
            for index in onlineIndexes where onlineSince[index] == nil {
                onlineSince[index] = now
            }

            let stable = online.filter { display in
                onlineSince[display.index].map { now.timeIntervalSince($0) >= Seconds.stableFor } == true
            }
            if !present.isEmpty, present.isSubset(of: Set(stable.map(\.index))) {
                return stable
            }
            if now >= deadline {
                present = onlineIndexes
                return stable.isEmpty ? nil : stable
            }
            try await reenableDisplaysLongOffline(in: topology)
            try await pass(Seconds.poll)
        }
    }

    /// A monitor can go off again after its enable succeeded, and nothing else would turn it back on.
    /// Waits first, because one that's only flapping comes back by itself, as it did in the spike.
    private func reenableDisplaysLongOffline(in topology: Topology) async throws {
        // This read can't tell a monitor that's off from one that has gone.
        guard !topology.listReadFailed else { return }
        for (index, record) in records.enumerated() {
            guard record.onlineDisplay(in: topology) == nil, let id = Self.idToEnable(record, in: topology) else {
                offlineSince[index] = nil
                continue
            }
            let since = offlineSince[index] ?? clock.now()
            offlineSince[index] = since
            if clock.now().timeIntervalSince(since) > Seconds.reenableAfter {
                Self.log.notice("Display \(id) is still off, so it gets another enable")
                try await enable(id)
                offlineSince[index] = clock.now()
            }
        }
    }

    /// Step 5: the recorded mode where it differs, and always the recorded origin. A mode the display
    /// doesn't list is left out, and the commit would leave it out anyway. A list can lack the mode for a
    /// moment after the display returns, so at first that only fails this attempt's read-back, which
    /// tries again. Once it has been absent for long enough, the display goes without it.
    ///
    /// An empty list is a failed read, or this process's stale copy of the display, and says nothing
    /// about the mode. Skipping on it could leave a monitor at the wrong rate and call that verified,
    /// so the mode stays in and the commit decides. Its wait only goes on while commits say the mode
    /// isn't there.
    private func changes(for displays: [PresentDisplay]) -> [DisplayChange] {
        modeNotOffered = []
        modeAskedBlind = []
        let now = clock.now()
        return displays.flatMap { item -> [DisplayChange] in
            let origin = DisplayChange.origin(item.display.id, item.record.origin)
            guard item.display.mode?.matches(item.record.mode) != true else { return [origin] }
            let mode = DisplayChange.mode(item.display.id, item.record.mode)
            let offered = backend.modes(of: item.display.id)
            if offered.contains(where: { $0.matches(item.record.mode) }) {
                modeAbsentSince[item.index] = now
                return [mode, origin]
            }
            if now.timeIntervalSince(modeAbsentSince[item.index] ?? now) >= Seconds.modeAbsentLimit {
                Self.log.error("Display \(item.display.id) no longer offers its recorded mode, so it only gets its origin")
                modeNotOffered.insert(item.index)
                return [origin]
            }
            if offered.isEmpty {
                modeAskedBlind.insert(item.index)
                return [mode, origin]
            }
            Self.log.notice("Display \(item.display.id) doesn't list its recorded mode yet, so this attempt only sets its origin")
            return [origin]
        }
    }

    /// A commit that doesn't name a display in `modesNotApplied` has said nothing against a mode asked
    /// for on an empty list, so that display's wait for it starts over.
    private func restartBlindModeWaits(in displays: [PresentDisplay], except unlisted: Set<DisplayID>) {
        let now = clock.now()
        for item in displays where modeAskedBlind.contains(item.index) && !unlisted.contains(item.display.id) {
            modeAbsentSince[item.index] = now
        }
    }

    /// Step 6. What was committed has to read back as recorded, and everything else it was waiting
    /// for has to be among that. A recorded display that isn't online has to be known to be gone: one
    /// that may be plugged in and dark fails this, because whoever reads the report may never try again.
    ///
    /// With the old main missing, macOS picks a new main and shifts everything to keep it at (0,0),
    /// so only the positions relative to each other can match. With the old main back, they have to
    /// match exactly, because that's what makes it main again.
    private func readBackMatches(_ committed: [PresentDisplay]) -> Bool {
        let topology = read()
        guard !topology.listReadFailed else { return false }
        let committedIndexes = Set(committed.map(\.index))
        let back = presentDisplays(in: topology).filter { committedIndexes.contains($0.index) }
        guard present.isSubset(of: committedIndexes), back.count == committed.count, let first = back.first else {
            return false
        }
        guard !records.contains(where: { Self.isDark($0, in: topology) }) else { return false }

        let oldMainIsBack = back.contains(where: \.record.wasMain)
        let shiftX = oldMainIsBack ? 0 : first.display.origin.x - first.record.origin.x
        let shiftY = oldMainIsBack ? 0 : first.display.origin.y - first.record.origin.y
        return back.allSatisfy { item in
            let origin = item.record.origin
            return item.display.origin == DisplayOrigin(x: origin.x + shiftX, y: origin.y + shiftY)
                && (modeNotOffered.contains(item.index) || item.display.mode?.matches(item.record.mode) == true)
        }
    }

    func report() -> RestoreReport {
        let topology = backend.topology()
        var restored: [DisplayID] = []
        var missing: [PhysicalRecord] = []
        var stillDark: [PhysicalRecord] = []
        for record in records {
            if let display = record.onlineDisplay(in: topology) {
                restored.append(display.id)
            } else if Self.isDark(record, in: topology) {
                stillDark.append(record)
            } else {
                missing.append(record)
            }
        }
        return RestoreReport(
            restored: restored,
            missing: missing,
            stillDark: stillDark,
            attempts: attempts,
            verified: verified,
            anyReturned: !restored.isEmpty,
            modeNotOffered: modeNotOffered.sorted().map { records[$0] }
        )
    }

    // MARK: Reconnect with no records

    func reconnect(_ entries: [RegistryEntry]) async throws -> Bool {
        let hold = try await wakeDisplays()
        defer { hold.release() }

        var tried = Set<DisplayID>()
        for entry in entries {
            let topology = read()
            let isOnline = RecordedMonitor.listing(id: entry.lastID, identity: entry.identity, online: true, in: topology) != nil
            // An entry can be left on a stale twin, which reads as an empty pipe and never comes on.
            let isEmptyPipe = topology.display(entry.lastID)?.kind == .emptyPipe
            guard !isOnline, !isEmptyPipe, tried.insert(entry.lastID).inserted else { continue }
            try await enable(entry.lastID)
            try await pass(Seconds.afterEnable)
        }
        tried.formUnion(try await enableEveryOfflineDisplay(except: tried))

        _ = try await wait(upTo: Seconds.allOnlineLimit) { topology in
            !tried.contains { Self.mayStillComeOn($0, entries: entries, in: topology) }
        }
        return read().online.contains { $0.kind == .physical }
    }

    /// Whether the reconnect waits for a display it tried. It waits for an entry's own listing, by its ID
    /// or its location, and for an offline monitor no entry knows. It doesn't wait for one that has left
    /// the list, or for a stale twin: one marked as an empty pipe, or one that shares an entry's vendor,
    /// model and serial and nothing else, since that's no sign of the monitor. While the fallback is up
    /// or the list can't be read, nothing offline is listed, so it waits for everything not yet online.
    private static func mayStillComeOn(_ id: DisplayID, entries: [RegistryEntry], in topology: Topology) -> Bool {
        if topology.online.contains(where: { $0.id == id && $0.kind == .physical }) { return false }
        if topology.listReadFailed || fallbackIsUp(in: topology) { return true }
        guard let display = topology.display(id), !display.isOnline, display.kind == .physical else { return false }
        let sameMonitor = entries.filter { $0.identity.isSameMonitor(as: display.identity) }
        return sameMonitor.isEmpty
            || sameMonitor.contains { RecordedMonitor.isListing(display, id: $0.lastID, identity: $0.identity) }
    }

    // MARK: Shared steps

    /// A vanished display reads as all ones and a stale twin reads as an empty pipe, and neither is any
    /// use to enable. Each one is checked on a fresh read, because turning a monitor on makes its twin
    /// stale. Returns the IDs it tried.
    private func enableEveryOfflineDisplay(except tried: Set<DisplayID>) async throws -> Set<DisplayID> {
        func offline(in topology: Topology) -> [DisplayID] {
            topology.displays.filter { display in
                !display.isOnline && display.identity.vendor != 0 && display.kind != .emptyPipe
                    && !tried.contains(display.id)
            }.map(\.id)
        }
        var enabled = Set<DisplayID>()
        for id in offline(in: read()) {
            guard offline(in: read()).contains(id) else { continue }
            try await enable(id)
            enabled.insert(id)
        }
        return enabled
    }

    /// A failed enable is usually everything being asleep, so each retry wakes the displays first.
    private func enable(_ id: DisplayID) async throws {
        for attempt in 1...Self.enableAttempts {
            do {
                try blockingCall { try backend.setEnabled(id, true) }
                return
            } catch {
                Self.log.error("Enabling display \(id) failed, try \(attempt): \(String(describing: error), privacy: .public)")
                guard attempt < Self.enableAttempts else { break }
                power.declareUserActivity()
                try await pass(Seconds.enableRetry)
            }
        }
    }

    // MARK: Reads

    /// Every read goes through here, so a display counts as present from the moment any read shows it.
    private func read() -> Topology {
        let topology = backend.topology()
        let online = Set(presentDisplays(in: topology).map(\.index))
        present.formUnion(online)

        let now = clock.now()
        modeAbsentSince = modeAbsentSince.filter { online.contains($0.key) }
        for index in online where modeAbsentSince[index] == nil {
            modeAbsentSince[index] = now
        }
        return topology
    }

    private func presentDisplays(in topology: Topology) -> [PresentDisplay] {
        records.enumerated().compactMap { index, record in
            record.onlineDisplay(in: topology).map {
                PresentDisplay(index: index, record: record, display: $0)
            }
        }
    }

    /// Not online and not known to be gone: listed offline under its recorded ID or at its recorded
    /// location, by the rule in `RecordedMonitor`. While the OS fallback display is up it's all that any
    /// list shows, and a list that couldn't be read shows nothing either, so neither says it has gone.
    private static func isDark(_ record: PhysicalRecord, in topology: Topology) -> Bool {
        guard record.onlineDisplay(in: topology) == nil else { return false }
        return topology.listReadFailed
            || fallbackIsUp(in: topology)
            || record.offlineListing(in: topology) != nil
    }

    private static func fallbackIsUp(in topology: Topology) -> Bool {
        topology.displays.contains { $0.kind == .osFallback }
    }

    /// The listing's current ID. With the fallback up, the recorded ID is all there is to go on.
    private static func idToEnable(_ record: PhysicalRecord, in topology: Topology) -> DisplayID? {
        if let listed = record.offlineListing(in: topology) { return listed.id }
        return fallbackIsUp(in: topology) ? record.id : nil
    }

    // MARK: Time

    /// True if `condition` held before the limit. Polls the topology.
    private func wait(upTo limit: Double, until condition: (Topology) -> Bool) async throws -> Bool {
        let deadline = clock.now().addingTimeInterval(limit)
        while !condition(read()) {
            guard clock.now() < deadline else { return false }
            try await pass(Seconds.poll)
        }
        return true
    }

    /// All waiting goes through here, so the heartbeat holds inside every wait. Throws if the task is
    /// cancelled, which is how every loop in this run stops.
    private func pass(_ seconds: Double) async throws {
        var left = seconds
        while left > 0 {
            let slice = min(left, Seconds.beat)
            try await clock.sleep(seconds: slice)
            left -= slice

            let now = clock.now()
            if now.timeIntervalSince(lastBeat) >= Seconds.beat {
                lastBeat = now
                onProgress()
            }
        }
    }

    /// A live `setEnabled` or `commit` can block this thread for about 10 seconds, and the heartbeat
    /// has to go on through it, but not for as long as a hung call lasts.
    private func blockingCall(_ call: () throws -> Void) rethrows {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let deadline = DispatchTime.now() + blockedCallHeartbeat.limit
        timer.schedule(deadline: .now() + blockedCallHeartbeat.interval, repeating: blockedCallHeartbeat.interval)
        timer.setEventHandler { [onProgress] in
            if DispatchTime.now() < deadline { onProgress() }
        }
        timer.resume()
        defer { timer.cancel() }
        try call()
    }
}

extension DisplayIdentity {
    /// These three stay readable while a display is off, unlike its UUID and name.
    fileprivate func isSameMonitor(as other: DisplayIdentity) -> Bool {
        vendor == other.vendor && model == other.model && serial == other.serial
    }
}
