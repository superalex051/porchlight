import CoreGraphics
import Foundation
import Synchronization

/// Tells subscribers that the display arrangement may have changed. The pulses carry nothing, so
/// a subscriber reads the topology again, and debounces if it needs to.
public protocol TopologyEventSource: Sendable {
    func events() -> AsyncStream<Void>
}

/// Hands each pulse to every open stream.
private final class TopologyEventHub: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    deinit {
        for continuation in subscribers.withLock({ $0 }).values {
            continuation.finish()
        }
    }

    func subscribe() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let key = UUID()
            subscribers.withLock { $0[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.subscribers.withLock { $0.removeValue(forKey: key) }
            }
        }
    }

    func fire() {
        // Outside the lock, in case a subscriber's termination handler needs it.
        for continuation in subscribers.withLock({ $0 }).values {
            continuation.yield()
        }
    }
}

/// Display reconfiguration events from CoreGraphics. Create it on the main thread: the spike got no
/// events without a running `NSApplication`.
public final class LiveTopologyEvents: TopologyEventSource {
    /// One registration for the whole process, never removed, so no callback can outlive its target.
    private static let hub: TopologyEventHub = {
        // Some display calls abort until CoreGraphics has initialized, and this one initializes it.
        _ = CGMainDisplayID()
        CGDisplayRegisterReconfigurationCallback(
            { _, flags, _ in
                if LiveTopologyEvents.isChangeFinished(flags) {
                    LiveTopologyEvents.hub.fire()
                }
            },
            nil
        )
        return TopologyEventHub()
    }()

    public init() {
        _ = Self.hub
    }

    public func events() -> AsyncStream<Void> {
        Self.hub.subscribe()
    }

    /// Each change is announced twice. The first has the begin flag, while the old state still stands.
    static func isChangeFinished(_ flags: CGDisplayChangeSummaryFlags) -> Bool {
        !flags.contains(.beginConfigurationFlag)
    }
}

/// Events a test fires by hand.
public final class ManualTopologyEvents: TopologyEventSource {
    private let hub = TopologyEventHub()

    public init() {}

    public func events() -> AsyncStream<Void> {
        hub.subscribe()
    }

    public func fire() {
        hub.fire()
    }
}
