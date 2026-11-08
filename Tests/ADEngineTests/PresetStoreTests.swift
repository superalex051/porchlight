import ADFoundation
import ADModel
import Foundation
import Testing

@testable import ADEngine

private func presetsURL() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(component: "presets.json", directoryHint: .notDirectory)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func markerURL(beside url: URL) -> URL {
    url.deletingLastPathComponent().appending(component: "presets-version", directoryHint: .notDirectory)
}

/// What the marker says, or nil with no marker.
private func marker(beside url: URL) -> String? {
    (try? String(contentsOf: markerURL(beside: url), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A file that has had the 120 Hz upgrade, so a test about something else isn't changed by it.
private func markUpgraded(_ url: URL) throws {
    try write("2\n", to: markerURL(beside: url))
}

private func decoded(_ url: URL) throws -> [Preset] {
    try JSONDecoder().decode([Preset].self, from: Data(contentsOf: url))
}

private let macBook120 = Preset(name: "MacBook 14 120 Hz", lookslike: "1728x1080", hidpi: true, hz: 120)

/// A file from before the 120 Hz preset: the six sizes the first builds wrote, in their format.
private let sixBefore = """
    [
      {
        "hidpi" : true,
        "hz" : 60,
        "lookslike" : "1728x1080",
        "name" : "MacBook 14"
      },
      {
        "hidpi" : true,
        "hz" : 60,
        "lookslike" : "1512x945",
        "name" : "MacBook 14 Sharpest"
      },
      {
        "hidpi" : true,
        "hz" : 60,
        "lookslike" : "1920x1200",
        "name" : "MacBook 14 More Room"
      },
      {
        "hidpi" : true,
        "hz" : 60,
        "lookslike" : "1920x1080",
        "name" : "4K Screen"
      },
      {
        "hidpi" : false,
        "hz" : 60,
        "lookslike" : "2560x1440",
        "name" : "1440p Screen"
      },
      {
        "hidpi" : false,
        "hz" : 60,
        "lookslike" : "1920x1080",
        "name" : "1080p Screen"
      }
    ]
    """

@Test func writesDefaultsWhenMissing() throws {
    let url = try presetsURL()
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.presets() == Presets.builtIn)

    let written = try JSONDecoder().decode([Preset].self, from: Data(contentsOf: url))
    #expect(written == Presets.builtIn)
    #expect(marker(beside: url) == "2", "The defaults already have the 120 Hz preset")
}

@Test func writesDefaultsEvenWithItsFolderMissing() throws {
    let url = try presetsURL().deletingLastPathComponent()
        .appending(component: "new/presets.json", directoryHint: .notDirectory)
    let store = PresetStore(url: url, log: { _ in })

    _ = store.presets()

    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func anUnwritableFolderStillGivesTheBuiltIns() throws {
    let notAFolder = try presetsURL()
    try write("not a folder", to: notAFolder)
    let lines = Recorder<String>()
    let store = PresetStore(url: notAFolder.appending(component: "presets.json"), log: { lines.append($0) })

    #expect(store.presets() == Presets.builtIn)
    #expect(!lines.values.isEmpty)
}

@Test func readsEditedFileWithoutRestart() throws {
    let url = try presetsURL()
    let store = PresetStore(url: url, log: { _ in })
    #expect(store.preset(named: "Mine") == nil)

    try write(#"[{"name":"Mine","lookslike":"1280x800","hidpi":true,"hz":75}]"#, to: url)

    let mine = Preset(name: "Mine", lookslike: "1280x800", hidpi: true, hz: 75)
    #expect(store.presets() == [mine])
    #expect(store.preset(named: "Mine") == mine)
}

@Test func invalidFileFallsBackAndIsNotOverwritten() throws {
    let url = try presetsURL()
    let garbage = "{ this is not a list"
    try write(garbage, to: url)
    let lines = Recorder<String>()
    let store = PresetStore(url: url, log: { lines.append($0) })

    #expect(store.presets() == Presets.builtIn)

    #expect(try String(contentsOf: url, encoding: .utf8) == garbage)
    #expect(lines.values.count == 1)
    #expect(marker(beside: url) == nil, "Once it's fixed, it still gets the upgrade")
}

@Test func unreadableFileFallsBackAndIsNotOverwritten() throws {
    // A folder at that path reads as an error, and it isn't "missing".
    let url = try presetsURL()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.presets() == Presets.builtIn)

    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder))
    #expect(isFolder.boolValue)
}

@Test func outOfLimitEntrySkipped() throws {
    let url = try presetsURL()
    // The last entry is the point of the order: validating first is what stops `pixels` overflowing.
    try write(
        """
        [
          {"name":"Good","lookslike":"1280x800","hidpi":true,"hz":60},
          {"name":"Too narrow","lookslike":"100x800","hidpi":true,"hz":60},
          {"name":"Too fast","lookslike":"1280x800","hidpi":true,"hz":1000},
          {"name":"Not a size","lookslike":"big","hidpi":true,"hz":60},
          {"name":"Absurd","lookslike":"9000000000000000000x1080","hidpi":true,"hz":60}
        ]
        """,
        to: url
    )
    try markUpgraded(url)
    let lines = Recorder<String>()
    let store = PresetStore(url: url, log: { lines.append($0) })

    #expect(store.presets().map(\.name) == ["Good"])
    #expect(lines.values.count == 4)
    #expect(lines.values.contains { $0.contains("Absurd") })
}

@Test func lookupIsCaseInsensitive() throws {
    let store = PresetStore(url: try presetsURL(), log: { _ in })

    #expect(store.preset(named: "macbook 14 SHARPEST")?.lookslike == "1512x945")
    #expect(store.preset(named: "no such preset") == nil)
}

// MARK: The 120 Hz upgrade

/// The six entries get the new one right after MacBook 14, each of the others as it was, and the
/// marker says the upgrade ran.
@Test func anExistingFileGetsThe120HzPresetAfterMacBook14() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let six = try decoded(url)
    let store = PresetStore(url: url, log: { _ in })

    let presets = store.presets()

    var wanted = six
    wanted.insert(macBook120, at: 1)
    #expect(presets == wanted)
    #expect(presets == Presets.builtIn, "The file had the old defaults, so now it has the new ones")
    #expect(try decoded(url) == wanted)
    #expect(marker(beside: url) == "2")
}

@Test func theUpgradeRunsOnce() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let store = PresetStore(url: url, log: { _ in })
    _ = store.presets()
    let upgraded = try Data(contentsOf: url)

    _ = store.presets()

    #expect(try Data(contentsOf: url) == upgraded, "A second read writes nothing")
    #expect(try decoded(url).filter { $0 == macBook120 }.count == 1)
}

/// Once the upgrade has run, a 120 Hz preset the user deletes stays deleted.
@Test func aDeleted120HzPresetStaysDeleted() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let store = PresetStore(url: url, log: { _ in })
    _ = store.presets()

    try write(sixBefore, to: url)

    #expect(!store.presets().contains(macBook120))
    #expect(try String(contentsOf: url, encoding: .utf8) == sixBefore)
}

@Test func withoutMacBook14ItGoesAtTheEnd() throws {
    let url = try presetsURL()
    try write(#"[{"name":"Mine","lookslike":"1280x800","hidpi":true,"hz":75}]"#, to: url)
    let store = PresetStore(url: url, log: { _ in })

    let mine = Preset(name: "Mine", lookslike: "1280x800", hidpi: true, hz: 75)
    #expect(store.presets() == [mine, macBook120])
    #expect(try decoded(url) == [mine, macBook120])
}

/// Wherever the user moved MacBook 14 to, and in whatever case they wrote it.
@Test func itFollowsMacBook14WhereverItIs() throws {
    let url = try presetsURL()
    try write(
        """
        [
          {"name":"Mine","lookslike":"1280x800","hidpi":true,"hz":75},
          {"name":"macbook 14","lookslike":"1600x1000","hidpi":true,"hz":60},
          {"name":"Last","lookslike":"1920x1080","hidpi":false,"hz":60}
        ]
        """,
        to: url
    )
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.presets().map(\.name) == ["Mine", "macbook 14", "MacBook 14 120 Hz", "Last"])
}

/// A file that already has a preset by that name, in any case, keeps it as it is.
@Test func anExisting120HzPresetIsKept() throws {
    let url = try presetsURL()
    let text = #"[{"name":"MacBook 14","lookslike":"1728x1080","hidpi":true,"hz":60},"#
        + #"{"name":"macbook 14 120 HZ","lookslike":"1512x945","hidpi":true,"hz":120}]"#
    try write(text, to: url)
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.presets().map(\.name) == ["MacBook 14", "macbook 14 120 HZ"])
    #expect(try String(contentsOf: url, encoding: .utf8) == text, "Nothing to add, so nothing is written")
    #expect(marker(beside: url) == "2")
}

/// An entry the store skips when it reads is still the user's, so the upgrade keeps it in the file.
@Test func theUpgradeKeepsSkippedEntriesInTheFile() throws {
    let url = try presetsURL()
    try write(
        """
        [
          {"name":"MacBook 14","lookslike":"1728x1080","hidpi":true,"hz":60},
          {"name":"Too Wide","lookslike":"5000x1000","hidpi":false,"hz":60}
        ]
        """,
        to: url
    )
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.presets().map(\.name) == ["MacBook 14", "MacBook 14 120 Hz"])
    #expect(try decoded(url).map(\.name) == ["MacBook 14", "MacBook 14 120 Hz", "Too Wide"])
}

/// A file that can't be written still gives the new preset, says why, and tries again next time.
@Test func anUnwritableFolderStillGivesThe120HzPreset() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let folder = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    let lines = Recorder<String>()
    let store = PresetStore(url: url, log: { lines.append($0) })

    #expect(store.presets() == Presets.builtIn)

    #expect(try String(contentsOf: url, encoding: .utf8) == sixBefore)
    #expect(marker(beside: url) == nil)
    #expect(lines.values.count == 1)
    #expect(lines.values.first?.hasPrefix("Can't add MacBook 14 120 Hz to presets.json") == true)
}

// MARK: What the presets window reads and saves

/// Every entry, including one the commands skip, so a save from the window never drops one unseen.
@Test func editableKeepsTheEntriesTheCommandsSkip() throws {
    let url = try presetsURL()
    try write(
        """
        [
          {"name":"Good","lookslike":"1280x800","hidpi":true,"hz":60},
          {"name":"Too narrow","lookslike":"100x800","hidpi":true,"hz":60}
        ]
        """,
        to: url
    )
    try markUpgraded(url)
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.editable() == SavedPresets(presets: [
        Preset(name: "Good", lookslike: "1280x800", hidpi: true, hz: 60),
        Preset(name: "Too narrow", lookslike: "100x800", hidpi: true, hz: 60),
    ]))
    #expect(store.presets().map(\.name) == ["Good"])
}

@Test func editableOfAMissingFileIsTheDefaults() throws {
    let url = try presetsURL()
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.editable() == SavedPresets(presets: Presets.builtIn))
    #expect(try decoded(url) == Presets.builtIn)
}

@Test func editableGetsThe120HzUpgrade() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.editable() == SavedPresets(presets: Presets.builtIn))
    #expect(marker(beside: url) == "2")
}

/// The window shows what the commands use, and says why, and the file is left alone until a save.
@Test func editableOfABrokenFileIsTheBuiltInsAndWhy() throws {
    let url = try presetsURL()
    try write("{ this is not a list", to: url)
    let store = PresetStore(url: url, log: { _ in })

    #expect(store.editable() == SavedPresets(presets: Presets.builtIn, problem: "presets.json isn't valid"))
    #expect(try String(contentsOf: url, encoding: .utf8) == "{ this is not a list")

    let folder = try presetsURL()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(PresetStore(url: folder, log: { _ in }).editable().problem == "presets.json can't be read")
}

@Test func saveWritesTheListInTheUsualFormat() throws {
    let url = try presetsURL()
    let store = PresetStore(url: url, log: { _ in })
    let list = [Preset(name: "Mine", lookslike: "1600x1000", hidpi: true, hz: 120), Presets.builtIn[0]]

    #expect(try store.save(list) == [], "Nothing to say besides that it saved")

    #expect(store.presets() == list)
    #expect(try decoded(url) == list)
    #expect(try String(contentsOf: url, encoding: .utf8).contains(#""lookslike" : "1600x1000""#))
}

/// The marker goes to 2 with the save, so the upgrade can't bring back a 120 Hz preset deleted in the
/// window, even in a folder that never had a marker.
@Test func aPresetDeletedInTheWindowStaysDeleted() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let six = try decoded(url)
    let store = PresetStore(url: url, log: { _ in })

    #expect(try store.save(six) == [])

    #expect(marker(beside: url) == "2")
    #expect(store.presets() == six)
}

@Test func saveRefusesAListTheCommandsCouldNotUse() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let store = PresetStore(url: url, log: { _ in })
    let twins = [Presets.builtIn[0], Preset(name: "macbook 14", lookslike: "1512x945", hidpi: true, hz: 60)]

    #expect(throws: PresetSaveFailure(reason: "two presets are called macbook 14")) { try store.save(twins) }
    #expect(throws: PresetSaveFailure(reason: "Wide: lookslike width must be 640 to 3840")) {
        try store.save([Preset(name: "Wide", lookslike: "5000x1000", hidpi: false, hz: 60)])
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == sixBefore)
}

/// A hand edit with a typo isn't lost: a copy is kept beside it, as the other stores keep theirs, and
/// the window says where.
@Test func saveKeepsACopyOfABrokenFile() throws {
    let url = try presetsURL()
    try write("{ this is not a list", to: url)
    let lines = Recorder<String>()
    let store = PresetStore(url: url, log: { lines.append($0) })

    let notes = try store.save(Presets.builtIn)

    #expect(store.editable() == SavedPresets(presets: Presets.builtIn))
    let folder = url.deletingLastPathComponent()
    let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("presets.json.corrupt-") }
    #expect(kept.count == 1)
    let copy = try #require(kept.first)
    #expect(try String(contentsOf: folder.appending(component: copy), encoding: .utf8) == "{ this is not a list")
    #expect(notes == ["The old presets.json couldn't be used, so a copy is kept beside it as \(copy)."])
    #expect(lines.values.contains("presets.json couldn't be used, so a copy is kept as \(copy) before it's replaced"))
}

/// A valid file, even one with an entry the commands skip, is replaced with no copy.
@Test func aValidFileGetsNoCopy() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let store = PresetStore(url: url, log: { _ in })

    #expect(try store.save(Presets.builtIn) == [])

    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(!names.contains { $0.contains("corrupt") })
}

/// With no copy, it isn't replaced.
@Test func aBrokenFileThatCantBeCopiedIsKept() throws {
    let url = try presetsURL()
    try write("{ this is not a list", to: url)
    let folder = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    let store = PresetStore(url: url, log: { _ in })

    do {
        _ = try store.save(Presets.builtIn)
        Issue.record("The save should have failed")
    } catch {
        #expect(error.reason.hasPrefix("presets.json couldn't be used and a copy of it couldn't be kept, so it wasn't replaced: "))
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "{ this is not a list")
}

/// The list is saved, but without the marker the upgrade could add the 120 Hz preset back, so the window
/// says so instead of only "Saved."
@Test func aMarkerThatCantBeWrittenIsSaid() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let six = try decoded(url)
    // A folder where the marker goes: it reads as no marker, and can't be written over.
    try FileManager.default.createDirectory(at: markerURL(beside: url), withIntermediateDirectories: true)
    let lines = Recorder<String>()
    let store = PresetStore(url: url, log: { lines.append($0) })

    let notes = try store.save(six)

    #expect(try decoded(url) == six)
    #expect(notes == ["Couldn't write presets-version, so the next read may add MacBook 14 120 Hz back."])
    #expect(lines.values.contains { $0.hasPrefix("Can't write presets-version") })
}

@Test func aSaveThatCantWriteSaysWhy() throws {
    let url = try presetsURL()
    try write(sixBefore, to: url)
    let folder = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    let store = PresetStore(url: url, log: { _ in })

    do {
        _ = try store.save(Presets.builtIn)
        Issue.record("The save should have failed")
    } catch {
        #expect(error.reason.hasPrefix("can't write presets.json: "))
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == sixBefore)
}
