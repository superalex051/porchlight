public enum SessionState: String, Codable, Sendable {
    case idle, starting, active, degraded, ending
}

public struct SessionRequest: Codable, Sendable {
    public var client: String
    public var looksLike: ScreenSize
    public var hiDPI: Bool
    public var hz: Int
    public var ownerPIDs: [Int32]
    public var keepOn: [String]

    public init(
        client: String,
        looksLike: ScreenSize,
        hiDPI: Bool,
        hz: Int,
        ownerPIDs: [Int32] = [],
        keepOn: [String] = []
    ) {
        self.client = client
        self.looksLike = looksLike
        self.hiDPI = hiDPI
        self.hz = hz
        self.ownerPIDs = ownerPIDs
        self.keepOn = keepOn
    }
}

/// The session API's version, in every status object a session command returns. The contract is
/// `docs/session-api.md`, and anything it says needs a new version does.
public enum SessionAPI {
    public static let version = 1
}

public struct SessionStatus: Codable, Sendable, Equatable {
    public var state: SessionState
    public var client: String?
    public var displayID: DisplayID?
    /// The screen's UUID, which the JSON calls `displayUUID`.
    public var uuid: String?
    public var looksLike: ScreenSize?
    public var pixels: ScreenSize?
    public var hiDPI: Bool?
    public var hz: Int?
    public var ownerPIDs: [Int32]
    public var physicalOff: [DisplayID]

    public init(
        state: SessionState,
        client: String? = nil,
        displayID: DisplayID? = nil,
        uuid: String? = nil,
        looksLike: ScreenSize? = nil,
        pixels: ScreenSize? = nil,
        hiDPI: Bool? = nil,
        hz: Int? = nil,
        ownerPIDs: [Int32] = [],
        physicalOff: [DisplayID] = []
    ) {
        self.state = state
        self.client = client
        self.displayID = displayID
        self.uuid = uuid
        self.looksLike = looksLike
        self.pixels = pixels
        self.hiDPI = hiDPI
        self.hz = hz
        self.ownerPIDs = ownerPIDs
        self.physicalOff = physicalOff
    }

    /// The one line `session start`, `resize` and `status` print. `state=idle` with no session.
    /// Otherwise a field that isn't known yet is left out, and `off=` is always there.
    public var statusLine: String {
        guard state != .idle else { return "state=idle" }
        var fields = ["state=\(state.rawValue)"]
        if let client { fields.append("client=\(client)") }
        if let displayID { fields.append("displayID=\(displayID)") }
        if let uuid { fields.append("UUID=\(uuid)") }
        if let looksLike { fields.append("lookslike=\(looksLike)") }
        if let pixels { fields.append("pixels=\(pixels)") }
        if let hz { fields.append("hz=\(hz)") }
        fields.append("off=" + physicalOff.map(String.init).joined(separator: ","))
        return fields.joined(separator: " ")
    }

    /// The status object of API version 1, which every session command's `--json` carries. With no
    /// session it's only the state and the version. Otherwise every key is present, null if unknown.
    public var asJSON: JSONValue {
        let version = JSONValue.number(Double(SessionAPI.version))
        guard state != .idle else {
            return .object(["state": .string(state.rawValue), "apiVersion": version])
        }
        func size(_ value: ScreenSize?) -> JSONValue {
            guard let value else { return .null }
            return .object(["w": .number(Double(value.w)), "h": .number(Double(value.h))])
        }
        func number(_ value: (some BinaryInteger)?) -> JSONValue {
            guard let value else { return .null }
            return .number(Double(value))
        }
        return .object([
            "apiVersion": version,
            "state": .string(state.rawValue),
            "client": client.map(JSONValue.string) ?? .null,
            "displayID": number(displayID),
            "displayUUID": uuid.map(JSONValue.string) ?? .null,
            "looksLike": size(looksLike),
            "pixels": size(pixels),
            "hiDPI": hiDPI.map(JSONValue.bool) ?? .null,
            "hz": number(hz),
            "ownerPIDs": .array(ownerPIDs.map { .number(Double($0)) }),
            "physicalOff": .array(physicalOff.map { .number(Double($0)) }),
        ])
    }
}

public enum SessionLimits {
    /// A session's looks-like width and height. A client's own size is checked against these too.
    public static let widths = 640...3840
    public static let heights = 360...2400
    private static let refreshRates = 24...240

    /// Returns why the size or refresh rate is refused, or nil if it's allowed.
    public static func validate(looksLike: ScreenSize, hz: Int) -> String? {
        if !widths.contains(looksLike.w) {
            return "lookslike width must be \(widths.lowerBound) to \(widths.upperBound)"
        }
        if !heights.contains(looksLike.h) {
            return "lookslike height must be \(heights.lowerBound) to \(heights.upperBound)"
        }
        if !refreshRates.contains(hz) {
            return "hz must be \(refreshRates.lowerBound) to \(refreshRates.upperBound)"
        }
        return nil
    }
}
