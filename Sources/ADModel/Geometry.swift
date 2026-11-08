public typealias DisplayID = UInt32

/// A width and height, in points or pixels depending on where it's used.
public struct ScreenSize: Codable, Sendable, Hashable, CustomStringConvertible {
    public var w: Int
    public var h: Int

    public init(w: Int, h: Int) {
        self.w = w
        self.h = h
    }

    /// Parses the `1728x1080` form. Both sides must be positive and written in plain digits.
    public init?(parsing text: String) {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let w = Self.dimension(parts[0]),
            let h = Self.dimension(parts[1])
        else { return nil }
        self.init(w: w, h: h)
    }

    public var description: String { "\(w)x\(h)" }

    // `Int(_:)` alone would accept a leading `+`.
    private static func dimension(_ text: Substring) -> Int? {
        guard text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let value = Int(text),
            value > 0
        else { return nil }
        return value
    }
}

public struct DisplayOrigin: Codable, Sendable, Hashable {
    public var x: Int32
    public var y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}
