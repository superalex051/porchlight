import Foundation
import Synchronization

/// Writes a line again only after `interval` seconds, so that something repeating on every tick can't
/// fill a log, maybe on a disk that's already full. A line stays quiet only while it was last written
/// in the past `interval`, so a clock set back can't silence it.
public final class RepeatLimitedLog: Sendable {
    private let interval: TimeInterval
    private let clock: any ADClock
    private let sink: @Sendable (String) -> Void
    private let lastWritten = Mutex<[String: Date]>([:])

    public init(interval: TimeInterval, clock: any ADClock, sink: @escaping @Sendable (String) -> Void) {
        self.interval = interval
        self.clock = clock
        self.sink = sink
    }

    public func write(_ line: String) {
        let now = clock.now()
        func isRecent(_ written: Date) -> Bool {
            (0..<interval).contains(now.timeIntervalSince(written))
        }

        let isDue = lastWritten.withLock { lastWritten in
            if let written = lastWritten[line], isRecent(written) { return false }
            lastWritten = lastWritten.filter { isRecent($0.value) }
            lastWritten[line] = now
            return true
        }
        if isDue { sink(line) }
    }
}
