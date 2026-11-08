import ADModel
import Observation

/// The presets window's state, as a model that can be tested without AppKit. It edits a copy of the
/// saved list and writes nothing until `save`. Each preset remembers the name it was saved under, so a
/// rename can be told from a delete and an add, and the clients that name it follow it.
@Observable
public final class PresetsEditorModel {
    nonisolated public struct Row: Identifiable, Equatable, Sendable {
        public let id: Int
        /// The name in the file, or nil for a preset added since the last save.
        public let savedName: String?
        public var name: String
        /// `<width>x<height>`, as `-lookslike` takes it.
        public var lookslike: String
        public var hidpi: Bool
        /// Text, so a half-typed rate stays as typed and the field never waits for a commit.
        public var hz: String
    }

    /// Asked before deleting a preset a client uses.
    nonisolated public struct DeleteQuestion: Equatable, Sendable {
        public let rowID: Row.ID
        public let title: String
        public let message: String
    }

    enum Outcome: Equatable {
        /// With what the save had to say, each a whole sentence.
        case saved(notes: [String])
        case failed(String)
    }

    /// What a new preset starts as: the MacBook's usual size.
    private static let newName = "New Preset"
    private static let newLooksLike = "1728x1080"
    private static let newRate = "60"

    public private(set) var rows: [Row] = []
    public var selection: Row.ID?
    public private(set) var question: DeleteQuestion?
    let library: any PresetLibrary

    /// The rows as last read, to tell whether anything changed.
    private var savedRows: [Row] = []
    private var clients: [ClientRule] = []
    private var fileProblem: String?
    private var clientsProblem: String?
    private var outcome: Outcome?
    private var nextID = 0

    public init(library: any PresetLibrary) {
        self.library = library
        reload()
    }

    // MARK: Reading

    /// Lines for the top of the window, about a file that can't be used.
    public var notices: [String] {
        var lines: [String] = []
        if let fileProblem {
            lines.append("\(fileProblem), so these are the built-in presets. Saving keeps a copy of the file and replaces it.")
        }
        if let clientsProblem {
            lines.append("\(clientsProblem), so a rename here won't change its clients.")
        }
        return lines
    }

    /// The line at the bottom: how the last save went, or that there's something to save.
    public var footnote: String? {
        switch outcome {
        case .saved(let notes): return (["Saved."] + notes).joined(separator: " ")
        case .failed(let reason): return Self.fullStop("Not saved: \(reason)")
        case nil: return hasChanges ? "Unsaved changes" : nil
        }
    }

    /// A failed save, or one with something to say.
    public var footnoteNeedsAttention: Bool {
        switch outcome {
        case .failed: true
        case .saved(let notes): !notes.isEmpty
        case nil: false
        }
    }

    public var hasChanges: Bool {
        rows != savedRows
    }

    /// A file that can't be used can be saved over as it is, with the built-ins shown.
    public var canSave: Bool {
        (hasChanges || fileProblem != nil) && rows.allSatisfy { problem(of: $0) == nil }
    }

    /// Why the preset can't be saved, as a sentence, or nil.
    public func problem(of id: Row.ID) -> String? {
        row(id).flatMap(problem(of:)).map(Self.sentence)
    }

    /// What the screen is in pixels, or nil if the size isn't one.
    public func pixels(of id: Row.ID) -> String? {
        guard let row = row(id), let size = ScreenSize(parsing: Self.trimmed(row.lookslike)) else { return nil }
        let scale = row.hidpi ? 2 : 1
        let (w, wideOverflow) = size.w.multipliedReportingOverflow(by: scale)
        let (h, tallOverflow) = size.h.multipliedReportingOverflow(by: scale)
        guard !wideOverflow, !tallOverflow else { return nil }
        return ScreenSize(w: w, h: h).description
    }

    /// The clients that will name this preset once the list is saved: the ones that name it now, which
    /// follow a rename, and the ones that name a preset that isn't saved by its new name.
    public func clientNames(of id: Row.ID) -> [String] {
        guard let row = row(id) else { return [] }
        let name = PresetRules.cleanName(row.name).lowercased()
        return clients.filter { presetName(after: $0).lowercased() == name }.map(\.name)
    }

    // MARK: Editing

    /// For the fields. A row's id and saved name can't change.
    public func update(_ id: Row.ID, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        outcome = nil
    }

    /// After the selected preset, or at the end, and selected.
    public func add() {
        var name = Self.newName
        var number = 2
        while rows.contains(where: { PresetRules.cleanName($0.name).lowercased() == name.lowercased() }) {
            name = "\(Self.newName) \(number)"
            number += 1
        }
        let row = makeRow(savedName: nil, name: name, lookslike: Self.newLooksLike, hidpi: true, hz: Self.newRate)
        let index = selectedIndex.map { $0 + 1 } ?? rows.endIndex
        rows.insert(row, at: index)
        selection = row.id
        outcome = nil
    }

    public var canDelete: Bool { selectedIndex != nil }
    public var canMoveUp: Bool { selectedIndex.map { $0 > 0 } ?? false }
    public var canMoveDown: Bool { selectedIndex.map { $0 < rows.count - 1 } ?? false }

    /// At once, unless a client uses it: then `question` asks first. The clients are read again, so one
    /// set with the CLI while the window is open counts.
    public func deleteSelected() {
        guard let index = selectedIndex else { return }
        readClients()
        let row = rows[index]
        let users = clientNames(of: row.id)
        guard !users.isEmpty else {
            delete(at: index)
            return
        }
        let name = PresetRules.cleanName(row.name).isEmpty ? (row.savedName ?? Self.newName) : PresetRules.cleanName(row.name)
        let who = users.count == 1 ? "Client \(users[0]) uses it" : "Clients \(Self.list(users)) use it"
        let sessions = users.count == 1 ? users[0] : "them"
        question = DeleteQuestion(
            rowID: row.id,
            title: "Delete \(name)?",
            message: "\(who). Once it's deleted and saved, sessions from \(sessions) get the default size."
        )
    }

    /// Takes the question it answers, because an alert can clear `question` as it closes, before or
    /// after its button's action runs.
    public func confirmDelete(_ answered: DeleteQuestion) {
        question = nil
        if let index = rows.firstIndex(where: { $0.id == answered.rowID }) { delete(at: index) }
    }

    public func cancelDelete() {
        question = nil
    }

    public func moveSelectedUp() {
        guard canMoveUp, let index = selectedIndex else { return }
        rows.swapAt(index, index - 1)
        outcome = nil
    }

    public func moveSelectedDown() {
        guard canMoveDown, let index = selectedIndex else { return }
        rows.swapAt(index, index + 1)
        outcome = nil
    }

    // MARK: Saving and reading again

    /// Writes the list, with each changed name as a rename, then reads it back. Nothing happens while a
    /// preset breaks a rule.
    public func save() {
        guard canSave else { return }
        let presets = rows.compactMap(preset(from:))
        let renames = rows.compactMap { row -> PresetRename? in
            let name = PresetRules.cleanName(row.name)
            guard let savedName = row.savedName, savedName != name else { return nil }
            return PresetRename(from: savedName, to: name)
        }
        do {
            let notes = try library.save(presets, renaming: renames)
            reload()
            outcome = .saved(notes: notes)
        } catch {
            outcome = .failed(error.reason)
        }
    }

    /// Back to what the files say now.
    public func revert() {
        reload()
    }

    /// For opening the window again: unsaved changes stay, and otherwise the files are read again, so a
    /// change made with the CLI meanwhile shows. The clients are read again either way.
    public func reloadIfUnchanged() {
        if hasChanges { readClients() } else { reload() }
    }

    /// Keeps the selection on the preset it was on, by name, or else the first.
    private func reload() {
        let selectedName = selectedIndex.map { PresetRules.cleanName(rows[$0].name).lowercased() }
        let saved = library.savedPresets()
        fileProblem = saved.problem
        rows = saved.presets.map { preset in
            makeRow(savedName: preset.name, name: preset.name, lookslike: preset.lookslike, hidpi: preset.hidpi, hz: String(preset.hz))
        }
        savedRows = rows
        readClients()
        question = nil
        outcome = nil
        selection = rows.first { PresetRules.cleanName($0.name).lowercased() == selectedName }?.id ?? rows.first?.id
    }

    // MARK: Helpers

    private var selectedIndex: Int? {
        selection.flatMap { id in rows.firstIndex { $0.id == id } }
    }

    private func row(_ id: Row.ID) -> Row? {
        rows.first { $0.id == id }
    }

    private func makeRow(savedName: String?, name: String, lookslike: String, hidpi: Bool, hz: String) -> Row {
        nextID += 1
        return Row(id: nextID, savedName: savedName, name: name, lookslike: lookslike, hidpi: hidpi, hz: hz)
    }

    private func readClients() {
        let saved = library.savedClients()
        clients = saved.clients
        clientsProblem = saved.problem
    }

    /// The next one takes the selection, or the one before if it was the last.
    private func delete(at index: Int) {
        rows.remove(at: index)
        selection = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
        outcome = nil
    }

    /// The preset a client will name after a save: a renamed one's new name. A client of a deleted
    /// preset keeps its name, as the save leaves it.
    private func presetName(after client: ClientRule) -> String {
        let wanted = client.preset.lowercased()
        guard let row = rows.first(where: { $0.savedName?.lowercased() == wanted }) else { return client.preset }
        return PresetRules.cleanName(row.name)
    }

    /// The rules in the order the fields are, in the commands' words.
    private func problem(of row: Row) -> String? {
        if let reason = PresetRules.nameProblem(row.name) { return reason }
        let name = PresetRules.cleanName(row.name).lowercased()
        if let other = rows.first(where: { $0.id != row.id && PresetRules.cleanName($0.name).lowercased() == name }) {
            return "another preset is called \(PresetRules.cleanName(other.name))"
        }
        guard let preset = preset(from: row) else { return "hz must be a whole number" }
        return PresetRules.problem(with: preset)
    }

    /// As the file will have it, or nil if the rate isn't a whole number.
    private func preset(from row: Row) -> Preset? {
        guard let hz = Self.wholeNumber(row.hz) else { return nil }
        return Preset(name: PresetRules.cleanName(row.name), lookslike: Self.trimmed(row.lookslike), hidpi: row.hidpi, hz: hz)
    }

    /// Plain digits, as `-hz` takes them.
    private static func wholeNumber(_ text: String) -> Int? {
        let digits = trimmed(text)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(digits)
    }

    private static func trimmed(_ text: String) -> String {
        PresetRules.cleanName(text)
    }

    /// `A`, `A and B`, `A, B and C`.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A reason in the commands' style, which starts in lower case with no full stop, as a sentence.
    private static func sentence(_ reason: String) -> String {
        StatusNotice.sentence(reason) ?? reason
    }

    private static func fullStop(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}
