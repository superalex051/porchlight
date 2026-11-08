import ADFoundation
import ADSafety
import Foundation
import Testing

private let app = ProcessRef(pid: 100, startTime: 1)
private let relaunched = ProcessRef(pid: 200, startTime: 2)

/// A limit with its time in plain seconds. A class, because `#expect` can't call a mutating method.
private final class Pings {
    private var limit = BusyPingLimit()

    func busy(from app: ProcessRef?, at seconds: Double) -> Bool {
        limit.noteBusy(from: app, at: Date(timeIntervalSinceReferenceDate: seconds))
    }

    func answered() {
        limit.noteAnswered()
    }
}

@Test func busyCountsForAtMost60SecondsInARow() {
    let pings = Pings()

    #expect(pings.busy(from: app, at: 0))
    #expect(pings.busy(from: app, at: 30))
    #expect(pings.busy(from: app, at: 60))
    #expect(!pings.busy(from: app, at: 60.5))
    #expect(!pings.busy(from: app, at: 62), "It stays no answer, so the hung row's silence keeps growing")
}

@Test func anAnswerThatIsNotBusyStartsOver() {
    let pings = Pings()
    _ = pings.busy(from: app, at: 0)
    #expect(!pings.busy(from: app, at: 61))

    pings.answered()

    #expect(pings.busy(from: app, at: 100))
    #expect(pings.busy(from: app, at: 160))
    #expect(!pings.busy(from: app, at: 161))
}

/// The old process used up its time and was killed. The new one has to get its own, or it would be
/// killed 15 seconds into a resume that's going fine.
@Test func anotherProcessGetsItsOwnTime() {
    let pings = Pings()
    _ = pings.busy(from: app, at: 0)
    #expect(!pings.busy(from: app, at: 61))

    #expect(pings.busy(from: relaunched, at: 75))
    #expect(pings.busy(from: relaunched, at: 135))
    #expect(!pings.busy(from: relaunched, at: 136))
}

/// A ledger that can't be read for a moment must not buy a hung app more time.
@Test func notKnowingWhoAnsweredDoesNotStartOver() {
    let pings = Pings()
    _ = pings.busy(from: app, at: 0)

    #expect(pings.busy(from: nil, at: 30))
    #expect(!pings.busy(from: nil, at: 61))
    #expect(!pings.busy(from: app, at: 62))
}

@Test func learningWhoAnsweredDoesNotStartOver() {
    let pings = Pings()
    _ = pings.busy(from: nil, at: 0)

    #expect(!pings.busy(from: app, at: 61))
}

@Test func aClockSetBackStartsOverFromThere() {
    let pings = Pings()
    _ = pings.busy(from: app, at: 1_000)

    #expect(pings.busy(from: app, at: 100))
    #expect(pings.busy(from: app, at: 160))
    #expect(!pings.busy(from: app, at: 161))
}
