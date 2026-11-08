/// `clients.json`: which preset each remote device gets when a session starts with `-preset=auto`, the
/// setting that turns that on, and the two settings for a device that isn't in the list. The stored
/// members are exactly the file's keys.
public struct ClientMapping: Codable, Sendable, Equatable {
    /// Off unless the user turns it on. Off, no device gets a preset by its address.
    public var autoSize: Bool
    public var clients: [ClientRule]
    /// On unless the user turns it off. On, a device that gets no preset by its address gets a screen
    /// matched to the size its Parsec client reported.
    public var matchClient: Bool
    /// On unless the user turns it off. On, a matched screen wider than 2:1 is trimmed to 28:15, so the
    /// client's black bars land under a phone's notch.
    public var clearOfNotch: Bool
    /// How much bigger than the phone's own pixels its matched screen is, after the notch trim. 4/3 unless
    /// the user changes it, 1/1 for pixel for pixel. Only screens wider than 2:1 count as phones.
    public var phoneRoom: RoomFactor

    /// What a missing file means: no presets by address, and the client's own size.
    public static let empty = ClientMapping(autoSize: false, clients: [])
    /// What a file that can't be used means: everything off, so the size is the default.
    public static let off = ClientMapping(
        autoSize: false, clients: [], matchClient: false, clearOfNotch: false, phoneRoom: .pixelForPixel
    )

    public init(
        autoSize: Bool,
        clients: [ClientRule],
        matchClient: Bool = true,
        clearOfNotch: Bool = true,
        phoneRoom: RoomFactor = .phoneDefault
    ) {
        self.autoSize = autoSize
        self.clients = clients
        self.matchClient = matchClient
        self.clearOfNotch = clearOfNotch
        self.phoneRoom = phoneRoom
    }

    /// A hand-edited file may leave out any key. A file from before `matchClient`, `clearOfNotch` and
    /// `phoneRoom` has them at their defaults. A `phoneRoom` that isn't a factor makes the file invalid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoSize = try container.decodeIfPresent(Bool.self, forKey: .autoSize) ?? false
        clients = try container.decodeIfPresent([ClientRule].self, forKey: .clients) ?? []
        matchClient = try container.decodeIfPresent(Bool.self, forKey: .matchClient) ?? true
        clearOfNotch = try container.decodeIfPresent(Bool.self, forKey: .clearOfNotch) ?? true
        phoneRoom = try container.decodeIfPresent(RoomFactor.self, forKey: .phoneRoom) ?? .phoneDefault
    }

    /// Names compare without regard to case.
    public func client(named name: String) -> ClientRule? {
        clients.first { $0.name.lowercased() == name.lowercased() }
    }
}

/// One device: a name for people, how to recognize it, and the preset its sessions get.
public struct ClientRule: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        /// An IPv4 or IPv6 address, as Parsec's log shows the device's.
        public var address: String

        public init(address: String) {
            self.address = address
        }
    }

    public var name: String
    public var match: Match
    /// A preset's name, compared without regard to case.
    public var preset: String

    public init(name: String, address: String, preset: String) {
        self.name = name
        match = Match(address: address)
        self.preset = preset
    }
}
