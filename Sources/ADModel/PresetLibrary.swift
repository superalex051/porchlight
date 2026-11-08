/// What makes a preset one Porch Light can use, for the presets window and the store that saves its
/// list. The size and rate limits are the session's own, as `-lookslike` and `-hz` have them. The
/// reasons are written like the commands' own, to follow `Failed. `: lower case, no full stop.
public enum PresetRules {
    /// `-preset=auto` asks Porch Light to choose, so a preset called this could never be picked.
    public static let reservedName = "auto"

    /// The name as it's saved, with spaces and line breaks at either end dropped.
    public static func cleanName(_ name: String) -> String {
        guard let first = name.firstIndex(where: { !$0.isWhitespace }),
            let last = name.lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return String(name[first...last])
    }

    /// Why the name can't be a preset's, or nil.
    public static func nameProblem(_ name: String) -> String? {
        let name = cleanName(name)
        if name.isEmpty { return "a preset needs a name" }
        if name.lowercased() == reservedName { return "the name \(reservedName) is kept for -preset=\(reservedName)" }
        return nil
    }

    /// Why this preset can't be saved, or nil. Two presets with one name are the list's problem.
    public static func problem(with preset: Preset) -> String? {
        if let reason = nameProblem(preset.name) { return reason }
        guard let size = ScreenSize(parsing: preset.lookslike) else {
            return "lookslike must be a size such as 1728x1080"
        }
        return SessionLimits.validate(looksLike: size, hz: preset.hz)
    }

    /// The first preset with a problem, or the first name used twice, compared without regard to case
    /// as `-preset=` compares them. Nil if the list can be saved, an empty one included.
    public static func problem(with presets: [Preset]) -> String? {
        var names = Set<String>()
        for preset in presets {
            if let reason = problem(with: preset) {
                return "\(preset.name): \(reason)"
            }
            let name = cleanName(preset.name)
            guard names.insert(name.lowercased()).inserted else {
                return "two presets are called \(name)"
            }
        }
        return nil
    }
}

/// A preset saved under one name and now under another. The clients that named it follow it.
public struct PresetRename: Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

extension ClientMapping {
    /// The clients with each renamed preset's new name. Names compare without regard to case. The
    /// renames apply all at once, so two presets can trade names and their clients trade with them.
    public func renamingPresets(_ renames: [PresetRename]) -> ClientMapping {
        // A hand-edited file can have two presets with one name, and `-preset=` takes the first.
        let newNames = Dictionary(renames.map { ($0.from.lowercased(), $0.to) }, uniquingKeysWith: { first, _ in first })
        var mapping = self
        for index in mapping.clients.indices {
            if let name = newNames[mapping.clients[index].preset.lowercased()] {
                mapping.clients[index].preset = name
            }
        }
        return mapping
    }
}

/// Every entry in `presets.json`, the ones the commands skip for breaking a rule included, or the
/// built-in list and why the file can't be used.
public struct SavedPresets: Equatable, Sendable {
    public var presets: [Preset]
    /// Nil if the file was read.
    public var problem: String?

    public init(presets: [Preset], problem: String? = nil) {
        self.presets = presets
        self.problem = problem
    }
}

/// The clients in `clients.json`, or none and why the file can't be used. No file means no clients.
public struct SavedClients: Equatable, Sendable {
    public var clients: [ClientRule]
    public var problem: String?

    public init(clients: [ClientRule], problem: String? = nil) {
        self.clients = clients
        self.problem = problem
    }
}

/// Why a list of presets wasn't saved, in the commands' style.
public struct PresetSaveFailure: Error, Equatable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// What the presets window reads and saves through: `presets.json`, and the clients in `clients.json`
/// that name its presets. The engine's is `PresetLibraryStore`.
public protocol PresetLibrary {
    func savedPresets() -> SavedPresets
    func savedClients() -> SavedClients
    /// Replaces the list, then makes each client of a renamed preset follow it. Throws if the list
    /// wasn't saved. Returns what there is to say besides that it saved, each a whole sentence: a broken
    /// file kept aside, a version marker that couldn't be written, clients that couldn't follow.
    func save(_ presets: [Preset], renaming renames: [PresetRename]) throws(PresetSaveFailure) -> [String]
}
