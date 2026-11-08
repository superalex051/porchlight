public struct Topology: Codable, Sendable, Equatable {
    public var displays: [DisplaySnapshot]
    /// This read couldn't get the full display list, so it shows only what's online, and a display
    /// that isn't listed says nothing about where that display went. It's about this read, so it
    /// isn't saved with the rest.
    public var listReadFailed: Bool = false

    private enum CodingKeys: String, CodingKey {
        case displays
    }

    public init(displays: [DisplaySnapshot], listReadFailed: Bool = false) {
        self.displays = displays
        self.listReadFailed = listReadFailed
    }

    public func display(_ id: DisplayID) -> DisplaySnapshot? {
        displays.first { $0.id == id }
    }

    /// UUIDs are hex, so a different letter case is still the same UUID.
    public func display(uuid: String) -> DisplaySnapshot? {
        let wanted = uuid.uppercased()
        return displays.first { $0.identity.uuid?.uppercased() == wanted }
    }

    public var online: [DisplaySnapshot] {
        displays.filter(\.isOnline)
    }

    public var onlineIDs: Set<DisplayID> {
        Set(online.map(\.id))
    }

    public var main: DisplaySnapshot? {
        displays.first(where: \.isMain)
    }
}
