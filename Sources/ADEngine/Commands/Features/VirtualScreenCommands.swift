import ADFoundation
import ADModel
import ADVirtualScreens

/// `-virtualScreenName`, `-useResolutionList`, `-resolutionList` and `-virtualScreenHiDPI`, which `create`
/// and `set` share.
struct ScreenSettingsRequest {
    var name: String?
    var useResolutionList: Bool?
    var resolutionList: [ScreenSize]?
    var hiDPI: Bool?

    var isEmpty: Bool { name == nil && useResolutionList == nil && resolutionList == nil && hiDPI == nil }

    /// False if `key` isn't one of these.
    mutating func read(_ key: String, _ value: String) throws -> Bool {
        switch key {
        case "virtualScreenName":
            guard !value.isEmpty else { throw CommandRefusal.bare }
            name = value
        case "useResolutionList":
            guard let on = CommandValues.onOff(value) else { throw CommandRefusal.bare }
            useResolutionList = on
        case "resolutionList":
            let sizes = value.split(separator: ",", omittingEmptySubsequences: false).map { ScreenSize(parsing: String($0)) }
            guard !sizes.contains(nil) else { throw CommandRefusal.bare }
            resolutionList = sizes.compactMap(\.self)
        case "virtualScreenHiDPI":
            guard let on = CommandValues.onOff(value) else { throw CommandRefusal.bare }
            hiDPI = on
        default:
            return false
        }
        return true
    }

    /// A screen using a list is always at a size on that list, the first one if it wasn't.
    func apply(to definition: inout VirtualScreenDefinition) {
        if let name { definition.name = name }
        if let useResolutionList { definition.useResolutionList = useResolutionList }
        if let resolutionList { definition.resolutionList = resolutionList }
        if let hiDPI { definition.hiDPI = hiDPI }
        if definition.useResolutionList, !definition.resolutionList.contains(definition.looksLike),
            let first = definition.resolutionList.first
        {
            definition.looksLike = first
        }
    }
}

extension CommandDispatcher {
    private static let log = ADLog.logger("commands")
    private static let goneLimitSeconds = 2.0
    private static let gonePollSeconds = 0.25

    // MARK: Get

    /// Nil for anything `create` didn't make.
    func screenSettingValue(_ key: String, of device: SelectedDevice) -> String? {
        guard let definition = device.definition else { return nil }
        switch key {
        case "virtualScreenName": return definition.name
        case "useResolutionList": return definition.useResolutionList ? "on" : "off"
        case "resolutionList": return definition.resolutionList.map(\.description).joined(separator: ",")
        case "virtualScreenHiDPI": return definition.hiDPI ? "on" : "off"
        default: return nil
        }
    }

    // MARK: Create

    func runCreate(_ parameters: [CommandParameter]) async throws -> CommandResult {
        var type: String?
        var settings = ScreenSettingsRequest()
        var seen = Set<String>()
        for parameter in parameters {
            guard seen.insert(parameter.name).inserted, let value = parameter.value else { throw CommandRefusal.bare }
            if parameter.name == "type" {
                type = value
            } else if try !settings.read(parameter.name, value) {
                throw CommandRefusal.bare
            }
        }
        guard type?.lowercased() == "virtualscreen" else {
            throw CommandRefusal(reason: "create needs -type=VirtualScreen")
        }
        guard let name = settings.name else { throw CommandRefusal(reason: "create needs -virtualScreenName") }

        var definition = VirtualScreenDefinition(name: name)
        settings.apply(to: &definition)
        // A new screen with a list starts at the top of it, even if the default size is on it too.
        if definition.useResolutionList, let first = definition.resolutionList.first { definition.looksLike = first }
        if let problem = definition.problem { throw CommandRefusal(reason: problem) }

        try await session.inTurn { [self] in
            // Saved first, so a screen never exists that wouldn't come back. A create that fails takes it
            // out again, so a definition doesn't claim a screen nobody could make.
            try updateDefinitions { all in
                guard !all.contains(where: { $0.key == definition.key }) else {
                    throw CommandRefusal(reason: "a virtual screen named \(definition.name) already exists")
                }
                all.append(definition)
            }
            do {
                try await bringUp(definition)
            } catch {
                try? updateDefinitions { $0.removeAll { $0.key == definition.key } }
                throw error
            }
        }
        return .success()
    }

    // MARK: Discard

    /// Only what `create` made can go. A session's screen goes with its session.
    func runDiscard(_ parameters: [CommandParameter]) async throws -> CommandResult {
        let selectors = parameters.filter { DeviceSelector.keys.contains($0.name) }
        var force = false
        for parameter in parameters where !DeviceSelector.keys.contains(parameter.name) {
            guard parameter.name == "force", let value = CommandValues.flag(parameter.value) else {
                throw CommandRefusal.bare
            }
            force = value
        }
        guard !selectors.isEmpty || force else {
            throw CommandRefusal(reason: "discard needs a selector, or --force for every virtual screen")
        }

        try await session.inTurn { [self] in
            let topology = backend.topology()
            let devices = selectors.isEmpty
                ? deviceSelector(topology).devices
                : try selectedDevices(selectors)
            let targets = devices.filter { $0.definition != nil }
            guard !targets.isEmpty || selectors.isEmpty else { throw CommandRefusal.bare }

            try refuseIfNothingWouldRemain(disconnecting: targets.filter(\.isOnline), in: topology)
            let keys = Set(targets.compactMap { $0.definition?.key })
            try updateDefinitions { $0.removeAll { keys.contains($0.key) } }
            for target in targets {
                if let definition = target.definition { await takeDown(definition) }
            }
        }
        return .success()
    }

    // MARK: Launch

    /// Brings back every saved screen that wasn't released. The app calls this once at launch, after it
    /// has resumed any session, and not in safe mode. One screen failing doesn't stop the rest.
    public func reconnectSavedScreens() async {
        try? await session.inTurn { [self] in
            let saved: [VirtualScreenDefinition]
            do {
                saved = try virtualStore.definitions()
            } catch {
                Self.log.error("Can't read the saved virtual screens: \(error.localizedDescription, privacy: .public)")
                return
            }
            for definition in saved where definition.connected {
                do {
                    try await bringUp(definition)
                } catch {
                    Self.log.error("Screen \(definition.name, privacy: .public) didn't come back: \(error.sessionReason, privacy: .public)")
                }
            }
        }
    }

    // MARK: Connected

    /// A failed create leaves the definition as it was. Only for use inside a turn.
    func connectScreen(_ definition: VirtualScreenDefinition) async throws {
        var connected = definition
        connected.connected = true
        try replace(definition, with: connected)
        do {
            try await bringUp(connected)
        } catch {
            try? replace(connected, with: definition)
            throw error
        }
    }

    /// Keeps the definition, so `on` can make it again. Only for use inside a turn.
    func releaseScreen(_ definition: VirtualScreenDefinition) async throws {
        var released = definition
        released.connected = false
        try replace(definition, with: released)
        await takeDown(definition)
    }

    // MARK: Changing

    func changeSettings(_ settings: ScreenSettingsRequest, on devices: [SelectedDevice]) async throws {
        for device in devices {
            guard let definition = device.definition else { throw CommandRefusal.bare }
            try await changeScreen(definition) { settings.apply(to: &$0) }
        }
    }

    /// Saved first, and if the screen can't change, the definition goes back. A released screen only
    /// changes on file, and comes back that way. Only for use inside a turn.
    func changeScreen(
        _ definition: VirtualScreenDefinition,
        _ change: (inout VirtualScreenDefinition) throws -> Void
    ) async throws {
        var changed = definition
        try change(&changed)
        guard changed != definition else { return }
        if let problem = changed.problem { throw CommandRefusal(reason: problem) }
        try updateDefinitions { all in
            guard !all.contains(where: { $0.key == changed.key && $0.key != definition.key }) else {
                throw CommandRefusal(reason: "a virtual screen named \(changed.name) already exists")
            }
            if let index = all.firstIndex(where: { $0.key == definition.key }) { all[index] = changed }
        }

        guard let held = heldScreens[definition.key], backend.topology().onlineIDs.contains(held.displayID) else {
            return
        }
        do {
            let screen = try await screens.reconfigure(held, to: changed.spec)
            heldScreens[definition.key] = nil
            heldScreens[changed.key] = screen
        } catch {
            try? replace(changed, with: definition)
            throw error
        }
    }

    // MARK: Parts

    private func bringUp(_ definition: VirtualScreenDefinition) async throws {
        heldScreens[definition.key] = try await screens.create(definition.spec)
    }

    /// A screen with the same identity must not race the removal of this one, and going ahead at the
    /// limit is better than holding up the command for good.
    private func takeDown(_ definition: VirtualScreenDefinition) async {
        guard let held = heldScreens.removeValue(forKey: definition.key) else { return }
        screens.destroy(held)
        let deadline = clock.now().addingTimeInterval(Self.goneLimitSeconds)
        while backend.topology().display(held.displayID) != nil, clock.now() < deadline {
            do {
                try await clock.sleep(seconds: Self.gonePollSeconds)
            } catch {
                return
            }
        }
    }

    private func replace(_ old: VirtualScreenDefinition, with new: VirtualScreenDefinition) throws {
        try updateDefinitions { all in
            if let index = all.firstIndex(where: { $0.key == old.key }) { all[index] = new }
        }
    }

    /// Read, change, write. Nothing changes on a display unless the write succeeded.
    private func updateDefinitions(_ change: (inout [VirtualScreenDefinition]) throws -> Void) throws {
        var all: [VirtualScreenDefinition]
        do {
            all = try virtualStore.definitions()
        } catch {
            Self.log.error("Can't read the saved virtual screens: \(error.localizedDescription, privacy: .public)")
            throw SessionError.cannotWriteState
        }
        try change(&all)
        do {
            try virtualStore.save(all)
        } catch {
            Self.log.error("Can't save the virtual screens: \(error.localizedDescription, privacy: .public)")
            throw SessionError.cannotWriteState
        }
    }
}
