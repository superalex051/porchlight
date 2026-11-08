import ADModel
import Darwin
import Foundation

/// Parsec's config file at one moment: the screen size the last client reported, and when the file was
/// last written.
nonisolated struct ParsecConfigReading: Equatable, Sendable {
    /// `server_resolution_x` by `server_resolution_y`, or nil if either is missing or isn't a size.
    var size: ScreenSize?
    var saved: Date
}

/// Reads `~/.parsec/config.json`, read only. Parsec writes it as an array: a comment string, then one
/// object whose keys each hold `{"value": ...}`. A client sends its screen size when it connects, and
/// Parsec saves it there as `server_resolution_x` and `server_resolution_y`, in pixels, in the client's
/// orientation. It doesn't always write the file again when the size hasn't changed, and it also
/// writes it at moments that have nothing to do with a client, so the file's date says only when it
/// was last written.
nonisolated enum ParsecConfig {
    static let widthKey = "server_resolution_x"
    static let heightKey = "server_resolution_y"
    /// The real file is under a kilobyte. A file bigger than this isn't Parsec's config.
    static let largestFile = 64 * 1024
    /// A side bigger than this isn't a screen, and could overflow the arithmetic.
    static let largestSide = 100_000

    struct Unreadable: Error, Equatable {}

    /// The size and the file's date. Throws for a missing file, one that isn't a regular file, or one
    /// that can't be read. Opened without blocking and checked once open, because this runs on the main
    /// actor and a FIFO or a device in its place could block a plain open or read.
    static func read(_ url: URL) throws -> ParsecConfigReading {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Unreadable() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= largestFile else {
            throw Unreadable()
        }
        let data: Data
        do {
            data = try handle.read(upToCount: largestFile + 1) ?? Data()
        } catch {
            throw Unreadable()
        }
        let modified = info.st_mtimespec
        return ParsecConfigReading(
            size: reportedSize(in: data),
            saved: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000)
        )
    }

    /// The client's size from the file's text, or nil. Takes Parsec's shape, an array holding an object,
    /// and a plain object too, and each value either as `{"value": 2622}` or as `2622`.
    static func reportedSize(in data: Data) -> ScreenSize? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let objects: [[String: JSONValue]] =
            switch json {
            case .object(let object): [object]
            case .array(let items): items.compactMap { if case .object(let object) = $0 { object } else { nil } }
            default: []
            }
        guard let w = side(widthKey, in: objects), let h = side(heightKey, in: objects) else { return nil }
        return ScreenSize(w: w, h: h)
    }

    /// The first object's value for `key`, if it's a whole number from 1 to `largestSide`.
    private static func side(_ key: String, in objects: [[String: JSONValue]]) -> Int? {
        guard let entry = objects.lazy.compactMap({ $0[key] }).first else { return nil }
        let value: JSONValue =
            if case .object(let wrapped) = entry, let inner = wrapped["value"] { inner } else { entry }
        guard case .number(let number) = value, number == number.rounded(), number >= 1, number <= Double(largestSide)
        else { return nil }
        return Int(number)
    }
}
