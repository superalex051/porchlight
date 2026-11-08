import ADFoundation
import ADModel
import Foundation

/// `clients.json`, which the user can edit by hand or change with the `clients` commands. It's read at each
/// use, so an edit applies without a restart. With no file, there are no clients and every setting has
/// its default, and nothing is written until a command changes something.
nonisolated public final class ClientStore: Sendable {
    /// Why the file can't be used. A file that's there but can't be read or isn't valid is never
    /// written over, so a hand edit with a typo isn't lost.
    struct Unusable: Error, Equatable {
        var reason: String
    }

    public let url: URL
    private let log: @Sendable (String) -> Void

    public init(url: URL, log: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.log = log
    }

    /// What `-preset=auto` goes by: an unusable file is logged and reads as everything off, so a hand
    /// edit with a typo gives the default size rather than settings it didn't mean.
    public func mapping() -> ClientMapping {
        do {
            return try read()
        } catch {
            log("\(error.reason), so size per device is off")
            return .off
        }
    }

    /// For the commands, which refuse to change a file they can't read.
    func read() throws(Unusable) -> ClientMapping {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .empty
        } catch {
            throw Unusable(reason: "\(url.lastPathComponent) can't be read")
        }
        guard let mapping = try? JSONDecoder().decode(ClientMapping.self, from: data) else {
            throw Unusable(reason: "\(url.lastPathComponent) isn't valid")
        }
        return mapping
    }

    /// Replaces the whole file, in the format the `clients` commands write.
    public func write(_ mapping: ClientMapping) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFile.write(encoder.encode(mapping), to: url)
    }
}
