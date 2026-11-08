import CoreFoundation
import Foundation
import Synchronization
import Testing
@testable import ADIntegrations

// `SMAppServiceLaunchAtLogin` is never called here: it would change this Mac's login items.

private final class NameLog: Sendable {
    private let names = Mutex<[String]>([])

    var all: [String] { names.withLock { $0 } }

    func record(_ name: String) {
        names.withLock { $0.append(name) }
    }
}

@MainActor private func runMainRunLoopBriefly() {
    CFRunLoopRunInMode(.defaultMode, 0.01, false)
}

/// Distributed notifications arrive through the main run loop, which nothing spins during a test run.
/// Lets go of the main actor between turns, in case delivery comes through the main queue instead.
@MainActor private func pumpMainRunLoop(until done: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !done(), ContinuousClock.now < deadline {
        runMainRunLoopBriefly()
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Posts for real, because the names are the contract. These reach every process on the Mac, so
/// this is the only test that posts, and it uses its own `object` so parallel runs can't cross.
@Test(.timeLimit(.minutes(1))) @MainActor func notificationNamesAreExact() async throws {
    let launched = "com.alexluncan.PorchLight.launched"
    let terminated = "com.alexluncan.PorchLight.terminated"
    let sessionChanged = "com.alexluncan.PorchLight.sessionChanged"

    let center = DistributedNotificationCenter.default()
    let object = "ADIntegrationsTests-\(UUID().uuidString)"
    let received = NameLog()
    let observers = [launched, terminated, sessionChanged].map { name in
        center.addObserver(forName: Notification.Name(name), object: object, queue: nil) { notification in
            received.record(notification.name.rawValue)
        }
    }
    defer { observers.forEach(center.removeObserver) }

    let notifier = DistributedLifecycleNotifier(object: object)

    notifier.launched()
    try await pumpMainRunLoop { received.all.count == 1 }
    #expect(received.all == [launched])

    notifier.terminated()
    try await pumpMainRunLoop { received.all.count == 2 }
    #expect(received.all == [launched, terminated])

    notifier.sessionChanged()
    try await pumpMainRunLoop { received.all.count == 3 }
    #expect(received.all == [launched, terminated, sessionChanged])
}

@Test func fakeNotifierRecordsEventsInOrder() {
    let notifier = FakeLifecycleNotifier()
    #expect(notifier.events.isEmpty)

    notifier.sessionChanged()
    notifier.launched()
    notifier.terminated()

    #expect(notifier.events == [.sessionChanged, .launched, .terminated])
}
