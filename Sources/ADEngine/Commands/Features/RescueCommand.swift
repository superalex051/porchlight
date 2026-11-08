import ADModel

extension CommandDispatcher {
    /// What the CLI's `rescue`, Reconnect All and the emergency hotkey call. A success means the monitors
    /// are back, because on a failure the CLI runs the restore helper. It takes no parameters and ignores
    /// any it's given, because a refusal here would make the CLI kill an app that could have helped.
    func runRescue() async throws -> CommandResult {
        let outcome = try await session.rescue()
        return .success(warning: outcome.warning)
    }
}
