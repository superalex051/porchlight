import ADSafety
import Testing

private let testPath = "/tmp/some-test-state"

// MARK: - Restore

@Test func aPlainEnvironmentRestoresForReal() {
    #expect(GuardianEnvironment([:]).restoreMode == .live)
    #expect(GuardianEnvironment(["HOME": "/Users/someone"]).restoreMode == .live)
}

@Test(arguments: ["AD_STATE_DIR", "AD_SOCKET_PATH"])
func anOverrideWithoutADryRunIsRefused(name: String) {
    guard case .refused = GuardianEnvironment([name: testPath]).restoreMode else {
        Issue.record("\(name) alone has to refuse a live restore")
        return
    }
}

@Test func bothOverridesWithoutADryRunAreRefused() {
    let environment = GuardianEnvironment(["AD_STATE_DIR": testPath, "AD_SOCKET_PATH": testPath])
    guard case .refused = environment.restoreMode else {
        Issue.record("Both overrides have to refuse a live restore")
        return
    }
}

/// Whoever set the flag didn't want a live restore, whatever they typed.
@Test(arguments: ["0", "true", "yes", "2", " 1"])
func aDryRunFlagThatIsNotOneIsRefused(value: String) {
    for extra in [[:], ["AD_STATE_DIR": testPath]] {
        let environment = GuardianEnvironment(extra.merging(["AD_DRY_RUN": value]) { $1 })
        guard case .refused = environment.restoreMode else {
            Issue.record("AD_DRY_RUN with another value has to refuse a live restore")
            continue
        }
    }
}

@Test func aDryRunIsAllowedWithOrWithoutOverrides() {
    #expect(GuardianEnvironment(["AD_DRY_RUN": "1"]).restoreMode == .dryRun)
    #expect(GuardianEnvironment(["AD_DRY_RUN": "1", "AD_STATE_DIR": testPath]).restoreMode == .dryRun)
    #expect(GuardianEnvironment(["AD_DRY_RUN": "1", "AD_SOCKET_PATH": testPath]).restoreMode == .dryRun)
}

@Test func anEmptyVariableCountsAsUnset() {
    let environment = GuardianEnvironment(["AD_DRY_RUN": "", "AD_STATE_DIR": "", "AD_SOCKET_PATH": ""])

    #expect(environment.restoreMode == .live, "The same rule as ADPaths, which ignores them too")
    #expect(environment.isRealRun)
    #expect(environment.watchRefusal == nil)
}

@Test func aRefusalNamesTheVariablesAndNotTheirValues() {
    guard case .refused(let why) = GuardianEnvironment(["AD_STATE_DIR": testPath]).restoreMode else {
        Issue.record("Expected a refusal")
        return
    }

    #expect(why.contains("AD_DRY_RUN=1"))
    #expect(why.contains("AD_STATE_DIR"))
    #expect(!why.contains(testPath))
}

// MARK: - Watching

@Test func aPlainEnvironmentWatchesForReal() {
    let environment = GuardianEnvironment([:])

    #expect(environment.watchRefusal == nil)
    #expect(environment.isRealRun)
}

@Test func aTestStateDirectoryCanBeWatchedButIsNotARealRun() {
    for extra in [[:], ["AD_DRY_RUN": "1"], ["AD_SOCKET_PATH": testPath]] {
        let environment = GuardianEnvironment(extra.merging(["AD_STATE_DIR": testPath]) { $1 })

        #expect(environment.watchRefusal == nil)
        #expect(!environment.isRealRun, "A test setup must not start the real app or post a notification")
    }
}

/// These would watch the real ledger, where a decision can send `SIGKILL` to the real app.
@Test(arguments: [
    ["AD_DRY_RUN": "1"],
    ["AD_DRY_RUN": "true"],
    ["AD_SOCKET_PATH": testPath],
])
func aTestSettingWithoutAStateDirectoryMustNotWatch(environment: [String: String]) {
    let parsed = GuardianEnvironment(environment)

    #expect(parsed.watchRefusal != nil)
    #expect(!parsed.isRealRun)
}
