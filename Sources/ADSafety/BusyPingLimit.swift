import ADFoundation
import Foundation

/// How long the guardian takes "busy" for an answer. An app that's still resuming a session answers
/// busy, and treating that as silence would risk the kill for a hung app. But the socket answers busy
/// without the part of the app that does the work, so a resume that hangs would look healthy for good,
/// with the monitors off. So busy counts for at most `seconds` in a row from one app process, and after
/// that it's no answer, and the guardian's usual row for a hung app takes over.
public struct BusyPingLimit: Sendable {
    public static let seconds: TimeInterval = 60

    private var app: ProcessRef?
    private var busySince: Date?

    public init() {}

    /// The app answered and wasn't busy, so the next busy is a new stretch.
    public mutating func noteAnswered() {
        busySince = nil
    }

    /// The app answered busy. True if that still counts as an answer. A nil `app` means it isn't known
    /// who answered, which doesn't start a new stretch. A failed ping isn't a reply and doesn't come here,
    /// because it says nothing about whether the app is still busy.
    public mutating func noteBusy(from app: ProcessRef?, at now: Date) -> Bool {
        if let app {
            if let known = self.app, known != app { busySince = nil }
            self.app = app
        }
        // A wall clock set back would otherwise give this stretch that much longer.
        guard let since = busySince, since <= now else {
            busySince = now
            return true
        }
        return now.timeIntervalSince(since) <= Self.seconds
    }
}
