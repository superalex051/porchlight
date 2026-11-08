import Foundation
import MachO

/// Keeps a test run from changing real display state. Live mutators call
/// `preconditionMutationAllowed()` before they touch anything.
/// The guard covers the current process only, so a test must never spawn a helper that can mutate displays.
public enum TestBundleGuard {
    /// Paths that only appear in a process's loaded images when it's running tests. A false positive
    /// would crash the app or the guardian at its first live mutation, including during a rescue. The
    /// leading slashes matter: `RecapPerformanceTesting.framework` loads in real processes.
    private static let testImageMarkers = [".xctest/", "/XCTest.framework/", "/Testing.framework/"]

    public static var isRunningInTestBundle: Bool {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            if isTestImagePath(String(cString: name)) {
                return true
            }
        }
        return false
    }

    static func isTestImagePath(_ path: String) -> Bool {
        testImageMarkers.contains(where: path.contains)
    }

    /// Crashes if this process is a test bundle and `AD_HIL` isn't `1`. Uses `fatalError` rather than
    /// `precondition` so the check stays in at every optimization level.
    public static func preconditionMutationAllowed() {
        let hil = ProcessInfo.processInfo.environment["AD_HIL"]
        guard isMutationAllowed(inTestBundle: isRunningInTestBundle, hil: hil) else {
            fatalError("A test tried to change real display state. Hardware tests are attended and need AD_HIL=1.")
        }
    }

    static func isMutationAllowed(inTestBundle: Bool, hil: String?) -> Bool {
        !inTestBundle || hil == "1"
    }
}
