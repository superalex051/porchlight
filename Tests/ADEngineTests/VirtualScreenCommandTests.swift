import ADCommand
import ADDisplays
import ADFoundation
import ADModel
import Foundation
import Testing

@testable import ADEngine

@MainActor
@Suite struct VirtualScreenCommandTests {
    private func screens(_ rig: DispatcherRig) -> [DisplaySnapshot] {
        rig.rig.simulated.topology().online.filter { $0.kind == .ownVirtual }
    }

    private func create(_ rig: DispatcherRig, _ name: String = "Office", _ extra: String...) async throws {
        let output = try await rig.run(["create", "-type=VirtualScreen", "-virtualScreenName=\(name)"] + extra)
        #expect(output == .silent)
    }

    /// The app dies, and its screens with it.
    private func relaunch(_ rig: DispatcherRig) {
        for screen in screens(rig) {
            rig.rig.simulated.removeVirtual(screen.id)
        }
        rig.rig.relaunch()
        rig.rebuild()
    }

    // MARK: Create

    @Test func createWithResolutionList() async throws {
        let rig = try DispatcherRig()

        try await create(rig, "Office", "-useResolutionList=on", "-resolutionList=1920x1080,1280x720", "-virtualScreenHiDPI=off")

        let screen = try #require(screens(rig).first)
        #expect(screens(rig).count == 1)
        #expect(screen.identity.productName == "Office")
        #expect(screen.mode?.matches(mode(1920, 1080, hz: 60)) == true, "The first size in the list, at 1x")

        let definition = try #require(try rig.definitions.first)
        #expect(definition.name == "Office")
        #expect(definition.useResolutionList)
        #expect(definition.resolutionList == [ScreenSize(w: 1920, h: 1080), ScreenSize(w: 1280, h: 720)])
        #expect(definition.hiDPI == false)
        #expect(definition.connected)

        #expect(try await rig.run("get", "-n=Office", "-virtualScreenName") == .out("Office"))
        #expect(try await rig.run("get", "-n=Office", "-useResolutionList") == .out("on"))
        #expect(try await rig.run("get", "-n=Office", "-resolutionList") == .out("1920x1080,1280x720"))
        #expect(try await rig.run("get", "-n=Office", "-virtualScreenHiDPI") == .out("off"))
        #expect(try await rig.run("get", "-n=Office", "-connected") == .out("on"))
        #expect(try await rig.run("get", "-type=VirtualScreen", "-resolution") == .out("1920x1080"))
    }

    @Test func createDefaultsToAHiDPIScreen() async throws {
        let rig = try DispatcherRig()

        try await create(rig)

        let shown = try #require(screens(rig).first?.mode)
        #expect(shown.matches(mode(1920, 1080, hz: 60, scale: 2)))
    }

    @Test func createRequiresType() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("create", "-virtualScreenName=Office").exitCode == 1)
        #expect(try await rig.run("create", "-type=DisplayGroup", "-virtualScreenName=Office").exitCode == 1)

        #expect(rig.rig.mutations.isEmpty)
        #expect(try rig.definitions.isEmpty)
    }

    @Test func createRequiresAName() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("create", "-type=VirtualScreen").exitCode == 1)
        #expect(try await rig.run("create", "-type=VirtualScreen", "-virtualScreenName=").exitCode == 1)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test(arguments: [
        ["-useResolutionList=on"],
        ["-useResolutionList=maybe"],
        ["-useResolutionList=on", "-resolutionList=wide"],
        ["-useResolutionList=on", "-resolutionList=1920x1080,wide"],
        ["-useResolutionList=on", "-resolutionList=10x10"],
        ["-virtualScreenHiDPI=maybe"],
        ["-nonsense=1"],
    ])
    func createBadValueChangesNothing(_ extra: [String]) async throws {
        let rig = try DispatcherRig()

        let output = try await rig.run(["create", "-type=VirtualScreen", "-virtualScreenName=Office"] + extra)

        #expect(output.exitCode == 1, "\(extra)")
        #expect(rig.rig.mutations.isEmpty, "\(extra)")
        #expect(try rig.definitions.isEmpty, "\(extra)")
    }

    @Test func aSecondScreenWithTheSameNameIsRefused() async throws {
        let rig = try DispatcherRig()
        try await create(rig)

        let output = try await rig.run("create", "-type=VirtualScreen", "-virtualScreenName=office")

        #expect(output.exitCode == 1)
        #expect(screens(rig).count == 1)
        #expect(try rig.definitions.count == 1)
    }

    /// The UUID comes from the serial, so a screen named like a client must not get that client's UUID.
    @Test func aScreenAndASessionWithOneNameGetTwoUUIDs() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "parsec")
        #expect(try await rig.result("session", "start", "-client=parsec", "-keepon=\(lgUUID)", "-keepon=\(m34UUID)").ok)

        let uuids = Set(screens(rig).compactMap(\.identity.uuid))

        #expect(uuids.count == 2)
    }

    @Test func aFailedCreateLeavesNoDefinition() async throws {
        let rig = try DispatcherRig()
        rig.rig.screens.createFailures = 1

        let output = try await rig.run("create", "-type=VirtualScreen", "-virtualScreenName=Office")

        #expect(output == .failed("scripted failure creating Office"))
        #expect(try rig.definitions.isEmpty)
    }

    @Test func aDefinitionThatCannotBeSavedMakesNoScreen() async throws {
        let rig = try DispatcherRig()
        // A folder where the file goes makes both the read and the write fail, without touching the disk's state.
        let blocked = rig.rig.folder.appending(component: "virtual-screens.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        #expect(try await rig.run("create", "-type=VirtualScreen", "-virtualScreenName=Office") == .failed("cannot write state"))

        #expect(rig.rig.mutations.isEmpty)
    }

    // MARK: Discard

    @Test func discardByName() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "Office")
        try await create(rig, "Kitchen")

        #expect(try await rig.run("discard", "-name=Office") == .silent)

        #expect(screens(rig).map(\.identity.productName) == ["Kitchen"])
        #expect(try rig.definitions.map(\.name) == ["Kitchen"])
        #expect(try await rig.run("get", "-n=Office", "-connected") == .failed)
    }

    @Test func discardWithoutSelectorRefused() async throws {
        let rig = try DispatcherRig()
        try await create(rig)

        let output = try await rig.run("discard")

        #expect(output == .failed("discard needs a selector, or --force for every virtual screen"))
        #expect(screens(rig).count == 1)
        #expect(try rig.definitions.count == 1)
    }

    @Test func discardForceTakesEveryMadeScreenAndNoSessionScreen() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "Office")
        try await create(rig, "Kitchen")
        #expect(try await rig.result("session", "start", "-client=parsec").ok)

        #expect(try await rig.run("discard", "--force") == .silent)

        #expect(try rig.definitions.isEmpty)
        #expect(screens(rig).map(\.id) == [try rig.rig.screenID])
    }

    @Test func discardForceWithNothingToDiscardSucceeds() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("discard", "-force") == .silent)
    }

    @Test func discardOfAMonitorFails() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("discard", "-UUID=\(lgUUID)") == .failed)
        #expect(try await rig.run("discard", "-n=Nothing") == .failed)
        #expect(try await rig.run("discard", "-UUID=\(lgUUID)", "-nonsense") == .failed)

        #expect(rig.rig.mutations.isEmpty)
    }

    @Test func discardOfAReleasedScreenWorks() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .silent)

        #expect(try await rig.run("discard", "-n=Office") == .silent)

        #expect(try rig.definitions.isEmpty)
    }

    // MARK: Persistence

    @Test func definitionsPersistAndReconnect() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "Office", "-useResolutionList=on", "-resolutionList=1280x720,1920x1080")
        relaunch(rig)
        #expect(screens(rig).isEmpty)

        await rig.dispatcher.reconnectSavedScreens()

        let screen = try #require(screens(rig).first)
        #expect(screen.identity.productName == "Office")
        #expect(screen.mode?.pointsWide == 1280)
        #expect(try await rig.run("get", "-n=Office", "-connected") == .out("on"))
        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .silent, "The new process holds it")
        #expect(screens(rig).isEmpty)
    }

    @Test func aReleasedScreenStaysOffAtLaunch() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .silent)
        relaunch(rig)

        await rig.dispatcher.reconnectSavedScreens()

        #expect(screens(rig).isEmpty)
        #expect(try rig.definitions.count == 1)
    }

    /// One bad screen mustn't keep the others away.
    @Test func aScreenThatCannotComeBackDoesNotStopTheRest() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "Office")
        try await create(rig, "Kitchen")
        relaunch(rig)
        rig.rig.screens.createFailures = 1

        await rig.dispatcher.reconnectSavedScreens()

        #expect(screens(rig).map(\.identity.productName) == ["Kitchen"])
        #expect(try rig.definitions.count == 2)
    }

    @Test func connectedOffReleasesKeepsDefinition() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        let uuid = try #require(screens(rig).first?.identity.uuid)
        try rig.rig.registry.update(from: rig.rig.simulated.topology())

        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .silent)

        #expect(screens(rig).isEmpty)
        #expect(rig.rig.countOfPrefix("disable") == 0, "Releasing isn't a disconnect")
        let definition = try #require(try rig.definitions.first)
        #expect(definition.name == "Office")
        #expect(definition.connected == false)
        #expect(try await rig.run("get", "-n=Office", "-connected") == .out("off"))
        #expect(try await rig.run("get", "-UUID=\(uuid)", "-connected") == .out("off"))

        #expect(try await rig.run("set", "-UUID=\(uuid)", "-connected=on") == .silent)

        #expect(screens(rig).map(\.identity.uuid) == [uuid], "It comes back as the same display")
        #expect(try rig.definitions.first?.connected == true)
    }

    @Test func aFailedReconnectLeavesTheDefinitionOff() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .silent)
        rig.rig.screens.createFailures = 1

        #expect(try await rig.run("set", "-n=Office", "-connected=on").exitCode == 1)

        #expect(try rig.definitions.first?.connected == false)
    }

    /// A screen the system ended is simply off, and `on` makes it again.
    @Test func aScreenTheSystemEndedCanComeBack() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        let screen = try #require(screens(rig).first)
        rig.rig.simulated.removeVirtual(screen.id)

        #expect(try await rig.run("get", "-n=Office", "-connected") == .out("off"))
        #expect(try await rig.run("set", "-n=Office", "-connected=on") == .silent)

        #expect(screens(rig).count == 1)
    }

    @Test func releasingCountsTowardTheRule() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        // Only a screen made by hand is left, and it doesn't count, so nothing that counts would remain.
        rig.rig.simulated.removePhysical(m34)
        rig.rig.simulated.removePhysical(lg)

        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .failed("would leave no working display"))
        #expect(try await rig.run("discard", "-n=Office") == .failed("would leave no working display"))

        #expect(screens(rig).count == 1)
        #expect(try rig.definitions.first?.connected == true)
    }

    // MARK: Changing a screen

    @Test func setResolutionFollowsTheList() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "Office", "-useResolutionList=on", "-resolutionList=1920x1080,1280x720")

        #expect(try await rig.run("set", "-n=Office", "-resolution=1280x720") == .silent)
        #expect(try await rig.run("get", "-n=Office", "-resolution") == .out("1280x720"))
        #expect(try rig.definitions.first?.looksLike == ScreenSize(w: 1280, h: 720))

        #expect(try await rig.run("set", "-n=Office", "-resolution=1024x768").exitCode == 1)
        #expect(try await rig.run("get", "-n=Office", "-resolution") == .out("1280x720"))
    }

    @Test func setChangesRateAndScaleInTheDefinitionToo() async throws {
        let rig = try DispatcherRig()
        try await create(rig)

        #expect(try await rig.run("set", "-n=Office", "-refreshRate=30", "-hiDPI=off") == .silent)

        #expect(try await rig.run("get", "-n=Office", "-refreshRate", "-hiDPI", "-virtualScreenHiDPI") == .out("30Hz,off,off"))
        #expect(try rig.definitions.first?.hz == 30)
        #expect(try rig.definitions.first?.hiDPI == false)
    }

    @Test func setOfAReleasedScreenAppliesWhenItReturns() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        #expect(try await rig.run("set", "-n=Office", "-connected=off") == .silent)

        #expect(try await rig.run("set", "-n=Office", "-resolution=1280x720") == .silent)
        #expect(screens(rig).isEmpty)

        #expect(try await rig.run("set", "-n=Office", "-connected=on") == .silent)
        #expect(try await rig.run("get", "-n=Office", "-resolution") == .out("1280x720"))
    }

    @Test func aChangeThatFailsGoesBackInTheDefinition() async throws {
        let rig = try DispatcherRig()
        try await create(rig)
        rig.rig.screens.reconfigureFailures = 1

        #expect(try await rig.run("set", "-n=Office", "-resolution=1280x720").exitCode == 1)

        #expect(try rig.definitions.first?.looksLike == ScreenSize(w: 1920, h: 1080))
    }

    @Test func renameMovesTheScreen() async throws {
        let rig = try DispatcherRig()
        try await create(rig)

        #expect(try await rig.run("set", "-n=Office", "-virtualScreenName=Kitchen") == .silent)

        #expect(try rig.definitions.map(\.name) == ["Kitchen"])
        #expect(screens(rig).map(\.identity.productName) == ["Kitchen"])
        #expect(try await rig.run("get", "-n=Office", "-connected") == .failed)
        #expect(try await rig.run("set", "-n=Kitchen", "-connected=off") == .silent, "It's still held under the new name")
        #expect(screens(rig).isEmpty)
    }

    @Test func renameOntoAnotherScreenFails() async throws {
        let rig = try DispatcherRig()
        try await create(rig, "Office")
        try await create(rig, "Kitchen")

        #expect(try await rig.run("set", "-n=Office", "-virtualScreenName=kitchen").exitCode == 1)

        #expect(try rig.definitions.map(\.name) == ["Office", "Kitchen"])
    }

    @Test func listSettingsMoveAScreenOntoTheList() async throws {
        let rig = try DispatcherRig()
        try await create(rig)

        #expect(try await rig.run("set", "-n=Office", "-resolutionList=1280x720,1024x768", "-useResolutionList=on") == .silent)

        #expect(try await rig.run("get", "-n=Office", "-resolution") == .out("1280x720"))
        #expect(try await rig.run("set", "-n=Office", "-useResolutionList=off") == .silent)
        #expect(try await rig.run("set", "-n=Office", "-resolution=1920x1080") == .silent)
    }

    @Test func screenSettingsAreOnlyForMadeScreens() async throws {
        let rig = try DispatcherRig()

        #expect(try await rig.run("get", "-UUID=\(lgUUID)", "-virtualScreenName") == .failed)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-virtualScreenName=Nope") == .failed)
        #expect(try await rig.run("set", "-UUID=\(lgUUID)", "-useResolutionList=on") == .failed)
    }

    // MARK: The file

    @Test func theFileIsItsOwnAndPrivate() async throws {
        let rig = try DispatcherRig()
        try await create(rig)

        let url = rig.rig.folder.appending(component: "virtual-screens.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let devices = (try? String(contentsOf: rig.rig.folder.appending(component: "devices.json"), encoding: .utf8)) ?? ""
        #expect(!devices.contains("useResolutionList"))
    }

    @Test func anInvalidFileIsSetAsideAndNothingIsLost() async throws {
        let rig = try DispatcherRig()
        let url = rig.rig.folder.appending(component: "virtual-screens.json")
        try Data("not json".utf8).write(to: url)

        #expect(try rig.definitions.isEmpty)
        try await create(rig)

        let names = try FileManager.default.contentsOfDirectory(atPath: rig.rig.folder.path)
        #expect(names.contains { $0.hasPrefix("virtual-screens.json.corrupt-") })
        #expect(try rig.definitions.count == 1)
    }

    @Test func aMissingFolderIsMadeOnFirstSave() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(component: "state", directoryHint: .isDirectory)
        let store = VirtualScreenStore(directory: folder, log: { _ in })
        let definition = VirtualScreenDefinition(name: "Office")

        try store.save([definition])

        #expect(try store.definitions() == [definition])
    }
}
