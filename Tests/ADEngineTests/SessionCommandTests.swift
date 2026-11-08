import ADCommand
import ADDisplays
import ADFoundation
import ADModel
import ADSafety
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct SessionCommandTests {
    // MARK: Start

    @Test func startParsesParameters() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run(
            "session", "start",
            "-client=vnc.ipad_1",
            "-lookslike=1180x820",
            "-hidpi=on",
            "-hz=120",
            "-ownerpid=\(ownerRef.pid)",
            "-ownerpid=\(secondOwnerRef.pid)",
            "-keepon=\(lgUUID)",
            "-keepon=\(m34UUID)"
        )

        let screen = try rig.rig.screenID
        let uuid = try #require(rig.rig.session.status().uuid)
        let wanted = "state=active client=vnc.ipad_1 displayID=\(screen) UUID=\(uuid)"
            + " lookslike=1180x820 pixels=2360x1640 hz=120 off="
        #expect(output == .out(wanted))
        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.client == "vnc.ipad_1")
        #expect(ledger.looksLike == ScreenSize(w: 1180, h: 820))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 120)
        #expect(ledger.owners == [ownerRef, secondOwnerRef])
        #expect(ledger.keepOn == [lgUUID, m34UUID])
        #expect(rig.rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
    }

    @Test func startUsesTheSpecsDefaults() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.result("session", "start").ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.client == "default")
        #expect(ledger.looksLike == ScreenSize(w: 1728, h: 1080))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 60)
        #expect(ledger.owners.isEmpty)
        #expect(ledger.keepOn.isEmpty)
        rig.rig.expectMonitorsOff()
    }

    @Test func hidpiOffGivesA1xSession() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.result("session", "start", "-lookslike=1920x1080", "-hidpi=off").ok)

        #expect(try rig.rig.ledger?.hiDPI == false)
        #expect(rig.rig.session.status().pixels == ScreenSize(w: 1920, h: 1080))
        let shown = rig.rig.simulated.topology().display(try rig.rig.screenID)?.mode
        #expect(shown?.pixelsWide == 1920)
        #expect(shown?.isHiDPI == false)
    }

    @Test func aRepeatedStartKeepsTheSizeAndAddsTheOwner() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-lookslike=1920x1080", "-ownerpid=\(ownerRef.pid)").ok)

        #expect(try await rig.result("session", "start", "-client=parsec", "-lookslike=1280x720", "-ownerpid=\(secondOwnerRef.pid)").ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1920, h: 1080))
        #expect(ledger.owners == [ownerRef, secondOwnerRef])
    }

    @Test func anotherClientIsRefused() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("session", "start", "-client=vnc") == .failed("session held by parsec"))
    }

    @Test func aDeadOwnerIsRefused() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-ownerpid=9999") == .failed("owner process 9999 is not running"))

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func aGuardianThatDoesNotAnswerRefusesTheStart() async throws {
        let rig = try DispatcherRig(SessionRig(guardianAlive: false))

        #expect(try await rig.run("session", "start") == .failed("guardian not running"))

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test(arguments: [
        "-lookslike=wide",
        "-lookslike=10x10",
        "-lookslike=4000x1080",
        "-lookslike",
        "-hidpi=maybe",
        "-hidpi",
        "-hz=fast",
        "-hz=+60",
        "-hz=10",
        "-hz=1000",
        "-ownerpid=abc",
        "-ownerpid=0",
        "-ownerpid=-1",
        "-ownerpid=99999999999",
        "-ownerpid",
        "-keepon=LG",
        "-keepon",
    ])
    func aBadValueChangesNothing(_ argument: String) async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("session", "start", argument)

        #expect(output.exitCode == 1, "\(argument)")
        #expect(output.stderr.hasPrefix("Failed. "), "\(argument)")
        #expect(rig.rig.mutations.isEmpty, "\(argument)")
        #expect(try rig.rig.ledger == nil, "\(argument)")
    }

    /// A typo here would turn off the very monitor the tester meant to keep.
    @Test(arguments: ["00000000-0000-0000-0000-000000000000", "M34WQ"])
    func aKeepOnThatMatchesNoDisplayIsRefused(_ value: String) async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-keepon=\(value)") == .failed("-keepon display not found: \(value)"))

        #expect(rig.rig.mutations.isEmpty)
        #expect(try rig.rig.ledger == nil)
    }

    @Test func aKeepOnOfADisplayThatIsOffIsRefused() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        let before = rig.rig.mutations.count

        #expect(try await rig.run("session", "start", "-keepon=\(m34UUID)") == .failed("-keepon display not found: \(m34UUID)"))

        #expect(rig.rig.mutations.count == before)
    }

    @Test func aKeepOnIgnoresLetterCase() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.result("session", "start", "-keepon=\(lgUUID.lowercased())").ok)

        #expect(rig.rig.simulated.topology().onlineIDs.contains(lg))
    }

    // MARK: Client names

    @Test(arguments: ["parsec", "remote-app", "MacBook_14.2", "a", "0"])
    func aGoodClientNameIsAccepted(_ name: String) async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.result("session", "start", "-client=\(name)").ok, "\(name)")

        #expect(try rig.rig.ledger?.client == name)
    }

    /// Says what a name may hold, so whoever typed it can fix it.
    private static let badClient = "invalid client name; use letters, digits, dot, dash and underscore"

    @Test(arguments: ["two words", "a/b", "semi;colon", "tab\t", "new\nline", "", "emoji\u{1F600}", "caf\u{00E9}", "a=b"])
    func aBadClientNameIsRefused(_ name: String) async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-client=\(name)") == .failed(Self.badClient), "\(name)")
        #expect(try await rig.run("session", "end", "-client=\(name)") == .failed(Self.badClient), "\(name)")

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func aClientWithNoValueIsRefused() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-client") == .failed(Self.badClient))
    }

    // MARK: Unknown parameters

    /// `--json` is the CLI's option, and `-json` is a typo for it, which must not turn monitors off.
    @Test func aOneHyphenJSONDoesNotStartASession() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-json") == .failed("unknown parameter: json"))

        #expect(rig.rig.mutations.isEmpty)
        #expect(try rig.rig.ledger == nil)
    }

    @Test(arguments: [
        (["session", "start", "-nonsense=1"], "nonsense"),
        (["session", "start", "-force"], "force"),
        (["session", "start", "-UUID=x"], "UUID"),
        (["session", "end", "-json"], "json"),
        (["session", "end", "-lookslike=1920x1080"], "lookslike"),
        (["session", "resize", "-lookslike=1920x1080", "-json"], "json"),
        (["session", "resize", "-lookslike=1920x1080", "-client=parsec"], "client"),
        (["session", "status", "-json"], "json"),
        (["session", "presets", "-json"], "json"),
    ])
    func unknownParametersAreRefused(_ argv: [String], _ name: String) async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run(argv) == .failed("unknown parameter: \(name)"), "\(argv)")
    }

    @Test func aSecondValueForOneParameterIsRefused() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-client=a", "-client=b") == .failed("repeated parameter: client"))

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func aBadSessionWordFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "begin") == .failed("unknown session operation: begin; use start, end, resize, status, watch or presets"))
        #expect(try await rig.run("session", "start", "now").exitCode == 1)
        #expect(try await rig.run("session").exitCode == 1)

        #expect(rig.rig.mutations.isEmpty)
    }

    // MARK: Presets

    @Test func presetExpands() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.result("session", "start", "-preset=1440P screen").ok, "Names ignore case")

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 2560, h: 1440))
        #expect(ledger.hiDPI == false)
        #expect(ledger.hz == 60)
    }

    /// The MacBook at 120 Hz, by its preset and by the rate alone: the screen runs at 120.
    @Test(arguments: [["-preset=MacBook 14 120 Hz"], ["-hz=120"]])
    func startAt120Hz(_ parameters: [String]) async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run(["session", "start", "-client=parsec"] + parameters)

        #expect(output.stdout.contains("lookslike=1728x1080 pixels=3456x2160 hz=120"))
        #expect(try rig.rig.ledger?.hz == 120)
        let mode = rig.rig.simulated.topology().display(try rig.rig.screenID)?.mode
        #expect(mode?.refreshHz == 120)
        #expect(mode?.pixelsWide == 3456)
        rig.rig.expectMonitorsOff()
    }

    @Test(arguments: ["-lookslike=1920x1080", "-hidpi=off", "-hz=60"])
    func aPresetWithASizeSettingIsRefused(_ setting: String) async throws {
        let rig = try DispatcherRig()

        for operation in ["start", "resize"] {
            let output = try await rig.run("session", operation, "-preset=MacBook 14", setting)

            #expect(output == .failed("-preset can't be combined with -lookslike, -hidpi or -hz"), "\(operation) \(setting)")
        }

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func presetWithLookslikeRefused() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("session", "start", "-preset=MacBook 14", "-lookslike=1920x1080")

        #expect(output.stderr == "Failed. -preset can't be combined with -lookslike, -hidpi or -hz\n")
    }

    @Test func unknownPresetFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "start", "-preset=Nope") == .failed("unknown preset: Nope"))
        #expect(try await rig.run("session", "start", "-preset").exitCode == 1)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func presetsListsLines() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("session", "presets")

        let lines = output.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == "MacBook 14: lookslike=1728x1080 pixels=3456x2160 hz=60")
        #expect(lines.dropFirst().first == "MacBook 14 120 Hz: lookslike=1728x1080 pixels=3456x2160 hz=120")
        #expect(lines.last == "1080p Screen: lookslike=1920x1080 pixels=1920x1080 hz=60")
        #expect(lines.count == Presets.builtIn.count)
    }

    // MARK: Status

    @Test func statusIdleLine() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "status") == .out("state=idle"))
    }

    @Test func statusLineWhileActive() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        let output = try await rig.run("session", "status")

        let screen = try rig.rig.screenID
        let uuid = try #require(rig.rig.session.status().uuid)
        let wanted = "state=active client=parsec displayID=\(screen) UUID=\(uuid)"
            + " lookslike=1728x1080 pixels=3456x2160 hz=60 off=\(lg),\(m34)"
        #expect(output == .out(wanted))
    }

    @Test func statusJSONInEnvelope() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        let output = try await rig.run("session", "status", "--json")

        let parsed = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        let envelope = try #require(parsed as? [String: Any])
        #expect(envelope["ok"] as? Bool == true)
        let json = try #require(envelope["json"] as? [String: Any])
        #expect(json["apiVersion"] as? Int == 1)
        #expect(json["state"] as? String == "active")
        #expect(json["client"] as? String == "parsec")
        #expect(json["displayID"] as? Int == Int(try rig.rig.screenID))
        #expect(json["displayUUID"] as? String == rig.rig.session.status().uuid)
        #expect((json["looksLike"] as? [String: Int]) == ["w": 1728, "h": 1080])
        #expect((json["pixels"] as? [String: Int]) == ["w": 3456, "h": 2160])
        #expect(json["hiDPI"] as? Bool == true)
        #expect(json["hz"] as? Int == 60)
        #expect((json["ownerPIDs"] as? [Int]) == [])
        #expect((json["physicalOff"] as? [Int]) == [Int(lg), Int(m34)])
        #expect(json.count == 11, "Nothing beyond API version 1's keys: \(json.keys.sorted())")
    }

    @Test func statusJSONHasTheOwnersAndHiDPI() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result(
            "session", "start", "-client=ipad", "-lookslike=1920x1080", "-hidpi=off",
            "-ownerpid=\(ownerRef.pid)", "-ownerpid=\(secondOwnerRef.pid)"
        ).ok)

        let result = try await rig.result("session", "status")

        guard case .object(let json)? = result.json else {
            Issue.record("no status object")
            return
        }
        #expect(json["hiDPI"] == .bool(false))
        #expect(json["ownerPIDs"] == .array([.number(Double(ownerRef.pid)), .number(Double(secondOwnerRef.pid))]))
        #expect(json["pixels"] == .object(["w": .number(1920), "h": .number(1080)]))
    }

    @Test func idleStatusJSONIsOnlyTheStateAndTheVersion() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("session", "status", "--json")

        #expect(output == .out(#"{"ok":true,"payload":"state=idle","reason":null,"warning":null,"json":{"apiVersion":1,"state":"idle"}}"#))
    }

    /// An app that captures the virtual screen reads which display to capture from this.
    @Test func startCarriesTheScreenInTheEnvelope() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("session", "start", "-client=vnc", "--json")

        let parsed = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        let json = try #require((parsed as? [String: Any])?["json"] as? [String: Any])
        #expect(json["displayID"] as? Int == Int(try rig.rig.screenID))
        #expect(json["displayUUID"] as? String == rig.rig.session.status().uuid)
        #expect(json["apiVersion"] as? Int == 1)
    }

    // MARK: End

    @Test func endRestoresTheDeskAndPrintsNothing() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("session", "end", "-client=parsec") == .silent)

        rig.rig.expectDeskRestored()
        rig.rig.expectNoScreen()
        #expect(try rig.rig.ledger == nil)
    }

    @Test func endWithNoSessionSucceeds() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "end", "-client=parsec") == .silent)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test(arguments: [true, false])
    func endAnswersWithTheIdleStatusInJSON(hadSession: Bool) async throws {
        let rig = try DispatcherRig()
        if hadSession { #expect(try await rig.result("session", "start", "-client=parsec").ok) }

        let output = try await rig.run("session", "end", "-client=parsec", "--json")

        #expect(output == .out(#"{"ok":true,"payload":null,"reason":null,"warning":null,"json":{"apiVersion":1,"state":"idle"}}"#))
    }

    @Test func endFromAnotherClientIsRefusedUnlessForced() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("session", "end", "-client=vnc") == .failed("session held by parsec"))
        #expect(try await rig.run("session", "end") == .failed("session held by parsec"), "No client means the default client")
        rig.rig.expectMonitorsOff()

        #expect(try await rig.run("session", "end", "-client=vnc", "-force") == .silent)

        rig.rig.expectDeskRestored()
    }

    @Test func endWithNoClientEndsTheDefaultClientsSession() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start").ok)

        #expect(try await rig.run("session", "end") == .silent)

        rig.rig.expectDeskRestored()
    }

    @Test func forceOffIsNotForce() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("session", "end", "-force=off") == .failed("session held by parsec"))
        #expect(try await rig.run("session", "end", "-force=maybe").exitCode == 1)
        rig.rig.expectMonitorsOff()
    }

    /// What the guardian sends when an owner dies.
    @Test func theGuardiansEndIsHeardAndItsReasonLogged() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        let result = await rig.dispatcher.handle(
            CommandRequest(
                operations: ["session", "end"],
                parameters: [CommandParameter(name: "force"), CommandParameter(name: "reason", value: "owner-died")]
            )
        )

        #expect(result == .success(json: SessionStatus(state: .idle).asJSON))
        rig.rig.expectDeskRestored()
        #expect(rig.rig.logText.contains("Ending the session: owner-died"))
    }

    @Test func endWarningSurfaces() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        rig.rig.simulated.removePhysical(m34)

        let output = try await rig.run("session", "end", "-client=parsec")

        #expect(output == RenderedOutput(stdout: "", stderr: "warning: not restored: M34WQ\n", exitCode: 0))
    }

    @Test func endFailureSurfaces() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        rig.rig.simulated.setEnableFails(m34, .max)

        #expect(try await rig.run("session", "end", "-client=parsec") == .failed("a display did not come back correctly"))

        #expect(try rig.rig.ledger?.state == .ending)
    }

    /// The whole sequence that once ended with only the OS fallback display and a success.
    @Test(arguments: [["session", "end", "-client=parsec"], ["rescue"]])
    func keepingEverythingOnAndTurningItOffNeverEndsDark(_ finish: [String]) async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)", "-keepon=\(m34UUID)").ok)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .failed("would leave no working display"))

        #expect(try await rig.run(finish) == .silent, "\(finish)")

        let topology = rig.rig.simulated.topology()
        #expect(topology.onlineIDs.contains(m34), "\(finish)")
        #expect(topology.onlineIDs.contains(lg) == (finish == ["rescue"]), "Only a rescue reconnects what was turned off by hand")
        #expect(rig.rig.simulated.fallbackAppearances == 0, "\(finish)")
        rig.rig.expectNoScreen()
        #expect(try rig.rig.ledger == nil)
    }

    /// Both monitors go by some way the commands can't refuse, like being unplugged. The screen is then
    /// all that's showing, so the end has to keep it, whatever the restorer reported.
    @Test func anEndKeepsTheScreenIfNothingElseIsShowing() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)", "-keepon=\(m34UUID)").ok)
        let screen = try rig.rig.screenID
        rig.rig.simulated.removePhysical(m34)
        rig.rig.simulated.removePhysical(lg)

        #expect(try await rig.run("session", "end", "-client=parsec") == .failed("a display did not come back correctly"))
        #expect(rig.rig.simulated.topology().onlineIDs.contains(screen))
        #expect(rig.rig.simulated.fallbackAppearances == 0)
        #expect(try rig.rig.ledger?.state == .ending)

        #expect(try await rig.run("rescue") == .failed("a display did not come back correctly"))
        #expect(rig.rig.simulated.topology().onlineIDs.contains(screen))
        #expect(rig.rig.simulated.fallbackAppearances == 0)
    }

    /// `physicalOff` lists a monitor that's been unplugged, so the screen counted when the kept one went
    /// off. Nothing recorded can come back, so the end fails before it would touch the screen.
    @Test func anUnpluggedRecordedMonitorDoesNotCostTheScreen() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        let screen = try rig.rig.screenID
        rig.rig.simulated.removePhysical(m34)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)

        #expect(try await rig.run("session", "end", "-client=parsec").exitCode == 1)

        #expect(rig.rig.simulated.topology().onlineIDs.contains(screen))
        #expect(rig.rig.simulated.fallbackAppearances == 0)
    }

    // MARK: Resize

    /// The second one names only a size, so it keeps what the first one set, even though the first hadn't
    /// run yet when the second arrived.
    @Test func aResizeQueuedBehindAnotherKeepsWhatThatOneSet() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-lookslike=1920x1080", "-hidpi=off", "-hz=30").ok)
        let dispatcher = try #require(rig.dispatcher)
        func resize(_ parameters: CommandParameter...) -> CommandRequest {
            CommandRequest(operations: ["session", "resize"], parameters: parameters)
        }

        let first = Task {
            await dispatcher.handle(
                resize(
                    CommandParameter(name: "lookslike", value: "1728x1080"),
                    CommandParameter(name: "hiDPI", value: "on"),
                    CommandParameter(name: "hz", value: "60")
                )
            )
        }
        let second = Task { await dispatcher.handle(resize(CommandParameter(name: "lookslike", value: "1512x945"))) }
        #expect(await first.value.ok)
        #expect(await second.value.ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1512, h: 945))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 60)
    }

    @Test func resizeChangesTheSizeAndLeavesTheMonitors() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        let monitorSwitches = rig.rig.countOfPrefix("enable") + rig.rig.countOfPrefix("disable")

        let output = try await rig.run("session", "resize", "-lookslike=1512x945")

        #expect(output.stdout.contains("lookslike=1512x945 pixels=3024x1890 hz=60"))
        #expect(try rig.rig.ledger?.looksLike == ScreenSize(w: 1512, h: 945))
        #expect(rig.rig.countOfPrefix("enable") + rig.rig.countOfPrefix("disable") == monitorSwitches)
    }

    @Test func resizeHidpiOffGivesA1xScreen() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        let output = try await rig.run("session", "resize", "-lookslike=1920x1080", "-hidpi=off", "-hz=30")

        #expect(output.stdout.contains("lookslike=1920x1080 pixels=1920x1080 hz=30"))
        #expect(try rig.rig.ledger?.hiDPI == false)
        #expect(rig.rig.simulated.topology().display(try rig.rig.screenID)?.mode?.isHiDPI == false)
    }

    /// The spec's defaults are for a start. A resize that names only a size changes only the size.
    @Test func resizeKeepsWhatItIsNotTold() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-lookslike=1920x1080", "-hidpi=off", "-hz=30").ok)

        let output = try await rig.run("session", "resize", "-lookslike=1280x720")

        #expect(output.stdout.contains("lookslike=1280x720 pixels=1280x720 hz=30"))
        #expect(try rig.rig.ledger?.hiDPI == false)
    }

    @Test func resizeToAPreset() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        let output = try await rig.run("session", "resize", "-preset=1080p screen")

        #expect(output.stdout.contains("lookslike=1920x1080 pixels=1920x1080 hz=60"))
    }

    @Test func resizeBadSizeFails() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        let before = rig.rig.mutations.count

        #expect(try await rig.run("session", "resize", "-lookslike=10x10") == .failed("lookslike width must be 640 to 3840"))
        #expect(try await rig.run("session", "resize", "-lookslike=1920x100") == .failed("lookslike height must be 360 to 2400"))
        #expect(try await rig.run("session", "resize", "-lookslike=wide") == .failed("invalid lookslike: wide"))
        #expect(try await rig.run("session", "resize", "-lookslike=1920x1080", "-hz=10") == .failed("hz must be 24 to 240"))

        #expect(rig.rig.mutations.count == before)
        #expect(try rig.rig.ledger?.looksLike == defaultSize)
    }

    @Test func resizeWithNoSizeFails() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("session", "resize") == .failed("session resize needs -lookslike, -preset or -hz"))
        #expect(try await rig.run("session", "resize", "-hidpi=off") == .failed("session resize needs -lookslike, -preset or -hz"))
    }

    /// The status menu's refresh rate choice: the rate alone, so the size and HiDPI stay, the screen
    /// changes in place, and no monitor is touched.
    @Test(arguments: [(60, 120), (120, 60)])
    func aRateAloneKeepsTheSize(from: Int, to: Int) async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-hz=\(from)").ok)
        let screen = try rig.rig.screenID
        let monitorSwitches = rig.rig.countOfPrefix("enable") + rig.rig.countOfPrefix("disable")

        let output = try await rig.run("session", "resize", "-hz=\(to)")

        #expect(output.stdout.contains("displayID=\(screen) "))
        #expect(output.stdout.contains("lookslike=1728x1080 pixels=3456x2160 hz=\(to)"))
        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1728, h: 1080))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == to)
        #expect(rig.rig.simulated.topology().display(screen)?.mode?.refreshHz == Double(to))
        #expect(rig.rig.countOfPrefix("enable") + rig.rig.countOfPrefix("disable") == monitorSwitches)
    }

    /// The size comes from the session when the resize gets its turn, so a size change ahead of it stays.
    @Test func aRateAloneQueuedBehindASizeKeepsThatSize() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-lookslike=1920x1080", "-hidpi=off").ok)
        let dispatcher = try #require(rig.dispatcher)
        func resize(_ parameters: CommandParameter...) -> CommandRequest {
            CommandRequest(operations: ["session", "resize"], parameters: parameters)
        }

        let first = Task {
            await dispatcher.handle(
                resize(CommandParameter(name: "lookslike", value: "1512x945"), CommandParameter(name: "hiDPI", value: "on"))
            )
        }
        let second = Task { await dispatcher.handle(resize(CommandParameter(name: "hz", value: "120"))) }
        #expect(await first.value.ok)
        #expect(await second.value.ok)

        let ledger = try #require(try rig.rig.ledger)
        #expect(ledger.looksLike == ScreenSize(w: 1512, h: 945))
        #expect(ledger.hiDPI)
        #expect(ledger.hz == 120)
    }

    @Test func resizeWithNoSessionFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("session", "resize", "-lookslike=1920x1080") == .failed("no session"))
        #expect(try await rig.run("session", "resize", "-hz=120") == .failed("no session"))

        #expect(rig.rig.mutations.isEmpty)
    }

    // MARK: Ping

    @Test func pingAnswers() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("ping") == .out("pong"))
    }

    /// `rescue` pings first and gives the answer 1 second, so a slow force-end must not hold it up, or
    /// the CLI would kill an app that was doing the right thing.
    @Test func pingAnswersDuringASlowForceEnd() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        let answer = Box<CommandResult>()
        let dispatcher = try #require(rig.dispatcher)
        rig.rig.atFirstSwitch(enabling: true) {
            answer.value = await dispatcher.handle(CommandRequest(operations: ["ping"]))
        }

        #expect(try await rig.run("session", "end", "-client=parsec", "-force") == .silent)

        #expect(answer.value == .success("pong"))
    }

    // MARK: Rescue

    @Test func rescueForceEndsSession() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("rescue") == .silent)

        rig.rig.expectDeskRestored()
        rig.rig.expectNoScreen()
        #expect(try rig.rig.ledger == nil)
    }

    @Test func rescueWithNoSessionReconnectsRegistry() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)

        #expect(try await rig.run("rescue") == .silent)

        #expect(rig.rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
    }

    @Test func rescuePassesOnAWarning() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        rig.rig.simulated.removePhysical(m34)

        let output = try await rig.run("rescue")

        #expect(output == RenderedOutput(stdout: "", stderr: "warning: not restored: M34WQ\n", exitCode: 0))
    }

    /// The CLI runs the restore helper on a failure, so a success has to mean the monitors are back.
    @Test func rescueFailsIfAMonitorDidNotReturn() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        rig.rig.simulated.setEnableFails(m34, .max)

        #expect(try await rig.run("rescue") == .failed("a display did not come back correctly"))
    }

    /// The end only brings back what the session recorded, and this one was off before it started.
    @Test func rescueBringsBackAMonitorThatWasOffBeforeTheSession() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        #expect(try rig.rig.ledger?.physical.map(\.id) == [lg], "It isn't recorded")

        #expect(try await rig.run("rescue") == .silent)

        #expect(rig.rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
        rig.rig.expectNoScreen()
        #expect(try rig.rig.ledger == nil)
    }

    @Test func rescueBringsBackAKeptMonitorTurnedOffByHand() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)

        #expect(try await rig.run("rescue") == .silent)

        #expect(rig.rig.simulated.topology().onlineIDs.isSuperset(of: [lg, m34]))
        rig.rig.expectNoScreen()
    }

    /// The end went fine, and then nothing physical is left, so this can't call itself a success.
    @Test func rescueFailsIfNoMonitorIsOnlineAfterTheEnd() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)", "-keepon=\(m34UUID)").ok)
        let simulated = rig.rig.simulated
        rig.rig.screens.afterDestroy = {
            simulated.removePhysical(m34)
            simulated.removePhysical(lg)
        }

        #expect(try await rig.run("rescue") == .failed("could not restore any display"))
    }

    /// A failed end still turns on whatever it can, because that's what someone rescuing is after.
    @Test func rescueReconnectsEvenIfTheEndFailed() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        rig.rig.simulated.removePhysical(m34)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)

        #expect(try await rig.run("rescue") == .failed("could not restore any display"))

        #expect(rig.rig.simulated.topology().onlineIDs.contains(lg))
    }

    /// A typo must not make the CLI think the app failed and kill it.
    @Test func rescueIgnoresStrayParameters() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("rescue", "-json") == .silent)

        rig.rig.expectDeskRestored()
    }
}
