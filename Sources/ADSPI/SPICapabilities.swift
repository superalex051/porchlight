/// Which private display features this Mac's macOS still provides.
public struct SPICapabilities: Sendable, Codable {
    public var displayList, infoDictionary, enableDisable, virtualDisplay: Bool
    /// The symbols, classes and `Class.selector` methods that didn't resolve.
    public var missing: [String]

    public init(
        displayList: Bool,
        infoDictionary: Bool,
        enableDisable: Bool,
        virtualDisplay: Bool,
        missing: [String]
    ) {
        self.displayList = displayList
        self.infoDictionary = infoDictionary
        self.enableDisable = enableDisable
        self.virtualDisplay = virtualDisplay
        self.missing = missing
    }

    /// One readable line. Computed, so it always matches the fields and isn't encoded.
    public var report: String {
        let flags = [
            ("displayList", displayList),
            ("infoDictionary", infoDictionary),
            ("enableDisable", enableDisable),
            ("virtualDisplay", virtualDisplay),
        ]
        let unavailable = flags.filter { !$0.1 }.map(\.0)
        var parts: [String] = []
        if !unavailable.isEmpty {
            parts.append("Unavailable: \(unavailable.joined(separator: ", ")).")
        }
        if !missing.isEmpty {
            parts.append("Missing private display symbols: \(missing.joined(separator: ", ")).")
        }
        return parts.isEmpty ? "All private display symbols resolved." : parts.joined(separator: " ")
    }

    /// Checks every private symbol, class and method the wrappers use. It resolves names only:
    /// it instantiates nothing, runs no class initializer and changes no display state.
    ///
    /// Verified on macOS 27.0.1. Failure: a feature that doesn't resolve reads false and its
    /// names go in `missing`. This never crashes on a missing symbol.
    public static func probe() -> SPICapabilities {
        let displayList = SkyLight.missingSymbols
        let infoDictionary = CoreDisplayInfo.missingSymbols
        let enableDisable = DisplayEnable.missingSymbols
        let virtualDisplay = VirtualDisplayHandle.missingSymbols
        return SPICapabilities(
            displayList: displayList.isEmpty,
            infoDictionary: infoDictionary.isEmpty,
            enableDisable: enableDisable.isEmpty,
            virtualDisplay: virtualDisplay.isEmpty,
            missing: displayList + infoDictionary + enableDisable + virtualDisplay
        )
    }
}
