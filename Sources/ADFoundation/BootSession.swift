import Darwin

public enum BootSession {
    /// This boot's `kern.bootsessionuuid`, which changes at every boot.
    /// Empty only if the sysctl fails, which it has no known reason to do on a supported macOS.
    public static func current() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }

        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }

        return String(decoding: bytes.prefix(size).prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
