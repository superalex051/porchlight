/// What a physical display looked like before a session turned it off.
public struct PhysicalRecord: Codable, Sendable, Equatable {
    public var id: DisplayID
    public var identity: DisplayIdentity
    public var origin: DisplayOrigin
    public var mode: DisplayMode
    public var wasMain: Bool

    public init(
        id: DisplayID,
        identity: DisplayIdentity,
        origin: DisplayOrigin,
        mode: DisplayMode,
        wasMain: Bool
    ) {
        self.id = id
        self.identity = identity
        self.origin = origin
        self.mode = mode
        self.wasMain = wasMain
    }
}
