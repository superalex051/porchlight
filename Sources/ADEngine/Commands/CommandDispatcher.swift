import ADCommand
import ADDisplayConfig
import ADDisplays
import ADFoundation
import ADIntegrations
import ADModel
import ADSPI
import ADVirtualScreens
import Foundation

/// A command that can't go ahead. With no reason the CLI prints a bare `Failed.`, which is what the
/// BetterDisplay-compatible commands answer for an unknown key or a device they can't select.
nonisolated struct CommandRefusal: Error, Equatable {
    var reason: String?

    static let bare = CommandRefusal(reason: nil)
}

/// Runs one request from any front end: the CLI, the status menu, the guardian.
///
/// **A command that changes a display waits its turn with the session controller.** The socket serves
/// each connection on its own, so without that, two `set -connected=off` could each pass the never-zero
/// check while the other's disconnect is still on its way, and leave no display at all. Reads don't
/// wait, and `ping` touches nothing, so it's answered even during a slow force-end.
@MainActor
public final class CommandDispatcher {
    let backend: any DisplayBackend
    let registry: DeviceRegistry
    let session: SessionController
    let presets: PresetStore
    /// `session start -preset=auto` and the `clients` commands.
    let sizer: DeviceSizer
    let operations: DisplayOperations
    let screens: any VirtualScreenProviding
    let virtualStore: VirtualScreenStore
    let launchAtLogin: any LaunchAtLoginControlling
    let capabilities: SPICapabilities
    let clock: any ADClock
    private let dryRunPlan: (@MainActor () -> [String])?
    /// What `session watch` answers from. The runtime records every session change in it.
    let sessionChanges: SessionChangeFeed

    /// The screens made with `create` that this process holds, by `VirtualScreenDefinition.key`.
    var heldScreens: [String: ActiveVirtualScreen] = [:]

    /// What `quit` calls, which the app sets. It has to return at once and quit afterward, so the caller
    /// gets its answer. It returns nil if it's going to quit, or why it won't, which the command fails
    /// with. Without it, `quit` fails.
    public var onQuit: (() -> String?)?

    /// `dryRunPlan` answers `get -dryRunPlan`. Without it, that key fails like any unknown one.
    public init(
        backend: any DisplayBackend,
        registry: DeviceRegistry,
        session: SessionController,
        presets: PresetStore,
        sizer: DeviceSizer,
        operations: DisplayOperations,
        screens: any VirtualScreenProviding,
        virtualStore: VirtualScreenStore,
        launchAtLogin: any LaunchAtLoginControlling,
        capabilities: SPICapabilities,
        clock: any ADClock,
        dryRunPlan: (@MainActor () -> [String])? = nil
    ) {
        self.backend = backend
        self.registry = registry
        self.session = session
        self.presets = presets
        self.sizer = sizer
        self.operations = operations
        self.screens = screens
        self.virtualStore = virtualStore
        self.launchAtLogin = launchAtLogin
        self.capabilities = capabilities
        self.clock = clock
        self.dryRunPlan = dryRunPlan
        sessionChanges = SessionChangeFeed(clock: clock)
    }

    public func handle(_ request: CommandRequest) async -> CommandResult {
        // The parser does this for the CLI, but not every front end comes through the parser.
        let parameters = request.parameters.map {
            CommandParameter(name: FeatureRegistry.canonical($0.name) ?? $0.name, value: $0.value)
        }
        let words = request.operations
        do {
            switch words.first {
            case nil:
                return .failure("no operation given")
            case "ping":
                return .success("pong")
            case "rescue":
                return try await runRescue()
            case "quit":
                guard let onQuit else { return .failure("quit isn't available here") }
                if let refusal = onQuit() { return .failure(refusal) }
                return .success()
            case "session":
                return try await runSession(Array(words.dropFirst()), parameters)
            case "clients":
                return try runClients(Array(words.dropFirst()), parameters)
            case "help":
                return .success(CommandHelp.text)
            case "get" where words.count == 1:
                return try runGet(parameters)
            case "set" where words.count == 1:
                return try await runSet(parameters)
            case "create" where words.count == 1:
                return try await runCreate(parameters)
            case "discard" where words.count == 1:
                return try await runDiscard(parameters)
            case "get", "set", "create", "discard":
                throw CommandRefusal.bare
            case let word?:
                return .failure("unknown operation: \(word); run porchlight help")
            }
        } catch let refusal as CommandRefusal {
            return .failure(refusal.reason)
        } catch {
            return .failure(error.sessionReason)
        }
    }

    // MARK: Get

    private static let globalKeys: Set<String> = ["launchAtLogin", "spiReport", "dryRunPlan"]

    private func runGet(_ parameters: [CommandParameter]) throws -> CommandResult {
        let selectors = parameters.filter { DeviceSelector.keys.contains($0.name) }
        let keys = parameters.filter { !DeviceSelector.keys.contains($0.name) }
        guard !keys.isEmpty, keys.allSatisfy({ $0.value == nil }) else { throw CommandRefusal.bare }

        var all: [SelectedDevice] = []
        var selected: [SelectedDevice]?
        if !selectors.isEmpty || keys.contains(where: { !Self.globalKeys.contains($0.name) }) {
            let topology = currentTopology()
            // A working Mac always lists something, so this read says nothing about any display. Going
            // by the registry here would answer `off` for a monitor that's on.
            guard !topology.online.isEmpty else { throw CommandRefusal.bare }
            let selector = deviceSelector(topology)
            all = selector.devices
            if !selectors.isEmpty {
                selected = selector.select(selectors)
                guard selected?.isEmpty == false else { throw CommandRefusal.bare }
            }
        }

        var values: [String] = []
        for key in keys {
            switch key.name {
            case "identifiers":
                values.append(identifiersText(selected ?? all))
            case "launchAtLogin":
                values.append(launchAtLoginValue)
            case "spiReport":
                values.append(spiReportValue)
            case "dryRunPlan":
                guard let dryRunPlan else { throw CommandRefusal.bare }
                values.append(dryRunPlan().joined(separator: "\n"))
            default:
                guard let selected else { throw CommandRefusal.bare }
                for device in selected {
                    guard let value = value(of: key.name, for: device) else { throw CommandRefusal.bare }
                    values.append(value)
                }
            }
        }

        let json = keys.map(\.name) == ["identifiers"] ? identifiersJSON(selected ?? all) : nil
        return .success(values.joined(separator: ","), json: json)
    }

    /// Nil if the key doesn't apply to this device right now, which answers `Failed.`.
    private func value(of key: String, for device: SelectedDevice) -> String? {
        switch key {
        case "connected": connectedValue(of: device)
        case "main": mainValue(of: device)
        case "placement": placementValue(of: device)
        case "resolution": resolutionValue(of: device)
        case "refreshRate": refreshRateValue(of: device)
        case "hiDPI": hiDPIValue(of: device)
        case "pinRefreshRate": pinValue(of: device)
        case "virtualScreenName", "useResolutionList", "resolutionList", "virtualScreenHiDPI":
            screenSettingValue(key, of: device)
        default: nil
        }
    }

    // MARK: Set

    private func runSet(_ parameters: [CommandParameter]) async throws -> CommandResult {
        let plan = try SetPlan(parameters)
        let warning = try await session.inTurn { [self] in try await apply(plan) }
        return .success(warning: warning)
    }

    /// In a fixed order whatever the command's order, so a display is on before anything else touches
    /// it, and off after. The selectors are read again at each step, because a display that has just
    /// come on now has a mode and a UUID. Returns what to warn about.
    private func apply(_ plan: SetPlan) async throws -> String? {
        let selectors = plan.selectors
        // All of this comes first, so a command that's going to be refused changes nothing at all.
        if plan.usesDevices || !selectors.isEmpty { _ = try selectedDevices(selectors) }
        try refuseWhatAnActiveSessionHolds(plan)
        if plan.connected == false { try refuseTurningOff(selectedDevices(selectors)) }

        if plan.connected == true { try await turnOn(selectedDevices(selectors)) }
        if !plan.mode.isEmpty { try await setMode(plan.mode, on: selectedDevices(selectors)) }
        var warning: String?
        if let origin = plan.placement { warning = try await setPlacement(origin, on: selectedDevices(selectors)) }
        if plan.makesMain { try await setMain(selectedDevices(selectors)) }
        if let pin = plan.pin { try setPin(pin, on: selectedDevices(selectors)) }
        if let on = plan.launchAtLogin { try setLaunchAtLogin(on) }
        if plan.connected == false { try await turnOff(selectedDevices(selectors)) }
        // Last, because a rename changes what the selectors find.
        if !plan.screenSettings.isEmpty { try await changeSettings(plan.screenSettings, on: selectedDevices(selectors)) }
        return warning
    }

    /// Enforcement would undo these within a second or so, so reporting success would be untrue. A
    /// degraded session has stopped enforcing, so there they can stand. A monitor kept on and turned off
    /// by hand isn't the session's to hold, so it can come back on.
    private func refuseWhatAnActiveSessionHolds(_ plan: SetPlan) throws {
        let status = session.status()
        guard status.state == .active, plan.usesDevices else { return }
        let ids = try selectedDevices(plan.selectors).compactMap(\.id)
        let isHeld = (plan.connected == true && ids.contains(where: status.physicalOff.contains))
            || (plan.makesMain && ids.contains { $0 != status.displayID })
            || (plan.placement != nil && ids.contains { $0 == status.displayID })
        if isHeld { throw CommandRefusal(reason: "a session is active; use session end") }
    }

    // MARK: Devices

    /// Throws for no selector at all, so `set -connected=off` alone can't mean every display. It also
    /// throws on an empty read, for the same reason as `get`: every display would look off, and turning
    /// off one that already looks off would report success over a monitor that's still on.
    func selectedDevices(_ selectors: [CommandParameter]) throws -> [SelectedDevice] {
        let topology = currentTopology()
        guard !selectors.isEmpty, !topology.online.isEmpty else { throw CommandRefusal.bare }
        let devices = deviceSelector(topology).select(selectors)
        guard !devices.isEmpty else { throw CommandRefusal.bare }
        return devices
    }

    func deviceSelector(_ topology: Topology) -> DeviceSelector {
        DeviceSelector(
            topology: topology,
            entries: registry.currentBootEntries(),
            definitions: (try? virtualStore.definitions()) ?? []
        )
    }

    /// The registry follows topology events, but a display only has a tag ID once it has an entry, and
    /// a pin needs one too. So a display with none gets one now. It's written only when something is
    /// missing, because a read shouldn't normally touch the disk. A failed write costs a tag ID and
    /// nothing else here. A disconnect makes its own write, and refuses if that fails.
    private func currentTopology() -> Topology {
        let topology = backend.topology()
        let known = Set(registry.currentBootEntries().compactMap { $0.identity.uuid?.uppercased() })
        let isBehind = topology.online.contains { display in
            guard display.kind != .emptyPipe, let uuid = display.identity.uuid else { return false }
            return !known.contains(uuid.uppercased())
        }
        if isBehind { try? registry.update(from: topology) }
        return topology
    }
}

/// Everything a `set` asks for, read in full before anything changes, so a bad value anywhere in the
/// command leaves every display as it was.
struct SetPlan {
    var selectors: [CommandParameter] = []
    var connected: Bool?
    var makesMain = false
    var placement: DisplayOrigin?
    var mode = ModeRequest()
    var pin: PinRequest?
    var launchAtLogin: Bool?
    var screenSettings = ScreenSettingsRequest()

    var usesDevices: Bool {
        connected != nil || makesMain || placement != nil || !mode.isEmpty || pin != nil || !screenSettings.isEmpty
    }

    init(_ parameters: [CommandParameter]) throws {
        var seen = Set<String>()
        for parameter in parameters {
            if DeviceSelector.keys.contains(parameter.name) {
                selectors.append(parameter)
                continue
            }
            guard seen.insert(parameter.name).inserted, let value = parameter.value else { throw CommandRefusal.bare }
            switch parameter.name {
            case "connected": connected = try Self.required(CommandValues.onOff(value))
            case "main":
                // A display can only be made main. It stops being main when another one is.
                guard CommandValues.onOff(value) == true else { throw CommandRefusal.bare }
                makesMain = true
            case "placement": placement = try Self.required(DisplayOrigin(placement: value))
            case "resolution": mode.resolution = try Self.required(ScreenSize(parsing: value))
            case "refreshRate": mode.refreshHz = try Self.required(CommandValues.hz(value))
            case "hiDPI": mode.hiDPI = try Self.required(CommandValues.onOff(value))
            case "pinRefreshRate": pin = try Self.required(PinRequest(parsing: value))
            case "launchAtLogin": launchAtLogin = try Self.required(CommandValues.onOff(value))
            default:
                guard try screenSettings.read(parameter.name, value) else { throw CommandRefusal.bare }
            }
        }
        guard !seen.isEmpty else { throw CommandRefusal.bare }
    }

    private static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw CommandRefusal.bare }
        return value
    }
}

/// How the commands read the values they share.
enum CommandValues {
    static func onOff(_ text: String?) -> Bool? {
        switch text?.lowercased() {
        case "on", "true": true
        case "off", "false": false
        default: nil
        }
    }

    /// For a parameter like `-force`, where saying nothing more means on.
    static func flag(_ text: String?) -> Bool? {
        text == nil ? true : onOff(text)
    }

    /// Plain digits only, because `Int(_:)` alone would accept a leading `+`.
    static func wholeNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(text)
    }
}
