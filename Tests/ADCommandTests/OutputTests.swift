import ADCommand
import ADModel
import Foundation
import Testing

// Plain `import`, not `@testable`, so these tests also prove the public surface later tasks use.

private let jsonOptions = CLIOptions(json: true)

private func renderText(_ result: CommandResult) -> RenderedOutput {
    OutputFormatter.render(result, options: CLIOptions())
}

private func decodedEnvelope(_ output: RenderedOutput) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
    return try #require(object as? [String: Any])
}

// MARK: - Text

@Test func renderSuccessPayload() {
    let output = renderText(.success("on"))

    #expect(output == RenderedOutput(stdout: "on\n", stderr: "", exitCode: 0))
}

@Test func renderSuccessEmpty() {
    let output = renderText(.success())

    #expect(output == RenderedOutput(stdout: "", stderr: "", exitCode: 0))
}

// An empty payload counts as absent, like an empty reason or warning, so no blank line is printed.
@Test func renderSuccessEmptyPayloadPrintsNothing() {
    let output = renderText(.success(""))

    #expect(output == RenderedOutput(stdout: "", stderr: "", exitCode: 0))
}

@Test func renderFailurePlain() {
    let output = renderText(.failure())

    #expect(output == RenderedOutput(stdout: "", stderr: "Failed.\n", exitCode: 1))
}

@Test func renderFailureWithReason() {
    let output = renderText(.failure("would leave no working display"))

    #expect(output.stdout == "")
    #expect(output.stderr == "Failed. would leave no working display\n")
    #expect(output.exitCode == 1)
}

// A stray empty reason must not change the exact `Failed.` bytes scripts depend on.
@Test func renderFailureWithEmptyReasonIsPlain() {
    let output = renderText(.failure(""))

    #expect(output.stderr == "Failed.\n")
}

@Test func renderFailureNeverPrintsAPayload() {
    let output = renderText(CommandResult(ok: false, payload: "on"))

    #expect(output == RenderedOutput(stdout: "", stderr: "Failed.\n", exitCode: 1))
}

@Test func renderWarning() {
    let output = renderText(.success("on", warning: "not restored: M34WQ"))

    #expect(output == RenderedOutput(stdout: "on\n", stderr: "warning: not restored: M34WQ\n", exitCode: 0))
}

@Test func renderWarningWithoutPayload() {
    let output = renderText(.success(warning: "not restored: M34WQ"))

    #expect(output == RenderedOutput(stdout: "", stderr: "warning: not restored: M34WQ\n", exitCode: 0))
}

// `Failed.` stays the last line, so a reader of the tail of stderr sees the outcome.
@Test func renderFailureKeepsAWarning() {
    let output = renderText(CommandResult(ok: false, reason: "boom", warning: "not restored: M34WQ"))

    #expect(output.stderr == "warning: not restored: M34WQ\nFailed. boom\n")
    #expect(output.exitCode == 1)
}

// MARK: - JSON

@Test func renderJSONEnvelope() {
    let output = OutputFormatter.render(.success("on"), options: jsonOptions)

    #expect(output.stdout == #"{"ok":true,"payload":"on","reason":null,"warning":null,"json":null}"# + "\n")
    #expect(output.stderr == "")
    #expect(output.exitCode == 0)
}

@Test(arguments: [CommandResult.success(), CommandResult.failure()])
func renderJSONEnvelopeAlwaysHasAllFiveKeys(result: CommandResult) throws {
    let envelope = try decodedEnvelope(OutputFormatter.render(result, options: jsonOptions))

    #expect(Set(envelope.keys) == ["ok", "payload", "reason", "warning", "json"])
    #expect(envelope["ok"] as? Bool == result.ok)
    #expect(envelope["payload"] is NSNull)
    #expect(envelope["reason"] is NSNull)
    #expect(envelope["warning"] is NSNull)
    #expect(envelope["json"] is NSNull)
}

@Test func renderJSONFailure() {
    let output = OutputFormatter.render(.failure("session held by parsec"), options: jsonOptions)

    #expect(
        output.stdout
            == #"{"ok":false,"payload":null,"reason":"session held by parsec","warning":null,"json":null}"# + "\n"
    )
    #expect(output.stderr == "")
    #expect(output.exitCode == 1)
}

@Test func renderJSONWarningStaysInTheEnvelope() throws {
    let output = OutputFormatter.render(.success(warning: "not restored: M34WQ"), options: jsonOptions)

    #expect(try decodedEnvelope(output)["warning"] as? String == "not restored: M34WQ")
    #expect(output.stderr == "")
    #expect(output.exitCode == 0)
}

@Test func renderJSONStructuredValue() {
    let status = JSONValue.object([
        "state": .string("active"),
        "displayID": .number(9),
        "looksLike": .object(["w": .number(1728), "h": .number(1080)]),
        "physicalOff": .array([.number(2), .number(4)]),
    ])

    let output = OutputFormatter.render(.success("state=active", json: status), options: jsonOptions)

    // Key order inside `json` is sorted so the bytes don't change between runs.
    let expectedStatus = #"{"displayID":9,"looksLike":{"h":1080,"w":1728},"physicalOff":[2,4],"state":"active"}"#
    #expect(
        output.stdout
            == #"{"ok":true,"payload":"state=active","reason":null,"warning":null,"json":"# + expectedStatus + "}\n"
    )
}

@Test func renderJSONEscapesThePayload() throws {
    let payload = "{\n  \"registryLocation\" : \"IOService:/a\\b\"\n}"

    let output = OutputFormatter.render(.success(payload), options: jsonOptions)

    #expect(output.stdout.filter { $0 == "\n" }.count == 1)
    #expect(try decodedEnvelope(output)["payload"] as? String == payload)
}

// NaN has no JSON form. The envelope must stay parsable anyway.
@Test func renderJSONKeepsTheEnvelopeValidWhenAValueCannotBeEncoded() throws {
    let result = CommandResult.success("on", json: .array([.number(.nan)]))

    let envelope = try decodedEnvelope(OutputFormatter.render(result, options: jsonOptions))

    #expect(envelope["payload"] as? String == "on")
    #expect(envelope["json"] is NSNull)
}
