import ADModel

/// An argument the parser can't turn into a request. `reason` reads well after `Failed. `.
public struct CommandParseError: Error, Equatable {
    public let reason: String
    /// The valid options found anywhere in argv, so a `--json` caller still gets an envelope.
    public let options: CLIOptions

    public init(reason: String, options: CLIOptions = CLIOptions()) {
        self.reason = reason
        self.options = options
    }
}

public enum CommandParser {
    /// One day. A huge finite value would trap later, in `Duration.seconds` or an `Int` conversion.
    private static let maxTimeoutSeconds = 86400

    /// Parses the arguments after the program name.
    ///
    /// Bare words are operations. `-x`, `--x`, `-x=v` and `--x=v` are parameters, in the order given
    /// and with duplicates kept. Known names become their registered spelling, and unknown names stay
    /// verbatim so the engine can answer `Failed.`. Values are not percent-decoded.
    ///
    /// `--json`, `--no-launch` and `--timeout=<seconds>` become `CLIOptions`.
    ///
    /// - Throws: `CommandParseError` for a malformed argument or a bad option value, so a mistyped
    ///   option stops the command before anything reaches the engine. It names the first problem
    ///   and carries the valid options from all of argv.
    public static func parse(_ argv: [String]) throws -> (CommandRequest, CLIOptions) {
        var request = CommandRequest(operations: [])
        var options = CLIOptions()
        var firstProblem: CommandParseError?

        // A bad argument doesn't stop the scan, so the error can carry a `--json` that comes after it.
        for argument in argv {
            do {
                try apply(argument, to: &request, options: &options)
            } catch {
                firstProblem = firstProblem ?? error
            }
        }

        if let firstProblem {
            throw CommandParseError(reason: firstProblem.reason, options: options)
        }
        return (request, options)
    }

    private static func apply(
        _ argument: String,
        to request: inout CommandRequest,
        options: inout CLIOptions
    ) throws(CommandParseError) {
        guard argument.hasPrefix("-") else {
            guard !argument.isEmpty else { throw malformed(argument) }
            request.operations.append(argument)
            return
        }

        let isDoubleHyphen = argument.hasPrefix("--")
        let body = argument.dropFirst(isDoubleHyphen ? 2 : 1)
        let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : nil
        guard !name.isEmpty, !name.hasPrefix("-") else { throw malformed(argument) }

        if isDoubleHyphen, try applyOption(name: name, value: value, to: &options) {
            return
        }
        request.parameters.append(CommandParameter(name: FeatureRegistry.canonical(name) ?? name, value: value))
    }

    /// Returns true if `name` is a CLI option, which is applied here and isn't kept as a parameter.
    private static func applyOption(
        name: String,
        value: String?,
        to options: inout CLIOptions
    ) throws(CommandParseError) -> Bool {
        switch name.lowercased() {
        case "json":
            guard value == nil else { throw CommandParseError(reason: "--json takes no value") }
            options.json = true
        case "no-launch":
            guard value == nil else { throw CommandParseError(reason: "--no-launch takes no value") }
            options.noLaunch = true
        case "timeout":
            // Double() also accepts "nan" and "inf". Both fail these comparisons.
            guard let value, let seconds = Double(value), seconds > 0, seconds <= Double(maxTimeoutSeconds) else {
                throw CommandParseError(reason: "--timeout needs a positive number of seconds, at most \(maxTimeoutSeconds)")
            }
            options.timeout = seconds
        default:
            return false
        }
        return true
    }

    private static func malformed(_ argument: String) -> CommandParseError {
        CommandParseError(reason: "invalid argument '\(argument)'")
    }
}
