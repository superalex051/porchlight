import Foundation
import Synchronization

public protocol LifecycleNotifying: Sendable {
    func launched()
    func terminated()
    func sessionChanged()
}

/// Tells every process on this Mac what the app is doing, so scripts and other apps can wait on an
/// event instead of polling.
public struct DistributedLifecycleNotifier: LifecycleNotifying {
    private let object: String?

    public init() {
        self.init(object: nil)
    }

    /// `object` lets a test tell its own posts from anyone else's.
    init(object: String?) {
        self.object = object
    }

    public func launched() {
        post("com.alexluncan.PorchLight.launched")
    }

    public func terminated() {
        post("com.alexluncan.PorchLight.terminated")
    }

    public func sessionChanged() {
        post("com.alexluncan.PorchLight.sessionChanged")
    }

    /// Delivered immediately, because a listener is often a background process, which the system
    /// could otherwise hold the notification back from.
    private func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: object,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

public enum LifecycleEvent: Equatable, Sendable {
    case launched
    case terminated
    case sessionChanged
}

/// A test double. Read `events` for every call, in order. It posts nothing.
public final class FakeLifecycleNotifier: LifecycleNotifying {
    private let recorded = Mutex<[LifecycleEvent]>([])

    public init() {}

    public var events: [LifecycleEvent] {
        recorded.withLock { $0 }
    }

    public func launched() {
        record(.launched)
    }

    public func terminated() {
        record(.terminated)
    }

    public func sessionChanged() {
        record(.sessionChanged)
    }

    private func record(_ event: LifecycleEvent) {
        recorded.withLock { $0.append(event) }
    }
}
