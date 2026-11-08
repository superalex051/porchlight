import ADFoundation
import ADModel
import Foundation
import Synchronization
import Testing

@testable import ADEngine

/// A clock that moves only when the sizer sleeps, and can do something at each sleep, such as Parsec
/// saving its config while the sizer waits for it.
private final class WaitClock: ADClock {
    private let inner: AutoAdvancingClock
    private let onSleep = Mutex<(@Sendable (Int) throws -> Void)?>(nil)
    private let sleeps = Mutex(0)

    init(start: Date) {
        inner = AutoAdvancingClock(start: start)
    }

    func now() -> Date { inner.now() }

    func sleep(seconds: Double) async throws {
        try await inner.sleep(seconds: seconds)
        let count = sleeps.withLock { count in
            count += 1
            return count
        }
        try onSleep.withLock { $0 }?(count)
    }

    /// Runs `action` after each sleep, with how many there have been.
    func whenSleeping(_ action: @escaping @Sendable (Int) throws -> Void) {
        onSleep.withLock { $0 = action }
    }

    var sleepCount: Int { sleeps.withLock { $0 } }
}

/// The chooser on its own, in a temp folder, with a clock that moves only when the chooser waits. Each
/// test sets up one rule.
private final class SizerRig {
    let folder: URL
    let clock = WaitClock(start: Date(timeIntervalSinceReferenceDate: 815_000_000))
    let lines = Recorder<String>()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var now: Date { clock.now() }
    var presetsURL: URL { folder.appending(component: "presets.json") }
    var logURL: URL { folder.appending(component: "parsec-log.txt") }
    var configURL: URL { folder.appending(component: "parsec-config.json") }

    var sizer: DeviceSizer {
        let lines = lines
        return DeviceSizer(
            clients: ClientStore(url: folder.appending(component: "clients.json"), log: { lines.append($0) }),
            presets: PresetStore(url: presetsURL, log: { _ in }),
            parsecLog: logURL,
            parsecConfig: configURL,
            clock: clock,
            timeZone: ParsecFixture.utc,
            log: { lines.append($0) }
        )
    }

    func clients(
        autoSize: Bool = true,
        _ rules: [ClientRule],
        matchClient: Bool = true,
        clearOfNotch: Bool = true,
        phoneRoom: RoomFactor = .phoneDefault
    ) throws {
        try sizer.clients.write(ClientMapping(
            autoSize: autoSize, clients: rules, matchClient: matchClient, clearOfNotch: clearOfNotch, phoneRoom: phoneRoom
        ))
    }

    func parsec(_ lines: [String]) throws {
        try ParsecFixture.write(lines, to: logURL)
    }

    func config(_ size: (w: Int, h: Int)?, savedAt saved: Date) throws {
        try ParsecFixture.writeConfig(size, savedAt: saved, to: configURL)
    }

    /// What the chooser picked, and the one line it logged for it.
    func choose(client: String = "parsec") async -> (Preset, String?) {
        let preset = await sizer.choose(client: client)
        return (preset, lines.values.last)
    }
}

private let macBook120 = ClientRule(name: "MacBook", address: "192.168.0.232", preset: "MacBook 14 120 Hz")
private let macBook14 = Preset(name: "MacBook 14", lookslike: "1728x1080", hidpi: true, hz: 60)
/// A documentation address (RFC 5737), standing in for a phone on cellular.
private let phoneAddress = "203.0.113.7"
private let iPhone17Pro = (w: 2622, h: 1206)

/// A client's own size: always HiDPI at 60 Hz, named by its looks like size.
private func matched(_ lookslike: String) -> Preset {
    Preset(name: lookslike, lookslike: lookslike, hidpi: true, hz: 60)
}

@Suite struct DeviceSizerTests {
    @Test func theMappedPresetOfTheNewestConnect() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120, ClientRule(name: "iPad", address: "::ffff:192.168.0.10", preset: "4K Screen")])
        try rig.parsec(ParsecFixture.connect(from: "::ffff:192.168.0.10", at: rig.now - 59))
        let time = ParsecFixture.stamp(rig.now - 59).suffix(8)

        let (preset, line) = await rig.choose()

        #expect(preset == Preset(name: "4K Screen", lookslike: "1920x1080", hidpi: true, hz: 60))
        #expect(line == "Auto size: the Parsec connect at \(time) came from 192.168.0.10, which is client iPad,"
            + " so the size is 4K Screen")
    }

    /// Mapped to `MacBook 14` on purpose isn't the default, and the log says which it was.
    @Test func aClientMappedToTheDefaultSaysSo() async throws {
        let rig = try SizerRig()
        try rig.clients([ClientRule(name: "MacBook", address: "192.168.0.232", preset: "macbook 14")])
        try rig.parsec(ParsecFixture.connect(at: rig.now))

        let (preset, line) = await rig.choose()

        #expect(preset == macBook14)
        #expect(line?.hasSuffix("which is client MacBook, so the size is MacBook 14") == true)
    }

    /// With no file, presets by address are off and matching the client is on. With no config to
    /// match, that's the default.
    @Test func noFileMatchesTheClientButNeedsAConfig() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        let time = ParsecFixture.stamp(rig.now).suffix(8)

        #expect(await rig.choose() == (
            macBook14,
            "Auto size: the Parsec connect at \(time) came from 192.168.0.232, and presets by address are off;"
                + " Parsec's config can't be read, so the size is MacBook 14, the default"
        ))
        #expect(!FileManager.default.fileExists(atPath: rig.folder.appending(component: "clients.json").path))
    }

    @Test func offWhenBothRulesAreOff() async throws {
        let rig = try SizerRig()
        try rig.clients(autoSize: false, [macBook120], matchClient: false)
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose() == (macBook14, "Auto size: off, so the size is MacBook 14, the default"))
    }

    /// A typo in a hand edit reads as everything off, not as the defaults, so it gives the default size.
    @Test func anInvalidFileIsLoggedAndReadsAsOff() async throws {
        let rig = try SizerRig()
        try Data("[1, 2]".utf8).write(to: rig.folder.appending(component: "clients.json"))
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose().0 == macBook14)
        #expect(rig.lines.values == [
            "clients.json isn't valid, so size per device is off",
            "Auto size: off, so the size is MacBook 14, the default",
        ])
    }

    @Test func onlyParsecSessions() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose(client: "vnc").1
            == "Auto size: only Parsec sessions are sized per device, and this one is for vnc, so the size is MacBook 14, the default")
    }

    @Test func aConnectOverAMinuteOldIsFromAnEarlierSession() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now - 61))
        try rig.config(iPhone17Pro, savedAt: rig.now - 61)

        #expect(await rig.choose() == (macBook14, "Auto size: no Parsec connect in the last 60 s, so the size is MacBook 14, the default"))
    }

    @Test func aConnectFromTheFutureIsNotTrusted() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now + 3))
        #expect(await rig.choose().0.hz == 120, "Within the log's rounding")

        try rig.parsec(ParsecFixture.connect(at: rig.now + 3600))
        #expect(await rig.choose().0 == macBook14)
    }

    @Test func aGuestWhoLeftIsNoGuest() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now - 10) + ParsecFixture.disconnect(at: rig.now - 1))

        #expect(await rig.choose().1 == "Auto size: no Parsec connect in the last 60 s, so the size is MacBook 14, the default")
    }

    @Test func aConnectWithNoAddress() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120], matchClient: false)
        try rig.parsec(ParsecFixture.outgoing(at: rig.now - 50) + ParsecFixture.connect(from: nil, at: rig.now))

        let time = ParsecFixture.stamp(rig.now).suffix(8)
        #expect(await rig.choose() == (macBook14, "Auto size: the Parsec connect at \(time) has no address, so the size is MacBook 14, the default"))
    }

    @Test func aDeletedPresetFallsBack() async throws {
        let rig = try SizerRig()
        try rig.clients([ClientRule(name: "MacBook", address: "192.168.0.232", preset: "Gone")], matchClient: false)
        try rig.parsec(ParsecFixture.connect(at: rig.now))

        #expect(await rig.choose() == (
            macBook14,
            "Auto size: client MacBook asks for preset Gone, which isn't saved, so the size is MacBook 14, the default"
        ))
    }

    /// With matching off, an address that's no client gives the default, with the line it always had.
    @Test func anUnknownAddressWithMatchingOff() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120], matchClient: false)
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)
        let time = ParsecFixture.stamp(rig.now).suffix(8)

        #expect(await rig.choose() == (
            macBook14,
            "Auto size: \(phoneAddress), from the Parsec connect at \(time), isn't a client, so the size is MacBook 14, the default"
        ))
        #expect(rig.clock.sleepCount == 0, "Matching is off, so nothing waits for Parsec's config")
    }

    /// With `MacBook 14` deleted from `presets.json`, the default is still its built-in size.
    @Test func theDefaultSurvivesItsPresetsDeletion() async throws {
        let rig = try SizerRig()
        try Data(#"[{"name":"Other","lookslike":"1280x800","hidpi":true,"hz":60}]"#.utf8).write(to: rig.presetsURL)
        try Data("2\n".utf8).write(to: rig.folder.appending(component: "presets-version"))

        #expect(await rig.choose().0 == macBook14)
    }

    /// For a session that's already running, the start keeps its size, and the log says so rather than
    /// name one. The preset is still chosen, for a session that ends before the start gets its turn.
    @Test func aRunningSessionKeepsItsSize() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now))

        let preset = await rig.sizer.choose(client: "parsec", sessionRunning: true)

        #expect(preset.hz == 120)
        #expect(rig.lines.values == ["Auto size: a session for parsec is already running, so it keeps its size"])
    }

    /// A FIFO in place of Parsec's log or config would block a plain open, and the sizer runs on the main
    /// actor. Neither is a regular file, so the size falls back at once. If it does block, a writer lets
    /// the stuck open go on, so the run doesn't hang.
    @Test(arguments: ["log", "config"])
    func aFIFOInPlaceOfAParsecFileFallsBackAtOnce(_ which: String) throws {
        let rig = try SizerRig()
        try rig.clients([], matchClient: true)
        let fifo = which == "log" ? rig.logURL : rig.configURL
        if which == "config" { try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now)) }
        let path = fifo.path(percentEncoded: false)
        #expect(mkfifo(path, 0o600) == 0)

        let sizer = rig.sizer
        let picked = Recorder<Preset>()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            picked.append(await sizer.choose(client: "parsec"))
            finished.signal()
        }
        let returned = finished.wait(timeout: .now() + 5) == .success
        if !returned {
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = finished.wait(timeout: .now() + 5)
        }

        #expect(returned, "choose blocked on the FIFO")
        #expect(picked.values == [macBook14])
        let why = which == "log" ? "Parsec's log can't be read" : "Parsec's config can't be read"
        #expect(rig.lines.values.last?.contains("\(why), so the size is MacBook 14, the default") == true)
    }

    @Test func aHandEditedAddressInParsecsFormMatches() async throws {
        let rig = try SizerRig()
        try rig.clients([ClientRule(name: "MacBook", address: "::ffff:192.168.0.232", preset: "MacBook 14 120 Hz")])
        try rig.parsec(ParsecFixture.connect(at: rig.now))

        #expect(await rig.choose().0.hz == 120)
    }
}

/// Rule 2: the size the client reported, from Parsec's config, and whether Parsec saved it at this connect.
@Suite struct MatchClientTests {
    /// The brief's own line, from a phone on cellular held upright, with the default phone room.
    @Test func aSizeSavedAtTheConnectIsReportedByThisClient() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(from: "::ffff:\(phoneAddress)", at: rig.now))
        try rig.config((w: 1206, h: 2622), savedAt: rig.now)
        let time = ParsecFixture.stamp(rig.now).suffix(8)

        #expect(await rig.choose() == (
            matched("1500x804"),
            "Auto size: \(phoneAddress), from the Parsec connect at \(time), isn't a client; the client reported 1206x2622,"
                + " so the size is 1500x804 (clear of the notch, phone room 4/3)"
        ))
        #expect(rig.clock.sleepCount == 0, "A size saved at the connect needs no wait")
    }

    /// The connect line's second is cut short, and Parsec can save the size just before writing it.
    @Test(arguments: [-2.0, -1.5, -0.4, 0, 1, 30])
    func savedWithinTheSlackCountsAsThisConnect(_ offset: Double) async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config((w: 2360, h: 1640), savedAt: rig.now + offset)

        let (preset, line) = await rig.choose()

        #expect(preset == matched("1180x820"))
        #expect(line?.contains("; the client reported 2360x1640, so the size is 1180x820") == true, "\(line ?? "")")
        #expect(rig.clock.sleepCount == 0)
    }

    /// Parsec doesn't always save a size that hasn't changed (a live connect at 14:33:10 on 2026-11-08
    /// left the file as the 14:05:13 connect saved it). The size is still used, after a wait, and the
    /// log says it was saved at an earlier connect.
    @Test func aSizeSavedEarlierIsStillUsedAfterTheWait() async throws {
        let rig = try SizerRig()
        let connect = rig.now
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: connect))
        let saved = connect - 1677
        try rig.config(iPhone17Pro, savedAt: saved)
        let time = ParsecFixture.stamp(connect).suffix(8)
        let savedTime = ParsecFixture.stamp(saved).suffix(8)

        #expect(await rig.choose() == (
            matched("1500x804"),
            "Auto size: the Parsec connect at \(time) came from \(phoneAddress), and presets by address are off;"
                + " Parsec kept 2622x1206 from an earlier connect (saved at \(savedTime)),"
                + " so the size is 1500x804 (clear of the notch, phone room 4/3)"
        ))
        #expect(rig.now.timeIntervalSince(connect) >= DeviceSizer.configWaitSeconds, "It waited for a new size first")
        #expect(rig.now.timeIntervalSince(connect) < DeviceSizer.configWaitSeconds + 1)
    }

    @Test func justOutsideTheSlackIsEarlier() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config((w: 2360, h: 1640), savedAt: rig.now - 2.5)

        #expect(await rig.choose().1?.contains("Parsec kept 2360x1640 from an earlier connect") == true)
    }

    @Test func aSizeFromAnotherDayNamesTheDay() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        let saved = rig.now - 3 * 86_400
        try rig.config(iPhone17Pro, savedAt: saved)

        #expect(await rig.choose().1?.contains("(saved at \(ParsecFixture.stamp(saved)))") == true)
    }

    /// Parsec saves the new size while the sizer waits: the new one counts, and the wait stops there.
    @Test func aSizeSavedDuringTheWaitIsUsed() async throws {
        let rig = try SizerRig()
        let connect = rig.now
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: connect))
        try rig.config((w: 2360, h: 1640), savedAt: connect - 600)
        let configURL = rig.configURL
        let clock = rig.clock
        rig.clock.whenSleeping { count in
            if count == 4 { try ParsecFixture.writeConfig(iPhone17Pro, savedAt: clock.now(), to: configURL) }
        }

        let (preset, line) = await rig.choose()

        #expect(preset == matched("1500x804"))
        #expect(line?.contains("; the client reported 2622x1206, so the size is 1500x804") == true, "\(line ?? "")")
        #expect(rig.clock.sleepCount == 4)
    }

    /// A file caught half written has no size yet, so the sizer looks again.
    @Test func aHalfWrittenConfigIsReadAgain() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        let configURL = rig.configURL
        let clock = rig.clock
        try Data(ParsecFixture.config(iPhone17Pro).prefix(200).utf8).write(to: configURL)
        rig.clock.whenSleeping { count in
            if count == 2 { try ParsecFixture.writeConfig(iPhone17Pro, savedAt: clock.now(), to: configURL) }
        }

        #expect(await rig.choose().0 == matched("1500x804"))
        #expect(rig.clock.sleepCount == 2)
    }

    /// A second start for a running session doesn't wait: its size won't be used.
    @Test func aRunningSessionDoesntWait() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now - 600)

        let preset = await rig.sizer.choose(client: "parsec", sessionRunning: true)

        #expect(preset == matched("1500x804"))
        #expect(rig.clock.sleepCount == 0)
        #expect(rig.lines.values == ["Auto size: a session for parsec is already running, so it keeps its size"])
    }

    @Test func noConfigIsTheDefaultAfterTheWait() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        let start = rig.now

        let (preset, line) = await rig.choose()

        #expect(preset == macBook14)
        #expect(line?.hasSuffix("; Parsec's config can't be read, so the size is MacBook 14, the default") == true)
        #expect(rig.now.timeIntervalSince(start) >= DeviceSizer.configWaitSeconds)
    }

    @Test func aConfigWithNoSizeIsTheDefault() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config(nil, savedAt: rig.now)
        let time = ParsecFixture.stamp(rig.now).suffix(8)

        #expect(await rig.choose() == (
            macBook14,
            "Auto size: the Parsec connect at \(time) came from \(phoneAddress), and presets by address are off;"
                + " Parsec's config has no client size, so the size is MacBook 14, the default"
        ))
    }

    @Test(arguments: [
        ((w: 1136, h: 640), "the client reported 1136x640, which is smaller than 1280x720"),
        ((w: 5120, h: 2880), "the client reported 5120x2880, which is taller than the 2160 lines Parsec streams"),
    ])
    func aSizeNoSessionCanMatchIsTheDefault(_ size: (w: Int, h: Int), _ why: String) async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config(size, savedAt: rig.now)

        let (preset, line) = await rig.choose()

        #expect(preset == macBook14)
        #expect(line?.hasSuffix("; \(why), so the size is MacBook 14, the default") == true, "\(line ?? "")")
    }

    @Test func theNotchAndRoomSettingsApply() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        try rig.clients(autoSize: false, [], phoneRoom: .pixelForPixel)
        #expect(await rig.choose().0 == matched("1125x603"))
        #expect(rig.lines.values.last?.hasSuffix("so the size is 1125x603 (clear of the notch)") == true)

        try rig.clients(autoSize: false, [], clearOfNotch: false)
        #expect(await rig.choose().0 == matched("1748x804"))
        #expect(rig.lines.values.last?.hasSuffix("so the size is 1748x804 (phone room 4/3)") == true)

        try rig.clients(autoSize: false, [], clearOfNotch: false, phoneRoom: .pixelForPixel)
        #expect(await rig.choose().0 == matched("1311x603"))
        #expect(rig.lines.values.last?.hasSuffix("so the size is 1311x603") == true)
    }
}

/// Which rule wins: a preset by address, then the client's size, then the default.
@Suite struct AutoSizeRuleOrderTests {
    @Test func aPresetByAddressWinsOverTheClientsSize() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose().0.name == "MacBook 14 120 Hz")
        #expect(rig.clock.sleepCount == 0, "A mapped client never waits for Parsec's config")
    }

    @Test func anAddressThatIsNoClientGetsItsOwnSize() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose().0 == matched("1500x804"))
    }

    @Test func aClientWhosePresetIsGoneGetsItsOwnSize() async throws {
        let rig = try SizerRig()
        try rig.clients([ClientRule(name: "MacBook", address: "192.168.0.232", preset: "Gone")])
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        try rig.config((w: 3024, h: 1964), savedAt: rig.now)

        #expect(await rig.choose() == (
            matched("1512x982"),
            "Auto size: client MacBook asks for preset Gone, which isn't saved; the client reported 3024x1964,"
                + " so the size is 1512x982"
        ))
    }

    @Test func withPresetsByAddressOffEvenAMappedClientGetsItsOwnSize() async throws {
        let rig = try SizerRig()
        try rig.clients(autoSize: false, [macBook120])
        try rig.parsec(ParsecFixture.connect(at: rig.now))
        try rig.config((w: 3024, h: 1964), savedAt: rig.now)

        #expect(await rig.choose().0 == matched("1512x982"))
    }

    @Test func aConnectWithNoAddressGetsItsOwnSize() async throws {
        let rig = try SizerRig()
        try rig.clients([macBook120])
        try rig.parsec(ParsecFixture.connect(from: nil, at: rig.now))
        try rig.config((w: 2360, h: 1640), savedAt: rig.now)
        let time = ParsecFixture.stamp(rig.now).suffix(8)

        #expect(await rig.choose() == (
            matched("1180x820"),
            "Auto size: the Parsec connect at \(time) has no address; the client reported 2360x1640, so the size is 1180x820"
        ))
    }

    /// The client's size needs a Parsec connect just now, as the address does.
    @Test func noRecentConnectIsTheDefaultWhateverTheConfigSays() async throws {
        let rig = try SizerRig()
        try rig.parsec(ParsecFixture.connect(from: phoneAddress, at: rig.now - 120))
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose() == (macBook14, "Auto size: no Parsec connect in the last 60 s, so the size is MacBook 14, the default"))
        #expect(rig.clock.sleepCount == 0)
    }

    @Test func noParsecLogIsTheDefaultWhateverTheConfigSays() async throws {
        let rig = try SizerRig()
        try rig.config(iPhone17Pro, savedAt: rig.now)

        #expect(await rig.choose() == (macBook14, "Auto size: Parsec's log can't be read, so the size is MacBook 14, the default"))
    }
}

@Suite struct ClientStoreTests {
    private func store() throws -> (ClientStore, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = folder.appending(component: "clients.json")
        return (ClientStore(url: url, log: { _ in }), url)
    }

    @Test func noFileHasTheDefaults() throws {
        let (store, url) = try store()

        #expect(try store.read() == .empty)
        #expect(store.mapping() == .empty)
        #expect(store.mapping().matchClient && store.mapping().clearOfNotch)
        #expect(store.mapping().phoneRoom == .phoneDefault)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writesAndReadsBack() throws {
        let (store, url) = try store()
        let mapping = ClientMapping(
            autoSize: true, clients: [macBook120], matchClient: false, clearOfNotch: false, phoneRoom: .pixelForPixel
        )

        try store.write(mapping)

        #expect(try store.read() == mapping)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// A file written before the client size settings has them at their defaults.
    @Test func aHandEditMayLeaveOutAnyKey() throws {
        let (store, url) = try store()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data("{}".utf8).write(to: url)
        #expect(try store.read() == .empty)

        try Data(#"{"autoSize": true}"#.utf8).write(to: url)
        #expect(try store.read() == ClientMapping(autoSize: true, clients: []))

        try Data(#"{"matchClient": false, "phoneRoom": "3/2"}"#.utf8).write(to: url)
        #expect(try store.read() == ClientMapping(
            autoSize: false, clients: [], matchClient: false, clearOfNotch: true, phoneRoom: RoomFactor(parsing: "3/2")!
        ))
    }

    @Test func anEntryMissingAFieldMakesTheFileInvalid() throws {
        let (store, url) = try store()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"clients": [{"name": "MacBook", "preset": "MacBook 14"}]}"#.utf8).write(to: url)

        #expect(throws: ClientStore.Unusable(reason: "clients.json isn't valid")) { try store.read() }
        #expect(store.mapping() == .off)
    }

    @Test(arguments: [#"{"phoneRoom": "3"}"#, #"{"phoneRoom": 1.5}"#, #"{"phoneRoom": "1/2"}"#, #"{"clearOfNotch": "yes"}"#])
    func aBadSettingMakesTheFileInvalid(_ text: String) throws {
        let (store, url) = try store()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)

        #expect(throws: ClientStore.Unusable(reason: "clients.json isn't valid")) { try store.read() }
    }

    @Test func aFolderInItsPlaceCantBeRead() throws {
        let (store, url) = try store()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(throws: ClientStore.Unusable(reason: "clients.json can't be read")) { try store.read() }
    }
}
