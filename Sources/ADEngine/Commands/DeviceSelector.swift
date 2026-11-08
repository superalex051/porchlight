import ADDisplays
import ADModel

/// One display a command can act on. It may be on, off and known only to the registry, or a saved
/// virtual screen that isn't up right now.
struct SelectedDevice {
    /// Nil only for a saved screen that hasn't been up in this boot.
    var id: DisplayID?
    var identity: DisplayIdentity
    var kind: DisplayKind
    var tagID: Int?
    var pinnedRefreshHz: Int?
    /// The current read of it, if it was listed. A disconnected display can be listed, offline.
    var display: DisplaySnapshot?
    /// Set if `create` made it.
    var definition: VirtualScreenDefinition?

    var isOnline: Bool { display?.isOnline == true }
    var isMain: Bool { display?.isMain == true }
    var name: String { identity.productName ?? definition?.name ?? "" }
    var deviceType: String { kind == .ownVirtual ? "VirtualScreen" : "Display" }
    /// Nil unless it's on.
    var mode: DisplayMode? { isOnline ? display?.mode : nil }
}

/// Finds displays through the current topology, then through the registry for the ones macOS will no
/// longer look up by UUID. Saved virtual screens that aren't up are listed too, so they can be turned on.
struct DeviceSelector {
    static let keys: Set<String> = [
        "UUID", "displayID", "name", "nameLike", "originalName", "tagID", "type", "displayWithMainStatus",
    ]

    let devices: [SelectedDevice]

    /// `entries` has to be this boot's, because an ID from another boot means nothing.
    ///
    /// Only monitors are found through the registry. It keeps every display ever seen, including a
    /// session's screen and Parsec's, and one of those that isn't listed right now doesn't exist.
    init(topology: Topology, entries: [RegistryEntry], definitions: [VirtualScreenDefinition]) {
        var devices: [SelectedDevice] = []
        var placedTags = Set<Int>()
        var placedDefinitions = Set<String>()

        for display in topology.displays where display.kind != .emptyPipe {
            let entry = entries.first { Self.entry($0, describes: display) }
            let definition = display.kind == .ownVirtual
                ? definitions.first { $0.spec.serial == display.identity.serial }
                : nil
            if let entry { placedTags.insert(entry.tagID) }
            if let definition { placedDefinitions.insert(definition.key) }
            devices.append(
                SelectedDevice(
                    id: display.id,
                    identity: Self.merged(display.identity, over: entry?.identity),
                    kind: display.kind,
                    tagID: entry?.tagID,
                    pinnedRefreshHz: entry?.pinnedRefreshHz,
                    display: display,
                    definition: definition
                )
            )
        }

        for entry in entries where entry.kind == .physical && !placedTags.contains(entry.tagID) {
            devices.append(
                SelectedDevice(
                    id: entry.lastID,
                    identity: entry.identity,
                    kind: entry.kind,
                    tagID: entry.tagID,
                    pinnedRefreshHz: entry.pinnedRefreshHz
                )
            )
        }

        for definition in definitions where !placedDefinitions.contains(definition.key) {
            let entry = entries.first { $0.kind == .ownVirtual && $0.identity.serial == definition.spec.serial }
            devices.append(
                SelectedDevice(
                    id: entry?.lastID,
                    identity: DisplayIdentity(
                        uuid: entry?.identity.uuid,
                        vendor: DisplayClassifier.ownVendor,
                        model: DisplayClassifier.ownProduct,
                        serial: definition.spec.serial,
                        productName: definition.name
                    ),
                    kind: .ownVirtual,
                    tagID: entry?.tagID,
                    definition: definition
                )
            )
        }

        self.devices = devices
    }

    /// Every selector has to match, so several together narrow the choice.
    func select(_ selectors: [CommandParameter]) -> [SelectedDevice] {
        devices.filter { device in selectors.allSatisfy { Self.matches(device, $0) } }
    }

    private static func matches(_ device: SelectedDevice, _ selector: CommandParameter) -> Bool {
        if selector.name == "displayWithMainStatus" {
            return CommandValues.flag(selector.value) == true && device.isMain
        }
        guard let value = selector.value, !value.isEmpty else { return false }
        let wanted = value.lowercased()
        switch selector.name {
        case "UUID":
            return device.identity.uuid?.lowercased() == wanted
        case "displayID":
            guard let id = DisplayID(value) else { return false }
            return device.id == id
        case "name", "originalName":
            return device.name.lowercased() == wanted
        case "nameLike":
            return device.name.lowercased().contains(wanted)
        case "tagID":
            guard let tag = Int(value) else { return false }
            return device.tagID == tag
        case "type":
            return device.deviceType.lowercased() == wanted
        default:
            return false
        }
    }

    /// A disconnected display reads with no UUID, so its ID and identity have to say which entry it is.
    private static func entry(_ entry: RegistryEntry, describes display: DisplaySnapshot) -> Bool {
        if let uuid = display.identity.uuid {
            return entry.identity.uuid?.uppercased() == uuid.uppercased()
        }
        return entry.lastID == display.id
            && entry.identity.vendor == display.identity.vendor
            && entry.identity.model == display.identity.model
            && entry.identity.serial == display.identity.serial
    }

    /// The read wins, but what a disconnected display no longer reports comes from what's on file.
    private static func merged(_ read: DisplayIdentity, over known: DisplayIdentity?) -> DisplayIdentity {
        guard let known else { return read }
        var merged = read
        merged.uuid = read.uuid ?? known.uuid
        merged.alphanumericSerial = read.alphanumericSerial ?? known.alphanumericSerial
        merged.productName = read.productName ?? known.productName
        merged.registryLocation = read.registryLocation ?? known.registryLocation
        merged.weekOfManufacture = read.weekOfManufacture ?? known.weekOfManufacture
        merged.yearOfManufacture = read.yearOfManufacture ?? known.yearOfManufacture
        return merged
    }
}
