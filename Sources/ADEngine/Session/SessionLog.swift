import ADFoundation
import Foundation

/// `session.log`: what the session controller did and why, for reading after the fact. Each line also
/// goes to the system log. A line that can't be written is dropped, because logging must not stop a
/// session from ending.
nonisolated public final class SessionLog: Sendable {
    private static let logger = ADLog.logger("session")

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ line: String) {
        Self.logger.notice("\(line, privacy: .public)")
        ADLog.appendLine(line, to: url)
    }
}
