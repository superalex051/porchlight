import ADModel
import Foundation
import Testing

@testable import ADEngine

/// Reading the client's screen size out of Parsec's config, `~/.parsec/config.json`, in a temp folder.
@Suite struct ParsecConfigTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(component: "ADEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func size(_ text: String) -> ScreenSize? {
        ParsecConfig.reportedSize(in: Data(text.utf8))
    }

    @Test func theRealShape() {
        #expect(ParsecConfig.reportedSize(in: Data(ParsecFixture.config((w: 2622, h: 1206)).utf8)) == ScreenSize(w: 2622, h: 1206))
        #expect(ParsecConfig.reportedSize(in: Data(ParsecFixture.config((w: 1206, h: 2622)).utf8)) == ScreenSize(w: 1206, h: 2622))
    }

    /// The fixture really is in the file's shape: a comment, then an object of `{"value": ...}` entries.
    @Test func theFixtureHasTheRealShape() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(ParsecFixture.config((w: 2622, h: 1206)).utf8))
        guard case .array(let items) = json, items.count == 2, case .string = items[0], case .object(let object) = items[1]
        else {
            Issue.record("not an array of a comment and an object: \(json)")
            return
        }
        #expect(object["server_resolution_x"] == .object(["value": .number(2622)]))
        #expect(object["host_name"] == .object(["value": .string("Fixture Mac")]))
    }

    @Test func aPlainObjectAndBareValuesToo() {
        #expect(size(#"{"server_resolution_x": 2360, "server_resolution_y": 1640}"#) == ScreenSize(w: 2360, h: 1640))
        #expect(size(#"{"server_resolution_x": {"value": 2360}, "server_resolution_y": 1640}"#) == ScreenSize(w: 2360, h: 1640))
        #expect(size(#"{"server_resolution_x": 2360.0, "server_resolution_y": 1640}"#) == ScreenSize(w: 2360, h: 1640))
    }

    /// The keys may sit in different objects of the array, as long as each is there once.
    @Test func keysInSeparateObjects() {
        let text = #"["c", {"server_resolution_x": {"value": 3024}}, {"server_resolution_y": {"value": 1964}}]"#
        #expect(size(text) == ScreenSize(w: 3024, h: 1964))
    }

    @Test func missingKeysAreNoSize() {
        #expect(ParsecConfig.reportedSize(in: Data(ParsecFixture.config(nil).utf8)) == nil)
        #expect(size(#"["c", {"server_resolution_x": {"value": 2622}}]"#) == nil)
        #expect(size(#"["c", {"server_resolution_y": {"value": 1206}}]"#) == nil)
        #expect(size(#"["c", {"server_resolution_x": {}, "server_resolution_y": {"value": 1206}}]"#) == nil)
        #expect(size("[]") == nil)
        #expect(size("{}") == nil)
    }

    @Test(arguments: [
        #""2622""#, "0", "-2622", "2622.5", "true", "null", "100001", "1e300", #"{"value": "2622"}"#, "[2622]",
    ])
    func aValueThatIsntASideIsNoSize(_ value: String) {
        #expect(size(#"["c", {"server_resolution_x": {"value": 1206}, "server_resolution_y": \#(value)}]"#) == nil)
        #expect(size(#"["c", {"server_resolution_x": \#(value), "server_resolution_y": {"value": 1206}}]"#) == nil)
    }

    @Test(arguments: ["", "not json", #"["c", {"server_resolution_x": {"value": 2622}"#, "2622", #""text""#])
    func textThatIsntTheConfigIsNoSize(_ text: String) {
        #expect(size(text) == nil)
    }

    @Test func readGivesTheSizeAndWhenItWasSaved() throws {
        let url = try folder().appending(component: "config.json")
        let saved = Date(timeIntervalSince1970: 1_793_212_713)
        try ParsecFixture.writeConfig((w: 2622, h: 1206), savedAt: saved, to: url)

        #expect(try ParsecConfig.read(url) == ParsecConfigReading(size: ScreenSize(w: 2622, h: 1206), saved: saved))
    }

    @Test func readFollowsALink() throws {
        let folder = try folder()
        let url = folder.appending(component: "config.json")
        let link = folder.appending(component: "link.json")
        try ParsecFixture.writeConfig((w: 2360, h: 1640), savedAt: Date(timeIntervalSince1970: 1_793_212_713), to: url)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)

        #expect(try ParsecConfig.read(link).size == ScreenSize(w: 2360, h: 1640))
    }

    @Test func aMissingFileCantBeRead() throws {
        let url = try folder().appending(component: "config.json")

        #expect(throws: ParsecConfig.Unreadable()) { try ParsecConfig.read(url) }
    }

    @Test func aFolderCantBeRead() throws {
        let url = try folder()

        #expect(throws: ParsecConfig.Unreadable()) { try ParsecConfig.read(url) }
    }

    /// Opened without blocking, so the test would hang here rather than fail if that broke.
    @Test func aFIFOCantBeReadAndDoesntBlock() throws {
        let url = try folder().appending(component: "config.json")
        #expect(mkfifo(url.path(percentEncoded: false), 0o600) == 0)

        #expect(throws: ParsecConfig.Unreadable()) { try ParsecConfig.read(url) }
    }

    @Test func aFileTooBigToBeTheConfigCantBeRead() throws {
        let url = try folder().appending(component: "config.json")
        try Data(repeating: UInt8(ascii: " "), count: ParsecConfig.largestFile + 1).write(to: url)

        #expect(throws: ParsecConfig.Unreadable()) { try ParsecConfig.read(url) }
    }

    @Test func aFileWithNoSizeStillHasItsDate() throws {
        let url = try folder().appending(component: "config.json")
        let saved = Date(timeIntervalSince1970: 1_793_212_713)
        try ParsecFixture.writeConfig(nil, savedAt: saved, to: url)

        #expect(try ParsecConfig.read(url) == ParsecConfigReading(size: nil, saved: saved))
    }
}
