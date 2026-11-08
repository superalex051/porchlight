import ADFoundation
import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Keeps displays awake. With every display asleep, turning a monitor on fails with error 1014, so
/// a restore declares user activity first.
public protocol PowerAsserting: Sendable {
    /// Wakes sleeping displays. Works from a process with no GUI.
    func declareUserActivity()

    /// Stops idle display sleep until the token is released. The caller has to keep the token.
    func holdNoDisplaySleep(reason: String) -> PowerAssertionToken
}

/// A hold on display sleep. Released by `release()` or when it's dropped. Releasing twice is harmless.
public final class PowerAssertionToken: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    public init(release: @escaping @Sendable () -> Void) {
        action = Mutex(release)
    }

    deinit {
        release()
    }

    public func release() {
        let pending = action.withLock { action in
            let pending = action
            action = nil
            return pending
        }
        pending?()
    }
}

/// The real IOKit calls. Waking a display changes its state, so these have the mutation guard too.
public final class LivePowerAssertions: PowerAsserting {
    private static let log = ADLog.logger("power")
    private static let activityName = "Porch Light is restoring displays"

    /// Apple's header asks repeat callers to pass back the ID from the last call.
    private let activityID = Mutex<IOPMAssertionID>(IOPMAssertionID(kIOPMNullAssertionID))

    public init() {}

    public func declareUserActivity() {
        TestBundleGuard.preconditionMutationAllowed()
        let result = activityID.withLock { id in
            IOPMAssertionDeclareUserActivity(Self.activityName as CFString, kIOPMUserActiveLocal, &id)
        }
        if result != kIOReturnSuccess {
            Self.log.error("Declaring user activity failed with \(result)")
        }
    }

    /// If the system refuses the assertion, this logs it and returns a token that does nothing: a
    /// restore carries on without it, because stopping would be worse than a display going to sleep.
    public func holdNoDisplaySleep(reason: String) -> PowerAssertionToken {
        TestBundleGuard.preconditionMutationAllowed()
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            Self.log.error("Holding off display sleep failed with \(result)")
            return PowerAssertionToken {}
        }
        let held = id
        return PowerAssertionToken {
            IOPMAssertionRelease(held)
        }
    }
}

/// Records calls for tests. `onDeclare` runs after each declaration, so a test can pass
/// `backend.wakeAll` to make declaring activity wake the simulated displays.
public final class FakePowerAssertions: PowerAsserting {
    private struct Record {
        var calls: [String] = []
        var declareCount = 0
        var activeHoldCount = 0
    }

    private let record = Mutex(Record())
    private let onDeclare: @Sendable () -> Void

    public init(onDeclare: @escaping @Sendable () -> Void = {}) {
        self.onDeclare = onDeclare
    }

    /// One line per call, in order: `declare`, `hold <reason>`, `release <reason>`.
    public var calls: [String] { record.withLock { $0.calls } }
    public var declareCount: Int { record.withLock { $0.declareCount } }
    public var activeHoldCount: Int { record.withLock { $0.activeHoldCount } }

    public func declareUserActivity() {
        record.withLock {
            $0.calls.append("declare")
            $0.declareCount += 1
        }
        onDeclare()
    }

    public func holdNoDisplaySleep(reason: String) -> PowerAssertionToken {
        record.withLock {
            $0.calls.append("hold \(reason)")
            $0.activeHoldCount += 1
        }
        return PowerAssertionToken { [self] in
            record.withLock {
                $0.calls.append("release \(reason)")
                $0.activeHoldCount -= 1
            }
        }
    }
}
