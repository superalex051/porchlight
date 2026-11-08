import ADModel
import Foundation

/// What a command writes to each stream, and the code it exits with.
public struct RenderedOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum OutputFormatter {
    public static func render(_ result: CommandResult, options: CLIOptions) -> RenderedOutput {
        options.json ? renderJSON(result) : renderText(result)
    }

    private static func renderText(_ result: CommandResult) -> RenderedOutput {
        var stderr = ""
        if let warning = result.warning, !warning.isEmpty {
            stderr += "warning: \(warning)\n"
        }

        guard result.ok else {
            if let reason = result.reason, !reason.isEmpty {
                stderr += "Failed. \(reason)\n"
            } else {
                stderr += "Failed.\n"
            }
            return RenderedOutput(stdout: "", stderr: stderr, exitCode: 1)
        }

        var stdout = ""
        if let payload = result.payload, !payload.isEmpty {
            stdout = "\(payload)\n"
        }
        return RenderedOutput(stdout: stdout, stderr: stderr, exitCode: 0)
    }

    /// One line on stdout, nothing on stderr. Written by hand because `CommandResult`'s synthesized
    /// `Codable` omits nil keys, and the envelope always carries all five, in this order.
    private static func renderJSON(_ result: CommandResult) -> RenderedOutput {
        let fields: [(key: String, value: JSONValue)] = [
            ("ok", .bool(result.ok)),
            ("payload", result.payload.map(JSONValue.string) ?? .null),
            ("reason", result.reason.map(JSONValue.string) ?? .null),
            ("warning", result.warning.map(JSONValue.string) ?? .null),
            ("json", result.json ?? .null),
        ]
        let body = fields.map { "\"\($0.key)\":\(jsonText($0.value))" }.joined(separator: ",")
        return RenderedOutput(stdout: "{\(body)}\n", stderr: "", exitCode: result.ok ? 0 : 1)
    }

    private static func jsonText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // NaN and infinity have no JSON form. Null keeps the envelope parsable.
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
