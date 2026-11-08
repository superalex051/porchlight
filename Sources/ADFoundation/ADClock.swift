import Foundation
import Synchronization

public protocol ADClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemClock: ADClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// A test clock. `sleep` moves time forward at once instead of waiting.
public final class AutoAdvancingClock: ADClock {
    private let current: Mutex<Date>

    public init(start: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        current = Mutex(start)
    }

    public func now() -> Date {
        current.withLock { $0 }
    }

    /// Throws if the task is cancelled, as a real sleep does, so a cancelled polling loop still stops.
    /// A negative wait returns without moving time, also as a real sleep does.
    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        advance(by: max(0, seconds))
        await Task.yield()
    }

    public func advance(by seconds: Double) {
        current.withLock { $0.addTimeInterval(seconds) }
    }
}
