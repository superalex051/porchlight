import ADModel

/// What a virtual screen should be. The numbers are the spec's "Virtual screens" section.
public struct VirtualScreenSpec: Sendable, Equatable {
    public var name: String
    public var serial: UInt32
    public var looksLike: ScreenSize
    public var hiDPI: Bool
    public var hz: Int

    public init(name: String, serial: UInt32, looksLike: ScreenSize, hiDPI: Bool, hz: Int) {
        self.name = name
        self.serial = serial
        self.looksLike = looksLike
        self.hiDPI = hiDPI
        self.hz = hz
    }

    /// A client keeps its serial, so it keeps its UUID, and macOS remembers where its screen goes.
    public static func forClient(_ client: String, looksLike: ScreenSize, hiDPI: Bool, hz: Int) -> VirtualScreenSpec {
        VirtualScreenSpec(
            name: "Porch Light (\(client))",
            serial: serial(forClient: client),
            looksLike: looksLike,
            hiDPI: hiDPI,
            hz: hz
        )
    }

    /// Both max sizes double the points whatever `hiDPI` is, so a 1x screen can turn HiDPI in place.
    public var maxPixelsWide: Int { max(2 * looksLike.w, 4032) }
    public var maxPixelsHigh: Int { max(2 * looksLike.h, 2520) }

    public var sizeMM: (w: Double, h: Double) {
        (w: 302, h: 302 * Double(looksLike.h) / Double(looksLike.w))
    }

    public var expectedMode: DisplayMode {
        let scale = hiDPI ? 2 : 1
        return DisplayMode(
            pointsWide: looksLike.w,
            pointsHigh: looksLike.h,
            pixelsWide: scale * looksLike.w,
            pixelsHigh: scale * looksLike.h,
            refreshHz: Double(hz)
        )
    }

    /// What the screen offers macOS: the expected mode alone, at the asked rate, 120 Hz included. With a
    /// second rate listed, an in-place change could leave macOS at the old one until the settle check
    /// selects the new mode.
    public var declaredModes: [DisplayMode] {
        [expectedMode]
    }

    /// FNV-1a, 32 bits, over the UTF-8 bytes. Never 0.
    private static func serial(forClient client: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in client.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return hash == 0 ? 1 : hash
    }
}

/// A virtual screen that exists. `displayID` changes with every recreate, and `uuid` doesn't as long
/// as the serial stays the same, so a caller must take both from the latest value it was given.
public struct ActiveVirtualScreen: Sendable, Equatable {
    public var displayID: DisplayID
    public var uuid: String
    public var spec: VirtualScreenSpec

    public init(displayID: DisplayID, uuid: String, spec: VirtualScreenSpec) {
        self.displayID = displayID
        self.uuid = uuid
        self.spec = spec
    }
}
