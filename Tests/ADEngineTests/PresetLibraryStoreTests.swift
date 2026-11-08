import ADFoundation
import ADModel
import Foundation
import Testing

@testable import ADEngine

/// `presets.json` and `clients.json` in a folder of their own, as the presets window saves them.
private struct LibraryRig {
    let folder: URL
    let lines = Recorder<String>()
    let library: PresetLibraryStore

    var presetsURL: URL { folder.appending(component: "presets.json") }
    var clientsURL: URL { folder.appending(component: "clients.json") }

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = lines
        let log: @Sendable (String) -> Void = { lines.append($0) }
        library = PresetLibraryStore(
            presets: PresetStore(url: folder.appending(component: "presets.json"), log: log),
            clients: ClientStore(url: folder.appending(component: "clients.json"), log: log),
            log: log
        )
    }

    func writeClients(_ mapping: ClientMapping) throws {
        try ClientStore(url: clientsURL, log: { _ in }).write(mapping)
    }

    func clients() throws -> ClientMapping {
        try JSONDecoder().decode(ClientMapping.self, from: Data(contentsOf: clientsURL))
    }

    func presets() throws -> [Preset] {
        try JSONDecoder().decode([Preset].self, from: Data(contentsOf: presetsURL))
    }
}

private let macBookClient = ClientRule(name: "MacBook", address: "192.168.0.232", preset: "MacBook 14 120 Hz")
private let iPadClient = ClientRule(name: "iPad", address: "192.168.0.10", preset: "4K Screen")

/// The built-ins with one renamed.
private func builtIns(renaming old: String, to new: String) -> [Preset] {
    Presets.builtIn.map { preset in
        var preset = preset
        if preset.name == old { preset.name = new }
        return preset
    }
}

@Suite struct PresetLibraryStoreTests {
    @Test func aRenameTakesItsClientsAlong() throws {
        let rig = try LibraryRig()
        try rig.writeClients(ClientMapping(autoSize: true, clients: [macBookClient, iPadClient]))
        let list = builtIns(renaming: "MacBook 14 120 Hz", to: "MacBook 120")

        let notes = try rig.library.save(list, renaming: [PresetRename(from: "MacBook 14 120 Hz", to: "MacBook 120")])

        #expect(notes == [])
        #expect(try rig.presets() == list)
        #expect(try rig.clients() == ClientMapping(
            autoSize: true,
            clients: [ClientRule(name: "MacBook", address: "192.168.0.232", preset: "MacBook 120"), iPadClient]
        ))
        #expect(rig.lines.values == [
            "Presets saved from the window: 7 presets",
            "Client MacBook now uses MacBook 120, renamed from MacBook 14 120 Hz",
        ])
    }

    /// Its clients keep its name, so `-preset=auto` gives them the default.
    @Test func aDeleteLeavesItsClientsAsTheyWere() throws {
        let rig = try LibraryRig()
        try rig.writeClients(ClientMapping(autoSize: true, clients: [macBookClient]))
        let before = try Data(contentsOf: rig.clientsURL)
        let list = Presets.builtIn.filter { $0.name != "MacBook 14 120 Hz" }

        #expect(try rig.library.save(list, renaming: []) == [])

        #expect(try rig.presets() == list)
        #expect(try Data(contentsOf: rig.clientsURL) == before)
    }

    @Test func withNoClientsFileNoneIsWritten() throws {
        let rig = try LibraryRig()

        let notes = try rig.library.save(
            builtIns(renaming: "4K Screen", to: "4K"),
            renaming: [PresetRename(from: "4K Screen", to: "4K")]
        )

        #expect(notes == [])
        #expect(!FileManager.default.fileExists(atPath: rig.clientsURL.path))
    }

    /// A hand edit with a typo is never written over. The presets are saved, and the window says so.
    @Test func aBrokenClientsFileIsLeftAloneAndSaid() throws {
        let rig = try LibraryRig()
        let typo = #"{"autoSize": true, "clients": [{"name": "MacBook"}]}"#
        try Data(typo.utf8).write(to: rig.clientsURL)
        let list = builtIns(renaming: "MacBook 14 120 Hz", to: "MacBook 120")

        let notes = try rig.library.save(list, renaming: [PresetRename(from: "MacBook 14 120 Hz", to: "MacBook 120")])

        #expect(notes == ["The clients still name the old presets, because clients.json isn't valid."])
        #expect(try rig.presets() == list)
        #expect(try String(contentsOf: rig.clientsURL, encoding: .utf8) == typo)
    }

    /// The store's notes and the clients' come back together, the presets' first.
    @Test func everyNoteComesBack() throws {
        let rig = try LibraryRig()
        try Data("{ broken".utf8).write(to: rig.presetsURL)
        try Data("not json".utf8).write(to: rig.clientsURL)

        let notes = try rig.library.save(
            builtIns(renaming: "4K Screen", to: "4K"),
            renaming: [PresetRename(from: "4K Screen", to: "4K")]
        )

        #expect(notes.count == 2)
        #expect(notes.first?.hasPrefix("The old presets.json couldn't be used, so a copy is kept beside it as presets.json.corrupt-") == true)
        #expect(notes.last == "The clients still name the old presets, because clients.json isn't valid.")
    }

    /// One preset, one in the words.
    @Test func theLogLineCountsInGoodGrammar() throws {
        let rig = try LibraryRig()

        _ = try rig.library.save([Presets.builtIn[0]], renaming: [])

        #expect(rig.lines.values == ["Presets saved from the window: 1 preset"])
    }

    @Test func aRenameNoClientUsesWritesNoClients() throws {
        let rig = try LibraryRig()
        try rig.writeClients(ClientMapping(autoSize: false, clients: [iPadClient]))
        let before = try Data(contentsOf: rig.clientsURL)

        _ = try rig.library.save(builtIns(renaming: "1080p Screen", to: "1080p"), renaming: [
            PresetRename(from: "1080p Screen", to: "1080p"),
        ])

        #expect(try Data(contentsOf: rig.clientsURL) == before)
    }

    @Test func aRefusedListChangesNothing() throws {
        let rig = try LibraryRig()
        try rig.writeClients(ClientMapping(autoSize: true, clients: [macBookClient]))
        let before = try Data(contentsOf: rig.clientsURL)
        let auto = builtIns(renaming: "MacBook 14 120 Hz", to: "auto")

        #expect(throws: PresetSaveFailure(reason: "auto: the name auto is kept for -preset=auto")) {
            try rig.library.save(auto, renaming: [PresetRename(from: "MacBook 14 120 Hz", to: "auto")])
        }
        #expect(try Data(contentsOf: rig.clientsURL) == before)
        #expect(!FileManager.default.fileExists(atPath: rig.presetsURL.path))
    }

    @Test func itReadsTheClientsOrWhyNot() throws {
        let rig = try LibraryRig()
        #expect(rig.library.savedClients() == SavedClients(clients: []))

        try rig.writeClients(ClientMapping(autoSize: false, clients: [macBookClient]))
        #expect(rig.library.savedClients() == SavedClients(clients: [macBookClient]))

        try Data("not json".utf8).write(to: rig.clientsURL)
        #expect(rig.library.savedClients() == SavedClients(clients: [], problem: "clients.json isn't valid"))
    }

    @Test func itReadsThePresetsAsTheStoreHasThem() throws {
        let rig = try LibraryRig()

        #expect(rig.library.savedPresets() == SavedPresets(presets: Presets.builtIn))
    }
}

/// A save from the window reaches every place a preset is used, the next time it's used.
@MainActor
@Suite struct PresetLibraryCommandTests {
    private func library(_ rig: DispatcherRig) -> PresetLibraryStore {
        PresetLibraryStore(presets: rig.dispatcher.presets, clients: rig.dispatcher.sizer.clients, log: { _ in })
    }

    @Test func aRenamedPresetIsWhatTheCommandsAndTheMappingUse() async throws {
        let rig = try DispatcherRig()
        let set = try await rig.run(
            "clients", "set", "-name=MacBook", "-address=\(ParsecFixture.macBook)", "-preset=MacBook 14 120 Hz"
        )
        #expect(set == .silent)
        #expect(try await rig.run("clients", "auto", "-on") == .silent)

        _ = try library(rig).save(
            builtIns(renaming: "MacBook 14 120 Hz", to: "MacBook 120"),
            renaming: [PresetRename(from: "MacBook 14 120 Hz", to: "MacBook 120")]
        )

        #expect(try await rig.run("clients", "list") == .out(
            "autoSize=on\nmatchClient=on\nclearOfNotch=on\nphoneRoom=4/3\nMacBook: address=192.168.0.232 preset=MacBook 120"
        ))
        let listed = try await rig.result("session", "presets")
        #expect(listed.payload?.contains("MacBook 120: lookslike=1728x1080 pixels=3456x2160 hz=120") == true)
        #expect(listed.payload?.contains("MacBook 14 120 Hz") == false)
        #expect(try await rig.run("session", "start", "-preset=MacBook 14 120 Hz") == .failed("unknown preset: MacBook 14 120 Hz"))

        let now = rig.rig.clock.now()
        try ParsecFixture.write(
            ParsecFixture.connect(at: now.addingTimeInterval(-1)),
            to: rig.rig.folder.appending(component: "parsec-log.txt")
        )
        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)
        #expect(try rig.rig.ledger?.hz == 120)
        #expect(rig.rig.logText.contains("which is client MacBook, so the size is MacBook 120"))
    }

    /// With nothing for it in Parsec's config either, that's the default.
    @Test func aDeletedPresetsClientGetsTheDefault() async throws {
        let rig = try DispatcherRig()
        #expect(try await rig.run(
            "clients", "set", "-name=MacBook", "-address=\(ParsecFixture.macBook)", "-preset=MacBook 14 120 Hz"
        ) == .silent)
        #expect(try await rig.run("clients", "auto", "-on") == .silent)

        _ = try library(rig).save(Presets.builtIn.filter { $0.name != "MacBook 14 120 Hz" }, renaming: [])

        #expect(try await rig.run("clients", "list") == .out(
            "autoSize=on\nmatchClient=on\nclearOfNotch=on\nphoneRoom=4/3\n"
                + "MacBook: address=192.168.0.232 preset=MacBook 14 120 Hz (no such preset)"
        ))
        let now = rig.rig.clock.now()
        try ParsecFixture.write(
            ParsecFixture.connect(at: now.addingTimeInterval(-1)),
            to: rig.rig.folder.appending(component: "parsec-log.txt")
        )
        #expect(try await rig.result("session", "start", "-client=parsec", "-preset=auto").ok)
        #expect(try rig.rig.ledger?.hz == 60)
        #expect(rig.rig.logText.contains(
            "asks for preset MacBook 14 120 Hz, which isn't saved; Parsec's config can't be read, so the size is MacBook 14, the default"
        ))
    }
}
