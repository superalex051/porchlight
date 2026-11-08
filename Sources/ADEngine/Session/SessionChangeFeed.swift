import ADFoundation
import ADModel
import Foundation

/// The session's changes since this process started, numbered from 1, for `session watch`. A watcher
/// asks for the first change after the last number it got, and waits for one if there's none yet, so
/// it gets every change in order over the one control socket. The contract is section 9 of
/// `docs/session-api.md`.
final class SessionChangeFeed {
    struct Change: Equatable {
        var number: Int
        /// The status as it was at this change.
        var status: SessionStatus
    }

    /// Far more than a watcher can fall behind by between one request and the next.
    static let kept = 32

    /// Tells one run of the app from the next, whose numbers start over.
    let instance = UUID().uuidString
    private(set) var latest = 0

    private let clock: any ADClock
    private var recent: [Change] = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0
    private var isClosed = false

    init(clock: any ADClock) {
        self.clock = clock
    }

    func record(_ status: SessionStatus) {
        guard !isClosed else { return }
        latest += 1
        recent.append(Change(number: latest, status: status))
        if recent.count > Self.kept { recent.removeFirst(recent.count - Self.kept) }
        wakeAll()
    }

    /// The app is quitting. Every wait ends now, and none starts again.
    func close() {
        isClosed = true
        wakeAll()
    }

    /// The first change after `number`, waiting up to `seconds` for one. Nil if none came. A watcher
    /// that fell further behind than `kept` gets the oldest one kept.
    func change(after number: Int, waitingUpTo seconds: Double) async -> Change? {
        if let found = first(after: number) { return found }
        guard !isClosed, seconds > 0 else { return nil }

        let id = nextWaiter
        nextWaiter += 1
        let timer = Task { [weak self, clock] in
            try? await clock.sleep(seconds: seconds)
            self?.wake(id)
        }
        // Nothing runs on this actor between making the timer and storing the waiter, so the timer
        // can't fire first and be missed.
        await withCheckedContinuation { waiters[id] = $0 }
        timer.cancel()
        return first(after: number)
    }

    private func first(after number: Int) -> Change? {
        recent.first { $0.number > number }
    }

    private func wake(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func wakeAll() {
        let all = waiters.values
        waiters = [:]
        for waiter in all { waiter.resume() }
    }
}
