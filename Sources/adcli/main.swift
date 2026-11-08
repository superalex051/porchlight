import ADFoundation
import ADIPC
import Foundation

let runner = CLIRunner(
    transport: IPCTransport(client: IPCClient(path: ADPaths().socketPath)),
    launcher: AppLauncher(),
    rescue: RescueRunner()
)
let output = await runner.run(Array(CommandLine.arguments.dropFirst()))
try? FileHandle.standardOutput.write(contentsOf: Data(output.stdout.utf8))
try? FileHandle.standardError.write(contentsOf: Data(output.stderr.utf8))
exit(output.exitCode)
