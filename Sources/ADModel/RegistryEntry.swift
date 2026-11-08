/// One known display in `devices.json`.
public struct RegistryEntry: Codable, Sendable, Equatable {
    public var identity: DisplayIdentity
    public var lastID: DisplayID
    public var bootSessionID: String
    public var tagID: Int
    public var kind: DisplayKind
    public var pinnedRefreshHz: Int?

    public init(
        identity: DisplayIdentity,
        lastID: DisplayID,
        bootSessionID: String,
        tagID: Int,
        kind: DisplayKind,
        pinnedRefreshHz: Int? = nil
    ) {
        self.identity = identity
        self.lastID = lastID
        self.bootSessionID = bootSessionID
        self.tagID = tagID
        self.kind = kind
        self.pinnedRefreshHz = pinnedRefreshHz
    }
}
