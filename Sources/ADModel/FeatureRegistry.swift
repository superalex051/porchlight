public enum OutputStyle: Sendable {
    case onOff, trueFalse, value
}

public struct Feature: Sendable {
    public let key: String
    public let aliases: [String]
    public let style: OutputStyle

    init(_ key: String, aliases: [String] = [], style: OutputStyle = .value) {
        self.key = key
        self.aliases = aliases
        self.style = style
    }
}

public enum FeatureRegistry {
    public static let all: [Feature] = [
        // Features
        Feature("connected", style: .onOff),
        Feature("main", style: .trueFalse),
        Feature("placement"),
        Feature("resolution"),
        Feature("refreshRate"),
        // Also the `session` parameter `-hidpi`. Names are case-insensitive, so the two
        // spellings can't be separate keys: `-hidpi=off` canonicalizes to `hiDPI`.
        Feature("hiDPI", style: .onOff),
        Feature("identifiers"),
        Feature("create"),
        Feature("discard"),
        Feature("virtualScreenName"),
        Feature("useResolutionList", style: .onOff),
        Feature("resolutionList"),
        Feature("virtualScreenHiDPI", style: .onOff),

        // Selectors
        Feature("UUID"),
        Feature("displayID"),
        Feature("name"),
        Feature("nameLike", aliases: ["n"]),
        Feature("originalName"),
        Feature("tagID"),
        Feature("type", aliases: ["deviceType"]),
        Feature("displayWithMainStatus"),

        // Extension keys
        Feature("launchAtLogin", style: .onOff),
        Feature("spiReport"),
        Feature("pinRefreshRate"),

        // Session parameters
        Feature("client"),
        Feature("lookslike"),
        Feature("hz"),
        Feature("preset"),
        Feature("ownerpid"),
        Feature("keepon"),
        Feature("force"),
        Feature("reason"),

        // Dry run
        Feature("dryRunPlan"),
    ]

    /// The registered spelling of a key or alias, in any letter case, or nil if it's unknown.
    public static func canonical(_ name: String) -> String? {
        canonicalByLowercasedName[name.lowercased()]
    }

    private static let canonicalByLowercasedName: [String: String] = {
        var table: [String: String] = [:]
        for feature in all {
            for name in [feature.key] + feature.aliases {
                table[name.lowercased()] = feature.key
            }
        }
        return table
    }()
}
