// The whole engine on a simulated copy of this Mac, for trying a flow without touching a real display.
// It refuses to start unless it's a complete dry run, before it builds anything.
import ADEngine
import AppKit

let environment = ProcessInfo.processInfo.environment

func say(_ line: String) {
    FileHandle.standardError.write(Data("addevhost: \(line)\n".utf8))
}

if let refusal = EngineRuntime.dryRunRefusal(in: environment) {
    say("refusing to start: \(refusal)")
    exit(2)
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate {
    private var runtime: EngineRuntime?
    private var signalSources: [any DispatchSourceSignal] = []
    private var isStopping = false

    /// Not earlier: the engine has to start with the application running, as it does in the app.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = EngineRuntime(environment: environment, safeMode: false)
        self.runtime = runtime
        stop(on: SIGTERM)
        stop(on: SIGINT)
        Task {
            do {
                try await runtime.start()
                say("ready, in a dry run")
            } catch EngineRuntimeError.alreadyRunning {
                say("couldn't start: another host is using this state directory")
                exit(1)
            } catch {
                // Not the error's own words, which can include a path from the environment.
                say("couldn't start: the state directory, its lock or the socket can't be set up")
                exit(1)
            }
        }
    }

    private func stop(on signalNumber: Int32) {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.shutDownAndExit() }
        }
        source.activate()
        signalSources.append(source)
    }

    private func shutDownAndExit() {
        guard !isStopping else { return }
        isStopping = true
        Task {
            await runtime?.shutdown()
            say("stopped")
            exit(0)
        }
    }
}

let delegate = HostDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
