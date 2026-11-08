import ADModel
import Testing

@testable import ADUI

/// The files in memory. A save replaces the list, as the real one does, and is recorded.
private final class FakeLibrary: PresetLibrary {
    var presets: SavedPresets
    var clients: SavedClients
    var saves: [(presets: [Preset], renames: [PresetRename])] = []
    var failure: PresetSaveFailure?
    var notes: [String] = []

    init(_ presets: [Preset] = Presets.builtIn, problem: String? = nil, clients: [ClientRule] = [], clientsProblem: String? = nil) {
        self.presets = SavedPresets(presets: presets, problem: problem)
        self.clients = SavedClients(clients: clients, problem: clientsProblem)
    }

    func savedPresets() -> SavedPresets { presets }

    func savedClients() -> SavedClients { clients }

    func save(_ list: [Preset], renaming renames: [PresetRename]) throws(PresetSaveFailure) -> [String] {
        if let failure { throw failure }
        saves.append((list, renames))
        presets = SavedPresets(presets: list)
        return notes
    }
}

private let macBookClient = ClientRule(name: "MacBook", address: "192.168.0.232", preset: "MacBook 14 120 Hz")
private let iPadClient = ClientRule(name: "iPad", address: "192.168.0.10", preset: "macbook 14 120 hz")

@MainActor
@Suite struct PresetsEditorModelTests {
    private func select(_ name: String, in model: PresetsEditorModel) throws {
        model.selection = try #require(model.rows.first { $0.name == name }).id
    }

    private func names(_ model: PresetsEditorModel) -> [String] {
        model.rows.map(\.name)
    }

    private func selectedName(_ model: PresetsEditorModel) -> String? {
        model.rows.first { $0.id == model.selection }?.name
    }

    // MARK: Reading

    @Test func showsTheSavedListInMenuOrder() {
        let model = PresetsEditorModel(library: FakeLibrary())

        #expect(names(model) == Presets.builtIn.map(\.name))
        #expect(selectedName(model) == "MacBook 14")
        #expect(model.rows[1].lookslike == "1728x1080")
        #expect(model.rows[1].hidpi)
        #expect(model.rows[1].hz == "120")
        #expect(!model.hasChanges)
        #expect(!model.canSave)
        #expect(model.footnote == nil)
        #expect(model.notices.isEmpty)
    }

    /// An entry the commands skip is shown with its reason, and has to be fixed before a save.
    @Test func aBrokenEntryFromTheFileShowsWhy() throws {
        let narrow = Preset(name: "Too narrow", lookslike: "100x800", hidpi: true, hz: 60)
        let model = PresetsEditorModel(library: FakeLibrary([Presets.builtIn[0], narrow]))
        let row = try #require(model.rows.last)

        #expect(model.problem(of: row.id) == "Lookslike width must be 640 to 3840.")
        model.update(row.id) { $0.name = "Mine" }
        #expect(!model.canSave)

        model.update(row.id) { $0.lookslike = "1000x800" }
        #expect(model.problem(of: row.id) == nil)
        #expect(model.canSave)
    }

    /// The commands use the built-ins then, and a save replaces the file.
    @Test func aBrokenFileIsSaidAndCanBeReplaced() {
        let model = PresetsEditorModel(library: FakeLibrary(problem: "presets.json isn't valid"))

        #expect(names(model) == Presets.builtIn.map(\.name))
        #expect(model.notices == [
            "presets.json isn't valid, so these are the built-in presets. Saving keeps a copy of the file and replaces it.",
        ])
        #expect(model.canSave, "Saving the built-ins is how the file gets fixed from here")
    }

    @Test func aBrokenClientsFileIsSaid() {
        let model = PresetsEditorModel(library: FakeLibrary(clientsProblem: "clients.json can't be read"))

        #expect(model.notices == ["clients.json can't be read, so a rename here won't change its clients."])
    }

    // MARK: Adding and moving

    @Test func addGoesAfterTheSelectedOneWithAFreeName() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        try select("MacBook 14 Sharpest", in: model)

        model.add()
        model.add()

        #expect(Array(names(model)[2...4]) == ["MacBook 14 Sharpest", "New Preset", "New Preset 2"])
        #expect(selectedName(model) == "New Preset 2")
        let added = try #require(model.rows.first { $0.name == "New Preset" })
        #expect(added.lookslike == "1728x1080" && added.hidpi && added.hz == "60")
        #expect(added.savedName == nil)
        #expect(model.hasChanges)
        #expect(model.footnote == "Unsaved changes")
    }

    @Test func addWithNothingSelectedGoesAtTheEnd() {
        let model = PresetsEditorModel(library: FakeLibrary())
        model.selection = nil

        model.add()

        #expect(names(model).last == "New Preset")
        #expect(selectedName(model) == "New Preset")
    }

    @Test func moveTakesTheSelectionAlong() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        try select("1080p Screen", in: model)
        #expect(!model.canMoveDown)

        model.moveSelectedUp()
        model.moveSelectedUp()

        #expect(Array(names(model).suffix(3)) == ["1080p Screen", "4K Screen", "1440p Screen"])
        #expect(selectedName(model) == "1080p Screen")
        #expect(model.canMoveDown)

        try select("MacBook 14", in: model)
        #expect(!model.canMoveUp)
        model.moveSelectedUp()
        #expect(names(model).first == "MacBook 14")
    }

    @Test func movingBackLeavesNothingToSave() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        try select("4K Screen", in: model)

        model.moveSelectedDown()
        #expect(model.hasChanges)
        model.moveSelectedUp()

        #expect(!model.hasChanges)
    }

    // MARK: Rules

    @Test(arguments: [
        ("", "60", "A preset needs a name."),
        ("auto", "60", "The name auto is kept for -preset=auto."),
        ("MACBOOK 14", "60", "Another preset is called MacBook 14."),
        ("Mine", "sixty", "Hz must be a whole number."),
        ("Mine", "+60", "Hz must be a whole number."),
        ("Mine", "300", "Hz must be 24 to 240."),
    ])
    func eachRuleSaysWhy(name: String, hz: String, why: String) throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        let id = try #require(model.rows.last?.id)

        model.update(id) {
            $0.name = name
            $0.hz = hz
        }

        #expect(model.problem(of: id) == why)
        #expect(!model.canSave)
        model.save()
        #expect((model.library as? FakeLibrary)?.saves.isEmpty == true)
    }

    @Test func bothPresetsWithOneNameAreMarked() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        let first = try #require(model.rows.first?.id)
        let last = try #require(model.rows.last?.id)

        model.update(last) { $0.name = " macbook 14 " }

        #expect(model.problem(of: first) == "Another preset is called macbook 14.")
        #expect(model.problem(of: last) == "Another preset is called MacBook 14.")
    }

    @Test(arguments: [("big", "Lookslike must be a size such as 1728x1080."), ("1728x100", "Lookslike height must be 360 to 2400.")])
    func theSizeGetsTheSessionLimits(lookslike: String, why: String) throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        let id = try #require(model.rows.first?.id)

        model.update(id) { $0.lookslike = lookslike }

        #expect(model.problem(of: id) == why)
    }

    @Test func pixelsFollowTheSizeAndHiDPI() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        let id = try #require(model.rows.first?.id)
        #expect(model.pixels(of: id) == "3456x2160")

        model.update(id) { $0.hidpi = false }
        #expect(model.pixels(of: id) == "1728x1080")

        model.update(id) { $0.lookslike = "big" }
        #expect(model.pixels(of: id) == nil)

        // Doubling this would overflow, which must not crash.
        model.update(id) {
            $0.lookslike = "9000000000000000000x1080"
            $0.hidpi = true
        }
        #expect(model.pixels(of: id) == nil)
    }

    // MARK: Saving

    @Test func saveSendsTheListAsTheFileHasIt() throws {
        let library = FakeLibrary()
        let model = PresetsEditorModel(library: library)
        model.selection = nil
        model.add()
        let id = try #require(model.selection)
        model.update(id) {
            $0.name = "  Office  "
            $0.lookslike = " 1600x1000 "
            $0.hidpi = false
            $0.hz = "75"
        }

        model.save()

        let saved = try #require(library.saves.first)
        #expect(saved.presets == Presets.builtIn + [Preset(name: "Office", lookslike: "1600x1000", hidpi: false, hz: 75)])
        #expect(saved.renames.isEmpty, "A new preset isn't a rename")
        #expect(model.footnote == "Saved.")
        #expect(!model.hasChanges)
        #expect(selectedName(model) == "Office", "The selection stays on the preset it was on")
    }

    @Test func aChangedNameIsSentAsARename() throws {
        let library = FakeLibrary()
        let model = PresetsEditorModel(library: library)
        let id = model.rows[1].id

        model.update(id) { $0.name = "MacBook 120" }
        model.save()

        #expect(library.saves.first?.renames == [PresetRename(from: "MacBook 14 120 Hz", to: "MacBook 120")])

        // Saved under its new name now, so the next rename starts from there.
        let again = try #require(model.rows.first { $0.name == "MacBook 120" })
        #expect(again.savedName == "MacBook 120")
        model.update(again.id) { $0.name = "MacBook Fast" }
        model.save()
        #expect(library.saves.last?.renames == [PresetRename(from: "MacBook 120", to: "MacBook Fast")])
    }

    /// Both at once, so their clients trade too.
    @Test func twoPresetsCanTradeNames() throws {
        let library = FakeLibrary()
        let model = PresetsEditorModel(library: library)
        let first = try #require(model.rows.first { $0.name == "4K Screen" }).id
        let second = try #require(model.rows.first { $0.name == "1080p Screen" }).id

        model.update(first) { $0.name = "1080p Screen" }
        #expect(!model.canSave)
        model.update(second) { $0.name = "4K Screen" }
        model.save()

        #expect(library.saves.first?.renames == [
            PresetRename(from: "4K Screen", to: "1080p Screen"),
            PresetRename(from: "1080p Screen", to: "4K Screen"),
        ])
    }

    /// A broken file kept aside, a marker that couldn't be written, or clients that couldn't follow: shown
    /// instead of a plain "Saved."
    @Test func whatTheSaveHasToSayIsShown() {
        let library = FakeLibrary()
        library.notes = [
            "The old presets.json couldn't be used, so a copy is kept beside it as presets.json.corrupt-1.",
            "Couldn't write presets-version, so the next read may add MacBook 14 120 Hz back.",
        ]
        let model = PresetsEditorModel(library: library)
        model.moveSelectedDown()

        model.save()

        #expect(model.footnote == "Saved. The old presets.json couldn't be used, so a copy is kept beside it as "
            + "presets.json.corrupt-1. Couldn't write presets-version, so the next read may add MacBook 14 120 Hz back.")
        #expect(model.footnoteNeedsAttention)
        #expect(!model.hasChanges)
    }

    @Test func aFailedSaveKeepsTheChanges() {
        let library = FakeLibrary()
        library.failure = PresetSaveFailure(reason: "can't write presets.json: The disk is full.")
        let model = PresetsEditorModel(library: library)
        model.moveSelectedDown()

        model.save()

        #expect(model.footnote == "Not saved: can't write presets.json: The disk is full.")
        #expect(model.footnoteNeedsAttention)
        #expect(model.hasChanges)
        #expect(model.rows.first?.name == "MacBook 14 120 Hz")
    }

    @Test func anEditAfterASaveClearsTheSavedLine() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        model.moveSelectedDown()
        model.save()
        #expect(model.footnote == "Saved.")
        #expect(!model.footnoteNeedsAttention)

        model.moveSelectedUp()

        #expect(model.footnote == "Unsaved changes")
        #expect(!model.footnoteNeedsAttention)
    }

    // MARK: Deleting

    @Test func aPresetNoClientUsesGoesAtOnce() throws {
        let model = PresetsEditorModel(library: FakeLibrary(clients: [macBookClient]))
        try select("4K Screen", in: model)

        model.deleteSelected()

        #expect(model.question == nil)
        #expect(!names(model).contains("4K Screen"))
        #expect(selectedName(model) == "1440p Screen", "The next one is selected")
    }

    @Test func deletingTheLastSelectsTheOneBefore() throws {
        let model = PresetsEditorModel(library: FakeLibrary())
        try select("1080p Screen", in: model)

        model.deleteSelected()

        #expect(selectedName(model) == "1440p Screen")
    }

    @Test func aPresetAClientUsesAsksFirst() throws {
        let model = PresetsEditorModel(library: FakeLibrary(clients: [macBookClient]))
        try select("MacBook 14 120 Hz", in: model)

        model.deleteSelected()

        let question = try #require(model.question)
        #expect(question.title == "Delete MacBook 14 120 Hz?")
        #expect(question.message == "Client MacBook uses it. Once it's deleted and saved, sessions from MacBook get the default size.")
        #expect(names(model).contains("MacBook 14 120 Hz"), "Nothing goes before the answer")

        model.cancelDelete()
        #expect(model.question == nil)
        #expect(names(model).contains("MacBook 14 120 Hz"))

        model.deleteSelected()
        let asked = try #require(model.question)
        // The alert may clear the question as it closes, before or after its button's action runs.
        model.cancelDelete()
        model.confirmDelete(asked)
        #expect(model.question == nil)
        #expect(!names(model).contains("MacBook 14 120 Hz"))
        model.save()
        #expect(model.library.savedPresets().presets.count == 6)
    }

    @Test func twoClientsAreBothNamed() throws {
        let model = PresetsEditorModel(library: FakeLibrary(clients: [macBookClient, iPadClient]))
        try select("MacBook 14 120 Hz", in: model)

        model.deleteSelected()

        #expect(model.question?.message
            == "Clients MacBook and iPad use it. Once it's deleted and saved, sessions from them get the default size.")
    }

    /// A client set with the CLI while the window is open counts too.
    @Test func theQuestionReadsTheClientsAgain() throws {
        let library = FakeLibrary()
        let model = PresetsEditorModel(library: library)
        try select("MacBook 14 120 Hz", in: model)
        library.clients = SavedClients(clients: [macBookClient])

        model.deleteSelected()

        #expect(model.question != nil)
    }

    // MARK: Used by

    /// The clients follow a rename on save, so they still count before it.
    @Test func usedByFollowsAnUnsavedRename() throws {
        let model = PresetsEditorModel(library: FakeLibrary(clients: [macBookClient, iPadClient]))
        let id = model.rows[1].id

        model.update(id) { $0.name = "MacBook 120" }

        #expect(model.clientNames(of: id) == ["MacBook", "iPad"])
        #expect(model.rows.allSatisfy { $0.id == id || model.clientNames(of: $0.id).isEmpty })
    }

    /// A client whose preset isn't saved gets a new preset by that name.
    @Test func aNewPresetCanBeTheOneAClientNames() throws {
        let tablet = ClientRule(name: "Tablet", address: "192.168.0.10", preset: "iPad")
        let model = PresetsEditorModel(library: FakeLibrary(clients: [tablet]))

        model.add()
        let id = try #require(model.selection)
        #expect(model.clientNames(of: id).isEmpty)
        model.update(id) { $0.name = "ipad" }

        #expect(model.clientNames(of: id) == ["Tablet"])
    }

    // MARK: Opening again

    @Test func reopeningKeepsUnsavedChanges() throws {
        let library = FakeLibrary()
        let model = PresetsEditorModel(library: library)
        model.moveSelectedDown()
        library.presets = SavedPresets(presets: [Presets.builtIn[0]])
        library.clients = SavedClients(clients: [macBookClient])

        model.reloadIfUnchanged()

        #expect(model.rows.count == 7)
        #expect(model.hasChanges)
        let macBook120 = try #require(model.rows.first { $0.name == "MacBook 14 120 Hz" })
        #expect(model.clientNames(of: macBook120.id) == ["MacBook"], "The clients are read again")

        model.revert()
        #expect(names(model) == ["MacBook 14"])
        #expect(!model.hasChanges)
    }

    @Test func reopeningWithNoChangesReadsTheFilesAgain() {
        let library = FakeLibrary()
        let model = PresetsEditorModel(library: library)
        library.presets = SavedPresets(presets: [Presets.builtIn[0]])

        model.reloadIfUnchanged()

        #expect(names(model) == ["MacBook 14"])
    }
}
