import ADCommand
import ADModel
import Foundation
import Testing

@testable import ADEngine

/// `session start -preset=auto` and the `clients` commands, through the real parser, on the test desk in
/// memory. The rig's Parsec log is `parsec-log.txt` in its folder, read in UTC.
@MainActor
@Suite struct SizePerDeviceCommandTests {
    private func parsecLog(_ rig: DispatcherRig) -> URL {
        rig.rig.folder.appending(component: "parsec-log.txt", directoryHint: .notDirectory)
    }

    private func clientsFile(_ rig: DispatcherRig) -> URL {
        rig.rig.folder.appending(component: "clients.json", directoryHint: .notDirectory)
    }

    private func parsecConfig(_ rig: DispatcherRig) -> URL {
        rig.rig.folder.appending(component: "parsec-config.json", directoryHint: .notDirectory)
    }

    /// The first lines of `clients list`: the settings.
    private func settings(auto: Bool = false, match: Bool = true, notch: Bool = true, room: String = "4/3") -> String {
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        return "autoSize=\(onOff(auto))\nmatchClient=\(onOff(match))\nclearOfNotch=\(onOff(notch))\nphoneRoom=\(room)"
    }

    /// The MacBook connected a second ago.
    private func macBookJustConnected(_ rig: DispatcherRig) throws {
        let now = rig.rig.clock.now()
        try ParsecFixture.write(ParsecFixture.connect(at: now.addingTimeInterval(-1)), to: parsecLog(rig))
    }

    private func mapMacBookTo120(_ rig: DispatcherRig) async throws {
        let set = try await rig.run(
            "clients", "set", "-name=MacBook", "-address=\(ParsecFixture.macBook)", "-preset=MacBook 14 120 Hz"
        )
        #expect(set == .silent)
        #expect(try await rig.run("clients", "auto", "-on") == .silent)
    }

    // MARK: session start -preset=auto

    @Test func autoGivesTheMappedPresetOfTheDeviceThatConnected() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)
        try macBookJustConnected(rig)

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto", "-ownerpid=\(ownerRef.pid)").ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1728, h: 1080))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 120)
        let stamp = ParsecFixture.stamp(rig.rig.clock.now().addingTimeInterval(-1)).suffix(8)
        #expect(rig.rig.logText.contains(
            "Auto size: the Parsec connect at \(stamp) came from 192.168.0.232, which is client MacBook,"
                + " so the size is MacBook 14 120 Hz"
        ))
    }

    @Test func autoFallsBackToMacBook14WhenTheSettingsAreOff() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)
        #expect(try await rig.run("clients", "auto", "-off") == .silent)
        #expect(try await rig.run("clients", "match", "-off") == .silent)
        try macBookJustConnected(rig)
        try ParsecFixture.writeConfig((w: 2622, h: 1206), savedAt: rig.rig.clock.now(), to: parsecConfig(rig))

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1728, h: 1080))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 60)
        #expect(rig.rig.logText.contains("Auto size: off, so the size is MacBook 14, the default"))
    }

    @Test func autoFallsBackForAnAddressThatIsNoClient() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)
        let now = rig.rig.clock.now()
        try ParsecFixture.write(ParsecFixture.connect(from: "::ffff:192.168.0.10", at: now), to: parsecLog(rig))

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        #expect(try rig.rig.ledger?.hz == 60)
        #expect(rig.rig.logText.contains("192.168.0.10, from the Parsec connect at"))
        #expect(rig.rig.logText.contains("isn't a client; Parsec's config can't be read, so the size is MacBook 14, the default"))
    }

    @Test func autoWithNoParsecLogFallsBack() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        #expect(try rig.rig.ledger?.hz == 60)
        #expect(rig.rig.logText.contains("Auto size: Parsec's log can't be read"))
    }

    @Test func autoFollowsAnEditedMacBook14() async throws {
        let rig = try DispatcherRig()
        let presets = #"[{"name":"MacBook 14","lookslike":"1512x945","hidpi":true,"hz":60}]"#
        try Data(presets.utf8).write(to: rig.rig.folder.appending(component: "presets.json"))
        try Data("2\n".utf8).write(to: rig.rig.folder.appending(component: "presets-version"))

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        #expect(try rig.rig.ledger?.looksLike == ScreenSize(w: 1512, h: 945))
    }

    /// A second guest's start only adds owners and keeps the running size, so the log mustn't name a
    /// size that won't be used.
    @Test func autoForARunningSessionSaysItKeepsItsSize() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)
        try macBookJustConnected(rig)
        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)
        #expect(try rig.rig.ledger?.hz == 120)
        #expect(try await rig.run("clients", "auto", "-off") == .silent)

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        #expect(try rig.rig.ledger?.hz == 120)
        #expect(rig.rig.logText.contains("Auto size: a session for parsec is already running, so it keeps its size"))
        #expect(!rig.rig.logText.contains("Auto size: off"))
    }

    @Test func autoIsOnlyForAStart() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("session", "resize", "-preset=auto") == .failed("-preset=auto is only for session start"))
        #expect(try await rig.run("session", "resize", "-preset=AUTO") == .failed("-preset=auto is only for session start"))
    }

    @Test func autoCannotBeCombinedWithASize() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("session", "start", "-preset=auto", "-lookslike=1920x1080")

        #expect(output == .failed("-preset can't be combined with -lookslike, -hidpi or -hz"))
        #expect(try rig.rig.ledger == nil)
    }

    // MARK: clients

    @Test func listShowsTheSettingsAndEachClient() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("clients", "list") == .out(settings()))

        try await mapMacBookTo120(rig)
        #expect(try await rig.run("clients", "set", "-name=iPad", "-address=::ffff:192.168.0.10", "-preset=4k screen") == .silent)

        let wanted = """
            \(settings(auto: true))
            MacBook: address=192.168.0.232 preset=MacBook 14 120 Hz
            iPad: address=192.168.0.10 preset=4K Screen
            """
        #expect(try await rig.run("clients", "list") == .out(wanted))
    }

    @Test func setWritesTheFileInItsFormat() async throws {
        let rig = try DispatcherRig()

        try await mapMacBookTo120(rig)

        let written = try String(contentsOf: clientsFile(rig), encoding: .utf8)
        #expect(written == """
            {
              "autoSize" : true,
              "clearOfNotch" : true,
              "clients" : [
                {
                  "match" : {
                    "address" : "192.168.0.232"
                  },
                  "name" : "MacBook",
                  "preset" : "MacBook 14 120 Hz"
                }
              ],
              "matchClient" : true,
              "phoneRoom" : "4/3"
            }
            """)
    }

    @Test func setChangesTheClientWithThatNameInItsPlace() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)
        #expect(try await rig.run("clients", "set", "-name=iPad", "-address=192.168.0.10", "-preset=1080p Screen") == .silent)

        #expect(try await rig.run("clients", "set", "-name=macbook", "-address=192.168.0.233", "-preset=MacBook 14") == .silent)

        let wanted = """
            \(settings(auto: true))
            MacBook: address=192.168.0.233 preset=MacBook 14
            iPad: address=192.168.0.10 preset=1080p Screen
            """
        #expect(try await rig.run("clients", "list") == .out(wanted))
    }

    @Test(arguments: [
        (["-name=", "-address=192.168.0.10", "-preset=MacBook 14"], "a client needs a name of 1 to 64 characters"),
        (["-address=192.168.0.10", "-preset=MacBook 14"], "clients set needs -name, -address and -preset"),
        (["-name=iPad", "-address=192.168.0.300", "-preset=MacBook 14"], "not an IP address: 192.168.0.300"),
        (["-name=iPad", "-address=192.168.0.10", "-preset=Nope"], "unknown preset: Nope"),
        (["-name=iPad", "-address=192.168.0.10", "-preset=auto"], "unknown preset: auto"),
        (["-name=iPad", "-address=::ffff:192.168.0.232", "-preset=MacBook 14"], "192.168.0.232 is already client MacBook"),
        (["-name=iPad", "-address=192.168.0.10", "-preset=MacBook 14", "-hz=60"], "unknown parameter: hz"),
        (["-name=iPad", "-name=Pad", "-address=192.168.0.10", "-preset=MacBook 14"], "repeated parameter: name"),
    ])
    func setRefuses(_ parameters: [String], _ reason: String) async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)
        let before = try Data(contentsOf: clientsFile(rig))

        #expect(try await rig.run(["clients", "set"] + parameters) == .failed(reason))

        #expect(try Data(contentsOf: clientsFile(rig)) == before)
    }

    @Test func removeTakesTheClientOut() async throws {
        let rig = try DispatcherRig()
        try await mapMacBookTo120(rig)

        #expect(try await rig.run("clients", "remove", "-name=MACBOOK") == .silent)

        #expect(try await rig.run("clients", "list") == .out(settings(auto: true)))
        #expect(try await rig.run("clients", "remove", "-name=MacBook") == .failed("no client named MacBook"))
    }

    @Test func autoNeedsOnOrOff() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("clients", "auto") == .failed("clients auto needs -on or -off"))
        #expect(try await rig.run("clients", "auto", "-on", "-off") == .failed("clients auto needs -on or -off"))
        #expect(try await rig.run("clients", "auto", "-on=yes") == .failed("-on takes no value"))
        #expect(try await rig.run("clients", "auto", "-ON") == .silent)
        #expect(try await rig.run("clients", "list") == .out(settings(auto: true)))
    }

    @Test func unknownOperationsAreNamed() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("clients") == .failed("clients needs one of list, set, remove, auto, match, notch or room"))
        #expect(try await rig.run("clients", "add") == .failed(
            "unknown clients operation: add; use list, set, remove, auto, match, notch or room"
        ))
        #expect(try await rig.run("clients", "list", "-name=x") == .failed("unknown parameter: name"))
    }

    @Test func anInvalidFileIsNeverOverwritten() async throws {
        let rig = try DispatcherRig()
        let garbage = Data("{ \"autoSize\": tru".utf8)
        try garbage.write(to: clientsFile(rig))

        #expect(try await rig.run("clients", "auto", "-on") == .failed(
            "clients.json isn't valid; fix it or delete it"
        ))
        #expect(try await rig.run("clients", "list") == .failed("clients.json isn't valid; fix it or delete it"))

        #expect(try Data(contentsOf: clientsFile(rig)) == garbage)
        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)
        #expect(try rig.rig.ledger?.hz == 60)
    }

    @Test func listMarksWhatAHandEditBroke() async throws {
        let rig = try DispatcherRig()
        let file = """
            {"clients": [
              {"name": "Old", "match": {"address": "192.168.0.50"}, "preset": "Gone"},
              {"name": "Typo", "match": {"address": "192.168.0"}, "preset": "MacBook 14"}
            ]}
            """
        try Data(file.utf8).write(to: clientsFile(rig))

        let wanted = """
            \(settings())
            Old: address=192.168.0.50 preset=Gone (no such preset)
            Typo: address=192.168.0 preset=MacBook 14 (not an IP address)
            """
        #expect(try await rig.run("clients", "list") == .out(wanted))
    }

    // MARK: Match client

    /// A phone on cellular, which no client's address names: the size it reported, with the defaults.
    @Test func autoMatchesTheSizeTheClientReported() async throws {
        let rig = try DispatcherRig()
        let now = rig.rig.clock.now()
        try ParsecFixture.write(ParsecFixture.connect(from: "::ffff:203.0.113.7", at: now), to: parsecLog(rig))
        try ParsecFixture.writeConfig((w: 1206, h: 2622), savedAt: now, to: parsecConfig(rig))

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1500, h: 804))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 60)
        let stamp = ParsecFixture.stamp(now).suffix(8)
        #expect(rig.rig.logText.contains(
            "Auto size: the Parsec connect at \(stamp) came from 203.0.113.7, and presets by address are off;"
                + " the client reported 1206x2622, so the size is 1500x804 (clear of the notch, phone room 4/3)"
        ))
    }

    @Test func autoFollowsTheNotchAndRoomSettings() async throws {
        let rig = try DispatcherRig()
        let now = rig.rig.clock.now()
        try ParsecFixture.write(ParsecFixture.connect(from: "::ffff:203.0.113.7", at: now), to: parsecLog(rig))
        try ParsecFixture.writeConfig((w: 2622, h: 1206), savedAt: now, to: parsecConfig(rig))
        #expect(try await rig.run("clients", "notch", "-off") == .silent)
        #expect(try await rig.run("clients", "room", "-factor=1/1") == .silent)

        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)

        #expect(try rig.rig.ledger?.looksLike == ScreenSize(w: 1311, h: 603))
        #expect(rig.rig.logText.contains("the client reported 2622x1206, so the size is 1311x603\n"))
    }

    @Test func matchNotchAndRoomChangeTheirSettings() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("clients", "match", "-off") == .silent)
        #expect(try await rig.run("clients", "list") == .out(settings(match: false)))
        #expect(try await rig.run("clients", "notch", "-OFF") == .silent)
        #expect(try await rig.run("clients", "room", "-factor=3/2") == .silent)
        #expect(try await rig.run("clients", "list") == .out(settings(match: false, notch: false, room: "3/2")))

        #expect(try await rig.run("clients", "match", "-on") == .silent)
        #expect(try await rig.run("clients", "notch", "-on") == .silent)
        #expect(try await rig.run("clients", "room", "-Factor=1") == .silent)
        #expect(try await rig.run("clients", "list") == .out(settings(room: "1/1")))

        let written = try String(contentsOf: clientsFile(rig), encoding: .utf8)
        #expect(written.contains(#""phoneRoom" : "1/1""#))
        #expect(written.contains(#""matchClient" : true"#))
    }

    /// A file from before these settings keeps its clients, and gains the settings at their defaults
    /// with the next change.
    @Test func anOlderFileGainsTheSettings() async throws {
        let rig = try DispatcherRig()
        let old = #"{"autoSize": true, "clients": [{"name": "MacBook", "match": {"address": "192.168.0.232"}, "preset": "MacBook 14"}]}"#
        try Data(old.utf8).write(to: clientsFile(rig))

        #expect(try await rig.run("clients", "notch", "-off") == .silent)

        let wanted = """
            \(settings(auto: true, notch: false))
            MacBook: address=192.168.0.232 preset=MacBook 14
            """
        #expect(try await rig.run("clients", "list") == .out(wanted))
    }

    @Test(arguments: [
        (["match"], "clients match needs -on or -off"),
        (["notch", "-on", "-off"], "clients notch needs -on or -off"),
        (["match", "-on=yes"], "-on takes no value"),
        (["notch", "-factor=4/3"], "unknown parameter: factor"),
        (["room"], "clients room needs -factor"),
        (["room", "-factor"], "-factor must be a fraction from 1/1 to 2/1, such as 4/3"),
        (["room", "-factor=1/2"], "-factor must be a fraction from 1/1 to 2/1, such as 4/3"),
        (["room", "-factor=1.33"], "-factor must be a fraction from 1/1 to 2/1, such as 4/3"),
        (["room", "-factor=4/3", "-on"], "unknown parameter: on"),
        (["room", "-factor=4/3", "-factor=1/1"], "repeated parameter: factor"),
    ])
    func settingsRefuse(_ words: [String], _ reason: String) async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("clients", "auto", "-on") == .silent)
        let before = try Data(contentsOf: clientsFile(rig))

        #expect(try await rig.run(["clients"] + words) == .failed(reason))

        #expect(try Data(contentsOf: clientsFile(rig)) == before)
    }

    @Test func settingsAreNeverWrittenOverAnInvalidFile() async throws {
        let rig = try DispatcherRig()
        let garbage = Data(#"{"phoneRoom": "9/1"}"#.utf8)
        try garbage.write(to: clientsFile(rig))

        #expect(try await rig.run("clients", "room", "-factor=4/3") == .failed("clients.json isn't valid; fix it or delete it"))
        #expect(try await rig.run("clients", "match", "-on") == .failed("clients.json isn't valid; fix it or delete it"))

        #expect(try Data(contentsOf: clientsFile(rig)) == garbage)
    }
}
