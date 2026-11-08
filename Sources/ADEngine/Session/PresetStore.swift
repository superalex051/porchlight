import ADFoundation
import ADModel
import Foundation

/// `presets.json`, which the user can edit by hand or in the presets window. It's read at each call, so an
/// edit applies without a restart. A missing file gets the defaults. A file that can't be read or isn't
/// valid is logged and left alone, and the built-in list is used instead.
///
/// `presets-version`, beside it, says which built-in additions the file has had. A valid file from
/// before version 2 gets `MacBook 14 120 Hz` once, right after `MacBook 14`, and keeps every other entry
/// as it was. After that the marker says 2, so a preset the user deletes stays deleted.
nonisolated public final class PresetStore: Sendable {
    /// 2 added `MacBook 14 120 Hz`. A file with no marker is version 1.
    static let currentVersion = 2

    private let url: URL
    private let versionURL: URL
    private let log: @Sendable (String) -> Void

    public init(url: URL, log: @escaping @Sendable (String) -> Void) {
        self.url = url
        versionURL = url.deletingLastPathComponent().appending(component: "presets-version", directoryHint: .notDirectory)
        self.log = log
    }

    public func presets() -> [Preset] {
        read().presets.filter(isAllowed)
    }

    /// What the presets window shows: every entry, the ones `presets()` skips included, so a save never
    /// drops one unseen. A file that can't be used gives the built-in list, which is what the commands
    /// use then, and why.
    public func editable() -> SavedPresets {
        read()
    }

    /// Replaces the file with this list, as the presets window saves it, then sets the marker, so the
    /// upgrade can't add back a preset deleted there. A list the commands couldn't use all of is refused.
    ///
    /// A file that can't be read or isn't valid is a hand edit with a typo, so a copy is kept beside it
    /// first, named as the other stores name theirs. Without the copy, it isn't replaced. Returns what
    /// the window should say besides that it saved, each a whole sentence.
    public func save(_ presets: [Preset]) throws(PresetSaveFailure) -> [String] {
        if let reason = PresetRules.problem(with: presets) {
            throw PresetSaveFailure(reason: reason)
        }
        var notes: [String] = []
        if let kept = try keepBrokenFile() {
            notes.append("The old \(url.lastPathComponent) couldn't be used, so a copy is kept beside it as \(kept).")
        }
        do {
            try write(presets)
        } catch {
            throw PresetSaveFailure(reason: "can't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        if version() < Self.currentVersion, !writeVersion() {
            notes.append(
                "Couldn't write \(versionURL.lastPathComponent), so the next read may add \(Presets.macBook120Hz.name) back."
            )
        }
        return notes
    }

    /// The copy's name, or nil if the file is missing or valid. Entries the commands skip don't make it
    /// broken: the window showed them.
    private func keepBrokenFile() throws(PresetSaveFailure) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), (try? JSONDecoder().decode([Preset].self, from: data)) != nil {
            return nil
        }
        let kept = url.deletingLastPathComponent()
            .appending(component: "\(url.lastPathComponent).corrupt-\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try FileManager.default.copyItem(at: url, to: kept)
        } catch {
            throw PresetSaveFailure(
                reason: "\(url.lastPathComponent) couldn't be used and a copy of it couldn't be kept, so it wasn't replaced: "
                    + error.localizedDescription
            )
        }
        log("\(url.lastPathComponent) couldn't be used, so a copy is kept as \(kept.lastPathComponent) before it's replaced")
        return kept.lastPathComponent
    }

    /// The whole file after the upgrade, or the built-in list and why the file can't be used.
    private func read() -> SavedPresets {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            writeDefaults()
            return SavedPresets(presets: Presets.builtIn)
        } catch {
            log("\(url.lastPathComponent) can't be read, using the built-in sizes: \(error.localizedDescription)")
            return SavedPresets(presets: Presets.builtIn, problem: "\(url.lastPathComponent) can't be read")
        }

        guard let listed = try? JSONDecoder().decode([Preset].self, from: data) else {
            log("\(url.lastPathComponent) isn't valid, using the built-in sizes")
            return SavedPresets(presets: Presets.builtIn, problem: "\(url.lastPathComponent) isn't valid")
        }
        return SavedPresets(presets: upgraded(listed))
    }

    /// Names compare without regard to case.
    public func preset(named name: String) -> Preset? {
        let wanted = name.lowercased()
        return presets().first { $0.name.lowercased() == wanted }
    }

    /// Comes before anything reads `pixels`, which can overflow on an absurd hand-edited size.
    private func isAllowed(_ preset: Preset) -> Bool {
        guard let size = ScreenSize(parsing: preset.lookslike) else {
            log("Skipping preset \(preset.name): \(preset.lookslike) isn't a size")
            return false
        }
        if let reason = SessionLimits.validate(looksLike: size, hz: preset.hz) {
            log("Skipping preset \(preset.name): \(reason)")
            return false
        }
        return true
    }

    /// The whole file, entries the read skips included, with what it hasn't had yet. A file that already
    /// has a preset by that name, in any case, keeps it. If a write fails, this still returns the
    /// addition, and the next read tries again: the name check stops a second copy.
    private func upgraded(_ listed: [Preset]) -> [Preset] {
        guard version() < Self.currentVersion else { return listed }
        let added = Presets.macBook120Hz
        var presets = listed
        if !presets.contains(where: { $0.name.lowercased() == added.name.lowercased() }) {
            let macBook = presets.firstIndex { $0.name.lowercased() == "macbook 14" }
            presets.insert(added, at: macBook.map { $0 + 1 } ?? presets.endIndex)
            do {
                try write(presets)
            } catch {
                log("Can't add \(added.name) to \(url.lastPathComponent): \(error.localizedDescription)")
                return presets
            }
        }
        writeVersion()
        return presets
    }

    /// 1 with no marker, or one that isn't a number.
    private func version() -> Int {
        guard let text = try? String(contentsOf: versionURL, encoding: .utf8) else { return 1 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    private func writeDefaults() {
        do {
            try write(Presets.builtIn)
        } catch {
            log("Can't write the default sizes to \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        writeVersion()
    }

    private func write(_ presets: [Preset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFile.write(encoder.encode(presets), to: url)
    }

    /// False if it couldn't be written, which is logged.
    @discardableResult
    private func writeVersion() -> Bool {
        do {
            try AtomicFile.write(Data("\(Self.currentVersion)\n".utf8), to: versionURL)
            return true
        } catch {
            log("Can't write \(versionURL.lastPathComponent), so the next read checks again: \(error.localizedDescription)")
            return false
        }
    }
}
