import CoreGraphics
import Foundation

public enum CoreDisplayInfo {
    private typealias CreateInfoDictionary = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

    private static let infoSymbol = "CoreDisplay_DisplayCreateInfoDictionary"
    private static let createInfoDictionary: CreateInfoDictionary? = SymbolResolver
        .symbol(
            infoSymbol,
            in: [
                "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
                "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
            ]
        )
        .map { unsafeBitCast($0, to: CreateInfoDictionary.self) }

    static var missingSymbols: [String] {
        createInfoDictionary == nil ? [infoSymbol] : []
    }

    /// The info dictionary for a display ID. Read only.
    ///
    /// Signature: `CoreDisplay_DisplayCreateInfoDictionary`, one display ID in and an owned
    /// `CFDictionary` out, as called in the 2026-11-06 spike. Verified on macOS 27.0.1.
    ///
    /// Failure: returns an empty dictionary if the symbol is missing or the call returns null.
    public static func info(for id: UInt32) -> [String: Any] {
        guard let createInfoDictionary else { return [:] }
        // The spec's rule for a new process: this comes first, because some display calls abort
        // until CoreGraphics has initialized.
        _ = CGMainDisplayID()
        return (createInfoDictionary(id)?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// The framebuffer path, from the `IODisplayLocation` key seen in the 2026-11-06 spike on
    /// macOS 27.0.1. Failure: nil if the key is absent, as it is on virtual screens.
    public static func registryLocation(_ info: [String: Any]) -> String? {
        info["IODisplayLocation"] as? String
    }

    /// Whether this is a virtual device, from the `kCGDisplayIsVirtualDevice` key seen in the
    /// 2026-11-06 spike on macOS 27.0.1. Failure: false if the key is absent.
    public static func isVirtual(_ info: [String: Any]) -> Bool {
        (info["kCGDisplayIsVirtualDevice"] as? Bool) ?? false
    }

    /// The product name, from the `DisplayProductName` key seen in the 2026-11-06 spike on
    /// macOS 27.0.1, a dictionary of locale to name. Prefers `en_US`, then the first locale in
    /// sort order, so the answer doesn't change between runs. Failure: nil if the key is absent
    /// or the name is empty, as it is on empty pipes.
    public static func productName(_ info: [String: Any]) -> String? {
        guard let names = info["DisplayProductName"] as? [String: String] else { return nil }
        let name = names["en_US"] ?? names.min { $0.key < $1.key }?.value
        return name?.isEmpty == false ? name : nil
    }
}
