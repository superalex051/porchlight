import ADCommand
import ADModel
import Testing

// Plain `import`, not `@testable`, so these tests also prove the public surface later tasks use.

private func request(
    _ operations: [String],
    _ parameters: [(String, String?)]
) -> CommandRequest {
    CommandRequest(
        operations: operations,
        parameters: parameters.map { CommandParameter(name: $0.0, value: $0.1) }
    )
}

@Test func parsesSingleAndDoubleHyphen() throws {
    let expected = request(["get"], [("UUID", "x"), ("main", nil)])

    let (single, _) = try CommandParser.parse(["get", "-UUID=x", "-main"])
    let (double, _) = try CommandParser.parse(["get", "--UUID=x", "--main"])

    #expect(single == expected)
    #expect(double == expected)
}

@Test func parsesCaseInsensitiveNames() throws {
    let (parsed, _) = try CommandParser.parse(["get", "-uuid=x", "-MAIN", "-hidpi=off"])

    #expect(parsed == request(["get"], [("UUID", "x"), ("main", nil), ("hiDPI", "off")]))
}

@Test func parsesAliasN() throws {
    let (lower, _) = try CommandParser.parse(["get", "-n=M34", "-main"])
    let (upper, _) = try CommandParser.parse(["get", "--N=M34", "-main"])

    let expected = request(["get"], [("nameLike", "M34"), ("main", nil)])
    #expect(lower == expected)
    #expect(upper == expected)
}

@Test func keepsParameterOrderAndDuplicates() throws {
    let (parsed, _) = try CommandParser.parse([
        "session", "start", "-ownerpid=5", "-client=parsec", "-ownerpid=6",
    ])

    #expect(
        parsed.parameters == [
            CommandParameter(name: "ownerpid", value: "5"),
            CommandParameter(name: "client", value: "parsec"),
            CommandParameter(name: "ownerpid", value: "6"),
        ]
    )
}

@Test func parsesSessionStart() throws {
    let (parsed, options) = try CommandParser.parse([
        "session", "start", "-client=parsec", "-lookslike=1728x1080", "-ownerpid=5",
    ])

    #expect(
        parsed == request(
            ["session", "start"],
            [("client", "parsec"), ("lookslike", "1728x1080"), ("ownerpid", "5")]
        )
    )
    #expect(options == CLIOptions())
}

@Test func extractsCLIOptions() throws {
    let (parsed, options) = try CommandParser.parse([
        "--json", "get", "--no-launch", "-main", "--timeout=2.5",
    ])

    #expect(parsed == request(["get"], [("main", nil)]))
    #expect(options == CLIOptions(json: true, noLaunch: true, timeout: 2.5))
}

@Test func optionsDefaultToOff() throws {
    let (_, options) = try CommandParser.parse(["get", "-main"])

    #expect(options.json == false)
    #expect(options.noLaunch == false)
    #expect(options.timeout == nil)
}

@Test func optionNamesAreCaseInsensitive() throws {
    let (parsed, options) = try CommandParser.parse(["get", "--JSON", "--No-Launch", "--TIMEOUT=3"])

    #expect(parsed.parameters.isEmpty)
    #expect(options == CLIOptions(json: true, noLaunch: true, timeout: 3))
}

@Test func lastTimeoutWins() throws {
    let (_, options) = try CommandParser.parse(["get", "--timeout=3", "--timeout=9"])

    #expect(options.timeout == 9)
}

// The spec spells these with two hyphens. One hyphen is an unknown parameter, which the engine refuses.
@Test func singleHyphenOptionStaysAParameter() throws {
    let (parsed, options) = try CommandParser.parse(["get", "-json", "-no-launch", "-timeout=3"])

    #expect(parsed == request(["get"], [("json", nil), ("no-launch", nil), ("timeout", "3")]))
    #expect(options == CLIOptions())
}

@Test func unknownNameKeptVerbatim() throws {
    let (parsed, _) = try CommandParser.parse(["get", "-UUID=x", "-NonExistentFeatureXYZ=1", "--AlsoUnknown"])

    #expect(
        parsed == request(
            ["get"],
            [("UUID", "x"), ("NonExistentFeatureXYZ", "1"), ("AlsoUnknown", nil)]
        )
    )
}

@Test func forceStaysAParameter() throws {
    let (parsed, options) = try CommandParser.parse(["discard", "--force"])

    #expect(parsed == request(["discard"], [("force", nil)]))
    #expect(options == CLIOptions())
}

@Test func valueSplitsOnTheFirstEqualsSignOnly() throws {
    let (parsed, _) = try CommandParser.parse(["session", "end", "-reason=a=b=c"])

    #expect(parsed.parameters == [CommandParameter(name: "reason", value: "a=b=c")])
}

@Test func valueMayStartWithAHyphen() throws {
    let (parsed, _) = try CommandParser.parse(["set", "-placement=-446x1440"])

    #expect(parsed.parameters == [CommandParameter(name: "placement", value: "-446x1440")])
}

@Test func emptyValueIsNotAMissingValue() throws {
    let (parsed, _) = try CommandParser.parse(["set", "-virtualScreenName="])

    #expect(parsed.parameters == [CommandParameter(name: "virtualScreenName", value: "")])
}

@Test func argvIsNotPercentDecoded() throws {
    let (parsed, _) = try CommandParser.parse(["get", "-name=LG%2027GL850", "-main"])

    #expect(parsed.parameters.first == CommandParameter(name: "name", value: "LG%2027GL850"))
}

@Test func emptyArgvIsAnEmptyRequest() throws {
    let (parsed, options) = try CommandParser.parse([])

    #expect(parsed == CommandRequest(operations: []))
    #expect(options == CLIOptions())
}

private let badTimeoutReason = "--timeout needs a positive number of seconds, at most 86400"

@Test(arguments: [
    "--timeout", "--timeout=", "--timeout=abc", "--timeout=0", "--timeout=-1", "--timeout=nan", "--timeout=inf",
    "--timeout=1e308", "--timeout=86401",
])
func rejectsBadTimeout(argument: String) {
    #expect(throws: CommandParseError(reason: badTimeoutReason)) {
        try CommandParser.parse(["get", argument])
    }
}

@Test func acceptsTheLargestTimeout() throws {
    let (_, options) = try CommandParser.parse(["get", "--timeout=86400"])

    #expect(options.timeout == 86400)
}

@Test(arguments: [
    ["--json", "session", "start", "--timeout=abc"],
    ["session", "start", "--timeout=abc", "--json"],
])
func parseErrorKeepsJSONFromEitherSide(argv: [String]) {
    #expect(throws: CommandParseError(reason: badTimeoutReason, options: CLIOptions(json: true))) {
        try CommandParser.parse(argv)
    }
}

@Test func parseErrorKeepsEveryValidOption() {
    let expected = CommandParseError(
        reason: "invalid argument '-'",
        options: CLIOptions(json: true, noLaunch: true, timeout: 5)
    )

    #expect(throws: expected) {
        try CommandParser.parse(["--timeout=5", "--no-launch", "-", "--json"])
    }
}

@Test func parseErrorReportsTheFirstProblem() {
    #expect(throws: CommandParseError(reason: "invalid argument '-'")) {
        try CommandParser.parse(["-", "--timeout=abc", "--json=true"])
    }
}

// The reason a parse error carries `options`: the caller asked for JSON, so stdout must not be empty.
@Test func parseFailureRendersAsAnEnvelopeForAJSONCaller() throws {
    do {
        _ = try CommandParser.parse(["session", "start", "--timeout=abc", "--json"])
        Issue.record("expected a parse error")
    } catch let error as CommandParseError {
        let output = OutputFormatter.render(.failure(error.reason), options: error.options)

        #expect(
            output.stdout
                == #"{"ok":false,"payload":null,"reason":"# + "\"\(badTimeoutReason)\""
                + #","warning":null,"json":null}"# + "\n"
        )
        #expect(output.stderr == "")
        #expect(output.exitCode == 1)
    }
}

@Test(arguments: [("--json=true", "--json"), ("--no-launch=off", "--no-launch")])
func rejectsValueOnAFlag(argument: String, flag: String) {
    #expect(throws: CommandParseError(reason: "\(flag) takes no value")) {
        try CommandParser.parse(["get", argument])
    }
}

@Test(arguments: ["", "-", "--", "-=v", "--=v", "---x"])
func rejectsMalformedArgument(argument: String) {
    #expect(throws: CommandParseError(reason: "invalid argument '\(argument)'")) {
        try CommandParser.parse(["get", argument])
    }
}
