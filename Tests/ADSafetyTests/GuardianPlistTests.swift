import Foundation
import Testing

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // ADSafetyTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repo

@Test func plistIsValidAndHasRequiredKeys() throws {
    let url = repo.appending(path: "Config/com.alexluncan.PorchLight.guardian.plist")
    let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    let plist = try #require(parsed as? [String: Any])
    let log = "__HOME__/Library/Logs/PorchLight/guardian.log"

    #expect(plist["Label"] as? String == "com.alexluncan.PorchLight.guardian")
    #expect(
        plist["ProgramArguments"] as? [String] == ["/Applications/PorchLight.app/Contents/Helpers/porchlight-guardian"]
    )
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(plist["ThrottleInterval"] as? Int == 5)
    #expect(plist["StandardOutPath"] as? String == log)
    #expect(plist["StandardErrorPath"] as? String == log)
    #expect(plist.count == 8, "Every key launchd sees is one of the keys above")
}

/// The module each import in `source` names. `import` can follow any attribute or access level, and
/// can name a kind and a symbol, as in `import struct Module.Symbol`.
private func importedModules(in source: String) -> [String] {
    let accessLevels: Set<Substring> = ["public", "package", "internal", "fileprivate", "private"]
    return source.split(separator: "\n").compactMap { line in
        let words = line.split(whereSeparator: \.isWhitespace)
        guard let keyword = words.firstIndex(of: "import"), keyword < words.count - 1,
            words[..<keyword].allSatisfy({ $0.hasPrefix("@") || accessLevels.contains($0) })
        else { return nil }
        return words[words.count - 1].split(separator: ".").first.map(String.init)
    }
}

@Test func theImportCheckSeesEveryFormOfImport() {
    let source = """
        import Foundation
        @preconcurrency import CoreGraphics
        internal import ADDisplays
        public import ADDisplayConfig
        package import ADSPI
        @preconcurrency public import AppKit
        import struct ColorSync.ColorSyncProfile
            import IOKit.pwr_mgt
        // import CommentedOut
        /// Says to import Nothing here.
        let importantThing = 1
        #if canImport(Something)
        #endif
        """

    #expect(
        importedModules(in: source) == [
            "Foundation", "CoreGraphics", "ADDisplays", "ADDisplayConfig", "ADSPI", "AppKit", "ColorSync", "IOKit",
        ]
    )
}

/// By path, because by bundle ID LaunchServices can pick a stale copy in a `build/` folder or a
/// worktree. The seam is in an executable target that this test can't link, and running it would start
/// the real app, so this reads the source.
@Test func guardianRelaunchesTheInstalledAppByPath() throws {
    let source = try String(
        contentsOf: repo.appending(path: "Sources/adguardian/LiveGuardianSeams.swift"),
        encoding: .utf8
    )

    #expect(source.contains(#"path: "/usr/bin/open""#))
    #expect(source.contains(#"arguments: ["-g", "-a", "/Applications/PorchLight.app"]"#))
    #expect(!source.contains(#""-b""#))
}

/// The notification's text comes from `GuardianAlert`, the same place as the alert window's, so the two
/// can't drift apart. `GuardianAlertTests` checks the words.
@Test func guardianNotificationTakesItsTextFromGuardianAlert() throws {
    let source = try String(
        contentsOf: repo.appending(path: "Sources/adguardian/LiveGuardianSeams.swift"),
        encoding: .utf8
    )
    #expect(source.contains(#""display notification \"\(GuardianAlert.notification)\"""#))
    #expect(!source.contains("needs attention"))
}

/// The spec keeps CoreGraphics out of the watching loop, so a CoreGraphics assertion can't kill the
/// supervisor. Only `RestoreCommand.swift` may name the display modules.
@Test(arguments: ["main.swift", "LiveGuardianSeams.swift"])
func watchingPathImportsNoDisplayCode(file: String) throws {
    let source = try String(contentsOf: repo.appending(path: "Sources/adguardian/\(file)"), encoding: .utf8)
    let imports = importedModules(in: source)

    #expect(!imports.isEmpty)
    for module in ["ADDisplays", "ADDisplayConfig", "ADSPI", "CoreGraphics", "AppKit"] {
        #expect(!imports.contains(module), "\(file) imports \(module)")
    }
}
