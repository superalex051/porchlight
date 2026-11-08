import Foundation
import Testing

@testable import ADEngine

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

private func latest(_ lines: [String]) -> ParsecConnect? {
    ParsecLog.latestConnect(in: lines.joined(separator: "\n"), timeZone: ParsecFixture.utc)
}

/// Whole seconds, as the log has them.
private func second(_ date: Date) -> Date {
    Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
}

@Suite struct ParsecLogTests {
    @Test func readsTheRealShapeOfAConnect() {
        let found = latest(ParsecFixture.noise(at: now - 60) + ParsecFixture.connect(at: now))

        #expect(found == ParsecConnect(at: second(now), address: "192.168.0.232"))
    }

    /// The real line, verbatim, with the local time the Mac writes it in.
    @Test func readsAVerbatimLineInItsTimeZone() throws {
        let text = """
            [D 2026-11-06 15:56:37] net           = BUD|::ffff:192.168.0.232|31938
            [I 2026-11-06 15:56:37] guest01#1234567 connected.
            """
        let bucharest = try #require(TimeZone(identifier: "Europe/Bucharest"))

        let found = ParsecLog.latestConnect(in: text, timeZone: bucharest)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bucharest
        let wanted = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15, minute: 56, second: 37))
        #expect(found?.at == wanted)
        #expect(found?.address == "192.168.0.232")
    }

    @Test func theNewestConnectWins() {
        let lines = ParsecFixture.connect(from: "::ffff:192.168.0.10", at: now - 600)
            + ParsecFixture.disconnect(at: now - 300)
            + ParsecFixture.connect(at: now)

        #expect(latest(lines)?.address == "192.168.0.232")
    }

    @Test func aDisconnectAfterTheNewestConnectLeavesNone() {
        #expect(latest(ParsecFixture.connect(at: now - 10) + ParsecFixture.disconnect(at: now)) == nil)
    }

    @Test func noConnectAtAll() {
        #expect(latest(ParsecFixture.noise(at: now)) == nil)
        #expect(latest([]) == nil)
    }

    /// When this Mac connects out to another host, its `net` line names that host, and no guest.
    @Test func anOutgoingNetLineIsNeverAGuestsAddress() {
        let lines = ParsecFixture.outgoing(at: now - 120) + ParsecFixture.connect(from: nil, at: now)

        #expect(latest(lines) == ParsecConnect(at: second(now), address: nil))
        #expect(latest(ParsecFixture.outgoing(at: now)) == nil)
    }

    @Test func aNetLineCountsOnlyCloseBeforeItsConnect() {
        #expect(latest(ParsecFixture.connect(at: now, netLead: 30))?.address == "192.168.0.232")
        #expect(latest(ParsecFixture.connect(at: now, netLead: 31))?.address == nil)
    }

    /// One `net` line pairs with one connect, so a reconnect without one isn't given the old address.
    @Test func aNetLineIsUsedOnce() {
        let lines = ParsecFixture.connect(at: now - 5) + ParsecFixture.disconnect(at: now - 4)
            + ParsecFixture.connect(from: nil, at: now)

        #expect(latest(lines)?.address == nil)
    }

    @Test func readsIPv6() {
        #expect(latest(ParsecFixture.connect(from: "FE80::1:2", at: now))?.address == "fe80::1:2")
    }

    @Test func linesInAnotherShapeAreSkipped() {
        let lines = [
            "guest01#1234567 connected.",
            "[I 2026-13-45 99:99:99] guest01#1234567 connected.",
            "[I 2026-11-06 15:56:37]guest01#1234567 connected.",
            ParsecFixture.line("I", now, "two words connected."),
            ParsecFixture.line("I", now, " connected."),
        ]

        #expect(latest(lines) == nil)
    }

    @Test func readsOnlyTheEndOfABigLog() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(component: "log.txt")
        let filler = ParsecFixture.line("D", now - 30, "[0] FPS:54.8/561, L:7.8/8.6, B:0.9/10.0, N:0/0/0")
        let lines = ParsecFixture.connect(from: "::ffff:192.168.0.10", at: now - 3600)
            + Array(repeating: filler, count: 8000)
            + ParsecFixture.connect(at: now)
        try ParsecFixture.write(lines, to: url)

        let tail = try ParsecLog.tail(of: url)

        #expect(try Data(contentsOf: url).count > ParsecLog.tailBytes)
        #expect(tail.utf8.count < ParsecLog.tailBytes)
        #expect(tail.hasPrefix("[D "), "It starts at a whole line")
        #expect(!tail.contains("192.168.0.10"))
        #expect(ParsecLog.latestConnect(in: tail, timeZone: ParsecFixture.utc)?.address == "192.168.0.232")
    }

    @Test(arguments: [
        ("192.168.0.232", "192.168.0.232"),
        ("::ffff:192.168.0.232", "192.168.0.232"),
        ("::FFFF:192.168.0.232", "192.168.0.232"),
        (" 10.0.0.1 ", "10.0.0.1"),
        ("FE80:0:0:0:0:0:0:1", "fe80::1"),
        ("2a02:2f0e::7", "2a02:2f0e::7"),
    ])
    func addressesHaveOnePlainForm(_ text: String, _ wanted: String) {
        #expect(ClientAddress.normalized(text) == wanted)
    }

    @Test(arguments: ["", "192.168.0", "192.168.0.300", "MacBook", "::ffff:192.168.0", "192.168.0.232:31938"])
    func notAnAddress(_ text: String) {
        #expect(ClientAddress.normalized(text) == nil)
    }
}
