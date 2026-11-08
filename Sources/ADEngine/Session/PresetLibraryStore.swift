import ADModel
import Foundation

/// What the presets window reads and saves through: the same `presets.json` and `clients.json` as the
/// commands. The window saves on the main actor, as the `clients` commands run, so a save and a command
/// can't interleave their reads and writes.
nonisolated public final class PresetLibraryStore: PresetLibrary, Sendable {
    private let presets: PresetStore
    private let clients: ClientStore
    private let log: @Sendable (String) -> Void

    public init(presets: PresetStore, clients: ClientStore, log: @escaping @Sendable (String) -> Void) {
        self.presets = presets
        self.clients = clients
        self.log = log
    }

    public func savedPresets() -> SavedPresets {
        presets.editable()
    }

    public func savedClients() -> SavedClients {
        do {
            return SavedClients(clients: try clients.read().clients)
        } catch {
            return SavedClients(clients: [], problem: error.reason)
        }
    }

    /// The presets first, so a list that isn't saved changes no client. A deleted preset isn't a rename:
    /// its clients keep its name, and `-preset=auto` gives them their own reported size or the default.
    /// `clients.json` is written only if a client changes, and never over a file that can't be read or
    /// isn't valid.
    public func save(_ list: [Preset], renaming renames: [PresetRename]) throws(PresetSaveFailure) -> [String] {
        var notes = try presets.save(list)
        log("Presets saved from the window: \(list.count) \(list.count == 1 ? "preset" : "presets")")
        guard !renames.isEmpty else { return notes }

        let mapping: ClientMapping
        do {
            mapping = try clients.read()
        } catch {
            notes.append("The clients still name the old presets, because \(error.reason).")
            return notes
        }
        let renamed = mapping.renamingPresets(renames)
        guard renamed != mapping else { return notes }
        do {
            try clients.write(renamed)
        } catch {
            let why = "The clients still name the old presets, because \(clients.url.lastPathComponent) can't be written: "
                + error.localizedDescription
            notes.append(why.hasSuffix(".") ? why : why + ".")
            return notes
        }
        for (before, after) in zip(mapping.clients, renamed.clients) where before.preset != after.preset {
            log("Client \(after.name) now uses \(after.preset), renamed from \(before.preset)")
        }
        return notes
    }
}
