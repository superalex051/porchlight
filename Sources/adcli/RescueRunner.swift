import ADFoundation
import Darwin
import Foundation

/// What the restore helper left, for the CLI to report.
enum HelperOutcome: Equatable {
    /// The monitors are back. These came back but not at their recorded mode.
    case restored(notAtRecordedMode: [String])
    case failed
}

/// Runs `porchlight-guardian restore`, the way out when the app can't help.
struct RescueRunner: RescueRunning {
    /// Longer than the restorer's own worst case, the same limit as the guardian's. A stuck helper is
    /// stopped, by SIGKILL if it has to be, because it would otherwise hold `restore.lock` and block
    /// every later restore.
    private static let helperLimit = 180.0
    private static let killGrace = 5.0

    private let helperPath: String?
    private let retryDelay: Double

    /// `retryDelay` is for tests.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String? = Self.currentExecutablePath(),
        retryDelay: Double = 1
    ) {
        helperPath = Self.helperPath(environment: environment, executablePath: executablePath)
        self.retryDelay = retryDelay
    }

    /// Named, because whoever reads this may be remote, with dark monitors, and needs to know what to fix.
    var helperProblem: String? {
        guard let helperPath else { return "the restore helper can't be found, set AD_GUARDIAN_PATH" }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return "the restore helper is missing: \(helperPath)"
        }
        return nil
    }

    /// Exit 3 means every display is back but one isn't at its recorded mode, and the helper that ran
    /// may never see that display's modes, because it started with the monitor off. So it runs once
    /// more, a fresh process that can. Either way the monitors are on, so a second run that still
    /// reports a mode not restored, or fails, is still a success, with the names for a warning.
    func runRestoreHelper() async -> HelperOutcome {
        guard let helperPath, let first = await runOnce(helperPath) else { return .failed }
        switch first.status {
        case RestoreHelperExit.restored:
            return .restored(notAtRecordedMode: first.outputLines)
        case RestoreHelperExit.modesNotRestored:
            break
        default:
            return .failed
        }

        try? await Task.sleep(for: .seconds(retryDelay))
        let second = await runOnce(helperPath)
        switch second?.status {
        case RestoreHelperExit.restored, RestoreHelperExit.modesNotRestored:
            return .restored(notAtRecordedMode: second?.outputLines ?? [])
        default:
            return .restored(notAtRecordedMode: first.outputLines)
        }
    }

    /// Nil if the helper couldn't start.
    private func runOnce(_ helperPath: String) async -> BoundedProcess.Completion? {
        await withCheckedContinuation { continuation in
            // Its own queue, because the wait blocks a thread for as long as the restore takes.
            DispatchQueue(label: "com.alexluncan.PorchLight.cli.restore", qos: .userInitiated).async {
                let completion = try? BoundedProcess.runCapturingOutput(
                    path: helperPath,
                    arguments: ["restore"],
                    limit: Self.helperLimit,
                    atLimit: .stop(killGrace: Self.killGrace)
                )
                continuation.resume(returning: completion)
            }
        }
    }

    /// `AD_GUARDIAN_PATH` if set, otherwise `porchlight-guardian` beside the real executable. Symlinks
    /// are resolved first, because the CLI is run through a link in `~/.local/bin` and the helper
    /// sits next to the original inside the app.
    static func helperPath(environment: [String: String], executablePath: String?) -> String? {
        if let override = environment["AD_GUARDIAN_PATH"], !override.isEmpty { return override }
        guard let executablePath, let resolved = realpath(executablePath, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
            .deletingLastPathComponent()
            .appending(component: "porchlight-guardian", directoryHint: .notDirectory)
            .path
    }

    /// Not `argv[0]`, which is whatever the caller typed, and may be a bare name found through `PATH`.
    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
