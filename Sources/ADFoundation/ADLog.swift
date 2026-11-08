import Darwin
import Foundation
import os

public enum ADLog {
    private static let subsystem = "com.alexluncan.PorchLight"

    /// Local time with its UTC offset, and milliseconds because the guardian ticks every 250 ms.
    private static let timestampStyle = Date.ISO8601FormatStyle(
        timeZoneSeparator: .colon,
        includingFractionalSeconds: true,
        timeZone: .current
    )

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Appends one timestamped line, creating the file and its directory if needed. Never throws,
    /// because a logging failure must not stop a rescue. The line goes out in one write to an
    /// `O_APPEND` descriptor, so lines from different processes don't interleave.
    public static func appendLine(_ line: String, to url: URL) {
        let text = "\(Date().formatted(timestampStyle)) \(line)\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard file >= 0 else { return }
        defer { close(file) }
        try? writeAll(Data(text.utf8), to: file)
    }
}
