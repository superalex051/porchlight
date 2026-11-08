/// How much more room a phone's matched screen has than the phone's own pixels: a fraction of two whole
/// numbers, written `4/3`, from 1/1 (pixel for pixel) to 2/1. Saved in `clients.json` as that text.
public struct RoomFactor: Codable, Sendable, Equatable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    /// Pixel for pixel.
    public static let pixelForPixel = RoomFactor(checked: 1, 1)
    /// What a phone gets unless the user changes it: an iPhone 17 Pro's 2250x1206 becomes 3000x1608.
    public static let phoneDefault = RoomFactor(checked: 4, 3)
    /// Each of the two numbers, so a hand edit can't overflow the arithmetic.
    private static let parts = 1...99

    public var description: String { "\(numerator)/\(denominator)" }

    /// `4/3`, or a whole number such as `1`. Nil for anything else, or a factor under 1 or over 2.
    public init?(parsing text: String) {
        let fields = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count),
            let numerator = Self.part(fields[0]),
            let denominator = fields.count == 2 ? Self.part(fields[1]) : 1,
            numerator >= denominator, numerator <= 2 * denominator
        else { return nil }
        self.init(checked: numerator, denominator)
    }

    private init(checked numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The same factor, however it's written: 2/2 is 1/1.
    public var isPixelForPixel: Bool { numerator == denominator }

    /// `value` times the factor, rounded down to an even number.
    func scale(_ value: Int) -> Int {
        value * numerator / denominator / 2 * 2
    }

    private static func part(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            text.count <= 2, let value = Int(text), parts.contains(value)
        else { return nil }
        return value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let factor = RoomFactor(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a factor from 1/1 to 2/1: \(text)")
        }
        self = factor
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The session screen that matches the screen size a remote client reported, as `session start
/// -preset=auto` makes it for a device that has no preset by its address. Always HiDPI, at half the
/// pixels, so the stream matches the client's screen pixel for pixel, or with a phone's extra room.
///
/// 1. Landscape: the longer side is the width. A phone held upright reports its screen upright.
/// 2. A screen wider than 2:1 is a phone with a notch or a Dynamic Island. With `clearOfNotch`, its width
///    is trimmed to 28:15 of its height, rounded down to an even number. The client fits the stream inside
///    its screen, so the black bars at the sides land under the notch: 2622x1206 becomes 2250x1206.
/// 3. A phone's size is then multiplied by `phoneRoom`, each side rounded down to an even number:
///    2250x1206 at 4/3 becomes 3000x1608. The client scales it down to fit, with the same bars.
/// 4. HiDPI at half: 3000x1608 pixels is looks like 1500x804.
/// 5. It has to fit a session (looks like 640x360 to 3840x2400) and Parsec, which streams at most 2160
///    lines. Otherwise there's no match, and the reason says why.
public struct ClientScreen: Equatable, Sendable {
    /// Why no session can match the reported size, written to follow `which is `.
    public struct Unmatched: Error, Equatable {
        public var reason: String
    }

    /// Parsec streams the main display in real pixels, up to this many lines.
    public static let streamLines = 2160
    /// The width to height a phone is trimmed to, with `clearOfNotch`.
    static let notchClearWidth = 28
    static let notchClearHeight = 15

    /// What the client reported, as Parsec saved it.
    public let reported: ScreenSize
    /// The session's screen: HiDPI, so its pixels are twice this.
    public let looksLike: ScreenSize
    public var pixels: ScreenSize { ScreenSize(w: looksLike.w * 2, h: looksLike.h * 2) }
    /// True if the width was trimmed to clear the notch.
    public let isClearOfNotch: Bool
    /// The phone room applied, or nil for a screen that isn't a phone's or a factor of 1/1.
    public let room: RoomFactor?

    public init(reported: ScreenSize, clearOfNotch: Bool, phoneRoom: RoomFactor) throws(Unmatched) {
        self.reported = reported
        var w = max(reported.w, reported.h)
        var h = min(reported.w, reported.h)
        // Checked before any arithmetic, so a hand-edited size can't overflow it. Room never shrinks.
        guard h <= Self.streamLines else { throw Self.tooTall(nil) }
        let isPhone = w > 2 * h
        isClearOfNotch = isPhone && clearOfNotch
        if isClearOfNotch {
            w = h * Self.notchClearWidth / Self.notchClearHeight / 2 * 2
        }
        guard w <= SessionLimits.widths.upperBound * 2 else { throw Self.tooWide(nil) }
        room = isPhone && !phoneRoom.isPixelForPixel ? phoneRoom : nil
        if let room {
            w = room.scale(w)
            h = room.scale(h)
        }
        looksLike = ScreenSize(w: w / 2, h: h / 2)

        if looksLike.h * 2 > Self.streamLines { throw Self.tooTall(room) }
        if looksLike.w > SessionLimits.widths.upperBound { throw Self.tooWide(room) }
        // The height's upper limit, 2400, is above Parsec's 1080 looks like, so it can't be reached here.
        if looksLike.w < SessionLimits.widths.lowerBound || looksLike.h < SessionLimits.heights.lowerBound {
            throw Unmatched(
                reason: "smaller than \(SessionLimits.widths.lowerBound * 2)x\(SessionLimits.heights.lowerBound * 2)"
            )
        }
    }

    /// What the log adds after the size, such as `clear of the notch, phone room 4/3`. Nil for a screen
    /// matched pixel for pixel.
    public var note: String? {
        var parts: [String] = []
        if isClearOfNotch { parts.append("clear of the notch") }
        if let room { parts.append("phone room \(room)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func tooTall(_ room: RoomFactor?) -> Unmatched {
        Unmatched(reason: "\(withRoom(room))taller than the \(streamLines) lines Parsec streams")
    }

    private static func tooWide(_ room: RoomFactor?) -> Unmatched {
        Unmatched(reason: "\(withRoom(room))wider than \(SessionLimits.widths.upperBound * 2)")
    }

    private static func withRoom(_ room: RoomFactor?) -> String {
        room.map { "with phone room \($0), " } ?? ""
    }
}
