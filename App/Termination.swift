import AppKit

/// The one way the app asks AppKit to quit, so every path does it the same safe way. `Scripts/lint.sh`
/// fails if anything else in `App/` calls `terminate`.
///
/// AppKit asks `applicationShouldTerminate`, which answers `.terminateLater`, and then spins a nested event
/// loop inside the call until the reply. If the call comes from inside a Swift task, that loop can't run
/// any other main actor job until the task returns, so the end sequence and every command wait forever,
/// and the app hangs. So the call always comes from a plain run loop callback, in the common modes, so an
/// open menu doesn't hold it back.
@MainActor
enum Termination {
    private static var isRequested = false

    /// Returns at once, from anywhere on the main actor. Only the first request does anything, because a
    /// second call while the first is waiting for its reply would nest another loop inside that one.
    static func request() {
        guard !isRequested else { return }
        isRequested = true
        let mainLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        CFRunLoopWakeUp(mainLoop)
    }
}
