import ADFoundation
import ADModel
import ADVirtualScreens
import Foundation

/// A screen made with `create`: everything it takes to make it again.
nonisolated public struct VirtualScreenDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var looksLike: ScreenSize
    public var hiDPI: Bool
    public var hz: Int
    public var useResolutionList: Bool
    /// The sizes the screen may switch between. Only one is offered to macOS at a time, because a
    /// `VirtualScreenSpec` is one mode.
    public var resolutionList: [ScreenSize]
    /// False once `set -connected=off` has released it. It stays defined, and stays off at launch.
    public var connected: Bool

    public init(
        name: String,
        looksLike: ScreenSize = ScreenSize(w: 1920, h: 1080),
        hiDPI: Bool = true,
        hz: Int = 60,
        useResolutionList: Bool = false,
        resolutionList: [ScreenSize] = [],
        connected: Bool = true
    ) {
        self.name = name
        self.looksLike = looksLike
        self.hiDPI = hiDPI
        self.hz = hz
        self.useResolutionList = useResolutionList
        self.resolutionList = resolutionList
        self.connected = connected
    }

    /// Names compare without regard to case.
    var key: String { name.lowercased() }

    /// The serial comes from the name, so a screen keeps its UUID. The prefix can't be in a client name,
    /// so a screen named like a client doesn't get that client's UUID.
    var spec: VirtualScreenSpec {
        VirtualScreenSpec(
            name: name,
            serial: VirtualScreenSpec.forClient("screen:\(name)", looksLike: looksLike, hiDPI: hiDPI, hz: hz).serial,
            looksLike: looksLike,
            hiDPI: hiDPI,
            hz: hz
        )
    }

    /// Why this can't be a screen, or nil if it can. The limits are the session's.
    var problem: String? {
        if useResolutionList, resolutionList.isEmpty { return "useResolutionList needs a resolutionList" }
        for size in resolutionList + [looksLike] {
            if let reason = SessionLimits.validate(looksLike: size, hz: hz) { return reason }
        }
        return nil
    }
}

/// `virtual-screens.json`, for the screens made with `create`. It's a file of its own because the
/// registry rewrites `devices.json` whole. It's read at each call and only written by the dispatcher.
///
/// A file that isn't valid is renamed to `virtual-screens.json.corrupt-<UUID>`, logged, and starts empty.
/// A file that can't be read at all may be fine, so that throws, and nothing replaces it.
nonisolated public final class VirtualScreenStore: Sendable {
    private static let schemaVersion = 1

    private struct Document: Codable {
        var schemaVersion: Int
        var screens: [VirtualScreenDefinition]
    }

    private let url: URL
    private let log: @Sendable (String) -> Void

    /// `directory` is the state directory.
    public init(directory: URL, log: @escaping @Sendable (String) -> Void) {
        url = directory.appending(component: "virtual-screens.json", directoryHint: .notDirectory)
        self.log = log
    }

    public func definitions() throws -> [VirtualScreenDefinition] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }

        if let document = try? JSONDecoder().decode(Document.self, from: data),
            document.schemaVersion == Self.schemaVersion
        {
            return document.screens
        }

        let kept = url.deletingLastPathComponent()
            .appending(component: "\(url.lastPathComponent).corrupt-\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try FileManager.default.moveItem(at: url, to: kept)
            log("\(url.lastPathComponent) isn't valid, so it starts empty. The old file is at \(kept.path)")
        } catch {
            // The next save replaces it, so the only thing lost is the copy to look at later.
            log("\(url.lastPathComponent) isn't valid and couldn't be renamed: \(error.localizedDescription)")
        }
        return []
    }

    public func save(_ definitions: [VirtualScreenDefinition]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFile.write(encoder.encode(Document(schemaVersion: Self.schemaVersion, screens: definitions)), to: url)
    }
}
