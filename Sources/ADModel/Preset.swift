/// A saved size. The stored members are exactly the keys of an entry in `presets.json`.
public struct Preset: Codable, Sendable, Equatable {
    public var name: String
    public var lookslike: String
    public var hidpi: Bool
    public var hz: Int

    public init(name: String, lookslike: String, hidpi: Bool, hz: Int) {
        self.name = name
        self.lookslike = lookslike
        self.hidpi = hidpi
        self.hz = hz
    }

    /// Nil if `lookslike` isn't a valid size, which a hand-edited file can do.
    public var pixels: ScreenSize? {
        guard let size = ScreenSize(parsing: lookslike) else { return nil }
        return hidpi ? ScreenSize(w: size.w * 2, h: size.h * 2) : size
    }

    /// One line of `session presets`.
    public var line: String {
        "\(name): lookslike=\(lookslike) pixels=\(pixels?.description ?? "?") hz=\(hz)"
    }
}

public enum Presets {
    /// For the MacBook Pro 14"'s 120 Hz screen. Added to the built-ins after the first builds, so the
    /// preset store also adds it, once, to a `presets.json` written before it.
    public static let macBook120Hz = Preset(name: "MacBook 14 120 Hz", lookslike: "1728x1080", hidpi: true, hz: 120)

    public static let builtIn: [Preset] = [
        Preset(name: "MacBook 14", lookslike: "1728x1080", hidpi: true, hz: 60),
        macBook120Hz,
        Preset(name: "MacBook 14 Sharpest", lookslike: "1512x945", hidpi: true, hz: 60),
        Preset(name: "MacBook 14 More Room", lookslike: "1920x1200", hidpi: true, hz: 60),
        Preset(name: "4K Screen", lookslike: "1920x1080", hidpi: true, hz: 60),
        Preset(name: "1440p Screen", lookslike: "2560x1440", hidpi: false, hz: 60),
        Preset(name: "1080p Screen", lookslike: "1920x1080", hidpi: false, hz: 60),
    ]
}
