import ADFoundation
import Foundation
import Synchronization
import Testing

private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] {
        lines.withLock { $0 }
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}

private func makeLog(clock: any ADClock) -> (RepeatLimitedLog, Lines) {
    let lines = Lines()
    return (RepeatLimitedLog(interval: 60, clock: clock) { lines.append($0) }, lines)
}

@Test func aRepeatInsideTheIntervalIsDropped() {
    let clock = AutoAdvancingClock()
    let (log, lines) = makeLog(clock: clock)

    for _ in 0..<239 {
        log.write("the same line")
        clock.advance(by: 0.25)
    }

    #expect(lines.all.count == 1)
}

@Test func aRepeatAfterTheIntervalIsWritten() {
    let clock = AutoAdvancingClock()
    let (log, lines) = makeLog(clock: clock)

    log.write("the same line")
    clock.advance(by: 60)
    log.write("the same line")

    #expect(lines.all.count == 2)
}

@Test func linesDoNotHoldEachOtherUp() {
    let (log, lines) = makeLog(clock: AutoAdvancingClock())

    log.write("one")
    log.write("two")
    log.write("one")

    #expect(lines.all == ["one", "two"])
}

@Test func aClockSetBackDoesNotSilenceALine() {
    let clock = AutoAdvancingClock()
    let (log, lines) = makeLog(clock: clock)

    log.write("the same line")
    clock.advance(by: -3600)
    log.write("the same line")

    #expect(lines.all.count == 2)
}
