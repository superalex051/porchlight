internal import CPrivateSPI
import CoreGraphics

public enum DisplayEnable {
    private static let enableSymbol = "CGSConfigureDisplayEnabled"

    static var missingSymbols: [String] {
        SymbolResolver.isLoaded(enableSymbol) ? [] : [enableSymbol]
    }

    /// Queues turning a monitor on or off in an open display configuration. The change happens
    /// when the configuration completes. There is no mutation guard here, so the call site must
    /// check first. `Scripts/lint.sh` confines callers to `LiveDisplayBackend`.
    ///
    /// Signature: `CGSConfigureDisplayEnabled`, as credited to displayplacer (MIT) in
    /// `THIRD_PARTY_NOTICES.md` and used in the 2026-11-06 spike. Verified on macOS 27.0.1.
    ///
    /// Failure: returns `.notImplemented` without calling anything if the symbol is missing,
    /// otherwise whatever error the call reports.
    public static func configure(_ config: CGDisplayConfigRef, _ id: UInt32, enabled: Bool) -> CGError {
        guard missingSymbols.isEmpty else { return .notImplemented }
        return CGSConfigureDisplayEnabled(config, id, enabled)
    }
}
