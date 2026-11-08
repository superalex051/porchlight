import ADCommand
import ADDisplayConfig
import ADDisplays
import ADIntegrations
import ADModel
import ADSPI
import Foundation
import Testing

@testable import ADEngine

let m34UUID = "0A4FA257-A531-4885-BA5E-76B9D0C0EF8D"

final class FakeLaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled = false
    var failure: (any Error)?

    func setEnabled(_ on: Bool) throws {
        if let failure { throw failure }
        isEnabled = on
    }
}

/// A dispatcher on the test desk in memory, driven the way the CLI drives it: real parser, real formatter.
@MainActor
final class DispatcherRig {
    let rig: SessionRig
    let launchAtLogin = FakeLaunchAtLogin()
    let capabilities = SPICapabilities(
        displayList: true,
        infoDictionary: true,
        enableDisable: false,
        virtualDisplay: true,
        missing: ["SomeSymbol"]
    )
    private(set) var dispatcher: CommandDispatcher!
    var plan: [String]?

    init(_ rig: SessionRig? = nil, registry: DeviceRegistry? = nil) throws {
        self.rig = try rig ?? SessionRig()
        rebuild(registry: registry)
    }

    /// A new dispatcher on what's there now, as a relaunched app builds. Anything it held in memory goes.
    func rebuild(registry: DeviceRegistry? = nil) {
        let folder = rig.folder
        dispatcher = CommandDispatcher(
            backend: rig.backend,
            registry: registry ?? rig.registry,
            session: rig.session,
            presets: PresetStore(url: folder.appending(component: "presets.json"), log: { _ in }),
            sizer: Self.sizer(rig),
            operations: DisplayOperations(backend: rig.backend, clock: rig.clock),
            screens: rig.screens,
            virtualStore: VirtualScreenStore(directory: folder, log: { _ in }),
            launchAtLogin: launchAtLogin,
            capabilities: capabilities,
            clock: rig.clock,
            dryRunPlan: { [weak self] in self?.plan ?? [] }
        )
    }

    /// `clients.json`, `parsec-log.txt` and `parsec-config.json` in the rig's folder, the log read in UTC,
    /// and the choice logged to `session.log` as the app does.
    static func sizer(_ rig: SessionRig) -> DeviceSizer {
        let folder = rig.folder
        let log = SessionLog(url: rig.logURL)
        return DeviceSizer(
            clients: ClientStore(url: folder.appending(component: "clients.json"), log: { log.append($0) }),
            presets: PresetStore(url: folder.appending(component: "presets.json"), log: { _ in }),
            parsecLog: folder.appending(component: "parsec-log.txt"),
            parsecConfig: folder.appending(component: "parsec-config.json"),
            clock: rig.clock,
            timeZone: ParsecFixture.utc,
            log: { log.append($0) }
        )
    }

    func result(_ argv: String...) async throws -> CommandResult {
        try await result(argv)
    }

    func result(_ argv: [String]) async throws -> CommandResult {
        let (request, _) = try CommandParser.parse(argv)
        return await dispatcher.handle(request)
    }

    func run(_ argv: String...) async throws -> RenderedOutput {
        try await run(argv)
    }

    func run(_ argv: [String]) async throws -> RenderedOutput {
        let (request, options) = try CommandParser.parse(argv)
        return OutputFormatter.render(await dispatcher.handle(request), options: options)
    }

    var definitions: [VirtualScreenDefinition] {
        get throws { try VirtualScreenStore(directory: rig.folder, log: { _ in }).definitions() }
    }
}

extension RenderedOutput {
    static func out(_ text: String) -> RenderedOutput {
        RenderedOutput(stdout: "\(text)\n", stderr: "", exitCode: 0)
    }

    static let silent = RenderedOutput(stdout: "", stderr: "", exitCode: 0)
    static let failed = RenderedOutput(stdout: "", stderr: "Failed.\n", exitCode: 1)

    static func failed(_ reason: String) -> RenderedOutput {
        RenderedOutput(stdout: "", stderr: "Failed. \(reason)\n", exitCode: 1)
    }
}

@MainActor
@Suite struct DispatcherTests {
    // MARK: Get

    @Test func requestOrderIsKept() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-placement", "-main") == .out("0x0,true"))
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-main", "-placement") == .out("true,0x0"))
    }

    @Test func getConnectedOfDisconnectedByUUIDIsOff() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)

        // macOS no longer looks this display up by UUID, so only the registry can answer.
        #expect(rig.rig.simulated.topology().display(uuid: m34UUID) == nil)
        #expect(try await rig.run("get", "-UUID=\(m34UUID)", "-connected") == .out("off"))
    }

    @Test func getFindsADisplayTheFallbackHides() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)
        try rig.rig.simulated.setEnabled(lg, false)

        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-connected") == .out("off"))
        #expect(try await rig.run("get", "-n=M34", "-connected") == .out("off"))
    }

    /// A working Mac always lists something, so an empty read says nothing about any display.
    @Test func getOnAnEmptyReadFailsRatherThanSayingOff() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        rig.rig.backend.update { $0.rewrite = { $0.displays = [] } }

        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-connected") == .failed)
    }

    @Test func getWithoutASelectorFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-main") == .failed)
    }

    @Test func getWithAValueFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-main=on") == .failed)
    }

    @Test func getOfAnOffDisplaysModeFails() async throws {
        let rig = try DispatcherRig()
        try rig.rig.simulated.setEnabled(m34, false)

        #expect(try await rig.run("get", "-displayID=\(m34)", "-resolution") == .failed)
        #expect(try await rig.run("get", "-displayID=\(m34)", "-refreshRate") == .failed)
        #expect(try await rig.run("get", "-displayID=\(m34)", "-hiDPI") == .failed)
        #expect(try await rig.run("get", "-displayID=\(m34)", "-placement") == .failed)
    }

    /// `Int(119.88)` would print the wrong rate.
    @Test func refreshRateRounds() async throws {
        let rig = try DispatcherRig()
        rig.rig.backend.update { script in
            script.rewrite = { topology in
                for index in topology.displays.indices where topology.displays[index].id == lg {
                    topology.displays[index].mode?.refreshHz = 119.88
                }
            }
        }

        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-refreshRate") == .out("120Hz"))
    }

    @Test func dryRunPlanPrintsOneLinePerMutation() async throws {
        let rig = try DispatcherRig()
        rig.plan = ["disable 4", "disable 2"]

        #expect(try await rig.run("get", "-dryRunPlan") == .out("disable 4\ndisable 2"))
    }

    @Test func dryRunPlanFailsOutsideADryRun() async throws {
        let rig = try DispatcherRig()
        let dispatcher = CommandDispatcher(
            backend: rig.rig.backend,
            registry: rig.rig.registry,
            session: rig.rig.session,
            presets: PresetStore(url: rig.rig.folder.appending(component: "presets.json"), log: { _ in }),
            sizer: DispatcherRig.sizer(rig.rig),
            operations: DisplayOperations(backend: rig.rig.backend, clock: rig.rig.clock),
            screens: rig.rig.screens,
            virtualStore: VirtualScreenStore(directory: rig.rig.folder, log: { _ in }),
            launchAtLogin: rig.launchAtLogin,
            capabilities: rig.capabilities,
            clock: rig.rig.clock
        )

        let result = await dispatcher.handle(
            CommandRequest(operations: ["get"], parameters: [CommandParameter(name: "dryRunPlan")])
        )

        #expect(result == .failure())
    }

    // MARK: Set connected

    @Test func setConnectedOnByUUIDAfterDisconnect() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        #expect(!rig.rig.simulated.topology().onlineIDs.contains(m34))

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=on") == .silent)

        #expect(rig.rig.simulated.topology().onlineIDs.contains(m34))
        #expect(try await rig.run("get", "-UUID=\(m34UUID)", "-connected") == .out("on"))
    }

    @Test func setConnectedOnAfterFallbackGoesByRecordedID() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)
        try rig.rig.simulated.setEnabled(lg, false)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=on") == .silent)

        #expect(rig.rig.simulated.topology().onlineIDs.contains(lg))
    }

    /// With the boot unknown, a display that went off before this process has an older entry, and it's
    /// still the only way to find it.
    @Test func setConnectedOnWithAnUnknownBoot() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)
        let url = rig.rig.folder.appending(component: "devices.json")

        rig.rebuild(registry: DeviceRegistry(url: url, bootSession: ""))

        #expect(try await rig.run("get", "-UUID=\(m34UUID)", "-connected") == .out("off"))
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=on") == .silent)
        #expect(rig.rig.simulated.topology().onlineIDs.contains(m34))
    }

    /// An ID from another boot means nothing. With the fallback up, nothing listed vouches for it either.
    @Test func setConnectedOnIgnoresAnotherBootsEntry() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)
        try rig.rig.simulated.setEnabled(lg, false)
        let url = rig.rig.folder.appending(component: "devices.json")
        let before = rig.rig.mutations.count

        rig.rebuild(registry: DeviceRegistry(url: url, bootSession: "boot-2"))

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=on") == .failed)
        #expect(rig.rig.mutations.count == before)
    }

    /// With every display asleep an enable fails, so a wake has to come first.
    @Test func setConnectedOnWakesFirst() async throws {
        let rig = try DispatcherRig(SessionRig(wakesOnDeclare: true))
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)
        rig.rig.simulated.setAsleep(lg, true)

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=on") == .silent)

        #expect(rig.rig.power.declareCount == 1)
        #expect(rig.rig.simulated.topology().onlineIDs.contains(m34))
    }

    @Test func setConnectedOnOfAnOnlineDisplayChangesNothing() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=on") == .silent)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func setConnectedOffLastPhysicalRefused() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        let before = rig.rig.mutations.count

        let output = try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off")

        #expect(output.stderr == "Failed. would leave no working display\n")
        #expect(output.exitCode == 1)
        #expect(rig.rig.mutations.count == before)
    }

    @Test func aPlanThatTakesEveryDisplayIsRefusedWhole() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-type=Display", "-connected=off") == .failed("would leave no working display"))

        #expect(rig.rig.mutations.isEmpty)
    }

    /// Outside a session a screen made by hand has no ledger or guardian behind it.
    @Test func aCreatedScreenDoesNotCountOutsideASession() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("create", "-type=VirtualScreen", "-virtualScreenName=Office") == .silent)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .failed("would leave no working display"))

        #expect(rig.rig.simulated.topology().onlineIDs.contains(lg))
    }

    /// The session's screen is the one display a live session can rely on.
    @Test func theSessionScreenCountsDuringALiveSession() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)

        #expect(!rig.rig.simulated.topology().onlineIDs.contains(lg))
    }

    /// With every monitor kept on, nothing is waiting to come back, so the end would take away the only
    /// thing left. The first one can go, because the other still counts. The second can't.
    @Test func keptMonitorsCannotAllBeTurnedOffByHand() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)", "-keepon=\(m34UUID)").ok)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .failed("would leave no working display"))

        #expect(rig.rig.simulated.topology().onlineIDs.contains(m34))
    }

    /// An end that failed partway still has to take the screen away, so it can't count any more.
    @Test func theSessionScreenDoesNotCountOnceEnding() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        rig.rig.simulated.setEnableFails(m34, .max)
        #expect(try await rig.result("session", "end", "-client=parsec").ok == false)
        #expect(rig.rig.session.status().state == .ending)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .failed("would leave no working display"))
    }

    @Test func theSessionsOwnScreenCanOnlyGoWithTheSession() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        let screen = try rig.rig.screenID

        let output = try await rig.run("set", "-displayID=\(screen)", "-connected=off")

        #expect(output.exitCode == 1)
        #expect(output.stderr.contains("session"))
        #expect(rig.rig.simulated.topology().onlineIDs.contains(screen))
    }

    /// It may be the very display a remote user is looking at.
    @Test func anotherAppsVirtualDisplayIsLeftAlone() async throws {
        let rig = try DispatcherRig()
        let parsec = rig.rig.simulated.addVirtual(
            identity: DisplayIdentity(vendor: 0x1234, model: 1, serial: 1, productName: "Parsec Virtual Display"),
            mode: mode(1920, 1080, hz: 60),
            modes: []
        )

        let output = try await rig.run("set", "-displayID=\(parsec)", "-connected=off")

        #expect(output.exitCode == 1)
        #expect(rig.rig.simulated.topology().onlineIDs.contains(parsec))
    }

    /// The socket serves each connection on its own, and a check is only good if nothing changes
    /// between it and the disconnect.
    @Test func twoDisconnectsAtOnceCannotBothPass() async throws {
        let rig = try DispatcherRig()
        let dispatcher = try #require(rig.dispatcher)
        func off(_ uuid: String) -> CommandRequest {
            CommandRequest(
                operations: ["set"],
                parameters: [CommandParameter(name: "UUID", value: uuid), CommandParameter(name: "connected", value: "off")]
            )
        }

        // The second command arrives with the first one's display still on its way off. It gets as far as
        // it can, either queued behind the first or through its check, and only then does the first land.
        let session = try #require(rig.rig.session)
        let second = Box<Task<CommandResult, Never>>()
        rig.rig.atFirstSwitch(enabling: false) {
            let task = Task { await dispatcher.handle(off(m34UUID)) }
            second.value = task
            let finished = Box<Bool>()
            Task {
                _ = await task.value
                finished.value = true
            }
            var waited = 0
            while session.turnsWaiting == 0, finished.value == nil, waited < 2000 {
                try? await Task.sleep(for: .milliseconds(1))
                waited += 1
            }
        }

        let first = await dispatcher.handle(off(lgUUID))
        let results = [first, await second.value?.value]

        #expect(first.ok)
        #expect(results.contains(.failure("would leave no working display")))
        #expect(rig.rig.simulated.fallbackAppearances == 0)
    }

    @Test func setConnectedOffWritesRegistryFirst() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        let url = rig.rig.folder.appending(component: "devices.json")
        // Nothing left on disk, so whatever is there at the disable came from this command.
        try FileManager.default.removeItem(at: url)
        let seen = Recorder<DisplayID?>()
        rig.rig.backend.update { script in
            script.beforeSetEnabled = { _, _ in
                seen.append(DeviceRegistry(url: url, bootSession: boot).entry(uuid: m34UUID)?.lastID)
            }
        }

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)

        #expect(seen.values == [m34])
    }

    @Test func setConnectedOffRefusedIfRegistryWriteFails() async throws {
        let rig = try DispatcherRig(SessionRig(registryWritable: false))

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .failed("cannot write state"))

        #expect(rig.rig.mutations.isEmpty)
    }

    /// A display that reads with no UUID gets no entry even when the write succeeds, and with no entry
    /// nothing could find it to turn it back on.
    @Test func setConnectedOffRefusedIfTheWriteLeftNoEntry() async throws {
        let rig = try DispatcherRig()
        rig.rig.backend.update { script in
            script.rewrite = { topology in
                for index in topology.displays.indices where topology.displays[index].id == m34 {
                    topology.displays[index].identity.uuid = nil
                }
            }
        }

        let output = try await rig.run("set", "-displayID=\(m34)", "-connected=off")

        #expect(output.exitCode == 1)
        #expect(output.stderr.contains("can't be recorded"))
        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func setConnectedOffOfAnOffDisplayChangesNothing() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        let before = rig.rig.mutations.count

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)

        #expect(rig.rig.mutations.count == before)
    }

    /// Every display looks off in a read like this, and success here would be a lie about a monitor.
    @Test func setOnAnEmptyReadFails() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        rig.rig.backend.update { $0.rewrite = { $0.displays = [] } }

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    /// A plan is refused whole, so the rest of the command must not have happened first.
    @Test func aMixedSetThatWouldLeaveNoDisplayChangesNothing() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        let before = rig.rig.mutations.count

        let output = try await rig.run(
            "set", "-UUID=\(lgUUID)", "-resolution=1920x1080", "-pinRefreshRate=60", "-launchAtLogin=on", "-connected=off"
        )

        #expect(output == .failed("would leave no working display"))
        #expect(rig.rig.mutations.count == before)
        #expect(rig.rig.registry.entry(uuid: lgUUID)?.pinnedRefreshHz == nil)
        #expect(rig.launchAtLogin.isEnabled == false)
    }

    @Test func aMixedSetOnADisplayThatCannotGoOffChangesNothing() async throws {
        let rig = try DispatcherRig()
        let parsec = rig.rig.simulated.addVirtual(
            identity: DisplayIdentity(vendor: 0x1234, model: 1, serial: 1, productName: "Parsec Virtual Display"),
            mode: mode(1920, 1080, hz: 60),
            modes: []
        )
        let before = rig.rig.mutations.count

        let output = try await rig.run("set", "-displayID=\(parsec)", "-main=on", "-connected=off")

        #expect(output.exitCode == 1)
        #expect(rig.rig.mutations.count == before)
    }

    // MARK: Set during a session

    private static let sessionRefusal = RenderedOutput.failed("a session is active; use session end")

    @Test func anActiveSessionHoldsItsMonitorsOff() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        let before = rig.rig.mutations.count

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=on") == Self.sessionRefusal)
        #expect(try await rig.run("set", "-type=Display", "-connected=on") == Self.sessionRefusal)

        #expect(rig.rig.mutations.count == before)
        rig.rig.expectMonitorsOff()
    }

    @Test func anActiveSessionHoldsMain() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        let screen = try rig.rig.screenID
        let before = rig.rig.mutations.count

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-main=on") == Self.sessionRefusal)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-main=on") == Self.sessionRefusal)
        #expect(rig.rig.mutations.count == before)

        #expect(try await rig.run("set", "-displayID=\(screen)", "-main=on") == .silent, "It's main already")
    }

    @Test func anActiveSessionHoldsItsScreensPlacement() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        let screen = try rig.rig.screenID
        let before = rig.rig.mutations.count

        #expect(try await rig.run("set", "-displayID=\(screen)", "-placement=100x100") == Self.sessionRefusal)
        #expect(rig.rig.mutations.count == before)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-placement=3000x0").exitCode == 0, "A kept monitor isn't held")
    }

    @Test func aRefusalInASessionStopsTheWholeSet() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        let output = try await rig.run("set", "-UUID=\(lgUUID)", "-connected=on", "-pinRefreshRate=144")

        #expect(output == Self.sessionRefusal)
        #expect(rig.rig.registry.entry(uuid: lgUUID)?.pinnedRefreshHz == nil)
    }

    @Test func aKeptMonitorTurnedOffByHandCanComeBackOn() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)").ok)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=off") == .silent)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-connected=on") == .silent)

        #expect(rig.rig.simulated.topology().onlineIDs.contains(lg))
    }

    /// Enforcement has stopped, so what these do stays done, and refusing would only get in the way.
    @Test func aDegradedSessionAllowsThem() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.result("session", "start", "-client=parsec").ok)
        for _ in 1...6 {
            rig.rig.simulated.simulateWake(reconnecting: [lg])
            await rig.rig.session.topologyChanged()
        }
        #expect(rig.rig.session.status().state == .degraded)
        let screen = try rig.rig.screenID

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=on") == .silent)
        #expect(rig.rig.simulated.topology().onlineIDs.contains(m34))
        #expect(try await rig.run("set", "-displayID=\(screen)", "-placement=5000x0").exitCode == 0)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-main=on") == .silent)
        #expect(rig.rig.simulated.topology().main?.id == lg)
    }

    /// Someone may be sitting in front of dark monitors, so a rescue goes ahead of whatever is waiting,
    /// and only the command already running gets to finish first.
    @Test func aRescueGoesAheadOfAQueuedSet() async throws {
        let rig = try DispatcherRig()
        let dispatcher = try #require(rig.dispatcher)
        let session = try #require(rig.rig.session)
        let queued = Box<Task<CommandResult, Never>>()
        let rescue = Box<Task<CommandResult, Never>>()
        rig.rig.atFirstSwitch(enabling: false) {
            queued.value = Task {
                await dispatcher.handle(
                    CommandRequest(
                        operations: ["set"],
                        parameters: [
                            CommandParameter(name: "UUID", value: lgUUID),
                            CommandParameter(name: "refreshRate", value: "144"),
                        ]
                    )
                )
            }
            while session.turnsWaiting < 1 { await Task.yield() }
            rescue.value = Task { await dispatcher.handle(CommandRequest(operations: ["rescue"])) }
            while session.turnsWaiting < 2 { await Task.yield() }
        }

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off") == .silent)
        #expect(await rescue.value?.value == .success())
        #expect(await queued.value?.value == .success())

        let order = rig.rig.mutations
        let disable = try #require(order.firstIndex(of: "disable \(m34)"))
        let enable = try #require(order.firstIndex(of: "enable \(m34)"))
        let commit = try #require(order.firstIndex { $0.hasPrefix("commit mode \(lg)") })
        #expect(disable < enable, "The running command finished first")
        #expect(enable < commit, "The rescue went ahead of the set that was waiting")
    }

    // MARK: Set others

    @Test func setWithoutASelectorChangesNothing() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-connected=off") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func aBadKeyStopsTheWholeSet() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off", "-nonexistentFeatureXYZ=1") == .failed)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=maybe") == .failed)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected") == .failed)
        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-connected=off", "-connected=on") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func extraWordsStopTheCommand() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "now", "-UUID=\(m34UUID)", "-connected=off") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func setMainMakesItMain() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-main=on") == .silent)

        #expect(rig.rig.simulated.topology().main?.id == m34)
        #expect(try await rig.run("get", "-UUID=\(m34UUID)", "-main") == .out("true"))
    }

    @Test func setMainOffFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-main=off") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func setMainOfSeveralFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-type=Display", "-main=on") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func setResolutionAndRefreshRate() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-refreshRate=144") == .silent)
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-refreshRate") == .out("144Hz"))

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-resolution=1920x1080", "-refreshRate=60Hz") == .silent)
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-resolution", "-refreshRate") == .out("1920x1080,60Hz"))
        #expect(rig.rig.countOfPrefix("commit mode") == 2, "The size and the rate go in one change")
    }

    @Test func setModeNotOfferedFailsWithAReason() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("set", "-UUID=\(lgUUID)", "-resolution=123x456")

        #expect(output.stderr.contains("has no mode 123x456"))
        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func hiDPIReadsAndSets() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-hiDPI") == .out("off"))
        let offered = rig.rig.simulated.modes(of: lg).first { $0.isHiDPI }
        let hiDPI = try #require(offered)

        let output = try await rig.run(
            "set", "-UUID=\(lgUUID)", "-resolution=\(hiDPI.pointsWide)x\(hiDPI.pointsHigh)", "-hiDPI=on"
        )

        #expect(output == .silent)
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-hiDPI") == .out("on"))
    }

    @Test func setPlacement() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-placement=-100x1440") == .silent)

        #expect(try await rig.run("get", "-UUID=\(m34UUID)", "-placement") == .out("-100x1440"))
    }

    @Test func setPlacementSaysSoIfMacOSPutItElsewhere() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("set", "-UUID=\(lgUUID)", "-placement=500x500")

        #expect(output.exitCode == 0)
        #expect(output.stderr == "warning: display \(lg) was placed at 0x0\n")
    }

    @Test func setPlacementBadValueFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(m34UUID)", "-placement=left") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    // MARK: Identifiers

    @Test func identifiersShapeIsExact() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())

        let output = try await rig.run("get", "-identifiers")

        #expect(output.exitCode == 0)
        let text = String(output.stdout.dropLast())
        // Objects joined by a comma, so the whole isn't a JSON document until an array goes around it.
        #expect(text.hasPrefix("{"))
        #expect(text.hasSuffix("}"))
        #expect(text.contains("},{"))
        #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil)
        #expect(text.contains("\n  \"UUID\" : \""), "Pretty-printed")

        let parsed = try JSONSerialization.jsonObject(with: Data("[\(text)]".utf8))
        let objects = try #require(parsed as? [[String: Any]])
        #expect(objects.count == 2)
        for object in objects {
            #expect(object.allSatisfy { $0.value is String }, "Every value is a string")
            #expect(
                object.keys.sorted() == [
                    "UUID", "alphanumericSerial", "deviceType", "displayID", "model", "name", "originalName",
                    "productName", "registryLocation", "serial", "tagID", "vendor", "weekOfManufacture",
                    "yearOfManufacture",
                ]
            )
        }

        let first = try #require(objects.first as? [String: String])
        #expect(first["UUID"] == lgUUID)
        #expect(first["deviceType"] == "Display")
        #expect(first["displayID"] == "2")
        #expect(first["name"] == "27GL850")
        #expect(first["originalName"] == "27GL850")
        #expect(first["productName"] == "27GL850")
        #expect(first["vendor"] == "7789")
        #expect(first["model"] == "23423")
        #expect(first["serial"] == "198499")
        #expect(first["tagID"] == "1")
        #expect(first["weekOfManufacture"] == "11")
        #expect(first["yearOfManufacture"] == "2020")
        #expect(first["registryLocation"]?.hasPrefix("IOService:/") == true)
        #expect(!text.contains("\\/"), "Slashes print as they are")
    }

    @Test func identifiersFollowTheSelector() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("get", "-n=M34", "-identifiers")

        let parsed = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        let object = try #require(parsed as? [String: String])
        #expect(object["UUID"] == m34UUID)
    }

    @Test func identifiersIsAValidDocumentInTheEnvelope() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("get", "-identifiers", "--json")

        let parsed = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        let envelope = try #require(parsed as? [String: Any])
        let list = try #require(envelope["json"] as? [[String: String]])
        #expect(list.map { $0["UUID"] } == [lgUUID, m34UUID])
    }

    @Test func identifiersListADisplayThatIsOff() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)

        let output = try await rig.run("get", "-identifiers")

        let parsed = try JSONSerialization.jsonObject(with: Data("[\(output.stdout)]".utf8))
        let objects = try #require(parsed as? [[String: String]])
        #expect(objects.first { $0["UUID"] == m34UUID }?["name"] == "M34WQ")
    }

    // MARK: Pin

    @Test func pinRefreshRateRoundTrip() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-pinRefreshRate") == .out("off"))

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-pinRefreshRate=120") == .silent)
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-pinRefreshRate") == .out("120Hz"))
        #expect(rig.rig.registry.entry(uuid: lgUUID)?.pinnedRefreshHz == 120)

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-pinRefreshRate=off") == .silent)
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-pinRefreshRate") == .out("off"))
        #expect(rig.rig.registry.entry(uuid: lgUUID)?.pinnedRefreshHz == nil)
    }

    @Test func pinDoesNotChangeDisplay() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-pinRefreshRate=144") == .silent)

        #expect(rig.rig.mutations.isEmpty)
        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-refreshRate") == .out("120Hz"))
    }

    @Test func pinBadValueFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-pinRefreshRate=fast") == .failed)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-pinRefreshRate=0") == .failed)
    }

    // MARK: Selectors

    @Test func selectorsWork() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        let tag = try #require(rig.rig.registry.entry(uuid: m34UUID)?.tagID)

        for selector in [
            "-UUID=\(m34UUID)",
            "-UUID=\(m34UUID.lowercased())",
            "-displayID=\(m34)",
            "-name=M34WQ",
            "-name=m34wq",
            "-nameLike=34W",
            "-n=m34",
            "-originalName=M34WQ",
            "-tagID=\(tag)",
        ] {
            #expect(try await rig.run("get", selector, "-main") == .out("false"), "\(selector)")
        }

        #expect(try await rig.run("get", "-displayWithMainStatus", "-UUID=\(lgUUID)", "-connected") == .out("on"))
        #expect(try await rig.run("get", "-displayWithMainStatus", "-resolution") == .out("2560x1440"))
        #expect(try await rig.run("get", "-type=Display", "-main") == .out("true,false"))
        #expect(try await rig.run("get", "-deviceType=display", "-connected") == .out("on,on"))

        for selector in [
            "-UUID=\(lgUUID)x",
            "-UUID",
            "-displayID=99",
            "-displayID=abc",
            "-name=M34",
            "-nameLike=nothing",
            "-originalName=nothing",
            "-tagID=99",
            "-type=VirtualScreen",
            "-type=DisplayGroup",
            "-displayWithMainStatus=off",
        ] {
            #expect(try await rig.run("get", selector, "-main") == .failed, "\(selector)")
        }
    }

    @Test func selectorsTogetherNarrow() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-type=Display", "-n=M34", "-main") == .out("false"))
        #expect(try await rig.run("get", "-n=M34", "-displayWithMainStatus", "-main") == .failed)
    }

    @Test func tagIDFindsADisplayWithNoEntryYet() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-tagID=2", "-main") == .out("false"), "The read wrote the registry")
    }

    @Test func aDisconnectedDisplaySelectsByNameThroughTheRegistry() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)

        #expect(try await rig.run("get", "-name=M34WQ", "-connected") == .out("off"))
        #expect(try await rig.run("set", "-n=M34", "-connected=on") == .silent)
        #expect(rig.rig.simulated.topology().onlineIDs.contains(m34))
    }

    // MARK: Extension keys

    @Test func spiReportReturnsReport() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-spiReport") == .out(rig.capabilities.report))
    }

    @Test func launchAtLoginRoundTrip() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run("get", "-launchAtLogin") == .out("off"))

        #expect(try await rig.run("set", "-launchAtLogin=on") == .silent)

        #expect(rig.launchAtLogin.isEnabled)
        #expect(try await rig.run("get", "-launchAtLogin") == .out("on"))
        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func launchAtLoginFailureSaysSo() async throws {
        let rig = try DispatcherRig()
        rig.launchAtLogin.failure = POSIXError(.EPERM)

        let output = try await rig.run("set", "-launchAtLogin=on")

        #expect(output.exitCode == 1)
        #expect(output.stderr.contains("launch at login"))
    }

    // MARK: Other operations

    @Test func helpListsTheCommandsInOurOwnWords() async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run("help")

        #expect(output.exitCode == 0)
        for word in ["get", "set", "create", "discard", "session start", "session end", "rescue", "quit"] {
            #expect(output.stdout.contains(word), "\(word)")
        }
        #expect(!output.stdout.lowercased().contains("betterdisplay"))
        #expect(output.stdout == CommandHelp.text + "\n", "The same text the CLI prints without the app")
    }

    @Test func quitCallsWhatTheAppSet() async throws {
        let rig = try DispatcherRig()
        var calls = 0
        rig.dispatcher.onQuit = {
            calls += 1
            return nil
        }

        #expect(try await rig.run("quit") == .silent)

        #expect(calls == 1)
    }

    /// The app says why it won't quit, as during a restart, so the caller isn't told it worked.
    @Test func quitFailsWithTheAppsReasonForNotQuitting() async throws {
        let rig = try DispatcherRig()
        rig.dispatcher.onQuit = { "restarting" }

        #expect(try await rig.run("quit") == .failed("restarting"))
    }

    /// `addevhost` and the tests have no app around the engine to quit.
    @Test func quitFailsWithNoAppToQuit() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("quit") == .failed("quit isn't available here"))
    }

    @Test func anUnknownOperationFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("frobnicate") == .failed("unknown operation: frobnicate; run porchlight help"))
    }

    @Test func noOperationFails() async throws {
        let rig = try DispatcherRig()

        let result = await rig.dispatcher.handle(CommandRequest(operations: []))

        #expect(result == .failure("no operation given"))
    }

    /// Something other than the parser may send a name in any case, and it has to mean the same.
    @Test func namesAreNormalizedForEveryFrontEnd() async throws {
        let rig = try DispatcherRig()

        let result = await rig.dispatcher.handle(
            CommandRequest(
                operations: ["get"],
                parameters: [CommandParameter(name: "uuid", value: lgUUID), CommandParameter(name: "MAIN")]
            )
        )

        #expect(result == .success("true"))
    }
}
