public struct DisplayMode: Codable, Sendable, Hashable {
    public var pointsWide: Int
    public var pointsHigh: Int
    public var pixelsWide: Int
    public var pixelsHigh: Int
    public var refreshHz: Double

    public init(pointsWide: Int, pointsHigh: Int, pixelsWide: Int, pixelsHigh: Int, refreshHz: Double) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.refreshHz = refreshHz
    }

    /// Derived, so a mode can never claim a scale its pixels don't have.
    public var isHiDPI: Bool { pixelsWide > pointsWide }

    /// Compares points, pixels and refresh rate rounded to the nearest whole number.
    public func matches(_ other: DisplayMode) -> Bool {
        pointsWide == other.pointsWide
            && pointsHigh == other.pointsHigh
            && pixelsWide == other.pixelsWide
            && pixelsHigh == other.pixelsHigh
            && refreshHz.rounded() == other.refreshHz.rounded()
    }
}

public enum DisplayKind: String, Codable, Sendable {
    case physical, ownVirtual, parsecVirtual, osFallback, otherVirtual, emptyPipe
}

public struct DisplayIdentity: Codable, Sendable, Hashable {
    public var uuid: String?
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var alphanumericSerial: String?
    public var productName: String?
    public var registryLocation: String?
    public var weekOfManufacture: Int?
    public var yearOfManufacture: Int?

    public init(
        uuid: String? = nil,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        alphanumericSerial: String? = nil,
        productName: String? = nil,
        registryLocation: String? = nil,
        weekOfManufacture: Int? = nil,
        yearOfManufacture: Int? = nil
    ) {
        self.uuid = uuid
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.alphanumericSerial = alphanumericSerial
        self.productName = productName
        self.registryLocation = registryLocation
        self.weekOfManufacture = weekOfManufacture
        self.yearOfManufacture = yearOfManufacture
    }
}

public struct DisplaySnapshot: Codable, Sendable, Hashable {
    public var id: DisplayID
    public var identity: DisplayIdentity
    public var kind: DisplayKind
    public var isOnline: Bool
    public var isActive: Bool
    public var isMain: Bool
    public var isAsleep: Bool
    public var origin: DisplayOrigin
    public var mode: DisplayMode?

    public init(
        id: DisplayID,
        identity: DisplayIdentity,
        kind: DisplayKind,
        isOnline: Bool,
        isActive: Bool,
        isMain: Bool,
        isAsleep: Bool,
        origin: DisplayOrigin,
        mode: DisplayMode? = nil
    ) {
        self.id = id
        self.identity = identity
        self.kind = kind
        self.isOnline = isOnline
        self.isActive = isActive
        self.isMain = isMain
        self.isAsleep = isAsleep
        self.origin = origin
        self.mode = mode
    }
}
