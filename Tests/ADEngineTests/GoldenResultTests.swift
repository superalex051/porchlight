import ADCommand
import ADDisplays
import ADModel
import Foundation
import Testing

@testable import ADEngine

private struct CorpusRow: Decodable {
    let argv: [String]
    let stdout: String
    let stderr: String
    let exit: Int32
}

@MainActor
@Suite struct GoldenResultTests {
    private func corpus() throws -> [CorpusRow] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ADEngineTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/Golden/cli.json")
        let rows = try JSONDecoder().decode([CorpusRow].self, from: Data(contentsOf: url))
        // A shorter corpus would let the loop pass while checking too little.
        try #require(rows.count >= 17)
        return rows
    }

    /// The placeholders stand for what the simulator lists, so this reads them from there.
    private func filledIn(_ argv: [String], on simulated: SimulatedDisplayBackend) throws -> [String] {
        let online = simulated.topology().online
        let lgUUID = try #require(online.first { $0.identity.productName == "27GL850" }?.identity.uuid)
        let m34UUID = try #require(online.first { $0.identity.productName == "M34WQ" }?.identity.uuid)
        return argv.map {
            $0.replacingOccurrences(of: "<LG>", with: lgUUID).replacingOccurrences(of: "<M34>", with: m34UUID)
        }
    }

    @Test func goldenResultsMatch() async throws {
        for row in try corpus() {
            let rig = try DispatcherRig()

            let output = try await rig.run(try filledIn(row.argv, on: rig.rig.simulated))

            let wanted = RenderedOutput(stdout: row.stdout, stderr: row.stderr, exitCode: row.exit)
            #expect(output == wanted, "\(row.argv)")
        }
    }

    @Test func theMultiKeyRowIsInTheLoop() throws {
        let row = try #require(try corpus().first { $0.argv.contains("-main") && $0.argv.contains("-connected") })

        #expect(row.stdout == "true,on\n")
    }

    /// What `parsec-mode` logs today. The registry path has to come out the same as the others.
    @Test func getConnectedOfDisconnectedByUUIDIsOff() async throws {
        let rig = try DispatcherRig()
        try rig.rig.registry.update(from: rig.rig.simulated.topology())
        try rig.rig.simulated.setEnabled(m34, false)

        let output = try await rig.run("get", "-UUID=\(m34UUID)", "-connected")

        #expect(output == RenderedOutput(stdout: "off\n", stderr: "", exitCode: 0))
    }
}
