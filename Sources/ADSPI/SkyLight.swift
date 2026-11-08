import CoreGraphics

public enum SkyLight {
    private typealias GetDisplayList = @convention(c) (
        UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?
    ) -> Int32

    private static let displayListSymbol = "SLSGetDisplayList"
    private static let getDisplayList: GetDisplayList? = SymbolResolver
        .symbol(displayListSymbol, in: ["/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"])
        .map { unsafeBitCast($0, to: GetDisplayList.self) }

    /// The spike's limit. The most IDs seen on this Mac so far is 6.
    private static let maxDisplays = 32

    static var missingSymbols: [String] {
        getDisplayList == nil ? [displayListSymbol] : []
    }

    /// Every display ID WindowServer knows about, including software-disabled displays and
    /// empty pipes, which the public online list leaves out. Read only.
    ///
    /// Signature: `SLSGetDisplayList`, the same shape as the public `CGGetOnlineDisplayList`,
    /// called the same way in the 2026-11-06 spike. Verified on macOS 27.0.1.
    ///
    /// Failure: returns nil if the symbol is missing or the call reports an error.
    public static func allDisplayIDs() -> [UInt32]? {
        guard let getDisplayList else { return nil }
        // The spec's rule for a new process: this comes first, because some display calls abort
        // until CoreGraphics has initialized.
        _ = CGMainDisplayID()
        var ids = [UInt32](repeating: 0, count: maxDisplays)
        var count: UInt32 = 0
        guard getDisplayList(UInt32(maxDisplays), &ids, &count) == 0 else { return nil }
        return Array(ids.prefix(Int(count)))
    }
}
