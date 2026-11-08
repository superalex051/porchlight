/// Flags for the CLI itself. They never reach the engine.
public struct CLIOptions: Sendable, Equatable {
    public var json = false
    public var noLaunch = false
    /// Seconds. Nil means the CLI picks its default for the operation.
    public var timeout: Double?

    public init(json: Bool = false, noLaunch: Bool = false, timeout: Double? = nil) {
        self.json = json
        self.noLaunch = noLaunch
        self.timeout = timeout
    }
}
