import Foundation

/// What the environment lets `adguardian` do. `AD_STATE_DIR`, `AD_SOCKET_PATH` and `AD_DRY_RUN` only
/// mean a test setup, and a process under one must not reach the real displays, the real app or the
/// real ledger. An empty variable counts as unset, the same as in `ADPaths`.
public struct GuardianEnvironment: Sendable, Equatable {
    public enum RestoreMode: Sendable, Equatable {
        case live
        case dryRun
        case refused(String)
    }

    /// The only way to a live restore is `.live`. A test bundle's mutation guard doesn't reach a
    /// spawned `adguardian`, so this is what stands between a test setup and the monitors.
    public let restoreMode: RestoreMode
    /// Why watching must not start, or nil if it may. Without `AD_STATE_DIR` a test setup would be
    /// watching the real ledger, where a decision can send `SIGKILL` to the real app.
    public let watchRefusal: String?
    /// False under any test setup, which must not start the real app, post a notification or write
    /// to the real log.
    public let isRealRun: Bool

    public init(_ environment: [String: String]) {
        func isSet(_ name: String) -> Bool { environment[name]?.isEmpty == false }

        let flagged = isSet("AD_DRY_RUN")
        let overridden = isSet("AD_STATE_DIR") || isSet("AD_SOCKET_PATH")

        if environment["AD_DRY_RUN"] == "1" {
            restoreMode = .dryRun
        } else if flagged {
            restoreMode = .refused("refusing a live restore: AD_DRY_RUN is set to something other than 1")
        } else if overridden {
            restoreMode = .refused("refusing a live restore: AD_STATE_DIR or AD_SOCKET_PATH is set without AD_DRY_RUN=1")
        } else {
            restoreMode = .live
        }

        isRealRun = !flagged && !overridden
        watchRefusal = !isRealRun && !isSet("AD_STATE_DIR")
            ? "refusing to watch the real ledger: AD_DRY_RUN or AD_SOCKET_PATH is set without AD_STATE_DIR"
            : nil
    }
}
