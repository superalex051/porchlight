import Foundation

/// Where everything lives on disk. The app, the CLI and the guardian all build this,
/// so they agree on the ledger and the sockets.
public struct ADPaths: Sendable {
    public var stateDirectory: URL
    public var logsDirectory: URL
    public var ledger, devices, presets, restoreLock, appLock: URL
    /// The per-device sizes, `clients.json`, beside `presets.json`.
    public var clients: URL
    /// Parsec's own log, read only, for the address of the device that connected. `AD_PARSEC_LOG` puts a
    /// fixture in its place for a dry run.
    public var parsecLog: URL
    /// Parsec's own settings, read only, for the screen size the connecting client reported.
    /// `AD_PARSEC_CONFIG` puts a fixture in its place for a dry run.
    public var parsecConfig: URL
    public var socketPath, guardianSocketPath: String

    /// `sun_path` holds 104 bytes on macOS, including the terminating NUL.
    private static let maxSocketPathBytes = 103

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // An empty override counts as unset, so it can't resolve to the current directory.
        func override(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }

        // Not read from HOME: every process has to find the same ledger, however it was launched.
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(component: "Library", directoryHint: .isDirectory)

        let state = override("AD_STATE_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? library
                .appending(component: "Application Support", directoryHint: .isDirectory)
                .appending(component: "PorchLight", directoryHint: .isDirectory)

        stateDirectory = state
        logsDirectory = library
            .appending(component: "Logs", directoryHint: .isDirectory)
            .appending(component: "PorchLight", directoryHint: .isDirectory)
        ledger = state.appending(component: "safety.json", directoryHint: .notDirectory)
        devices = state.appending(component: "devices.json", directoryHint: .notDirectory)
        presets = state.appending(component: "presets.json", directoryHint: .notDirectory)
        restoreLock = state.appending(component: "restore.lock", directoryHint: .notDirectory)
        appLock = state.appending(component: "app.lock", directoryHint: .notDirectory)
        clients = state.appending(component: "clients.json", directoryHint: .notDirectory)
        let parsec = FileManager.default.homeDirectoryForCurrentUser
            .appending(component: ".parsec", directoryHint: .isDirectory)
        parsecLog = override("AD_PARSEC_LOG").map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? parsec.appending(component: "log.txt", directoryHint: .notDirectory)
        parsecConfig = override("AD_PARSEC_CONFIG").map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? parsec.appending(component: "config.json", directoryHint: .notDirectory)

        // A path that's too long moves to the temp directory, under a name derived from all of it,
        // so two state directories can't share a socket. It's standardized first because
        // `$AD_STATE_DIR/guardian.sock` has a doubled slash when the variable ends in one, and both
        // ends of a socket must get the same answer.
        func bindable(_ socket: URL) -> String {
            let path = socket.standardizedFileURL.path
            func fits(_ candidate: String) -> Bool { candidate.utf8.count <= Self.maxSocketPathBytes }
            guard !fits(path) else { return path }

            let temp = URL(fileURLWithPath: override("TMPDIR") ?? NSTemporaryDirectory(), isDirectory: true).path
            let stem = "PorchLight.\(Self.stableHash(path))"
            // The hash alone identifies the socket, so the file name is the first thing to give way.
            // /tmp is only reached with a TMPDIR over 70 bytes, and this name always fits there.
            let candidates = ["\(temp)/\(stem).\(socket.lastPathComponent)", "\(temp)/\(stem)"]
            return candidates.first(where: fits) ?? "/tmp/\(stem)"
        }

        // AD_SOCKET_PATH moves only the control socket. The guardian's always follows the state directory.
        socketPath = bindable(
            override("AD_SOCKET_PATH").map { URL(fileURLWithPath: $0, isDirectory: false) }
                ?? state.appending(component: "ctl.sock", directoryHint: .notDirectory)
        )
        guardianSocketPath = bindable(state.appending(component: "guardian.sock", directoryHint: .notDirectory))
    }

    /// Creates the state directory if needed, and forces its mode to 0700 even if it already existed.
    public func ensureStateDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }

    /// 64-bit FNV-1a in fixed-width hex. Not `hashValue`, which is seeded per process:
    /// the guardian and the CLI have to arrive at the same name.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
