import ADFoundation
import ADSafety
import Synchronization

/// Every write a session makes to the ledger, one at a time.
///
/// The restorer's heartbeat can arrive from any thread, including a timer running while a display call
/// blocks. So a beat and the session's own writes share a lock, and a beat that comes late can't bring
/// back a ledger that has been cleared or undo a change of state.
nonisolated final class SessionLedgerWriter: Sendable {
    private struct State {
        /// The ledger as last written, or nil once it's cleared.
        var current: SafetyLedger?
        var isBeating = false
        var hasLoggedFailure = false
    }

    private let store: any LedgerStoring
    private let clock: any ADClock
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    init(store: any LedgerStoring, clock: any ADClock, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.clock = clock
        self.log = log
    }

    func load() throws -> SafetyLedger? {
        try store.load()
    }

    func takeSetAsideEvent() -> Bool {
        store.takeSetAsideEvent()
    }

    /// Stamps `updatedAt` and returns the ledger as written. Nothing else about it changes, so
    /// `startedAt` stays what the caller passed in.
    @discardableResult
    func save(_ ledger: SafetyLedger) throws -> SafetyLedger {
        try state.withLock { state in
            var stamped = ledger
            stamped.updatedAt = clock.now()
            try store.save(stamped)
            state.current = stamped
            return stamped
        }
    }

    func clear() throws {
        try state.withLock { state in
            try store.clear()
            state.current = nil
            state.isBeating = false
        }
    }

    /// While this is on, `beat` writes. It's on only while the restorer runs, so a failed end leaves
    /// `updatedAt` frozen, which is how the guardian knows to take over.
    func setBeating(_ on: Bool) {
        state.withLock { $0.isBeating = on }
    }

    /// For the restorer's `onProgress`, from any thread.
    func beat() {
        state.withLock { state in
            guard state.isBeating else { return }
            touch(&state)
        }
    }

    /// Moves `updatedAt` between the steps of a start, so a watcher can see it's making progress.
    func touch() {
        state.withLock { touch(&$0) }
    }

    /// A failure here takes nothing back: the records it would rewrite are already on disk. So it's
    /// logged once, and the next one tries again.
    private func touch(_ state: inout State) {
        guard var ledger = state.current else { return }
        ledger.updatedAt = clock.now()
        do {
            try store.save(ledger)
            state.current = ledger
        } catch {
            guard !state.hasLoggedFailure else { return }
            state.hasLoggedFailure = true
            log("Moving the ledger's updatedAt failed: \(error.localizedDescription)")
        }
    }
}
