import ADIPC
import ADModel

/// Whether a guardian is there to bring the monitors back. A session won't start without one.
nonisolated public protocol GuardianProbing: Sendable {
    func isAlive() async -> Bool
}

/// Pings `guardianSocketPath`, and waits 1 second for the answer.
nonisolated public struct IPCGuardianProbe: GuardianProbing {
    private static let timeout = 1.0
    private static let answer = "pong"
    private static let busyPrefix = "busy"

    private let client: IPCClient

    public init(socketPath: String) {
        client = IPCClient(path: socketPath)
    }

    /// A busy guardian is one that answered, and is only still starting up. Anything else that isn't
    /// the right answer, and any thrown error, means there's nobody to rely on.
    public func isAlive() async -> Bool {
        do {
            let result = try await client.send(CommandRequest(operations: ["ping"], parameters: []), timeout: Self.timeout)
            return result.ok ? result.payload == Self.answer : result.reason?.hasPrefix(Self.busyPrefix) == true
        } catch {
            return false
        }
    }
}

/// A test double, also used by a dry run, which has no guardian.
nonisolated public struct FakeGuardianProbe: GuardianProbing {
    public var alive: Bool

    public init(alive: Bool = true) {
        self.alive = alive
    }

    public func isAlive() async -> Bool {
        alive
    }
}
