import ADCommand
import ADModel
import Foundation
import Testing

private struct CorpusRow: Decodable {
    let argv: [String]
    let operations: [String]
    let parameters: [[String?]]
    let stdout: String
    let stderr: String
    let exit: Int32
}

private func loadCorpus() throws -> [CorpusRow] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ADCommandTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures/Golden/cli.json")
    let rows = try JSONDecoder().decode([CorpusRow].self, from: Data(contentsOf: url))
    // Every row of the spec's table, with `<display>` expanded to both monitors.
    // A shorter corpus would let the loops below pass while checking too little.
    try #require(rows.count >= 17)
    return rows
}

@Test func goldenRequestsParse() throws {
    for row in try loadCorpus() {
        let expected = try row.parameters.map { pair in
            try #require(pair.count == 2, "\(row.argv)")
            return CommandParameter(name: try #require(pair[0], "\(row.argv)"), value: pair[1])
        }

        let (request, options) = try CommandParser.parse(row.argv)

        #expect(request.operations == row.operations, "\(row.argv)")
        #expect(request.parameters == expected, "\(row.argv)")
        #expect(options == CLIOptions(), "\(row.argv)")
    }
}

// Task 14 asserts byte equality against these fields, so they must be bytes the formatter can emit.
@Test func goldenOutputsMatchTheFormatter() throws {
    for row in try loadCorpus() {
        let payload = row.stdout.isEmpty ? nil : String(row.stdout.dropLast())
        let result: CommandResult = row.exit == 0 ? .success(payload) : .failure()

        let rendered = OutputFormatter.render(result, options: CLIOptions())

        #expect(rendered == RenderedOutput(stdout: row.stdout, stderr: row.stderr, exitCode: row.exit), "\(row.argv)")
    }
}

@Test func goldenKeepsTheMultiKeyRow() throws {
    let row = try #require(try loadCorpus().first { $0.argv == ["get", "-UUID=<LG>", "-main", "-connected"] })

    #expect(row.stdout == "true,on\n")
    #expect(row.stderr == "")
    #expect(row.exit == 0)
}

// Consumers replace only these two, so any other placeholder would reach the engine as a literal.
@Test func goldenUsesOnlyTheKnownPlaceholders() throws {
    for row in try loadCorpus() {
        let text = row.argv.joined(separator: " ")
            .replacingOccurrences(of: "<LG>", with: "")
            .replacingOccurrences(of: "<M34>", with: "")
        #expect(!text.contains("<"), "\(row.argv)")
    }
}
